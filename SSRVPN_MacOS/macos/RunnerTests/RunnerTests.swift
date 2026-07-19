import Cocoa
import Darwin
import FlutterMacOS
import XCTest
@testable import SSRVPN

class RunnerTests: XCTestCase {

  func testDockReopenRevealsHiddenWindow() {
    let delegate = AppDelegate()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    addTeardownBlock { window.close() }

    window.orderOut(nil)
    XCTAssertFalse(window.isVisible)

    XCTAssertTrue(delegate.revealWindow(window))
    XCTAssertTrue(window.isVisible)
  }

  func testDockReopenDelegateHandlesDockActivation() {
    let delegate = AppDelegate()
    XCTAssertTrue(
      delegate.applicationShouldHandleReopen(
        NSApplication.shared,
        hasVisibleWindows: false
      )
    )
  }

  func testTerminationPreservesMalformedPidFileFailClosed() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    try "not-a-pid\n".write(to: pidURL, atomically: true, encoding: .utf8)

    XCTAssertFalse(delegate.terminateOwnedCore(in: directory))
    XCTAssertEqual(
      try String(contentsOf: pidURL, encoding: .utf8),
      "not-a-pid\n"
    )
  }

  func testTerminationPreservesOverflowingPidFileFailClosed() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    let contents = "999999999999999999999999999999\n"
    try contents.write(to: pidURL, atomically: true, encoding: .utf8)

    XCTAssertFalse(delegate.terminateOwnedCore(in: directory))
    XCTAssertEqual(try String(contentsOf: pidURL, encoding: .utf8), contents)
  }

  func testTerminationPreservesUnreadablePidFileFailClosed() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    try "4242\n".write(to: pidURL, atomically: true, encoding: .utf8)
    XCTAssertEqual(chmod(pidURL.path, 0), 0)
    addTeardownBlock { _ = chmod(pidURL.path, S_IRUSR | S_IWUSR) }

    XCTAssertFalse(delegate.terminateOwnedCore(in: directory))
    XCTAssertTrue(FileManager.default.fileExists(atPath: pidURL.path))
  }

  func testTerminationKeepsTheRuntimeDirectoryAfterProxyStateRemoval() {
    let delegate = AppDelegate()
    let stateURL = URL(
      fileURLWithPath: "/Users/test/Library/Application Support/SSRVPN/system_proxy.json"
    )

    XCTAssertEqual(
      delegate.runtimeDirectoryForTermination(proxyStateURL: stateURL)?.path,
      "/Users/test/Library/Application Support/SSRVPN"
    )
  }

  func testTerminationKnowsBothSupportedTunRequestLocations() {
    let delegate = AppDelegate()
    let support = URL(fileURLWithPath: "/Users/test/Library/Application Support")
    let paths = delegate.tunRequestURLs(in: support).map(\.path)

    XCTAssertTrue(paths.contains(
      "/Users/test/Library/Application Support/SSRVPN/.tun-session-request"
    ))
    XCTAssertTrue(paths.contains(where: {
      $0.hasSuffix("/SSRVPN/.tun-session-request") && $0.contains("com.ssrvpn")
    }))
  }

  func testTerminationEscalatesWhenSigtermIsDeliveredButProcessRemainsAlive() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    try "4242\n".write(to: pidURL, atomically: true, encoding: .utf8)

    var processIsAlive = true
    var sentSignals: [Int32] = []
    var pidExistedWhenKillWasSent = false

    let stopped = delegate.terminateConfirmedCoreProcess(
      pid: 4242,
      pidURL: pidURL,
      signalProcess: { _, signal in
        sentSignals.append(signal)
        if signal == SIGKILL {
          pidExistedWhenKillWasSent = FileManager.default.fileExists(
            atPath: pidURL.path
          )
          processIsAlive = false
        }
        return 0
      },
      isProcessAlive: { _ in processIsAlive },
      canSignalProcess: { _, _ in true },
      sleep: { _ in },
      gracefulPollCount: 2,
      forcedPollCount: 2
    )

    XCTAssertTrue(stopped)
    XCTAssertEqual(sentSignals, [SIGTERM, SIGKILL])
    XCTAssertTrue(pidExistedWhenKillWasSent)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pidURL.path))
  }

  func testTerminationWaitsForDelayedSigtermExitWithoutSendingSigkill() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    let readyURL = directory.appendingPathComponent("ready")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      "trap 'sleep 0.2; exit 0' TERM; printf ready > \"$1\"; "
        + "while :; do sleep 0.05; done",
      "delayed-term-test",
      readyURL.path,
    ]
    try process.run()
    addTeardownBlock {
      if process.isRunning {
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
      }
      process.waitUntilExit()
    }

    let readyDeadline = Date().addingTimeInterval(2)
    while !FileManager.default.fileExists(atPath: readyURL.path),
      Date() < readyDeadline
    {
      Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: readyURL.path))

    let pid = process.processIdentifier
    try "\(pid)\n".write(to: pidURL, atomically: true, encoding: .utf8)
    var sentSignals: [Int32] = []
    let startedAt = Date()
    let stopped = delegate.terminateConfirmedCoreProcess(
      pid: pid,
      pidURL: pidURL,
      signalProcess: { target, signal in
        sentSignals.append(signal)
        return Darwin.kill(target, signal)
      },
      isProcessAlive: { target in
        errno = 0
        if Darwin.kill(target, 0) == 0 { return true }
        return errno != ESRCH
      },
      canSignalProcess: { _, _ in true },
      sleep: { Thread.sleep(forTimeInterval: $0) },
      gracefulPollCount: 101,
      forcedPollCount: 2,
      pollInterval: 0.02
    )

    XCTAssertTrue(stopped)
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.15)
    XCTAssertEqual(sentSignals, [SIGTERM])
    XCTAssertFalse(FileManager.default.fileExists(atPath: pidURL.path))
  }

  func testTerminationKeepsPidWhenExitCannotBeConfirmedAfterSigkill() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    try "4242\n".write(to: pidURL, atomically: true, encoding: .utf8)

    var sentSignals: [Int32] = []
    var sleepCount = 0
    let stopped = delegate.terminateConfirmedCoreProcess(
      pid: 4242,
      pidURL: pidURL,
      signalProcess: { _, signal in
        sentSignals.append(signal)
        return 0
      },
      isProcessAlive: { _ in true },
      canSignalProcess: { _, _ in true },
      sleep: { _ in sleepCount += 1 },
      gracefulPollCount: 2,
      forcedPollCount: 2
    )

    XCTAssertFalse(stopped)
    XCTAssertEqual(sentSignals, [SIGTERM, SIGKILL])
    XCTAssertEqual(sleepCount, 2)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pidURL.path))
  }

  func testTerminationFailsClosedImmediatelyWhenSigtermIsRejected() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    try "4242\n".write(to: pidURL, atomically: true, encoding: .utf8)

    var sentSignals: [Int32] = []
    var sleepCount = 0
    let stopped = delegate.terminateConfirmedCoreProcess(
      pid: 4242,
      pidURL: pidURL,
      signalProcess: { _, signal in
        sentSignals.append(signal)
        errno = EPERM
        return -1
      },
      isProcessAlive: { _ in true },
      canSignalProcess: { _, _ in true },
      sleep: { _ in sleepCount += 1 },
      gracefulPollCount: 2,
      forcedPollCount: 2
    )

    XCTAssertFalse(stopped)
    XCTAssertEqual(sentSignals, [SIGTERM])
    XCTAssertEqual(sleepCount, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pidURL.path))
  }

  func testTerminationFailsClosedImmediatelyWhenSigkillIsRejected() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    try "4242\n".write(to: pidURL, atomically: true, encoding: .utf8)

    var sentSignals: [Int32] = []
    var sleepCount = 0
    let stopped = delegate.terminateConfirmedCoreProcess(
      pid: 4242,
      pidURL: pidURL,
      signalProcess: { _, signal in
        sentSignals.append(signal)
        if signal == SIGKILL {
          errno = EPERM
          return -1
        }
        return 0
      },
      isProcessAlive: { _ in true },
      canSignalProcess: { _, _ in true },
      sleep: { _ in sleepCount += 1 },
      gracefulPollCount: 2,
      forcedPollCount: 2
    )

    XCTAssertFalse(stopped)
    XCTAssertEqual(sentSignals, [SIGTERM, SIGKILL])
    XCTAssertEqual(sleepCount, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pidURL.path))
  }

  func testTerminationDoesNotForceKillAfterOwnershipCanNoLongerBeConfirmed() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    try "4242\n".write(to: pidURL, atomically: true, encoding: .utf8)

    var sentSignals: [Int32] = []
    let stopped = delegate.terminateConfirmedCoreProcess(
      pid: 4242,
      pidURL: pidURL,
      signalProcess: { _, signal in
        sentSignals.append(signal)
        return 0
      },
      isProcessAlive: { _ in true },
      canSignalProcess: { _, signal in signal == SIGTERM },
      sleep: { _ in },
      gracefulPollCount: 1,
      forcedPollCount: 1
    )

    XCTAssertFalse(stopped)
    XCTAssertEqual(sentSignals, [SIGTERM])
    XCTAssertTrue(FileManager.default.fileExists(atPath: pidURL.path))
  }

  func testTerminationDoesNotSendSigtermWithoutFreshOwnershipConfirmation() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    try "4242\n".write(to: pidURL, atomically: true, encoding: .utf8)

    var sentSignals: [Int32] = []
    let stopped = delegate.terminateConfirmedCoreProcess(
      pid: 4242,
      pidURL: pidURL,
      signalProcess: { _, signal in
        sentSignals.append(signal)
        return 0
      },
      isProcessAlive: { _ in true },
      canSignalProcess: { _, _ in false },
      sleep: { _ in },
      gracefulPollCount: 1,
      forcedPollCount: 1
    )

    XCTAssertFalse(stopped)
    XCTAssertTrue(sentSignals.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pidURL.path))
  }

  func testTerminationRejectsSamePidAndPathFromDifferentStartGeneration() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    let corePath = directory.appendingPathComponent("AtlasCore").path
    try "4242\n".write(to: pidURL, atomically: true, encoding: .utf8)

    let original = CoreProcessIdentity(
      pid: 4242,
      executablePath: corePath,
      startSeconds: 100,
      startMicroseconds: 1
    )
    let replacement = CoreProcessIdentity(
      pid: 4242,
      executablePath: corePath,
      startSeconds: 101,
      startMicroseconds: 2
    )
    var identityReads = 0
    var sentSignals: [Int32] = []

    let stopped = delegate.terminateOwnedCore(
      in: directory,
      identityForProcess: { _, _ in
        identityReads += 1
        return identityReads == 1 ? original : replacement
      },
      signalProcess: { _, signal in
        sentSignals.append(signal)
        return 0
      },
      isProcessAlive: { _ in true },
      sleep: { _ in }
    )

    XCTAssertFalse(stopped)
    XCTAssertEqual(identityReads, 2)
    XCTAssertTrue(sentSignals.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pidURL.path))
  }

  func testProcessIdentityIncludesExecutablePathAndStartGeneration() throws {
    let pid = getpid()
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let pathLength = pathBuffer.withUnsafeMutableBufferPointer {
      proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
    }
    XCTAssertGreaterThan(pathLength, 0)
    let executablePath = String(cString: pathBuffer)

    let identity = try XCTUnwrap(
      AppDelegate.currentCoreProcessIdentity(
        pid: pid,
        expectedExecutablePath: executablePath
      )
    )

    XCTAssertEqual(identity.pid, pid)
    XCTAssertEqual(identity.executablePath, executablePath)
    XCTAssertGreaterThan(identity.startSeconds, 0)
    XCTAssertNil(
      AppDelegate.currentCoreProcessIdentity(
        pid: pid,
        expectedExecutablePath: executablePath + ".replacement"
      )
    )
  }

  func testTerminationDoesNotRemovePidFileReplacedByANewerProcess() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    try "4242\n".write(to: pidURL, atomically: true, encoding: .utf8)

    let stopped = delegate.terminateConfirmedCoreProcess(
      pid: 4242,
      pidURL: pidURL,
      signalProcess: { _, _ in
        try? "5252\n".write(to: pidURL, atomically: true, encoding: .utf8)
        return 0
      },
      isProcessAlive: { _ in false },
      canSignalProcess: { _, _ in true },
      sleep: { _ in },
      gracefulPollCount: 1,
      forcedPollCount: 1
    )

    XCTAssertTrue(stopped)
    XCTAssertEqual(try String(contentsOf: pidURL, encoding: .utf8), "5252\n")
  }

  func testPidCleanupCannotDeleteANewerPidCreatedAfterAtomicQuarantine() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    try "4242\n".write(to: pidURL, atomically: true, encoding: .utf8)

    let removed = delegate.removePidFileIfMatching(
      at: pidURL,
      expectedPid: 4242,
      afterQuarantine: { quarantineURL in
        XCTAssertTrue(
          FileManager.default.fileExists(atPath: quarantineURL.path)
        )
        try? "5252\n".write(to: pidURL, atomically: true, encoding: .utf8)
      }
    )

    XCTAssertTrue(removed)
    XCTAssertEqual(try String(contentsOf: pidURL, encoding: .utf8), "5252\n")
  }

}
