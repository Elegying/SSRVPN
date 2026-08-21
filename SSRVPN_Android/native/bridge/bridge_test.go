package bridge

import (
	"encoding/binary"
	"errors"
	"io"
	"os"
	"testing"
	"time"
)

type fixedRawConn uintptr

func (connection fixedRawConn) Control(control func(uintptr)) error {
	control(uintptr(connection))
	return nil
}

func (fixedRawConn) Read(func(uintptr) bool) error {
	return errors.New("unexpected RawConn.Read")
}

func (fixedRawConn) Write(func(uintptr) bool) error {
	return errors.New("unexpected RawConn.Write")
}

func TestProtectSessionCancelUnblocksPendingRequest(t *testing.T) {
	session := newProtectSession()
	result := make(chan bool, 1)
	go func() {
		_, err := session.wait(time.Second)
		result <- err == nil
	}()

	session.cancel()
	select {
	case active := <-result:
		if active {
			t.Fatal("canceled protect request was reported as active")
		}
	case <-time.After(time.Second):
		t.Fatal("canceled protect request remained blocked")
	}
}

func TestProtectSessionDeliversResult(t *testing.T) {
	session := newProtectSession()
	result := make(chan bool, 1)
	go func() {
		ok, err := session.wait(time.Second)
		result <- ok && err == nil
	}()

	if !session.report(true) {
		t.Fatal("active protect session rejected a result")
	}
	select {
	case ok := <-result:
		if !ok {
			t.Fatal("protect result was not delivered")
		}
	case <-time.After(time.Second):
		t.Fatal("protect result remained blocked")
	}
}

func TestStableProtectDispatcherFailsClosedWithoutSession(t *testing.T) {
	replaceProtectSession(nil)
	if err := protectSocket("tcp", "example.com:443", nil); err == nil {
		t.Fatal("protect dispatcher allowed a socket without an active monitor")
	}
}

func TestProtectSessionWaitTimesOut(t *testing.T) {
	session := newProtectSession()
	if _, err := session.wait(10 * time.Millisecond); err != errProtectTimedOut {
		t.Fatalf("wait error = %v, want %v", err, errProtectTimedOut)
	}
}

func TestStopCancelsProtectBeforeCoreLock(t *testing.T) {
	replaceProtectSession(nil)
	session := newProtectSession()
	if !installProtectSession(session) {
		t.Fatal("protect session was unexpectedly rejected")
	}

	coreMu.Lock()
	stopReturned := make(chan struct{})
	go func() {
		Stop()
		close(stopReturned)
	}()

	select {
	case <-session.done:
		// Cancellation must happen while Stop is still blocked on coreMu.
	case <-time.After(time.Second):
		coreMu.Unlock()
		t.Fatal("Stop waited for coreMu before canceling protect")
	}
	select {
	case <-stopReturned:
		coreMu.Unlock()
		t.Fatal("Stop returned while coreMu was held")
	default:
	}
	coreMu.Unlock()

	select {
	case <-stopReturned:
	case <-time.After(time.Second):
		t.Fatal("Stop did not return after coreMu was released")
	}
}

func TestInstallProtectSessionRejectsPendingStop(t *testing.T) {
	replaceProtectSession(nil)
	protectStopRequests.Add(1)
	defer protectStopRequests.Add(-1)

	session := newProtectSession()
	if installProtectSession(session) {
		t.Fatal("protect session was installed during a pending stop")
	}
	if session.active() {
		t.Fatal("rejected protect session remained active")
	}
	if currentProtectSession() != nil {
		t.Fatal("rejected protect session became globally visible")
	}
}

