import Cocoa
import Darwin
import FlutterMacOS
import XCTest
@testable import SSRVPN

private final class FakeWindowRevealTarget: WindowRevealTarget {
  var isMiniaturized: Bool
  private(set) var deminiaturizeCallCount = 0
  private(set) var makeKeyAndOrderFrontCallCount = 0

  init(isMiniaturized: Bool) {
    self.isMiniaturized = isMiniaturized
  }

  func deminiaturize(_ sender: Any?) {
    deminiaturizeCallCount += 1
    isMiniaturized = false
  }

  func makeKeyAndOrderFront(_ sender: Any?) {
    makeKeyAndOrderFrontCallCount += 1
  }
}

class RunnerTests: XCTestCase {

  func testMainWindowUsesIntegratedTitlebarAppearance() {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )

    window.configureIntegratedTitlebar()

    XCTAssertEqual(window.titleVisibility, .hidden)
    XCTAssertTrue(window.titlebarAppearsTransparent)
    XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
    XCTAssertEqual(window.backgroundColor, MainFlutterWindow.integratedBackgroundColor)
    if #available(macOS 11.0, *) {
      XCTAssertEqual(window.titlebarSeparatorStyle, .none)
    }
  }

  private func buildNativeCoreFixture(at executableURL: URL) throws {
    let sourceURL = executableURL
      .deletingLastPathComponent()
      .appendingPathComponent("AtlasCoreFixture.c")
    let source = """
    #define _POSIX_C_SOURCE 200809L
    #include <signal.h>
    #include <stdio.h>
    #include <time.h>
    #include <unistd.h>

    static volatile sig_atomic_t stop_requested = 0;

    static void handle_term(int signal_number) {
      (void)signal_number;
      stop_requested = 1;
    }

    static int write_marker(const char *path) {
      FILE *marker = fopen(path, "w");
      if (marker == NULL) return -1;
      fputs("ready", marker);
      return fclose(marker);
    }

    int main(int argc, char **argv) {
      struct sigaction action = {0};
      action.sa_handler = handle_term;
      sigemptyset(&action.sa_mask);
      if (sigaction(SIGTERM, &action, NULL) != 0) return 2;

      if (argc > 1 && write_marker(argv[1]) != 0) return 3;

      fputs("native-stdout", stdout);
      fflush(stdout);
      fputs("native-stderr", stderr);
      fflush(stderr);

      if (argc > 3) {
        const unsigned char partial_scalar[] = {0xE4, 0xB8};
        fputs("utf8-before:", stdout);
        fwrite(partial_scalar, 1, sizeof(partial_scalar), stdout);
        fflush(stdout);
        if (write_marker(argv[2]) != 0) return 4;
        const struct timespec poll = {.tv_sec = 0, .tv_nsec = 10000000};
        while (access(argv[3], F_OK) != 0 && !stop_requested) {
          nanosleep(&poll, NULL);
        }
        if (!stop_requested) {
          const unsigned char final_byte = 0xAD;
          fwrite(&final_byte, 1, 1, stdout);
          fputs(":after", stdout);
          fflush(stdout);
        }
      }

      sigset_t blocked_signals;
      sigset_t previous_mask;
      sigemptyset(&blocked_signals);
      sigaddset(&blocked_signals, SIGTERM);
      if (sigprocmask(SIG_BLOCK, &blocked_signals, &previous_mask) != 0) return 5;
      while (!stop_requested) sigsuspend(&previous_mask);
      if (sigprocmask(SIG_SETMASK, &previous_mask, NULL) != 0) return 6;

      const struct timespec delay = {.tv_sec = 0, .tv_nsec = 200000000};
      nanosleep(&delay, NULL);
      return 0;
    }
    """
    try source.write(to: sourceURL, atomically: true, encoding: .utf8)

    let compiler = Process()
    let compilerFinished = DispatchSemaphore(value: 0)
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compiler.arguments = [
      "-std=c11",
      "-Wall",
      "-Wextra",
      "-Werror",
      sourceURL.path,
      "-o",
      executableURL.path,
    ]
    compiler.standardInput = FileHandle.nullDevice
    compiler.standardOutput = FileHandle.nullDevice
    compiler.standardError = FileHandle.nullDevice
    compiler.terminationHandler = { _ in compilerFinished.signal() }
    try compiler.run()
    guard compilerFinished.wait(timeout: .now() + 15) == .success else {
      if compiler.isRunning { compiler.terminate() }
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(ETIMEDOUT),
        userInfo: [NSLocalizedDescriptionKey: "Timed out compiling native core fixture"]
      )
    }
    guard compiler.terminationStatus == 0 else {
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(EIO),
        userInfo: [NSLocalizedDescriptionKey: "Could not compile native core fixture"]
      )
    }
    XCTAssertEqual(
      Darwin.chmod(executableURL.path, S_IRUSR | S_IWUSR | S_IXUSR),
      0
    )
  }

  func testActiveProxyLifecycleLeaseDefersTerminationUntilExactTokenEnds() throws {
    let delegate = AppDelegate()
    var replies: [Bool] = []
    let terminationReply = expectation(
      description: "application termination receives its final reply"
    )
    delegate.replyToPendingApplicationTermination = {
      replies.append($0)
      terminationReply.fulfill()
    }
    let token = try XCTUnwrap(delegate.beginProxyLifecycleTransaction())

    XCTAssertTrue(delegate.hasActiveProxyLifecycleTransaction)
    XCTAssertEqual(
      delegate.applicationShouldTerminate(NSApplication.shared),
      .terminateLater
    )
    XCTAssertFalse(delegate.endProxyLifecycleTransaction(token: "wrong-token"))
    XCTAssertTrue(delegate.hasActiveProxyLifecycleTransaction)
    XCTAssertTrue(replies.isEmpty)

    XCTAssertTrue(delegate.endProxyLifecycleTransaction(token: token))
    XCTAssertFalse(delegate.hasActiveProxyLifecycleTransaction)
    wait(for: [terminationReply], timeout: 5)
    XCTAssertEqual(replies, [true])
  }

  func testTerminationPendingRejectsNewProxyLifecycleTransactions() throws {
    let delegate = AppDelegate()
    var replies: [Bool] = []
    var timeout: (() -> Void)?
    let terminationReply = expectation(
      description: "committed application termination receives its final reply"
    )
    delegate.replyToPendingApplicationTermination = {
      replies.append($0)
      terminationReply.fulfill()
    }
    delegate.schedulePendingApplicationTerminationTimeout = { timeout = $0 }
    let token = try XCTUnwrap(delegate.beginProxyLifecycleTransaction())

    XCTAssertEqual(
      delegate.applicationShouldTerminate(NSApplication.shared),
      .terminateLater
    )
    XCTAssertNil(delegate.beginProxyLifecycleTransaction())

    XCTAssertTrue(delegate.endProxyLifecycleTransaction(token: token))
    // The final reply is queued on the main thread. A new transaction must not
    // slip into that window after termination has already been committed.
    XCTAssertNil(delegate.beginProxyLifecycleTransaction())
    XCTAssertFalse(delegate.hasActiveProxyLifecycleTransaction)

    wait(for: [terminationReply], timeout: 5)
    XCTAssertEqual(replies, [true])
    XCTAssertNil(delegate.beginProxyLifecycleTransaction())
    timeout?()
    XCTAssertEqual(replies, [true])
  }

  func testPendingTerminationTimeoutCancelsOnlyTheQuitAttempt() throws {
    let delegate = AppDelegate()
    var replies: [Bool] = []
    var timeout: (() -> Void)?
    delegate.replyToPendingApplicationTermination = { replies.append($0) }
    delegate.schedulePendingApplicationTerminationTimeout = { timeout = $0 }
    let originalToken = try XCTUnwrap(delegate.beginProxyLifecycleTransaction())

    XCTAssertEqual(
      delegate.applicationShouldTerminate(NSApplication.shared),
      .terminateLater
    )
    XCTAssertNotNil(timeout)
    timeout?()

    XCTAssertEqual(replies, [false])
    XCTAssertTrue(delegate.hasActiveProxyLifecycleTransaction)
    let laterToken = try XCTUnwrap(delegate.beginProxyLifecycleTransaction())
    XCTAssertTrue(delegate.endProxyLifecycleTransaction(token: laterToken))
    XCTAssertTrue(delegate.endProxyLifecycleTransaction(token: originalToken))
    XCTAssertEqual(replies, [false])
    XCTAssertFalse(delegate.hasActiveProxyLifecycleTransaction)
  }

  func testTerminationPreflightKeepsUIAndCoreWhenProxyRestoreFails() {
    let delegate = AppDelegate()
    var events: [String] = []
    var failure: String?

    let safe = delegate.performSafeTerminationPreflight(
      hadProxyState: true,
      restoreProxy: {
        events.append("restore")
        return false
      },
      terminateCore: {
        events.append("terminate")
        return true
      },
      onFailure: { failure = $0 }
    )

    XCTAssertFalse(safe)
    XCTAssertEqual(events, ["restore"])
    XCTAssertTrue(failure?.contains("系统代理") == true)
    XCTAssertTrue(failure?.contains("未继续终止当前 Mihomo 核心") == true)
    XCTAssertFalse(failure?.contains("安全核心") == true)
    XCTAssertTrue(failure?.contains("重试退出") == true)
  }

  func testTerminationPreflightRequiresOwnedCoreCleanupBeforeExit() {
    let delegate = AppDelegate()
    var events: [String] = []
    var failure: String?

    let safe = delegate.performSafeTerminationPreflight(
      hadProxyState: true,
      restoreProxy: {
        events.append("restore")
        return true
      },
      terminateCore: {
        events.append("terminate")
        return false
      },
      onFailure: { failure = $0 }
    )

    XCTAssertFalse(safe)
    XCTAssertEqual(events, ["restore", "terminate"])
    XCTAssertTrue(failure?.contains("Mihomo") == true)
    XCTAssertTrue(failure?.contains("重试退出") == true)
  }

  func testTerminationPreflightLeavesActiveTunForPrivilegedDnsCleanup() {
    let delegate = AppDelegate()
    var events: [String] = []

    let safe = delegate.performSafeTerminationPreflight(
      hadProxyState: false,
      hasTunSessionRequest: true,
      restoreProxy: {
        events.append("restore")
        return true
      },
      terminateCore: {
        events.append("terminate")
        return true
      },
      onFailure: { _ in XCTFail("TUN handoff should be safe") }
    )

    XCTAssertTrue(safe)
    XCTAssertEqual(events, [])
  }

  func testNativeLaunchPublishesIdentityAndDrainsDiagnosticsBeforeReturning() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock {
      _ = delegate.terminateOwnedCore(in: directory)
      try? FileManager.default.removeItem(at: directory)
    }
    let coreURL = directory.appendingPathComponent("AtlasCore")
    try buildNativeCoreFixture(at: coreURL)

    let launch = try delegate.launchOwnedCore(
      in: directory,
      arguments: []
    )

    XCTAssertGreaterThan(launch.pid, 1)
    XCTAssertEqual(CorePidRecord(text: launch.pidRecordContents)?.pid, launch.pid)
    XCTAssertEqual(
      try String(
        contentsOf: directory.appendingPathComponent("AtlasCore.pid"),
        encoding: .utf8
      ),
      launch.pidRecordContents
    )

    var status = delegate.statusForOwnedCore(
      in: directory,
      expectedContents: launch.pidRecordContents
    )
    let diagnosticDeadline = Date().addingTimeInterval(2)
    while status?.standardOutput.contains("native-stdout") != true ||
      status?.standardError.contains("native-stderr") != true
    {
      guard Date() < diagnosticDeadline else { break }
      Thread.sleep(forTimeInterval: 0.01)
      let next = delegate.statusForOwnedCore(
        in: directory,
        expectedContents: launch.pidRecordContents
      )
      status = CoreProcessStatus(
        isRunning: next?.isRunning ?? false,
        exitCode: next?.exitCode,
        standardOutput: (status?.standardOutput ?? "") + (next?.standardOutput ?? ""),
        standardError: (status?.standardError ?? "") + (next?.standardError ?? "")
      )
    }

    XCTAssertEqual(status?.isRunning, true)
    XCTAssertTrue(status?.standardOutput.contains("native-stdout") == true)
    XCTAssertTrue(status?.standardError.contains("native-stderr") == true)
  }

  func testNativeStatusPreservesUtf8ScalarAcrossDrains() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock {
      _ = delegate.terminateOwnedCore(in: directory)
      try? FileManager.default.removeItem(at: directory)
    }
    let coreURL = directory.appendingPathComponent("AtlasCore")
    let readyURL = directory.appendingPathComponent("ready")
    let splitURL = directory.appendingPathComponent("utf8-split-ready")
    let releaseURL = directory.appendingPathComponent("utf8-release")
    try buildNativeCoreFixture(at: coreURL)
    let launch = try delegate.launchOwnedCore(
      in: directory,
      arguments: [readyURL.path, splitURL.path, releaseURL.path]
    )

    let splitDeadline = Date().addingTimeInterval(2)
    while !FileManager.default.fileExists(atPath: splitURL.path),
      Date() < splitDeadline
    {
      Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: splitURL.path))

    var collectedOutput = ""
    let prefixDeadline = Date().addingTimeInterval(2)
    while !collectedOutput.contains("utf8-before:"), Date() < prefixDeadline {
      let status = delegate.statusForOwnedCore(
        in: directory,
        expectedContents: launch.pidRecordContents
      )
      collectedOutput += status?.standardOutput ?? ""
      Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertTrue(collectedOutput.contains("utf8-before:"))
    XCTAssertFalse(collectedOutput.contains("�"))
    XCTAssertFalse(collectedOutput.contains("中"))

    try Data().write(to: releaseURL)
    let scalarDeadline = Date().addingTimeInterval(2)
    while !collectedOutput.contains("中:after"), Date() < scalarDeadline {
      let status = delegate.statusForOwnedCore(
        in: directory,
        expectedContents: launch.pidRecordContents
      )
      collectedOutput += status?.standardOutput ?? ""
      Thread.sleep(forTimeInterval: 0.01)
    }

    XCTAssertTrue(collectedOutput.contains("中:after"))
    XCTAssertFalse(collectedOutput.contains("�"))
  }

  func testNativeLaunchRetriesIdentityAndContainsItsChildOnFailure() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let coreURL = directory.appendingPathComponent("AtlasCore")
    try buildNativeCoreFixture(at: coreURL)
    var createdProcess: Process?
    var identityReads = 0

    XCTAssertThrowsError(
      try delegate.launchOwnedCore(
        in: directory,
        arguments: [],
        identityForProcess: { _, _ in
          identityReads += 1
          return nil
        },
        sleep: { _ in },
        identityPollCount: 3,
        makeProcess: {
          let process = Process()
          createdProcess = process
          return process
        }
      )
    )

    XCTAssertEqual(identityReads, 3)
    XCTAssertEqual(createdProcess?.isRunning, false)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("AtlasCore.pid").path
    ))
  }

  func testTrackedNativeChildIsContainedWhenItsPidRecordDisappears() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock {
      _ = delegate.terminateOwnedCore(in: directory)
      try? FileManager.default.removeItem(at: directory)
    }
    let coreURL = directory.appendingPathComponent("AtlasCore")
    try buildNativeCoreFixture(at: coreURL)
    var createdProcess: Process?
    _ = try delegate.launchOwnedCore(
      in: directory,
      arguments: [],
      makeProcess: {
        let process = Process()
        createdProcess = process
        return process
      }
    )
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    try FileManager.default.removeItem(at: pidURL)

    XCTAssertEqual(
      delegate.runtimeDirectoryForTermination(proxyStateURL: nil),
      directory.standardizedFileURL
    )
    XCTAssertTrue(delegate.terminateOwnedCore(in: directory))
    XCTAssertEqual(createdProcess?.isRunning, false)
  }

  func testTrackedNativeChildContainmentPreservesAConflictingPidRecord() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock {
      _ = delegate.terminateOwnedCore(in: directory)
      try? FileManager.default.removeItem(at: directory)
    }
    let coreURL = directory.appendingPathComponent("AtlasCore")
    try buildNativeCoreFixture(at: coreURL)
    var createdProcess: Process?
    _ = try delegate.launchOwnedCore(
      in: directory,
      arguments: [],
      makeProcess: {
        let process = Process()
        createdProcess = process
        return process
      }
    )
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    let replacement = "v2 5252 200 2\n"
    try replacement.write(to: pidURL, atomically: true, encoding: .utf8)

    XCTAssertTrue(delegate.terminateOwnedCore(in: directory))
    XCTAssertEqual(createdProcess?.isRunning, false)
    XCTAssertEqual(try String(contentsOf: pidURL, encoding: .utf8), replacement)
  }

  func testExactStopContainsTrackedChildWhenItsPidRecordDisappears() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock {
      _ = delegate.terminateOwnedCore(in: directory)
      try? FileManager.default.removeItem(at: directory)
    }
    let coreURL = directory.appendingPathComponent("AtlasCore")
    try buildNativeCoreFixture(at: coreURL)
    let processFinished = DispatchSemaphore(value: 0)
    let launch = try delegate.launchOwnedCore(
      in: directory,
      arguments: [],
      makeProcess: {
        let process = Process()
        process.terminationHandler = { _ in processFinished.signal() }
        return process
      }
    )
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    try FileManager.default.removeItem(at: pidURL)

    XCTAssertTrue(delegate.terminateOwnedCoreRecord(
      in: directory,
      expectedContents: launch.pidRecordContents
    ))
    XCTAssertEqual(processFinished.wait(timeout: .now() + 2), .success)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pidURL.path))
  }

  func testExactStopContainsTrackedChildAndPreservesConflictingPidRecord() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock {
      _ = delegate.terminateOwnedCore(in: directory)
      try? FileManager.default.removeItem(at: directory)
    }
    let coreURL = directory.appendingPathComponent("AtlasCore")
    try buildNativeCoreFixture(at: coreURL)
    let processFinished = DispatchSemaphore(value: 0)
    let launch = try delegate.launchOwnedCore(
      in: directory,
      arguments: [],
      makeProcess: {
        let process = Process()
        process.terminationHandler = { _ in processFinished.signal() }
        return process
      }
    )
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    let replacement = "v2 5252 101 2\n"
    try replacement.write(to: pidURL, atomically: true, encoding: .utf8)

    XCTAssertTrue(delegate.terminateOwnedCoreRecord(
      in: directory,
      expectedContents: launch.pidRecordContents
    ))
    XCTAssertEqual(processFinished.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(try String(contentsOf: pidURL, encoding: .utf8), replacement)
  }

  func testExactStopContainsTrackedChildWhenExecutablePathDisappears() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock {
      _ = delegate.terminateOwnedCore(in: directory)
      try? FileManager.default.removeItem(at: directory)
    }
    let coreURL = directory.appendingPathComponent("AtlasCore")
    try buildNativeCoreFixture(at: coreURL)
    let processFinished = DispatchSemaphore(value: 0)
    let launch = try delegate.launchOwnedCore(
      in: directory,
      arguments: [],
      makeProcess: {
        let process = Process()
        process.terminationHandler = { _ in processFinished.signal() }
        return process
      }
    )
    try FileManager.default.removeItem(at: coreURL)

    XCTAssertTrue(delegate.terminateOwnedCoreRecord(
      in: directory,
      expectedContents: launch.pidRecordContents
    ))
    XCTAssertEqual(processFinished.wait(timeout: .now() + 2), .success)
    XCTAssertFalse(FileManager.default.fileExists(atPath: coreURL.path))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("AtlasCore.pid").path
    ))
  }

  func testExactStopContainsTrackedChildAfterIdentityGateRecordReplacement() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock {
      _ = delegate.terminateOwnedCore(in: directory)
      try? FileManager.default.removeItem(at: directory)
    }
    let coreURL = directory.appendingPathComponent("AtlasCore")
    try buildNativeCoreFixture(at: coreURL)
    let processFinished = DispatchSemaphore(value: 0)
    let launch = try delegate.launchOwnedCore(
      in: directory,
      arguments: [],
      makeProcess: {
        let process = Process()
        process.terminationHandler = { _ in processFinished.signal() }
        return process
      }
    )
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    let record = try XCTUnwrap(CorePidRecord(text: launch.pidRecordContents))
    let replacement = "v2 5252 101 2\n"
    var identityReads = 0
    var pidSignals: [Int32] = []

    XCTAssertTrue(delegate.terminateOwnedCoreRecord(
      in: directory,
      expectedContents: launch.pidRecordContents,
      identityForProcess: { _, expectedPath in
        identityReads += 1
        if identityReads == 1 {
          try? replacement.write(to: pidURL, atomically: true, encoding: .utf8)
        }
        return record.identity(executablePath: expectedPath)
      },
      signalProcess: { _, signal in
        pidSignals.append(signal)
        return 0
      }
    ))

    XCTAssertEqual(identityReads, 1)
    XCTAssertTrue(pidSignals.isEmpty)
    XCTAssertEqual(processFinished.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(try String(contentsOf: pidURL, encoding: .utf8), replacement)
  }

  func testTerminationCleanupWaitsForPendingCoreProcessOperations() {
    let delegate = AppDelegate()
    let persistenceStarted = DispatchSemaphore(value: 0)
    let releasePersistence = DispatchSemaphore(value: 0)
    let cleanupFinished = DispatchSemaphore(value: 0)
    var events: [String] = []

    delegate.enqueueCoreProcessOperation {
      persistenceStarted.signal()
      _ = releasePersistence.wait(timeout: .now() + 2)
      events.append("persisted")
    }
    XCTAssertEqual(persistenceStarted.wait(timeout: .now() + 1), .success)

    DispatchQueue.global(qos: .userInitiated).async {
      delegate.performCoreProcessOperationAndWait {
        events.append("cleanup")
      }
      cleanupFinished.signal()
    }

    XCTAssertEqual(cleanupFinished.wait(timeout: .now() + 0.1), .timedOut)
    releasePersistence.signal()
    XCTAssertEqual(cleanupFinished.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(events, ["persisted", "cleanup"])
  }

  func testProxyStateReaderRejectsSymlinksAndNonRegularEntriesWithoutBlocking() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let targetURL = directory.appendingPathComponent("target.json")
    let symlinkURL = directory.appendingPathComponent("linked.json")
    let danglingURL = directory.appendingPathComponent("dangling.json")
    let fifoURL = directory.appendingPathComponent("fifo.json")
    let nestedDirectoryURL = directory.appendingPathComponent("directory.json")
    let oversizedURL = directory.appendingPathComponent("oversized.json")
    let unreadableURL = directory.appendingPathComponent("unreadable.json")
    let writableByOthersURL = directory.appendingPathComponent("writable.json")
    let contents = Data("{\"safe\":true}".utf8)
    try contents.write(to: targetURL)
    try Data(repeating: 0x61, count: 1_048_577).write(to: oversizedURL)
    try contents.write(to: unreadableURL)
    XCTAssertEqual(Darwin.chmod(unreadableURL.path, 0), 0)
    addTeardownBlock { _ = Darwin.chmod(unreadableURL.path, S_IRUSR | S_IWUSR) }
    try contents.write(to: writableByOthersURL)
    XCTAssertEqual(Darwin.chmod(writableByOthersURL.path, S_IRUSR | S_IWUSR | S_IWOTH), 0)
    try FileManager.default.createSymbolicLink(
      at: symlinkURL,
      withDestinationURL: targetURL
    )
    try FileManager.default.createSymbolicLink(
      at: danglingURL,
      withDestinationURL: directory.appendingPathComponent("missing.json")
    )
    XCTAssertEqual(Darwin.mkfifo(fifoURL.path, S_IRUSR | S_IWUSR), 0)
    try FileManager.default.createDirectory(
      at: nestedDirectoryURL,
      withIntermediateDirectories: false
    )

    XCTAssertEqual(delegate.readProxyStateData(at: targetURL), contents)
    XCTAssertNil(delegate.readProxyStateData(at: symlinkURL))
    XCTAssertNil(delegate.readProxyStateData(at: danglingURL))
    let startedAt = Date()
    XCTAssertNil(delegate.readProxyStateData(at: fifoURL))
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
    XCTAssertNil(delegate.readProxyStateData(at: nestedDirectoryURL))
    XCTAssertNil(delegate.readProxyStateData(at: oversizedURL))
    XCTAssertNil(delegate.readProxyStateData(at: unreadableURL))
    XCTAssertNil(delegate.readProxyStateData(at: writableByOthersURL))
  }

  func testProxyStatePathDetectionKeepsDanglingSymlinkAsRecoveryEvidence() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appendingPathComponent("system_proxy.json")
    try FileManager.default.createSymbolicLink(
      at: stateURL,
      withDestinationURL: directory.appendingPathComponent("missing.json")
    )

    XCTAssertTrue(delegate.proxyStatePathEntryExists(at: stateURL))
    XCTAssertNil(delegate.readProxyStateData(at: stateURL))
  }

  func testLegacyProxyStateWithoutOwnershipProofRemainsUnresolved() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appendingPathComponent("system_proxy.json")
    try Data("{\"Wi-Fi\":{}}".utf8).write(to: stateURL)

    XCTAssertFalse(delegate.restoreSavedProxyState(at: stateURL))
    XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
  }

  func testOwnershipOnlyProxyStateRemainsUnresolvedWithoutCommands() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appendingPathComponent("system_proxy.json")
    let contents = """
    {"_ownedProxyHost":"127.0.0.1","_ownedProxyPort":7890,"_ownerPid":4242}
    """
    try Data(contents.utf8).write(to: stateURL)
    var commands: [[String]] = []

    let restored = delegate.restoreSavedProxyState(
      at: stateURL,
      proxyCommandRunner: { _, arguments in
        commands.append(arguments)
        return ProxyCommandResult(succeeded: false, output: nil)
      }
    )

    XCTAssertFalse(restored)
    XCTAssertTrue(commands.isEmpty)
    XCTAssertEqual(try String(contentsOf: stateURL, encoding: .utf8), contents)
  }

  func testMalformedProxyServiceRemainsUnresolvedWithoutCommands() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appendingPathComponent("system_proxy.json")
    let contents = """
    {"_ownedProxyHost":"127.0.0.1","_ownedProxyPort":7890,"Wi-Fi":{"web":{"enabled":false,"server":"","port":0},"secureWeb":{"enabled":false,"server":"","port":0}}}
    """
    try Data(contents.utf8).write(to: stateURL)
    var commands: [[String]] = []

    let restored = delegate.restoreSavedProxyState(
      at: stateURL,
      proxyCommandRunner: { _, arguments in
        commands.append(arguments)
        return ProxyCommandResult(succeeded: false, output: nil)
      }
    )

    XCTAssertFalse(restored)
    XCTAssertTrue(commands.isEmpty)
    XCTAssertEqual(try String(contentsOf: stateURL, encoding: .utf8), contents)
  }

  func testBooleanProxyOwnershipPortRemainsUnresolvedWithoutCommands() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appendingPathComponent("system_proxy.json")
    let contents = """
    {"_ownedProxyHost":"127.0.0.1","_ownedProxyPort":true,"Wi-Fi":{"web":{"enabled":false,"server":"","port":0},"secureWeb":{"enabled":false,"server":"","port":0},"socks":{"enabled":false,"server":"","port":0}}}
    """
    try Data(contents.utf8).write(to: stateURL)
    var commands: [[String]] = []

    let restored = delegate.restoreSavedProxyState(
      at: stateURL,
      proxyCommandRunner: { _, arguments in
        commands.append(arguments)
        return ProxyCommandResult(succeeded: false, output: nil)
      }
    )

    XCTAssertFalse(restored)
    XCTAssertTrue(commands.isEmpty)
    XCTAssertEqual(try String(contentsOf: stateURL, encoding: .utf8), contents)
  }

  func testUnderscorePrefixedProxyServiceIsRestored() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appendingPathComponent("system_proxy.json")
    let contents = """
    {"_ownedProxyHost":"127.0.0.1","_ownedProxyPort":7890,"_Wi-Fi":{"web":{"enabled":false,"server":"","port":0},"secureWeb":{"enabled":false,"server":"","port":0},"socks":{"enabled":false,"server":"","port":0}}}
    """
    try Data(contents.utf8).write(to: stateURL)
    var commands: [[String]] = []

    let restored = delegate.restoreSavedProxyState(
      at: stateURL,
      proxyCommandRunner: { _, arguments in
        commands.append(arguments)
        if arguments.first?.hasPrefix("-get") == true {
          return ProxyCommandResult(
            succeeded: true,
            output: "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n"
          )
        }
        return ProxyCommandResult(succeeded: true, output: nil)
      }
    )

    XCTAssertTrue(restored)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    XCTAssertEqual(commands, [
      ["-getwebproxy", "_Wi-Fi"],
      ["-setwebproxystate", "_Wi-Fi", "off"],
      ["-getsecurewebproxy", "_Wi-Fi"],
      ["-setsecurewebproxystate", "_Wi-Fi", "off"],
      ["-getsocksfirewallproxy", "_Wi-Fi"],
      ["-setsocksfirewallproxystate", "_Wi-Fi", "off"],
    ])
  }

  func testXCTestEnvironmentSurvivesDyldVariableSanitization() {
    XCTAssertTrue(AppDelegate.isXCTestEnvironment([
      "XCTestBundlePath": "Contents/PlugIns/RunnerTests.xctest",
      "XCTestSessionIdentifier": "session-id",
    ]))
  }

  func testXCTestEnvironmentRejectsOrdinaryAndIncompleteDebugLaunches() {
    XCTAssertFalse(AppDelegate.isXCTestEnvironment([:]))
    XCTAssertFalse(AppDelegate.isXCTestEnvironment([
      "XCTestBundlePath": "Contents/PlugIns/RunnerTests.xctest",
    ]))
    XCTAssertFalse(AppDelegate.isXCTestEnvironment([
      "XCTestBundlePath": "Contents/PlugIns/RunnerTests.xctest",
      "XCTestSessionIdentifier": " \n\t ",
    ]))
    XCTAssertFalse(AppDelegate.isXCTestEnvironment([
      "XCTestSessionIdentifier": "session-id",
    ]))
  }

  func testXCTestEnvironmentAcceptsLegacyBundleInjectionMarker() {
    XCTAssertTrue(AppDelegate.isXCTestEnvironment([
      "XCTestBundlePath": "Contents/PlugIns/RunnerTests.xctest",
      "DYLD_INSERT_LIBRARIES": "/tmp/libXCTestBundleInject.dylib",
    ]))
  }

  func testInstanceLeaseExcludesASecondProcessAndTransfersAfterRelease() throws {
    let first = AppDelegate()
    let second = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let leaseURL = directory.appendingPathComponent("instance.lock")
    addTeardownBlock {
      first.releaseInstanceLease()
      second.releaseInstanceLease()
      try? FileManager.default.removeItem(at: directory)
    }

    XCTAssertTrue(first.acquireInstanceLease(at: leaseURL))
    XCTAssertFalse(second.acquireInstanceLease(at: leaseURL))
    XCTAssertTrue(first.ownsInstanceLease)
    XCTAssertFalse(second.ownsInstanceLease)

    first.releaseInstanceLease()
    XCTAssertTrue(second.acquireInstanceLease(at: leaseURL))
  }

  func testLeaseLoserCannotRunTerminationCleanup() throws {
    let owner = AppDelegate()
    let loser = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let leaseURL = directory.appendingPathComponent("instance.lock")
    addTeardownBlock {
      owner.releaseInstanceLease()
      loser.releaseInstanceLease()
      try? FileManager.default.removeItem(at: directory)
    }
    XCTAssertTrue(owner.acquireInstanceLease(at: leaseURL))
    XCTAssertFalse(loser.acquireInstanceLease(at: leaseURL))
    var ownerCleanupCount = 0
    var loserCleanupCount = 0

    XCTAssertTrue(owner.performTerminationCleanupIfLeaseOwner {
      ownerCleanupCount += 1
    })
    XCTAssertFalse(loser.performTerminationCleanupIfLeaseOwner {
      loserCleanupCount += 1
    })
    XCTAssertEqual(ownerCleanupCount, 1)
    XCTAssertEqual(loserCleanupCount, 0)
  }

  func testDockReopenRevealsHiddenWindow() {
    let delegate = AppDelegate()
    let miniaturizedWindow = FakeWindowRevealTarget(isMiniaturized: true)
    let hiddenWindow = FakeWindowRevealTarget(isMiniaturized: false)

    XCTAssertTrue(delegate.revealWindow(miniaturizedWindow))
    XCTAssertEqual(miniaturizedWindow.deminiaturizeCallCount, 1)
    XCTAssertEqual(miniaturizedWindow.makeKeyAndOrderFrontCallCount, 1)
    XCTAssertFalse(miniaturizedWindow.isMiniaturized)

    XCTAssertTrue(delegate.revealWindow(hiddenWindow))
    XCTAssertEqual(hiddenWindow.deminiaturizeCallCount, 0)
    XCTAssertEqual(hiddenWindow.makeKeyAndOrderFrontCallCount, 1)
  }

  func testDockReopenDelegateHandlesDockActivation() {
    let delegate = AppDelegate()
    var revealCount = 0

    XCTAssertTrue(delegate.handleApplicationReopen { revealCount += 1 })
    XCTAssertEqual(revealCount, 1)
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

  func testTerminationPreservesOversizedPidFileFailClosed() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    let contents = String(repeating: "9", count: 129)
    try contents.write(to: pidURL, atomically: true, encoding: .utf8)

    XCTAssertFalse(delegate.terminateOwnedCore(in: directory))
    XCTAssertEqual(try String(contentsOf: pidURL, encoding: .utf8), contents)
  }

  func testTerminationDoesNotFollowPidFileSymlinks() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let targetURL = directory.appendingPathComponent("target")
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    let contents = "v2 4242 100 1\n"
    try contents.write(to: targetURL, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: pidURL,
      withDestinationURL: targetURL
    )

    XCTAssertFalse(delegate.terminateOwnedCore(in: directory))
    XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), contents)
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: pidURL.path),
      targetURL.path
    )
  }

  func testTerminationPreservesDanglingPidFileSymlinks() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let targetURL = directory.appendingPathComponent("missing-target")
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    try FileManager.default.createSymbolicLink(
      at: pidURL,
      withDestinationURL: targetURL
    )

    XCTAssertFalse(delegate.terminateOwnedCore(in: directory))
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: pidURL.path),
      targetURL.path
    )
  }

  func testTerminationDoesNotBlockOnPidFileFifo() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    XCTAssertEqual(Darwin.mkfifo(pidURL.path, S_IRUSR | S_IWUSR), 0)
    let startedAt = Date()

    XCTAssertFalse(delegate.terminateOwnedCore(in: directory))
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pidURL.path))
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
      expectedPidContents: "4242\n",
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
    let coreURL = directory.appendingPathComponent("AtlasCore")
    try buildNativeCoreFixture(at: coreURL)

    let process = Process()
    let processFinished = DispatchSemaphore(value: 0)
    var observedProcessExit = false
    process.executableURL = coreURL
    process.arguments = [readyURL.path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { _ in processFinished.signal() }
    try process.run()
    addTeardownBlock {
      if process.isRunning {
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
      }
      if !observedProcessExit {
        _ = processFinished.wait(timeout: .now() + 2)
      }
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
      expectedPidContents: "\(pid)\n",
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
    observedProcessExit = processFinished.wait(timeout: .now() + 2) == .success

    XCTAssertTrue(stopped)
    XCTAssertTrue(observedProcessExit)
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
      expectedPidContents: "4242\n",
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
      expectedPidContents: "4242\n",
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
      expectedPidContents: "4242\n",
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
      expectedPidContents: "4242\n",
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
      expectedPidContents: "4242\n",
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
    let originalRecord = CorePidRecord(identity: original)
    try originalRecord.serialized.write(
      to: pidURL,
      atomically: true,
      encoding: .utf8
    )
    var identityReads = 0
    var sentSignals: [Int32] = []

    let stopped = delegate.terminateOwnedCore(
      in: directory,
      identityForProcess: { _, _ in
        identityReads += 1
        return replacement
      },
      signalProcess: { _, signal in
        sentSignals.append(signal)
        return 0
      },
      isProcessAlive: { _ in true },
      sleep: { _ in }
    )

    XCTAssertFalse(stopped)
    XCTAssertEqual(identityReads, 1)
    XCTAssertTrue(sentSignals.isEmpty)
    XCTAssertEqual(
      try String(contentsOf: pidURL, encoding: .utf8),
      originalRecord.serialized
    )
  }

  func testTerminationStopsOnlyTheMatchingPersistedGeneration() throws {
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
    let identity = CoreProcessIdentity(
      pid: 4242,
      executablePath: corePath,
      startSeconds: 100,
      startMicroseconds: 1
    )
    let record = CorePidRecord(identity: identity)
    try record.serialized.write(
      to: pidURL,
      atomically: true,
      encoding: .utf8
    )
    var processIsAlive = true
    var sentSignals: [Int32] = []

    let stopped = delegate.terminateOwnedCore(
      in: directory,
      identityForProcess: { _, _ in processIsAlive ? identity : nil },
      signalProcess: { _, signal in
        sentSignals.append(signal)
        processIsAlive = false
        return 0
      },
      isProcessAlive: { _ in processIsAlive },
      sleep: { _ in }
    )

    XCTAssertTrue(stopped)
    XCTAssertEqual(sentSignals, [SIGTERM])
    XCTAssertFalse(FileManager.default.fileExists(atPath: pidURL.path))
  }

  func testPidRecordRoundTripsNativeStartGeneration() throws {
    let identity = CoreProcessIdentity(
      pid: 4242,
      executablePath: "/tmp/SSRVPN/AtlasCore",
      startSeconds: 100,
      startMicroseconds: 123_456
    )
    let record = CorePidRecord(identity: identity)

    XCTAssertEqual(CorePidRecord(text: record.serialized), record)
    XCTAssertNil(CorePidRecord(text: "4242\n"))
    XCTAssertNil(CorePidRecord(text: "v2 4242 100 1000000\n"))
  }

  func testAtomicPidRecordWriteUsesExclusivePrivatePermissions() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let identity = CoreProcessIdentity(
      pid: 4242,
      executablePath: directory.appendingPathComponent("AtlasCore").path,
      startSeconds: 100,
      startMicroseconds: 123_456
    )
    let contents = CorePidRecord(identity: identity).serialized
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    try delegate.writePidRecordAtomically(contents, to: pidURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: pidURL.path)

    XCTAssertEqual(contents, CorePidRecord(identity: identity).serialized)
    XCTAssertEqual(try String(contentsOf: pidURL, encoding: .utf8), contents)
    XCTAssertEqual(
      (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0,
      0o600
    )
    XCTAssertThrowsError(
      try delegate.writePidRecordAtomically(contents, to: pidURL)
    )
    XCTAssertEqual(try String(contentsOf: pidURL, encoding: .utf8), contents)
  }

  func testAtomicPidRecordPublishRollsBackAPartialTemporaryWrite() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    let contents = "v2 4242 100 123456\n"

    XCTAssertThrowsError(
      try delegate.writePidRecordAtomically(
        contents,
        to: pidURL,
        writeContents: { descriptor, bytes in
          let written = bytes.withUnsafeBytes { rawBuffer in
            Darwin.write(descriptor, rawBuffer.baseAddress, 3)
          }
          XCTAssertEqual(written, 3)
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
      )
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: pidURL.path))
    let leftovers = try FileManager.default.contentsOfDirectory(
      atPath: directory.path
    ).filter { $0.hasPrefix(".AtlasCore.pid.pending-") }
    XCTAssertTrue(leftovers.isEmpty)
  }

  func testNativeLaunchPublishFailureContainsItsDirectChild() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let coreURL = directory.appendingPathComponent("AtlasCore")
    try buildNativeCoreFixture(at: coreURL)
    var launchedProcess: Process?
    let processFinished = DispatchSemaphore(value: 0)
    var observedProcessExit = false
    addTeardownBlock {
      if launchedProcess?.isRunning == true {
        _ = Darwin.kill(launchedProcess!.processIdentifier, SIGKILL)
      }
      if launchedProcess != nil && !observedProcessExit {
        _ = processFinished.wait(timeout: .now() + 2)
      }
    }

    XCTAssertThrowsError(
      try delegate.launchOwnedCore(
        in: directory,
        arguments: [],
        writeRecord: { _, _ in
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        },
        makeProcess: {
          let process = Process()
          process.terminationHandler = { _ in processFinished.signal() }
          launchedProcess = process
          return process
        }
      )
    )

    observedProcessExit = processFinished.wait(timeout: .now() + 2) == .success
    XCTAssertNotNil(launchedProcess)
    XCTAssertTrue(observedProcessExit)
    XCTAssertFalse(launchedProcess?.isRunning ?? true)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("AtlasCore.pid").path
    ))
  }

  func testStrictProxySnapshotFailuresRemainUnresolvedWithoutCommands() throws {
    let snapshots = [
      """
      {"_ownedProxyHost":"127.0.0.1","_ownedProxyPort":7890,"Wi-Fi":{"web":{"enabled":false,"server":"","port":0},"secureWeb":{"enabled":false,"server":"","port":0},"socks":{"enabled":false,"server":"","port":0},"futureState":{}}}
      """,
      """
      {"_ownedProxyHost":"127.0.0.1","_ownedProxyPort":7890,"Wi-Fi":{"web":{"enabled":false,"server":"","port":0,"futureField":true},"secureWeb":{"enabled":false,"server":"","port":0},"socks":{"enabled":false,"server":"","port":0}}}
      """,
      """
      {"_ownedProxyHost":"127.0.0.1","_ownedProxyPort":7890,"Wi-Fi":{"web":{"enabled":true,"server":"   ","port":8080},"secureWeb":{"enabled":false,"server":"","port":0},"socks":{"enabled":false,"server":"","port":0}}}
      """,
    ]

    for (index, contents) in snapshots.enumerated() {
      let delegate = AppDelegate()
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString)-\(index)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
      let stateURL = directory.appendingPathComponent("system_proxy.json")
      try Data(contents.utf8).write(to: stateURL)
      var commands: [[String]] = []

      let restored = delegate.restoreSavedProxyState(
        at: stateURL,
        proxyCommandRunner: { _, arguments in
          commands.append(arguments)
          return ProxyCommandResult(succeeded: false, output: nil)
        }
      )

      XCTAssertFalse(restored)
      XCTAssertTrue(commands.isEmpty)
      XCTAssertEqual(try String(contentsOf: stateURL, encoding: .utf8), contents)
    }
  }

  func testLegacyLivePidRecordFailsClosedWithoutSendingSignals() throws {
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
    var identityReads = 0
    var sentSignals: [Int32] = []

    let stopped = delegate.terminateOwnedCore(
      in: directory,
      identityForProcess: { _, _ in
        identityReads += 1
        return nil
      },
      signalProcess: { _, signal in
        sentSignals.append(signal)
        return 0
      },
      isProcessAlive: { _ in true },
      sleep: { _ in }
    )

    XCTAssertFalse(stopped)
    XCTAssertEqual(identityReads, 0)
    XCTAssertTrue(sentSignals.isEmpty)
    XCTAssertEqual(try String(contentsOf: pidURL, encoding: .utf8), "4242\n")
  }

  func testLegacyAbsentPidRecordIsRemovedWithoutSendingSignals() throws {
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

    let stopped = delegate.terminateOwnedCore(
      in: directory,
      signalProcess: { _, signal in
        sentSignals.append(signal)
        return 0
      },
      isProcessAlive: { _ in false },
      sleep: { _ in }
    )

    XCTAssertTrue(stopped)
    XCTAssertTrue(sentSignals.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pidURL.path))
  }

  func testPidCleanupPreservesSamePidFromANewerGeneration() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    let oldRecord = "v2 4242 100 1\n"
    let newRecord = "v2 4242 101 2\n"
    try newRecord.write(to: pidURL, atomically: true, encoding: .utf8)

    let removed = delegate.removePidFileIfMatching(
      at: pidURL,
      expectedContents: oldRecord
    )

    XCTAssertFalse(removed)
    XCTAssertEqual(try String(contentsOf: pidURL, encoding: .utf8), newRecord)
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

  func testProcessIdentityAcceptsCanonicalAliasForSameExecutable() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("AtlasCore.real")
    let alias = directory.appendingPathComponent("AtlasCore")
    try Data("fixture".utf8).write(to: executable)
    try FileManager.default.createSymbolicLink(
      at: alias,
      withDestinationURL: executable
    )
    let generation = CoreProcessGeneration(
      pid: 4242,
      startSeconds: 100,
      startMicroseconds: 1
    )

    let identity = AppDelegate.currentCoreProcessIdentity(
      pid: generation.pid,
      expectedExecutablePath: alias.path,
      generationForProcess: { _ in generation },
      executablePathForProcess: { _ in executable.path }
    )

    XCTAssertEqual(identity?.pid, generation.pid)
    XCTAssertEqual(identity?.executablePath, alias.path)
    XCTAssertEqual(identity?.startSeconds, generation.startSeconds)
  }

  func testProcessIdentityRejectsGenerationChangeAcrossPathRead() {
    let original = CoreProcessGeneration(
      pid: 4242,
      startSeconds: 100,
      startMicroseconds: 1
    )
    let replacement = CoreProcessGeneration(
      pid: 4242,
      startSeconds: 101,
      startMicroseconds: 2
    )
    var generations = [original, replacement]
    var pathReads = 0

    let identity = AppDelegate.currentCoreProcessIdentity(
      pid: 4242,
      expectedExecutablePath: "/tmp/SSRVPN/AtlasCore",
      generationForProcess: { _ in generations.removeFirst() },
      executablePathForProcess: { _ in
        pathReads += 1
        return "/tmp/SSRVPN/AtlasCore"
      }
    )

    XCTAssertNil(identity)
    XCTAssertTrue(generations.isEmpty)
    XCTAssertEqual(pathReads, 1)
  }

  func testExactRecordTerminationRejectsAReplacementRecord() throws {
    let delegate = AppDelegate()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    let original = "v2 4242 100 1\n"
    let replacement = "v2 4242 101 2\n"
    try replacement.write(to: pidURL, atomically: true, encoding: .utf8)
    var signals: [Int32] = []

    let stopped = delegate.terminateOwnedCoreRecord(
      in: directory,
      expectedContents: original,
      signalProcess: { _, signal in
        signals.append(signal)
        return 0
      },
      isProcessAlive: { _ in true },
      sleep: { _ in }
    )

    XCTAssertFalse(stopped)
    XCTAssertTrue(signals.isEmpty)
    XCTAssertEqual(try String(contentsOf: pidURL, encoding: .utf8), replacement)
  }

  func testExactRecordTerminationStopsAndRemovesOnlyTheMatchingRecord() throws {
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
    let identity = CoreProcessIdentity(
      pid: 4242,
      executablePath: corePath,
      startSeconds: 100,
      startMicroseconds: 1
    )
    let record = CorePidRecord(identity: identity).serialized
    try record.write(to: pidURL, atomically: true, encoding: .utf8)
    var alive = true
    var signals: [Int32] = []

    let stopped = delegate.terminateOwnedCoreRecord(
      in: directory,
      expectedContents: record,
      identityForProcess: { _, _ in alive ? identity : nil },
      signalProcess: { _, signal in
        signals.append(signal)
        alive = false
        return 0
      },
      isProcessAlive: { _ in alive },
      sleep: { _ in }
    )

    XCTAssertTrue(stopped)
    XCTAssertEqual(signals, [SIGTERM])
    XCTAssertFalse(FileManager.default.fileExists(atPath: pidURL.path))
  }

  func testExactRecordTerminationDoesNotEscalateAfterRecordChanges() throws {
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
    let identity = CoreProcessIdentity(
      pid: 4242,
      executablePath: corePath,
      startSeconds: 100,
      startMicroseconds: 1
    )
    let record = CorePidRecord(identity: identity).serialized
    let replacement = "v2 5252 200 2\n"
    try record.write(to: pidURL, atomically: true, encoding: .utf8)
    var signals: [Int32] = []

    let stopped = delegate.terminateOwnedCoreRecord(
      in: directory,
      expectedContents: record,
      identityForProcess: { _, _ in identity },
      signalProcess: { _, signal in
        signals.append(signal)
        if signal == SIGTERM {
          try? replacement.write(to: pidURL, atomically: true, encoding: .utf8)
        }
        return 0
      },
      isProcessAlive: { _ in true },
      sleep: { _ in },
      gracefulPollCount: 1,
      forcedPollCount: 1
    )

    XCTAssertFalse(stopped)
    XCTAssertEqual(signals, [SIGTERM])
    XCTAssertEqual(try String(contentsOf: pidURL, encoding: .utf8), replacement)
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
      expectedPidContents: "4242\n",
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

    XCTAssertFalse(stopped)
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
      expectedContents: "4242\n",
      afterQuarantine: { quarantineURL in
        XCTAssertTrue(
          FileManager.default.fileExists(atPath: quarantineURL.path)
        )
        try? "5252\n".write(to: pidURL, atomically: true, encoding: .utf8)
      }
    )

    XCTAssertFalse(removed)
    XCTAssertEqual(try String(contentsOf: pidURL, encoding: .utf8), "5252\n")
  }

}
