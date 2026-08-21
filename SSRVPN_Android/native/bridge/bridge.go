// Package bridge exposes the Mihomo lifecycle used by the Android JNI wrapper.
package bridge

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
)

var (
	coreMu               sync.Mutex
	running              bool
	protectRead          *os.File
	protectWrite         *os.File
	protectSessionMu     sync.Mutex
	activeProtectSession *protectSession
	protectStopRequests  atomic.Int32
)

const protectResultTimeout = 5 * time.Second

var (
	errProtectStopped  = errors.New("protect monitor stopped")
	errProtectTimedOut = errors.New("protect monitor timed out")
)

type protectSession struct {
	result     chan bool
	done       chan struct{}
	cancelOnce sync.Once
	requestMu  sync.Mutex
	writer     *os.File
}

func newProtectSession() *protectSession {
	return &protectSession{
		result: make(chan bool),
		done:   make(chan struct{}),
	}
}

func (session *protectSession) wait(timeout time.Duration) (bool, error) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case ok := <-session.result:
		return ok, nil
	case <-session.done:
		return false, errProtectStopped
	case <-timer.C:
		return false, errProtectTimedOut
	}
}

func (session *protectSession) report(ok bool) bool {
	select {
	case session.result <- ok:
		return true
	case <-session.done:
		return false
	}
}

func (session *protectSession) active() bool {
	select {
	case <-session.done:
		return false
	default:
		return true
	}
}

func (session *protectSession) cancel() {
	session.cancelOnce.Do(func() { close(session.done) })
}

func replaceProtectSession(next *protectSession) {
	protectSessionMu.Lock()
	previous := activeProtectSession
	activeProtectSession = next
	protectSessionMu.Unlock()
	if previous != nil && previous != next {
		previous.cancel()
	}
}

func installProtectSession(next *protectSession) bool {
	protectSessionMu.Lock()
	if protectStopRequests.Load() > 0 {
		protectSessionMu.Unlock()
		next.cancel()
		return false
	}
	previous := activeProtectSession
	activeProtectSession = next
	protectSessionMu.Unlock()
	if previous != nil && previous != next {
		previous.cancel()
	}
	return true
}

func currentProtectSession() *protectSession {
	protectSessionMu.Lock()
	defer protectSessionMu.Unlock()
	return activeProtectSession
}

func retireProtectSession(session *protectSession) {
	protectSessionMu.Lock()
	if activeProtectSession == session {
		activeProtectSession = nil
	}
	protectSessionMu.Unlock()
	session.cancel()
	if session.writer != nil {
		_ = session.writer.Close()
	}
}

func protectReadyForStart(tunFd int64) bool {
	if tunFd <= 0 {
		return true
	}
	if protectWrite == nil || protectRead == nil {
		return false
	}
	session := currentProtectSession()
	return session != nil && session.writer == protectWrite && session.active()
}

func protectSocket(_ string, _ string, connection syscall.RawConn) error {
	session := currentProtectSession()
	if session == nil {
		return fmt.Errorf("protect monitor is unavailable")
	}

	session.requestMu.Lock()
	defer session.requestMu.Unlock()
	if !session.active() {
		return fmt.Errorf("protect monitor stopped")
	}

	var protectError error
	controlError := connection.Control(func(fd uintptr) {
		if !session.active() {
			protectError = fmt.Errorf("protect monitor stopped for fd %d", fd)
			return
		}
		var encoded [4]byte
		binary.LittleEndian.PutUint32(encoded[:], uint32(fd))
		if _, err := session.writer.Write(encoded[:]); err != nil {
			protectError = err
			return
		}
		ok, err := session.wait(protectResultTimeout)
		if err != nil {
			if errors.Is(err, errProtectTimedOut) {
				// A late response cannot be matched to its request. Retire the
				// whole session so it cannot be delivered to a later socket.
				retireProtectSession(session)
			}
			protectError = fmt.Errorf("%w for fd %d", err, fd)
		} else if !ok {
			protectError = fmt.Errorf("protect failed for fd %d", fd)
		}
	})
	if controlError != nil {
		return controlError
	}
	return protectError
}

// releaseProtectLocked must be called while coreMu is held.
func releaseProtectLocked() {
	replaceProtectSession(nil)
	if protectWrite != nil {
		_ = protectWrite.Close()
		protectWrite = nil
	}
	if protectRead != nil {
		_ = protectRead.Close()
		protectRead = nil
	}
}

func Init(homeDir, configFile string) {
	C.SetHomeDir(homeDir)
	C.SetConfig(configFile)
	log.Infoln("Bridge: init homeDir=%s configFile=%s", homeDir, configFile)
}

