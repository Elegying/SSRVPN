// Package bridge exposes the Mihomo lifecycle used by the Android JNI wrapper.
package bridge

import (
	"context"
	"encoding/binary"
	"fmt"
	"net"
	"net/netip"
	"os"
	"runtime"
	"sync"
	"syscall"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
)

var (
	coreMu        sync.Mutex
	running       bool
	protectRead   *os.File
	protectWrite  *os.File
	protectResult chan bool
)

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

	if protectWrite != nil && protectRead != nil {
		protectResult = make(chan bool)
		dialer.DefaultSocketHook = func(_ string, _ string, connection syscall.RawConn) error {
			var protectError error
			controlError := connection.Control(func(fd uintptr) {
				var encoded [4]byte
				binary.LittleEndian.PutUint32(encoded[:], uint32(fd))
				if _, err := protectWrite.Write(encoded[:]); err != nil {
					protectError = err
					return
				}
				if !<-protectResult {
					protectError = fmt.Errorf("protect failed for fd %d", fd)
				}
			})
			if controlError != nil {
				return controlError
			}
			return protectError
		}
		log.Infoln("Bridge: protect hook installed (sync)")
	}

	hub.ApplyConfig(cfg)
	running = true
	log.Infoln("Bridge: started successfully, API on %s", cfg.Controller.ExternalController)
	return ""
}

func Stop() {
	coreMu.Lock()
	defer coreMu.Unlock()
	if !running {
		return
	}

	listener.ReCreateMixed(0, nil)
	listener.ReCreateSocks(0, nil)
	executor.Shutdown()
	running = false
	dialer.DefaultSocketHook = nil
	if protectWrite != nil {
		_ = protectWrite.Close()
		protectWrite = nil
	}
	if protectRead != nil {
		_ = protectRead.Close()
		protectRead = nil
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
	if protectRead != nil {
		_ = protectRead.Close()
	}
	if protectWrite != nil {
		_ = protectWrite.Close()
	}
	protectRead = readPipe
	protectWrite = writePipe
	coreMu.Unlock()

	log.Infoln("Bridge: protect pipe ready, readFd=%d", readPipe.Fd())
	return int64(readPipe.Fd())
}

func SetProtectResult(ok bool) {
	if protectResult != nil {
		protectResult <- ok
	}
}

func init() {
	runtime.GOMAXPROCS(runtime.NumCPU())
	net.DefaultResolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			var dialer net.Dialer
			return dialer.DialContext(ctx, network, address)
		},
	}
}