func TestProtectTimeoutRetiresSessionAndClosesMonitorPipe(t *testing.T) {
	readPipe, writePipe, err := os.Pipe()
	if err != nil {
		t.Fatalf("create protect pipe: %v", err)
	}
	t.Cleanup(func() {
		replaceProtectSession(nil)
		_ = writePipe.Close()
		_ = readPipe.Close()
	})

	session := newProtectSession()
	session.writer = writePipe
	if !installProtectSession(session) {
		t.Fatal("protect session was unexpectedly rejected")
	}

	protectReturned := make(chan error, 1)
	go func() {
		protectReturned <- protectSocket("tcp", "example.com:443", fixedRawConn(42))
	}()

	var encoded [4]byte
	if _, err := io.ReadFull(readPipe, encoded[:]); err != nil {
		t.Fatalf("read protect request: %v", err)
	}
	if fd := binary.LittleEndian.Uint32(encoded[:]); fd != 42 {
		t.Fatalf("protect fd = %d, want 42", fd)
	}

	select {
	case err := <-protectReturned:
		if !errors.Is(err, errProtectTimedOut) {
			t.Fatalf("protect error = %v, want %v", err, errProtectTimedOut)
		}
	case <-time.After(protectResultTimeout + time.Second):
		t.Fatal("protect request did not time out")
	}
	if session.active() {
		t.Fatal("timed-out protect session remained active")
	}
	if currentProtectSession() != nil {
		t.Fatal("timed-out protect session remained globally visible")
	}

	lateReplyReturned := make(chan struct{})
	go func() {
		SetProtectResult(true)
		close(lateReplyReturned)
	}()
	select {
	case <-lateReplyReturned:
	case <-time.After(time.Second):
		t.Fatal("late protect reply remained blocked")
	}

	monitorRead := make(chan error, 1)
	go func() {
		var trailing [1]byte
		_, err := readPipe.Read(trailing[:])
		monitorRead <- err
	}()
	select {
	case err := <-monitorRead:
		if !errors.Is(err, io.EOF) {
			t.Fatalf("protect monitor pipe error = %v, want EOF", err)
		}
	case <-time.After(time.Second):
		t.Fatal("timed-out protect session left the monitor pipe open")
	}
}

func TestTunStartGateRejectsSessionClearedByCompletedStop(t *testing.T) {
	readPipe, writePipe, err := os.Pipe()
	if err != nil {
		t.Fatalf("create protect pipe: %v", err)
	}

	coreMu.Lock()
	releaseProtectLocked()
	protectRead = readPipe
	protectWrite = writePipe
	session := newProtectSession()
	session.writer = writePipe
	if !installProtectSession(session) {
		coreMu.Unlock()
		t.Fatal("protect session was unexpectedly rejected")
	}

	stopReturned := make(chan struct{})
	go func() {
		Stop()
		close(stopReturned)
	}()
	select {
	case <-session.done:
	case <-time.After(time.Second):
		coreMu.Unlock()
		t.Fatal("Stop did not cancel protect before waiting for coreMu")
	}
	coreMu.Unlock()
	select {
	case <-stopReturned:
	case <-time.After(time.Second):
		t.Fatal("Stop did not complete")
	}

	if protectReadyForStart(42) {
		t.Fatal("TUN start remained allowed after Stop cleared its protect session")
	}
}

func TestConcurrentStopsRejectSessionInstallUntilBothReturn(t *testing.T) {
	replaceProtectSession(nil)
	if count := protectStopRequests.Load(); count != 0 {
		t.Fatalf("pending stop count = %d, want 0", count)
	}

	coreMu.Lock()
	coreLocked := true
	defer func() {
		if coreLocked {
			coreMu.Unlock()
		}
	}()

	stopReturned := make(chan struct{}, 2)
	for i := 0; i < 2; i++ {
		go func() {
			Stop()
			stopReturned <- struct{}{}
		}()
	}
	deadline := time.Now().Add(time.Second)
	for protectStopRequests.Load() != 2 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if count := protectStopRequests.Load(); count != 2 {
		t.Fatalf("pending stop count = %d, want 2", count)
	}

	candidate := newProtectSession()
	if installProtectSession(candidate) {
		t.Fatal("protect session was installed while concurrent Stops were pending")
	}
	if candidate.active() {
		t.Fatal("rejected protect session remained active")
	}

	coreMu.Unlock()
	coreLocked = false
	for i := 0; i < 2; i++ {
		select {
		case <-stopReturned:
		case <-time.After(time.Second):
			t.Fatal("concurrent Stop did not return")
		}
	}
	if count := protectStopRequests.Load(); count != 0 {
		t.Fatalf("pending stop count = %d after return, want 0", count)
	}
}

func TestInitProtectTransfersDuplicateReaderAcrossStop(t *testing.T) {
	Stop()
	transferFd := InitProtect()
	if transferFd <= 0 {
		t.Fatalf("InitProtect fd = %d, want a transferred descriptor", transferFd)
	}
	transferRead := os.NewFile(uintptr(transferFd), "protect-transfer-read")
	if transferRead == nil {
		t.Fatal("could not adopt transferred protect descriptor")
	}
	defer func() {
		if err := transferRead.Close(); err != nil {
			t.Errorf("close transferred protect descriptor: %v", err)
		}
	}()

	Stop()
	var trailing [1]byte
	if count, err := transferRead.Read(trailing[:]); count != 0 || !errors.Is(err, io.EOF) {
		t.Fatalf("transferred reader after Stop = (%d, %v), want (0, EOF)", count, err)
	}
}