func Start(configPath string, tunFd int64) (result string) {
	coreMu.Lock()
	defer coreMu.Unlock()
	defer func() {
		if recovered := recover(); recovered != nil {
			result = fmt.Sprintf("panic: %v", recovered)
			log.Errorln("Bridge: recovered from panic: %v", recovered)
		}
		if result != "" && !running {
			releaseProtectLocked()
		}
	}()

	if running {
		return "already running"
	}

	log.Infoln("Bridge: reading config %s", configPath)
	configBytes, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Sprintf("read config: %v", err)
	}
	log.Infoln("Bridge: read %d bytes of config", len(configBytes))

	cfg, err := config.Parse(configBytes)
	if err != nil {
		return fmt.Sprintf("parse config: %v", err)
	}
	log.Infoln(
		"Bridge: config parsed, %d proxies, external-controller=%s",
		len(cfg.Proxies),
		cfg.Controller.ExternalController,
	)
	if cfg.Controller.ExternalController == "" {
		cfg.Controller.ExternalController = "127.0.0.1:9090"
		log.Infoln("Bridge: set external-controller to 127.0.0.1:9090")
	}

	if tunFd > 0 {
		cfg.General.Tun.Enable = true
		cfg.General.Tun.Stack = C.TunGvisor
		cfg.General.Tun.FileDescriptor = int(tunFd)
		cfg.General.Tun.DNSHijack = []string{"any:53"}
		cfg.General.Tun.AutoRoute = false
		cfg.General.Tun.AutoDetectInterface = false
		cfg.General.Tun.MTU = 1500
		cfg.General.Tun.Inet4Address = []netip.Prefix{
			netip.MustParsePrefix("10.0.0.2/32"),
		}
		log.Infoln("Bridge: TUN fd=%d, address=10.0.0.2/32", tunFd)
	} else {
		log.Infoln("Bridge: no TUN fd (tunFd=%d), running without TUN", tunFd)
	}

	if !protectReadyForStart(tunFd) {
		return "protect monitor is unavailable"
	}
	if tunFd > 0 {
		log.Infoln("Bridge: protect hook installed (sync)")
	}

	hub.ApplyConfig(cfg)
	running = true
	log.Infoln("Bridge: started successfully, API on %s", cfg.Controller.ExternalController)
	return ""
}

func Stop() {
	// Start holds coreMu while ApplyConfig may itself be waiting for a protect
	// response. Cancel that wait before attempting to take coreMu.
	protectStopRequests.Add(1)
	replaceProtectSession(nil)
	defer protectStopRequests.Add(-1)

	coreMu.Lock()
	defer coreMu.Unlock()

	releaseProtectLocked()
	if running {
		listener.ReCreateMixed(0, nil)
		listener.ReCreateSocks(0, nil)
		executor.Shutdown()
		running = false
	}
	log.Infoln("Bridge: stopped")
}

func IsRunning() bool {
	coreMu.Lock()
	defer coreMu.Unlock()
	return running
}

func InitProtect() int64 {
	readPipe, writePipe, err := os.Pipe()
	if err != nil {
		log.Errorln("Bridge: pipe error: %v", err)
		return -1
	}

	coreMu.Lock()
	releaseProtectLocked()
	session := newProtectSession()
	session.writer = writePipe
	if !installProtectSession(session) {
		_ = readPipe.Close()
		_ = writePipe.Close()
		coreMu.Unlock()
		log.Errorln("Bridge: protect pipe rejected while stop is pending")
		return -1
	}
	protectRead = readPipe
	protectWrite = writePipe
	readFd := int(readPipe.Fd())
	transferFd, err := syscall.Dup(readFd)
	if err != nil || transferFd <= 0 {
		if err == nil {
			err = fmt.Errorf("invalid duplicated descriptor %d", transferFd)
			_ = syscall.Close(transferFd)
		}
		releaseProtectLocked()
		coreMu.Unlock()
		log.Errorln("Bridge: duplicate protect pipe error: %v", err)
		return -1
	}
	syscall.CloseOnExec(transferFd)
	coreMu.Unlock()

	// The raw duplicate is transferred to Kotlin. Go keeps and closes only the
	// original readPipe; Kotlin must adopt and eventually close transferFd.
	log.Infoln("Bridge: protect pipe ready, readFd=%d transferFd=%d", readFd, transferFd)
	return int64(transferFd)
}

func SetProtectResult(ok bool) {
	if session := currentProtectSession(); session != nil {
		session.report(ok)
	}
}

func init() {
	dialer.DefaultSocketHook = protectSocket
	runtime.GOMAXPROCS(runtime.NumCPU())
	net.DefaultResolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			var dialer net.Dialer
			return dialer.DialContext(ctx, network, address)
		},
	}
}
