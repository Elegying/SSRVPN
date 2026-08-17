import Cocoa
import Darwin
import FlutterMacOS
import SystemConfiguration

struct ProxyCommandResult {
  let succeeded: Bool
  let output: String?
}

private final class ProxyStateFileSnapshot {
  init(descriptor: Int32, data: Data, fileInfo: stat) {
    self.descriptor = descriptor
    self.data = data
    self.fileInfo = fileInfo
  }

  deinit {
    _ = Darwin.close(descriptor)
  }

  let descriptor: Int32
  let data: Data
  let fileInfo: stat
}

private enum ApplicationTerminationLeaseState: Equatable {
  case idle
  case pending(UUID)
  case committed
}

class AppDelegate: FlutterAppDelegate {
  private let instanceLease = AppInstanceLease()
  private let coreProcessOperationQueue = DispatchQueue(
    label: "com.ssrvpn.core-process-operations",
    qos: .userInitiated
  )
  private var ownedCoreProcesses: [String: NativeOwnedCoreProcess] = [:]
  private let proxyLifecycleLeaseLock = NSLock()
  private var proxyLifecycleLeaseTokens = Set<String>()
  private var applicationTerminationLeaseState = ApplicationTerminationLeaseState.idle
  var replyToPendingApplicationTermination: (Bool) -> Void = {
    NSApp.reply(toApplicationShouldTerminate: $0)
  }
  var schedulePendingApplicationTerminationTimeout: (@escaping () -> Void) -> Void = {
    callback in
    DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: callback)
  }

  private static var activationNotificationName: Notification.Name {
    Notification.Name("com.ssrvpn.activate.\(geteuid())")
  }

  private var isRunningUnderXCTest: Bool {
    Self.isXCTestEnvironment(ProcessInfo.processInfo.environment)
  }

  static func isXCTestEnvironment(_ environment: [String: String]) -> Bool {
#if DEBUG
    guard environment["XCTestBundlePath"]?.hasSuffix(".xctest") == true else {
      return false
    }
    let sessionIdentifier = environment["XCTestSessionIdentifier"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let hasSession = sessionIdentifier?.isEmpty == false
    let hasInjectedBundle = environment["DYLD_INSERT_LIBRARIES"]?
      .contains("libXCTestBundleInject") == true
    // Hardened launch services may strip DYLD_* variables before Swift reads
    // ProcessInfo. Xcode still provides the XCTest bundle and session pair.
    return hasSession || hasInjectedBundle
#else
    return false
#endif
  }

  var ownsInstanceLease: Bool {
    instanceLease.isAcquired
  }

  @discardableResult
  func acquireInstanceLease(at url: URL? = nil) -> Bool {
    // Xcode may launch multiple UI-test hosts in parallel. They use isolated
    // fixtures and must neither contend for the production lease nor run
    // production termination cleanup.
    if url == nil && isRunningUnderXCTest {
      return true
    }
    if ownsInstanceLease { return true }
    let leaseURL = url ?? FileManager.default.temporaryDirectory
      .appendingPathComponent(".ssrvpn-app-instance.lock")
    guard instanceLease.acquire(at: leaseURL) else { return false }
    if url == nil {
      DistributedNotificationCenter.default().addObserver(
        self,
        selector: #selector(handlePrimaryInstanceActivation),
        name: AppDelegate.activationNotificationName,
        object: nil
      )
    }
    return true
  }

  func requestPrimaryInstanceActivation() {
    DistributedNotificationCenter.default().postNotificationName(
      AppDelegate.activationNotificationName,
      object: nil,
      userInfo: nil,
      deliverImmediately: true
    )
  }

  @objc private func handlePrimaryInstanceActivation(_ notification: Notification) {
    guard ownsInstanceLease else { return }
    revealMainWindow()
  }

  func releaseInstanceLease() {
    instanceLease.release()
  }

  func enqueueCoreProcessOperation(_ operation: @escaping () -> Void) {
    coreProcessOperationQueue.async(execute: operation)
  }

  func performCoreProcessOperationAndWait(_ operation: () -> Void) {
    coreProcessOperationQueue.sync(execute: operation)
  }

  func startProxyGuardian(
    statePath: String,
    nonce: String,
    readyTimeout: TimeInterval = 2
  ) -> Bool {
    guard
      (statePath as NSString).isAbsolutePath,
      ProxyGuardianCommand.isValidNonce(nonce),
      let generation = AppDelegate.currentProcessGeneration(getpid()),
      let executablePath = AppDelegate.currentExecutablePath(getpid())
    else {
      return false
    }
    let stateURL = URL(fileURLWithPath: statePath).standardizedFileURL
    let canonicalExecutable = URL(fileURLWithPath: executablePath)
      .standardizedFileURL.resolvingSymlinksInPath().path
    let owner = ProxyGuardianOwnerIdentity(
      pid: getpid(),
      startSeconds: generation.startSeconds,
      startMicroseconds: generation.startMicroseconds,
      executablePath: canonicalExecutable
    )
    let guardianArguments = ProxyGuardianArguments(
      stateURL: stateURL,
      nonce: nonce,
      owner: owner
    )
    guard !proxyStatePathEntryExists(at: guardianArguments.readyURL) else {
      return false
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: canonicalExecutable)
    process.arguments = ProxyGuardianCommand.arguments(
      stateURL: stateURL,
      nonce: nonce,
      owner: owner
    )
    if let nullOutput = FileHandle(forWritingAtPath: "/dev/null") {
      process.standardOutput = nullOutput
      process.standardError = nullOutput
    }
    process.terminationHandler = { _ in }
    do {
      try process.run()
    } catch {
      return false
    }

    let deadline = Date().addingTimeInterval(readyTimeout)
    while Date() < deadline {
      if ProxyGuardianCommand.consumeReadyFile(
        at: guardianArguments.readyURL,
        nonce: nonce
      ) {
        return process.isRunning
      }
      if !process.isRunning { return false }
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning { process.terminate() }
    return false
  }

  @discardableResult
  func performTerminationCleanupIfLeaseOwner(_ cleanup: () -> Void) -> Bool {
    guard ownsInstanceLease else { return false }
    cleanup()
    return true
  }

  // 返回 false：退出由 Flutter 侧 _quitApp() 主动调用 SystemNavigator.pop() 控制，
  // 避免系统在窗口关闭时自动终止应用，窗口关闭由 Flutter 层统一处理。
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    var pendingIdentifierToSchedule: UUID?
    var shouldRunPreflight = false
    proxyLifecycleLeaseLock.lock()
    if proxyLifecycleLeaseTokens.isEmpty {
      if applicationTerminationLeaseState == .idle {
        applicationTerminationLeaseState = .committed
        shouldRunPreflight = true
      }
      proxyLifecycleLeaseLock.unlock()
      if shouldRunPreflight {
        let safe = prepareForSafeApplicationTermination()
        if !safe { resetCommittedApplicationTermination() }
        return safe ? .terminateNow : .terminateCancel
      }
      return .terminateLater
    }
    if applicationTerminationLeaseState == .idle {
      let identifier = UUID()
      applicationTerminationLeaseState = .pending(identifier)
      pendingIdentifierToSchedule = identifier
    }
    proxyLifecycleLeaseLock.unlock()
    if let identifier = pendingIdentifierToSchedule {
      schedulePendingApplicationTerminationTimeout { [weak self] in
        self?.cancelPendingApplicationTerminationIfNeeded(identifier: identifier)
      }
    }
    return .terminateLater
  }

  func beginProxyLifecycleTransaction() -> String? {
    proxyLifecycleLeaseLock.lock()
    guard applicationTerminationLeaseState == .idle else {
      proxyLifecycleLeaseLock.unlock()
      return nil
    }
    let token = UUID().uuidString
    proxyLifecycleLeaseTokens.insert(token)
    proxyLifecycleLeaseLock.unlock()
    return token
  }

  @discardableResult
  func endProxyLifecycleTransaction(token: String) -> Bool {
    var shouldReply = false
    proxyLifecycleLeaseLock.lock()
    guard proxyLifecycleLeaseTokens.remove(token) != nil else {
      proxyLifecycleLeaseLock.unlock()
      return false
    }
    if proxyLifecycleLeaseTokens.isEmpty,
      case .pending = applicationTerminationLeaseState
    {
      applicationTerminationLeaseState = .committed
      shouldReply = true
    }
    proxyLifecycleLeaseLock.unlock()
    if shouldReply {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        let safe = self.prepareForSafeApplicationTermination()
        if !safe { self.resetCommittedApplicationTermination() }
        self.replyToPendingApplicationTermination(safe)
      }
    }
    return true
  }

  private func cancelPendingApplicationTerminationIfNeeded(identifier: UUID) {
    var shouldCancelTermination = false
    proxyLifecycleLeaseLock.lock()
    if applicationTerminationLeaseState == .pending(identifier),
      !proxyLifecycleLeaseTokens.isEmpty
    {
      applicationTerminationLeaseState = .idle
      shouldCancelTermination = true
    }
    proxyLifecycleLeaseLock.unlock()
    if shouldCancelTermination {
      // A lost Dart/end-channel reply must not hang Cmd+Q forever. Cancelling
      // this quit attempt lets the in-flight proxy mutation finish safely; it
      // never authorizes a timeout-based process exit.
      replyToPendingApplicationTermination(false)
    }
  }

  var hasActiveProxyLifecycleTransaction: Bool {
    proxyLifecycleLeaseLock.lock()
    let active = !proxyLifecycleLeaseTokens.isEmpty
    proxyLifecycleLeaseLock.unlock()
    return active
  }

  func currentNetworkServiceIdentities() -> [String: String]? {
    guard
      let preferences = SCPreferencesCreate(
        nil,
        "com.ssrvpn.network-service-identities" as CFString,
        nil
      ),
      // `networksetup` manages the current location's services. Reading every
      // preference service also returns orphaned entries that it cannot name.
      let currentSet = SCNetworkSetCopyCurrent(preferences),
      let rawServices = SCNetworkSetCopyServices(currentSet)
    else {
      return nil
    }
    let services = rawServices as NSArray
    var identities: [String: String] = [:]
    var seenIDs = Set<String>()
    for case let service as SCNetworkService in services {
      guard
        let rawName = SCNetworkServiceGetName(service),
        let rawServiceID = SCNetworkServiceGetServiceID(service)
      else {
        return nil
      }
      let name = (rawName as String)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let serviceID = (rawServiceID as String)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        !name.isEmpty,
        !serviceID.isEmpty,
        identities[name] == nil,
        seenIDs.insert(serviceID).inserted
      else {
        return nil
      }
      identities[name] = serviceID
    }
    return identities
  }

  private func resetCommittedApplicationTermination() {
    proxyLifecycleLeaseLock.lock()
    if applicationTerminationLeaseState == .committed {
      applicationTerminationLeaseState = .idle
    }
    proxyLifecycleLeaseLock.unlock()
  }

  @discardableResult
  func performSafeTerminationPreflight(
    hadProxyState: Bool,
    hasTunSessionRequest: Bool = false,
    restoreProxy: () -> Bool,
    terminateCore: () -> Bool,
    onFailure: (String) -> Void
  ) -> Bool {
    if hadProxyState && !restoreProxy() {
      onFailure("系统代理恢复失败。SSRVPN 已保留窗口和菜单栏图标，未继续终止当前 Mihomo 核心；请修复网络后重试退出。")
      return false
    }
    if hasTunSessionRequest {
      // The privileged runner owns the TUN core and must restore DNS before it
      // retires the exact session marker. App termination is the stop signal;
      // native cleanup must not delete that recovery evidence or kill the DNS
      // listener ahead of the runner's commit point.
      return true
    }
    if !terminateCore() {
      onFailure("Mihomo 安全停止失败。SSRVPN 已保留窗口和菜单栏图标，请稍后重试退出。")
      return false
    }
    return true
  }

  private func prepareForSafeApplicationTermination() -> Bool {
    guard ownsInstanceLease else { return true }
    var failureMessage: String?
    var safe = false
    performCoreProcessOperationAndWait {
      let proxyStateURL = findProxyStateFile()
      let runtimeDirectory = runtimeDirectoryForTermination(proxyStateURL: proxyStateURL)
      safe = performSafeTerminationPreflight(
        hadProxyState: proxyStateURL != nil,
        hasTunSessionRequest: hasTunSessionRequest(),
        restoreProxy: {
          guard let proxyStateURL else { return true }
          return restoreSavedProxyState(at: proxyStateURL)
        },
        terminateCore: {
          guard let runtimeDirectory else { return true }
          return terminateOwnedCore(in: runtimeDirectory)
        },
        onFailure: { failureMessage = $0 }
      )
    }
    if let failureMessage {
      presentTerminationFailure(failureMessage)
    }
    return safe
  }

  private func presentTerminationFailure(_ message: String) {
    _ = revealMainWindow()
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "SSRVPN 未能安全退出"
    alert.informativeText = message
    alert.addButton(withTitle: "知道了")
    let window = NSApp.windows.first(where: { $0 is MainFlutterWindow })
      ?? NSApp.windows.first(where: { $0.canBecomeKey || $0.canBecomeMain })
    if let window {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    return handleApplicationReopen {
      _ = revealMainWindow(in: sender)
    }
  }

  @discardableResult
  func handleApplicationReopen(_ reveal: () -> Void) -> Bool {
    reveal()
    return true
  }

  @discardableResult
  func revealMainWindow(in application: NSApplication = NSApp) -> Bool {
    application.unhide(nil)
    application.activate(ignoringOtherApps: true)
    let window = application.windows.first(where: { $0 is MainFlutterWindow })
      ?? application.windows.first(where: { $0.canBecomeKey || $0.canBecomeMain })
    return revealWindow(window)
  }

  @discardableResult
  func revealWindow(_ window: WindowRevealTarget?) -> Bool {
    WindowRevealController.reveal(window)
  }

  // Cmd+Q 等退出路径不经过 Flutter 侧的清理逻辑，
  // 在这里兜底：先恢复代理；只有恢复成功后才终止已记录 PID 的自有核心。
  override func applicationWillTerminate(_ notification: Notification) {
    _ = performTerminationCleanupIfLeaseOwner {
      // MethodChannel lifecycle work runs on the same queue. Waiting here
      // guarantees that a just-started core has either published its identity
      // record or been terminated before Cmd+Q performs the final cleanup.
      performCoreProcessOperationAndWait {
        let hasTunRequest = hasTunSessionRequest()
        let proxyStateURL = findProxyStateFile()
        let runtimeDirectory = runtimeDirectoryForTermination(proxyStateURL: proxyStateURL)
        let hadProxyState = proxyStateURL != nil
        let proxyRestored = restoreSavedProxyState()
        if (!hadProxyState || proxyRestored) && !hasTunRequest {
          _ = terminateOwnedCore(in: runtimeDirectory)
        } else if hasTunRequest {
          NSLog("[AppDelegate] Leaving TUN teardown to the privileged DNS recovery runner")
        } else {
          NSLog("[AppDelegate] Keeping AtlasCore alive because proxy restore failed")
        }
      }
    }
    DistributedNotificationCenter.default().removeObserver(self)
    releaseInstanceLease()
    // NSApplicationDelegate termination is an optional callback. Flutter's
    // parent delegate has no implementation to chain to here.
  }

  func tunRequestURLs(in support: URL) -> [URL] {
    var urls = [
      support.appendingPathComponent("SSRVPN/.tun-session-request")
    ]
    if let bundleId = Bundle.main.bundleIdentifier {
      urls.append(
        support.appendingPathComponent("\(bundleId)/SSRVPN/.tun-session-request")
      )
    }
    return urls
  }

  private func hasTunSessionRequest() -> Bool {
    let fm = FileManager.default
    guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return false
    }
    return tunRequestURLs(in: support).contains { pathEntryExists(at: $0) }
  }

  @discardableResult
  func terminateOwnedCore(
    in directory: URL?,
    identityForProcess: (Int32, String) -> CoreProcessIdentity? = {
      AppDelegate.currentCoreProcessIdentity(pid: $0, expectedExecutablePath: $1)
    },
    signalProcess: (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) },
    isProcessAlive: (Int32) -> Bool = { AppDelegate.processIsAlive($0) },
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    gracefulPollCount: Int = 21,
    forcedPollCount: Int = 11,
    pollInterval: TimeInterval = 0.1
  ) -> Bool {
    guard let directory else { return false }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    let trackedContents = ownedCoreProcesses[
      directory.standardizedFileURL.path
    ]?.pidRecordContents
    if !pathEntryExists(at: pidURL) {
      return containTrackedCoreWithoutRecord(in: directory) ?? true
    }
    guard let text = readCorePidContents(at: pidURL) else {
      if let contained = containTrackedCoreWithoutRecord(in: directory) {
        return contained
      }
      NSLog("[AppDelegate] AtlasCore PID file is unreadable; preserving it")
      return false
    }
    if let trackedContents, text != trackedContents {
      NSLog("[AppDelegate] AtlasCore PID record conflicts with the tracked direct child")
      return containTrackedCoreWithoutRecord(in: directory) ?? false
    }
    if let legacyPid = legacyCorePid(from: text) {
      if !isProcessAlive(legacyPid) {
        return removePidFileIfMatching(at: pidURL, expectedContents: text)
      }
      NSLog("[AppDelegate] Legacy AtlasCore PID state has no process generation; preserving it")
      return false
    }
    guard CorePidRecord(text: text) != nil else {
      NSLog("[AppDelegate] AtlasCore PID file is invalid; preserving it")
      return false
    }
    return terminateOwnedCoreRecord(
      in: directory,
      expectedContents: text,
      identityForProcess: identityForProcess,
      signalProcess: signalProcess,
      isProcessAlive: isProcessAlive,
      sleep: sleep,
      gracefulPollCount: gracefulPollCount,
      forcedPollCount: forcedPollCount,
      pollInterval: pollInterval
    )
  }

  @discardableResult
  func terminateOwnedCoreRecord(
    in directory: URL,
    expectedContents: String,
    identityForProcess: (Int32, String) -> CoreProcessIdentity? = {
      AppDelegate.currentCoreProcessIdentity(pid: $0, expectedExecutablePath: $1)
    },
    signalProcess: (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) },
    isProcessAlive: (Int32) -> Bool = { AppDelegate.processIsAlive($0) },
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    gracefulPollCount: Int = 21,
    forcedPollCount: Int = 11,
    pollInterval: TimeInterval = 0.1
  ) -> Bool {
    guard let record = CorePidRecord(text: expectedContents) else { return false }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    let corePath = directory.appendingPathComponent("AtlasCore").path
    guard readCorePidContents(at: pidURL) == expectedContents else {
      if let contained = containTrackedCoreForExactStop(
        in: directory,
        expectedContents: expectedContents
      ) {
        // A retained Foundation Process is the exact direct child created by
        // launchOwnedCore. Containing that handle cannot target a replacement
        // PID, and intentionally leaves any conflicting on-disk record intact.
        return contained
      }
      NSLog("[AppDelegate] AtlasCore PID record changed before termination")
      return false
    }

    let expectedIdentity = record.identity(executablePath: corePath)
    guard identityForProcess(record.pid, corePath) == expectedIdentity else {
      if let contained = containTrackedCoreForExactStop(
        in: directory,
        expectedContents: expectedContents
      ) {
        return contained
      }
      if !isProcessAlive(record.pid) {
        return removePidFileIfMatching(at: pidURL, expectedContents: expectedContents)
      }
      NSLog("[AppDelegate] AtlasCore identity could not be confirmed; preserving PID file")
      return false
    }
    let stopped = terminateConfirmedCoreProcess(
      pid: record.pid,
      pidURL: pidURL,
      expectedPidContents: expectedContents,
      signalProcess: signalProcess,
      isProcessAlive: isProcessAlive,
      canSignalProcess: { pid, _ in
        self.readCorePidContents(at: pidURL) == expectedContents &&
          identityForProcess(pid, corePath) == expectedIdentity
      },
      sleep: sleep,
      gracefulPollCount: gracefulPollCount,
      forcedPollCount: forcedPollCount,
      pollInterval: pollInterval
    )
    if stopped {
      forgetTrackedCore(in: directory, expectedContents: expectedContents)
      return true
    }
    // The PID record or path identity may change after the initial gate but
    // before a signal/cleanup step. The retained Process is still the exact
    // direct child launched with expectedContents, so contain it without ever
    // signaling a PID that may now represent a replacement generation.
    return containTrackedCoreForExactStop(
      in: directory,
      expectedContents: expectedContents
    ) ?? false
  }

  func launchOwnedCore(
    in directory: URL,
    arguments: [String]? = nil,
    identityForProcess: (Int32, String) -> CoreProcessIdentity? = {
      AppDelegate.currentCoreProcessIdentity(pid: $0, expectedExecutablePath: $1)
    },
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    identityPollCount: Int = 51,
    identityPollInterval: TimeInterval = 0.01,
    writeRecord: ((String, URL) throws -> Void)? = nil,
    makeProcess: () -> Process = { Process() }
  ) throws -> CoreLaunchResult {
    let runtimeDirectory = directory.standardizedFileURL
    let runtimeKey = runtimeDirectory.path
    let coreURL = runtimeDirectory.appendingPathComponent("AtlasCore")
    let configURL = runtimeDirectory.appendingPathComponent("config.yaml")
    let pidURL = runtimeDirectory.appendingPathComponent("AtlasCore.pid")
    guard ownedCoreProcesses[runtimeKey] == nil, !pathEntryExists(at: pidURL) else {
      throw corePidError(
        code: EEXIST,
        description: "An AtlasCore generation is already tracked"
      )
    }

    let outputCapture = CoreOutputCapture()
    let process = makeProcess()
    process.executableURL = coreURL
    process.arguments = arguments ?? [
      "-d", runtimeDirectory.path,
      "-f", configURL.path,
    ]
    process.currentDirectoryURL = runtimeDirectory
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = outputCapture.standardOutputPipe
    process.standardError = outputCapture.standardErrorPipe
    let temporaryDirectory = runtimeDirectory.appendingPathComponent(
      "tmp",
      isDirectory: true
    ).path
    process.environment = ProcessInfo.processInfo.environment.merging([
      "TMPDIR": temporaryDirectory,
      "TMP": temporaryDirectory,
      "TEMP": temporaryDirectory,
    ]) { _, newValue in newValue }

    do {
      try process.run()
      outputCapture.closeParentWriteHandles()
    } catch {
      outputCapture.closeParentWriteHandles()
      outputCapture.closeAfterExit()
      throw error
    }

    var identity: CoreProcessIdentity?
    let checks = max(1, identityPollCount)
    for check in 0..<checks {
      let candidate = identityForProcess(process.processIdentifier, coreURL.path)
      if candidate?.pid == process.processIdentifier,
        candidate?.executablePath == coreURL.path,
        candidate?.startSeconds ?? 0 > 0,
        candidate?.startMicroseconds ?? 1_000_000 < 1_000_000
      {
        identity = candidate
        break
      }
      if !process.isRunning { break }
      if check + 1 < checks {
        sleep(max(0, identityPollInterval))
      }
    }

    guard let identity else {
      let contained = containLaunchedCoreProcess(process)
      outputCapture.closeAfterExit()
      if !contained {
        NSLog("[AppDelegate] AtlasCore identity failed and its direct child could not be contained")
      }
      throw corePidError(
        code: ESRCH,
        description: "AtlasCore process identity could not be confirmed after launch"
      )
    }

    let contents = CorePidRecord(identity: identity).serialized
    do {
      if let writeRecord {
        try writeRecord(contents, pidURL)
      } else {
        try writePidRecordAtomically(contents, to: pidURL)
      }
    } catch {
      let contained = containLaunchedCoreProcess(process)
      if readCorePidContents(at: pidURL) == contents {
        _ = removePidFileIfMatching(at: pidURL, expectedContents: contents)
      }
      outputCapture.closeAfterExit()
      if !contained {
        NSLog("[AppDelegate] AtlasCore PID publish failed and its direct child could not be contained")
      }
      throw error
    }

    ownedCoreProcesses[runtimeKey] = NativeOwnedCoreProcess(
      process: process,
      pidRecordContents: contents,
      outputCapture: outputCapture
    )
    return CoreLaunchResult(
      pid: process.processIdentifier,
      pidRecordContents: contents
    )
  }

  func statusForOwnedCore(
    in directory: URL,
    expectedContents: String
  ) -> CoreProcessStatus? {
    let tracked = ownedCoreProcesses[directory.standardizedFileURL.path]
    guard tracked?.pidRecordContents == expectedContents else { return nil }
    return tracked?.takeStatus()
  }

  @discardableResult
  private func containLaunchedCoreProcess(_ process: Process) -> Bool {
    guard process.isRunning else { return true }
    process.terminate()
    let gracefulDeadline = Date().addingTimeInterval(2)
    while process.isRunning && Date() < gracefulDeadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
      // This PID is the still-unreaped direct child held by this Process
      // object, so it cannot have been recycled to an unrelated process.
      if Darwin.kill(process.processIdentifier, SIGKILL) != 0 && process.isRunning {
        return false
      }
      process.waitUntilExit()
    }
    return !process.isRunning
  }

  private func forgetTrackedCore(in directory: URL, expectedContents: String) {
    let key = directory.standardizedFileURL.path
    guard let tracked = ownedCoreProcesses[key],
      tracked.pidRecordContents == expectedContents
    else {
      return
    }
    if !tracked.process.isRunning {
      tracked.outputCapture.closeAfterExit()
    }
    ownedCoreProcesses.removeValue(forKey: key)
  }

  private func containTrackedCoreWithoutRecord(
    in directory: URL,
    expectedContents: String? = nil
  ) -> Bool? {
    let key = directory.standardizedFileURL.path
    guard let tracked = ownedCoreProcesses[key] else { return nil }
    if let expectedContents,
      tracked.pidRecordContents != expectedContents
    {
      return nil
    }
    let contained = containLaunchedCoreProcess(tracked.process)
    if contained {
      tracked.outputCapture.closeAfterExit()
      ownedCoreProcesses.removeValue(forKey: key)
    }
    return contained
  }

  private func containTrackedCoreForExactStop(
    in directory: URL,
    expectedContents: String
  ) -> Bool? {
    guard let contained = containTrackedCoreWithoutRecord(
      in: directory,
      expectedContents: expectedContents
    ) else {
      return nil
    }
    guard contained else { return false }

    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    guard readCorePidContents(at: pidURL) == expectedContents else {
      // Missing, unreadable, or replacement records are not owned by this
      // cleanup attempt. The exact direct child is already contained.
      return true
    }
    if removePidFileIfMatching(at: pidURL, expectedContents: expectedContents) {
      return true
    }
    // A concurrently published replacement must be preserved and does not
    // change the fact that our retained direct child was safely contained.
    return readCorePidContents(at: pidURL) != expectedContents
  }

  @discardableResult
  func removeOwnedCorePidRecord(
    in directory: URL,
    expectedContents: String
  ) -> Bool {
    guard CorePidRecord(text: expectedContents) != nil else { return false }
    let removed = removePidFileIfMatching(
      at: directory.appendingPathComponent("AtlasCore.pid"),
      expectedContents: expectedContents
    )
    if removed {
      forgetTrackedCore(in: directory, expectedContents: expectedContents)
    }
    return removed
  }

  @discardableResult
  func terminateConfirmedCoreProcess(
    pid: Int32,
    pidURL: URL,
    expectedPidContents: String,
    signalProcess: (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) },
    isProcessAlive: (Int32) -> Bool = { AppDelegate.processIsAlive($0) },
    canSignalProcess: (Int32, Int32) -> Bool,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    gracefulPollCount: Int = 21,
    forcedPollCount: Int = 11,
    pollInterval: TimeInterval = 0.1,
    cleanupPidRecord: (() -> Bool)? = nil
  ) -> Bool {
    // A delivered signal is not proof that the process exited. The default
    // polling budget is bounded to 2 seconds for TERM and 1 second for KILL.
    guard canSignalProcess(pid, SIGTERM) else {
      if !isProcessAlive(pid) {
        return cleanupPidRecord?() ?? removePidFileIfMatching(
          at: pidURL, expectedContents: expectedPidContents)
      }
      NSLog("[AppDelegate] AtlasCore ownership changed before SIGTERM; preserving PID file")
      return false
    }

    let termResult = signalProcess(pid, SIGTERM)
    if termResult != 0 {
      let signalError = errno
      if signalError == ESRCH || !isProcessAlive(pid) {
        return cleanupPidRecord?() ?? removePidFileIfMatching(
          at: pidURL, expectedContents: expectedPidContents)
      }
      NSLog("[AppDelegate] SIGTERM was rejected (errno \(signalError)); preserving PID file")
      return false
    }
    if waitForCoreExit(
      pid: pid,
      isProcessAlive: isProcessAlive,
      sleep: sleep,
      pollCount: gracefulPollCount,
      pollInterval: pollInterval
    ) {
      return cleanupPidRecord?() ?? removePidFileIfMatching(
        at: pidURL, expectedContents: expectedPidContents)
    }

    guard canSignalProcess(pid, SIGKILL) else {
      if !isProcessAlive(pid) {
        return cleanupPidRecord?() ?? removePidFileIfMatching(
          at: pidURL, expectedContents: expectedPidContents)
      }
      NSLog("[AppDelegate] AtlasCore ownership changed before SIGKILL; preserving PID file")
      return false
    }

    let killResult = signalProcess(pid, SIGKILL)
    if killResult != 0 {
      let signalError = errno
      if signalError == ESRCH || !isProcessAlive(pid) {
        return cleanupPidRecord?() ?? removePidFileIfMatching(
          at: pidURL, expectedContents: expectedPidContents)
      }
      NSLog("[AppDelegate] SIGKILL was rejected (errno \(signalError)); preserving PID file")
      return false
    }
    if waitForCoreExit(
      pid: pid,
      isProcessAlive: isProcessAlive,
      sleep: sleep,
      pollCount: forcedPollCount,
      pollInterval: pollInterval
    ) {
      return cleanupPidRecord?() ?? removePidFileIfMatching(
        at: pidURL, expectedContents: expectedPidContents)
    }

    NSLog("[AppDelegate] AtlasCore exit could not be confirmed; preserving PID file")
    return false
  }

  @discardableResult
  func removePidFileIfMatching(
    at pidURL: URL,
    expectedContents: String,
    afterQuarantine: ((URL) -> Void)? = nil
  ) -> Bool {
    let quarantineURL = pidURL.deletingLastPathComponent().appendingPathComponent(
      ".\(pidURL.lastPathComponent).cleanup-\(UUID().uuidString)"
    )
    let quarantineResult = renameExclusively(from: pidURL, to: quarantineURL)
    guard quarantineResult == 0 else {
      if errno == ENOENT { return true }
      NSLog("[AppDelegate] AtlasCore PID file could not be quarantined; preserving it")
      return false
    }

    afterQuarantine?(quarantineURL)
    guard
      let text = readCorePidContents(at: quarantineURL),
      text == expectedContents
    else {
      if renameExclusively(from: quarantineURL, to: pidURL) != 0 {
        NSLog("[AppDelegate] Newer AtlasCore PID state preserved in quarantine")
      }
      return false
    }

    do {
      try FileManager.default.removeItem(at: quarantineURL)
      if pathEntryExists(at: pidURL) {
        NSLog("[AppDelegate] A newer AtlasCore PID record is active")
        return false
      }
      return true
    } catch {
      NSLog("[AppDelegate] Quarantined AtlasCore PID file could not be removed")
      return false
    }
  }

  private func legacyCorePid(from text: String) -> Int32? {
    guard
      text.last == "\n",
      let pid = Int32(text.dropLast()),
      pid > 1,
      text == "\(pid)\n"
    else {
      return nil
    }
    return pid
  }

  private func pathEntryExists(at url: URL) -> Bool {
    var fileInfo = stat()
    let result = url.path.withCString { Darwin.lstat($0, &fileInfo) }
    return result == 0 || errno != ENOENT
  }

  private func readCorePidContents(at url: URL) -> String? {
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard descriptor >= 0 else { return nil }
    defer { _ = Darwin.close(descriptor) }

    var fileInfo = stat()
    guard
      Darwin.fstat(descriptor, &fileInfo) == 0,
      fileInfo.st_mode & S_IFMT == S_IFREG,
      fileInfo.st_size > 0,
      fileInfo.st_size <= 128
    else {
      return nil
    }

    var bytes = [UInt8](repeating: 0, count: Int(fileInfo.st_size))
    let completed = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
      guard let baseAddress = rawBuffer.baseAddress else { return false }
      var offset = 0
      while offset < rawBuffer.count {
        let count = Darwin.read(
          descriptor,
          baseAddress.advanced(by: offset),
          rawBuffer.count - offset
        )
        if count < 0 {
          if errno == EINTR { continue }
          return false
        }
        if count == 0 { return false }
        offset += count
      }
      return true
    }
    guard completed else { return nil }

    var extraByte: UInt8 = 0
    let extraCount = Darwin.read(descriptor, &extraByte, 1)
    guard extraCount == 0 else { return nil }
    return String(bytes: bytes, encoding: .utf8)
  }

  func writePidRecordAtomically(
    _ contents: String,
    to url: URL,
    writeContents: (Int32, [UInt8]) throws -> Void = AppDelegate.writeAllPidRecordBytes
  ) throws {
    let directoryURL = url.deletingLastPathComponent()
    let directoryDescriptor = directoryURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard directoryDescriptor >= 0 else {
      throw corePidError(
        code: errno,
        description: "AtlasCore runtime directory could not be opened safely"
      )
    }
    defer { _ = Darwin.close(directoryDescriptor) }

    var directoryInfo = stat()
    guard
      Darwin.fstat(directoryDescriptor, &directoryInfo) == 0,
      directoryInfo.st_mode & S_IFMT == S_IFDIR,
      directoryInfo.st_uid == geteuid()
    else {
      throw corePidError(
        code: EPERM,
        description: "AtlasCore runtime directory ownership could not be confirmed"
      )
    }

    let temporaryName = ".\(url.lastPathComponent).pending-\(UUID().uuidString)"
    let descriptor = temporaryName.withCString {
      Darwin.openat(
        directoryDescriptor,
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR
      )
    }
    guard descriptor >= 0 else {
      throw corePidError(
        code: errno,
        description: "AtlasCore PID temporary record could not be created"
      )
    }

    var createdInfo = stat()
    var published = false
    defer {
      _ = Darwin.close(descriptor)
      if !published {
        removeTemporaryFileIfMatching(
          directoryDescriptor: directoryDescriptor,
          name: temporaryName,
          expectedInfo: createdInfo
        )
      }
    }

    guard
      Darwin.fstat(descriptor, &createdInfo) == 0,
      createdInfo.st_mode & S_IFMT == S_IFREG,
      createdInfo.st_uid == geteuid(),
      createdInfo.st_nlink == 1,
      Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
    else {
      throw corePidError(
        code: errno == 0 ? EPERM : errno,
        description: "AtlasCore PID temporary record could not be secured"
      )
    }

    let bytes = Array(contents.utf8)
    try writeContents(descriptor, bytes)
    var completedInfo = stat()
    guard
      Darwin.fstat(descriptor, &completedInfo) == 0,
      completedInfo.st_dev == createdInfo.st_dev,
      completedInfo.st_ino == createdInfo.st_ino,
      completedInfo.st_size == bytes.count,
      Darwin.fsync(descriptor) == 0
    else {
      throw corePidError(
        code: errno == 0 ? EIO : errno,
        description: "AtlasCore PID temporary record was not completed safely"
      )
    }

    let publishResult = temporaryName.withCString { temporaryPath in
      url.lastPathComponent.withCString { finalPath in
        renameatx_np(
          directoryDescriptor,
          temporaryPath,
          directoryDescriptor,
          finalPath,
          UInt32(RENAME_EXCL)
        )
      }
    }
    guard publishResult == 0 else {
      throw corePidError(
        code: errno,
        description: "AtlasCore PID record could not be published exclusively"
      )
    }
    published = true
    if Darwin.fsync(directoryDescriptor) != 0 {
      NSLog("[AppDelegate] AtlasCore PID directory flush failed after atomic publish")
    }
  }

  private static func writeAllPidRecordBytes(
    descriptor: Int32,
    bytes: [UInt8]
  ) throws {
    try bytes.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        let written = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          rawBuffer.count - offset
        )
        if written < 0 {
          if errno == EINTR { continue }
          throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "AtlasCore PID record write failed"]
          )
        }
        guard written > 0 else {
          throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EIO),
            userInfo: [NSLocalizedDescriptionKey: "AtlasCore PID record write made no progress"]
          )
        }
        offset += written
      }
    }
  }

  private func removeTemporaryFileIfMatching(
    directoryDescriptor: Int32,
    name: String,
    expectedInfo: stat
  ) {
    guard expectedInfo.st_ino != 0 else { return }
    var currentInfo = stat()
    let matches = name.withCString {
      Darwin.fstatat(
        directoryDescriptor,
        $0,
        &currentInfo,
        AT_SYMLINK_NOFOLLOW
      ) == 0
    } && currentInfo.st_dev == expectedInfo.st_dev &&
      currentInfo.st_ino == expectedInfo.st_ino
    guard matches else { return }
    _ = name.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
  }

  private func corePidError(code: Int32, description: String) -> NSError {
    NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(code),
      userInfo: [NSLocalizedDescriptionKey: description]
    )
  }

  private func renameExclusively(from source: URL, to destination: URL) -> Int32 {
    source.path.withCString { sourcePath in
      destination.path.withCString { destinationPath in
        renameatx_np(
          AT_FDCWD,
          sourcePath,
          AT_FDCWD,
          destinationPath,
          UInt32(RENAME_EXCL)
        )
      }
    }
  }

  private func waitForCoreExit(
    pid: Int32,
    isProcessAlive: (Int32) -> Bool,
    sleep: (TimeInterval) -> Void,
    pollCount: Int,
    pollInterval: TimeInterval
  ) -> Bool {
    let checks = max(1, pollCount)
    for check in 0..<checks {
      if !isProcessAlive(pid) { return true }
      if check + 1 < checks {
        sleep(max(0, pollInterval))
      }
    }
    return false
  }

  private static func processIsAlive(_ pid: Int32) -> Bool {
    errno = 0
    if Darwin.kill(pid, 0) == 0 { return true }
    return errno != ESRCH
  }

  static func currentCoreProcessIdentity(
    pid: Int32,
    expectedExecutablePath: String,
    generationForProcess: ((Int32) -> CoreProcessGeneration?)? = nil,
    executablePathForProcess: ((Int32) -> String?)? = nil
  ) -> CoreProcessIdentity? {
    let generationReader = generationForProcess ?? currentProcessGeneration
    let pathReader = executablePathForProcess ?? currentExecutablePath
    guard let generationBefore = generationReader(pid) else { return nil }
    guard let executablePath = pathReader(pid) else { return nil }
    guard let generationAfter = generationReader(pid) else { return nil }
    guard
      let canonicalExecutablePath = canonicalExistingPath(executablePath),
      let canonicalExpectedPath = canonicalExistingPath(expectedExecutablePath)
    else {
      return nil
    }
    guard
      generationBefore == generationAfter,
      generationAfter.pid == pid,
      generationAfter.startSeconds > 0,
      generationAfter.startMicroseconds < 1_000_000,
      canonicalExecutablePath == canonicalExpectedPath
    else {
      return nil
    }

    return CoreProcessIdentity(
      pid: pid,
      // Preserve the caller's logical path in the identity record. The strict
      // comparison above uses realpath so macOS aliases such as /var and
      // /private/var cannot cause a false mismatch, while distinct files still
      // fail closed.
      executablePath: expectedExecutablePath,
      startSeconds: generationAfter.startSeconds,
      startMicroseconds: generationAfter.startMicroseconds
    )
  }

  private static func canonicalExistingPath(_ path: String) -> String? {
    guard !path.isEmpty else { return nil }
    var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
    let resolved = path.withCString { sourcePath in
      resolvedPath.withUnsafeMutableBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return false }
        return Darwin.realpath(sourcePath, baseAddress) != nil
      }
    }
    guard resolved else { return nil }
    return String(cString: resolvedPath)
  }

  private static func currentProcessGeneration(_ pid: Int32) -> CoreProcessGeneration? {
    var processInfo = proc_bsdinfo()
    let expectedInfoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    let infoSize = withUnsafeMutablePointer(to: &processInfo) {
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, expectedInfoSize)
    }
    guard
      infoSize == expectedInfoSize,
      processInfo.pbi_pid == UInt32(pid)
    else {
      return nil
    }

    return CoreProcessGeneration(
      pid: pid,
      startSeconds: processInfo.pbi_start_tvsec,
      startMicroseconds: processInfo.pbi_start_tvusec
    )
  }

  private static func currentExecutablePath(_ pid: Int32) -> String? {
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let pathLength = pathBuffer.withUnsafeMutableBufferPointer {
      proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
    }
    guard pathLength > 0 else { return nil }
    return String(cString: pathBuffer)
  }

  func runtimeDirectoryForTermination(proxyStateURL: URL?) -> URL? {
    if let proxyStateURL {
      return proxyStateURL.deletingLastPathComponent()
    }
    if ownedCoreProcesses.count == 1, let trackedPath = ownedCoreProcesses.keys.first {
      return URL(fileURLWithPath: trackedPath, isDirectory: true)
    }
    let fm = FileManager.default
    guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    var candidates = [support.appendingPathComponent("SSRVPN")]
    if let bundleId = Bundle.main.bundleIdentifier {
      candidates.append(support.appendingPathComponent("\(bundleId)/SSRVPN"))
    }
    return candidates.first {
      pathEntryExists(at: $0.appendingPathComponent("AtlasCore.pid"))
    }
  }

  func restoreSavedProxyState(
    at explicitStateURL: URL? = nil,
    proxyCommandRunner: ((String, [String]) -> ProxyCommandResult)? = nil,
    networkServiceIdentityProvider: (() -> [String: String]?)? = nil,
    proxyStateRemover: ((URL) throws -> Void)? = nil,
    expectedGuardianNonce: String? = nil,
    expectedOwnerPid: Int32? = nil
  ) -> Bool {
    guard let stateURL = explicitStateURL ?? findProxyStateFile() else { return false }
    do {
      guard let stateSnapshot = readProxyStateSnapshot(at: stateURL) else {
        NSLog("[AppDelegate] Proxy restore state is not a safe readable regular file")
        return false
      }
      let data = stateSnapshot.data
      guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
      }
      if let expectedGuardianNonce {
        guard root["_guardianNonce"] as? String == expectedGuardianNonce else {
          NSLog("[AppDelegate] Proxy guardian nonce no longer matches; preserving state")
          return false
        }
      }
      if let expectedOwnerPid {
        guard
          let ownerPidNumber = root["_ownerPid"] as? NSNumber,
          CFGetTypeID(ownerPidNumber) != CFBooleanGetTypeID(),
          ownerPidNumber.doubleValue == Double(ownerPidNumber.intValue),
          ownerPidNumber.intValue == Int(expectedOwnerPid)
        else {
          NSLog("[AppDelegate] Proxy guardian owner no longer matches; preserving state")
          return false
        }
      }
      guard let rawOwnedHost = root["_ownedProxyHost"] as? String else {
        // A legacy snapshot cannot prove which live proxy endpoint belongs to
        // SSRVPN. It must remain unresolved so termination cannot strand the
        // system proxy on a dead endpoint.
        NSLog("[AppDelegate] Proxy restore state has no ownership proof; preserving it")
        return false
      }
      let ownedHost = rawOwnedHost.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        !ownedHost.isEmpty,
        let ownedPortNumber = root["_ownedProxyPort"] as? NSNumber,
        CFGetTypeID(ownedPortNumber) != CFBooleanGetTypeID(),
        ownedPortNumber.doubleValue == Double(ownedPortNumber.intValue),
        (1...65_535).contains(ownedPortNumber.intValue)
      else {
        NSLog("[AppDelegate] Proxy restore ownership metadata is invalid; preserving it")
        return false
      }
      let ownedPort = ownedPortNumber.intValue
      if let rawOwnerPid = root["_ownerPid"] {
        guard
          let ownerPidNumber = rawOwnerPid as? NSNumber,
          CFGetTypeID(ownerPidNumber) != CFBooleanGetTypeID(),
          ownerPidNumber.doubleValue == Double(ownerPidNumber.intValue),
          ownerPidNumber.intValue > 1
        else {
          NSLog("[AppDelegate] Proxy restore owner PID metadata is invalid; preserving it")
          return false
        }
      }
      let identityKeyIsLegacyService = isCompleteSavedProxyServiceState(
        root["_networkServiceIDs"]
      )
      let hasStableServiceIdentities =
        root["_networkServiceIDs"] != nil && !identityKeyIsLegacyService
      guard
        let services = validatedProxyServices(
          in: root,
          hasStableServiceIdentities: hasStableServiceIdentities
        )
      else {
        NSLog("[AppDelegate] Proxy restore service snapshot is invalid; preserving it")
        return false
      }
      var savedServiceIdentities: [String: String]?
      var currentServiceIdentities: [String: String]?
      var currentNamesByID: [String: String] = [:]
      if hasStableServiceIdentities {
        guard let validatedSavedIdentities = validatedSavedNetworkServiceIdentities(
          root["_networkServiceIDs"],
          serviceNames: Set(services.map(\.0))
        ) else {
          NSLog("[AppDelegate] Stable network-service identity snapshot is invalid; preserving it")
          return false
        }
        let rawCurrentIdentities = networkServiceIdentityProvider != nil
          ? networkServiceIdentityProvider?()
          : currentNetworkServiceIdentities()
        guard
          let rawCurrentIdentities,
          let validatedCurrentIdentities =
            validatedCurrentNetworkServiceIdentities(rawCurrentIdentities)
        else {
          NSLog("[AppDelegate] Current stable network-service identities are unavailable")
          return false
        }
        savedServiceIdentities = validatedSavedIdentities
        currentServiceIdentities = validatedCurrentIdentities
        currentNamesByID = Dictionary(
          uniqueKeysWithValues: validatedCurrentIdentities.map {
            ($0.value, $0.key)
          }
        )
      }
      var hasMissingStableService = false
      var restoreTargets: [(String, String, [String: Any])] = []
      for (savedService, value) in services {
        if let savedServiceIdentities {
          guard
            let serviceID = savedServiceIdentities[savedService],
            let currentService = currentNamesByID[serviceID]
          else {
            hasMissingStableService = true
            continue
          }
          restoreTargets.append((savedService, currentService, value))
        } else {
          restoreTargets.append((savedService, savedService, value))
        }
      }
      var restoredAll = true
      var unresolvedLegacyServices: [String] = []
      for (savedService, service, value) in restoreTargets {
        var restoredService = restoreProxyStateIfOwned(
          service: service,
          value: value["web"],
          ownedHost: ownedHost,
          ownedPort: ownedPort,
          getCommand: "-getwebproxy",
          setCommand: "-setwebproxy",
          stateCommand: "-setwebproxystate",
          proxyCommandRunner: proxyCommandRunner
        )
        restoredService = restoreProxyStateIfOwned(
          service: service,
          value: value["secureWeb"],
          ownedHost: ownedHost,
          ownedPort: ownedPort,
          getCommand: "-getsecurewebproxy",
          setCommand: "-setsecurewebproxy",
          stateCommand: "-setsecurewebproxystate",
          proxyCommandRunner: proxyCommandRunner
        ) && restoredService
        restoredService = restoreProxyStateIfOwned(
          service: service,
          value: value["socks"],
          ownedHost: ownedHost,
          ownedPort: ownedPort,
          getCommand: "-getsocksfirewallproxy",
          setCommand: "-setsocksfirewallproxy",
          stateCommand: "-setsocksfirewallproxystate",
          proxyCommandRunner: proxyCommandRunner
        ) && restoredService
        if !restoredService && !hasStableServiceIdentities {
          unresolvedLegacyServices.append(savedService)
          continue
        }
        restoredAll = restoredService && restoredAll
      }
      if !unresolvedLegacyServices.isEmpty {
        restoredAll = legacyNetworkServicesAreConfirmedMissing(
          unresolvedLegacyServices,
          ownedHost: ownedHost,
          ownedPort: ownedPort,
          proxyCommandRunner: proxyCommandRunner
        ) && restoredAll
      }
      if hasMissingStableService {
        let currentServiceNames = currentServiceIdentities.map {
          Array($0.keys)
        } ?? []
        restoredAll = currentNetworkServicesDoNotOwnProxy(
          currentServiceNames,
          ownedHost: ownedHost,
          ownedPort: ownedPort,
          proxyCommandRunner: proxyCommandRunner
        ) && restoredAll
      }
      if restoredAll {
        do {
          if let proxyStateRemover {
            try proxyStateRemover(stateURL)
          } else {
            guard removeProxyStateSnapshot(stateSnapshot, at: stateURL) else {
              NSLog("[AppDelegate] Proxy restore state identity changed before removal")
              return false
            }
          }
          guard !proxyStatePathEntryExists(at: stateURL) else {
            NSLog("[AppDelegate] Proxy restore state still exists after removal")
            return false
          }
        } catch {
          NSLog("[AppDelegate] Could not retire restored proxy state: \(error)")
          return false
        }
      }
      return restoredAll
    } catch {
      NSLog("[AppDelegate] Proxy restore failed: \(error)")
      return false
    }
  }

  private func validatedProxyServices(
    in root: [String: Any],
    hasStableServiceIdentities: Bool
  ) -> [(String, [String: Any])]? {
    let metadataKeys: Set<String> = [
      "_ownedProxyHost",
      "_ownedProxyPort",
      "_ownerPid",
      "_guardianNonce",
    ]
    var services: [(String, [String: Any])] = []
    for (key, rawValue) in root {
      if metadataKeys.contains(key)
        || (key == "_networkServiceIDs" && hasStableServiceIdentities)
      {
        continue
      }
      guard
        let value = rawValue as? [String: Any],
        isCompleteSavedProxyServiceState(value)
      else {
        return nil
      }
      services.append((key, value))
    }
    return services.isEmpty ? nil : services
  }

  private func isCompleteSavedProxyServiceState(_ rawValue: Any?) -> Bool {
    guard let value = rawValue as? [String: Any] else { return false }
    return Set(value.keys) == Set(["web", "secureWeb", "socks"])
      && isValidSavedProxyState(value["web"])
      && isValidSavedProxyState(value["secureWeb"])
      && isValidSavedProxyState(value["socks"])
  }

  private func validatedSavedNetworkServiceIdentities(
    _ rawValue: Any?,
    serviceNames: Set<String>
  ) -> [String: String]? {
    guard let rawIdentities = rawValue as? [String: Any] else { return nil }
    var identities: [String: String] = [:]
    var seenIDs = Set<String>()
    for (rawName, rawID) in rawIdentities {
      let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let rawID = rawID as? String else { return nil }
      let serviceID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        !name.isEmpty,
        !serviceID.isEmpty,
        identities[name] == nil,
        seenIDs.insert(serviceID).inserted
      else {
        return nil
      }
      identities[name] = serviceID
    }
    return Set(identities.keys) == serviceNames ? identities : nil
  }

  private func validatedCurrentNetworkServiceIdentities(
    _ rawIdentities: [String: String]
  ) -> [String: String]? {
    var identities: [String: String] = [:]
    var seenIDs = Set<String>()
    for (rawName, rawID) in rawIdentities {
      let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
      let serviceID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        !name.isEmpty,
        !serviceID.isEmpty,
        identities[name] == nil,
        seenIDs.insert(serviceID).inserted
      else {
        return nil
      }
      identities[name] = serviceID
    }
    return identities
  }

  private func isValidSavedProxyState(_ rawValue: Any?) -> Bool {
    guard
      let value = rawValue as? [String: Any],
      Set(value.keys) == Set(["enabled", "server", "port"]),
      let enabled = value["enabled"] as? Bool,
      let server = value["server"] as? String,
      let portNumber = value["port"] as? NSNumber,
      CFGetTypeID(portNumber) != CFBooleanGetTypeID(),
      portNumber.doubleValue == Double(portNumber.intValue),
      (0...65_535).contains(portNumber.intValue)
    else {
      return false
    }
    return !enabled || (
      !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        portNumber.intValue > 0
    )
  }

  private func restoreProxyStateIfOwned(
    service: String,
    value: Any?,
    ownedHost: String,
    ownedPort: Int,
    getCommand: String,
    setCommand: String,
    stateCommand: String,
    proxyCommandRunner: ((String, [String]) -> ProxyCommandResult)?
  ) -> Bool {
    guard let isOwned = proxyMatchesOwnership(
      service: service,
      getCommand: getCommand,
      ownedHost: ownedHost,
      ownedPort: ownedPort,
      proxyCommandRunner: proxyCommandRunner
    ) else {
      // Keep the state file so the next launch can retry a transient read.
      return false
    }
    guard isOwned else {
      return true
    }
    return restoreProxyState(
      service: service,
      value: value,
      setCommand: setCommand,
      stateCommand: stateCommand,
      proxyCommandRunner: proxyCommandRunner
    )
  }

  private func legacyNetworkServicesAreConfirmedMissing(
    _ expectedServices: [String],
    ownedHost: String,
    ownedPort: Int,
    proxyCommandRunner: ((String, [String]) -> ProxyCommandResult)?
  ) -> Bool {
    guard !expectedServices.isEmpty else { return true }
    let result = executeProxyCommand(
      "/usr/sbin/networksetup",
      ["-listallnetworkservices"],
      proxyCommandRunner: proxyCommandRunner
    )
    guard result.succeeded, let output = result.output else { return false }
    let expectedHeader =
      "An asterisk (*) denotes that a network service is disabled."
    var sawHeader = false
    var currentServices: [String] = []
    for rawLine in output.split(
      separator: "\n",
      omittingEmptySubsequences: false
    ) {
      var service = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if service.isEmpty { continue }
      if !sawHeader {
        guard service == expectedHeader else { return false }
        sawHeader = true
        continue
      }
      if service.hasPrefix("*") {
        service.removeFirst()
        service = service.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard !service.isEmpty else { return false }
      currentServices.append(service)
    }
    guard sawHeader else { return false }
    let currentServiceSet = Set(currentServices)
    guard expectedServices.allSatisfy({ !currentServiceSet.contains($0) }) else {
      return false
    }
    return currentNetworkServicesDoNotOwnProxy(
      currentServices,
      ownedHost: ownedHost,
      ownedPort: ownedPort,
      proxyCommandRunner: proxyCommandRunner
    )
  }

  private func currentNetworkServicesDoNotOwnProxy(
    _ currentServices: [String],
    ownedHost: String,
    ownedPort: Int,
    proxyCommandRunner: ((String, [String]) -> ProxyCommandResult)?
  ) -> Bool {
    for service in currentServices {
      for getCommand in [
        "-getwebproxy",
        "-getsecurewebproxy",
        "-getsocksfirewallproxy",
      ] {
        guard let isOwned = proxyMatchesOwnership(
          service: service,
          getCommand: getCommand,
          ownedHost: ownedHost,
          ownedPort: ownedPort,
          proxyCommandRunner: proxyCommandRunner
        ) else {
          return false
        }
        if isOwned {
          NSLog(
            "[AppDelegate] A current network service still owns the SSRVPN proxy; "
              + "preserving the snapshot because the saved service may have been renamed"
          )
          return false
        }
      }
    }
    return true
  }

  private func findProxyStateFile() -> URL? {
    let fm = FileManager.default
    guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    var candidates = [
      support.appendingPathComponent("SSRVPN/system_proxy.json")
    ]
    if let bundleId = Bundle.main.bundleIdentifier {
      candidates.append(
        support.appendingPathComponent("\(bundleId)/SSRVPN/system_proxy.json")
      )
    }
    for url in candidates where proxyStatePathEntryExists(at: url) {
      return url
    }
    guard let enumerator = fm.enumerator(
      at: support,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else {
      return nil
    }
    for case let url as URL in enumerator {
      if url.path.hasSuffix("/SSRVPN/system_proxy.json") &&
        proxyStatePathEntryExists(at: url)
      {
        return url
      }
    }
    return nil
  }

  func proxyStatePathEntryExists(at url: URL) -> Bool {
    pathEntryExists(at: url)
  }

  func readProxyStateData(at url: URL) -> Data? {
    readProxyStateSnapshot(at: url)?.data
  }

  private func readProxyStateSnapshot(
    at url: URL
  ) -> ProxyStateFileSnapshot? {
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard descriptor >= 0 else { return nil }
    var shouldClose = true
    defer {
      if shouldClose {
        _ = Darwin.close(descriptor)
      }
    }

    var fileInfo = stat()
    guard
      Darwin.fstat(descriptor, &fileInfo) == 0,
      fileInfo.st_mode & S_IFMT == S_IFREG,
      fileInfo.st_uid == geteuid(),
      fileInfo.st_nlink == 1,
      fileInfo.st_mode & (S_IWGRP | S_IWOTH) == 0,
      fileInfo.st_size > 0,
      fileInfo.st_size <= 1_048_576
    else {
      return nil
    }

    var bytes = [UInt8](repeating: 0, count: Int(fileInfo.st_size))
    let completed = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
      guard let baseAddress = rawBuffer.baseAddress else { return false }
      var offset = 0
      while offset < rawBuffer.count {
        let count = Darwin.read(
          descriptor,
          baseAddress.advanced(by: offset),
          rawBuffer.count - offset
        )
        if count < 0 {
          if errno == EINTR { continue }
          return false
        }
        if count == 0 { return false }
        offset += count
      }
      return true
    }
    guard completed else { return nil }

    var extraByte: UInt8 = 0
    guard Darwin.read(descriptor, &extraByte, 1) == 0 else { return nil }
    shouldClose = false
    return ProxyStateFileSnapshot(
      descriptor: descriptor,
      data: Data(bytes),
      fileInfo: fileInfo
    )
  }

  private func removeProxyStateSnapshot(
    _ snapshot: ProxyStateFileSnapshot,
    at url: URL
  ) -> Bool {
    let parentURL = url.deletingLastPathComponent()
    let name = url.lastPathComponent
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
      return false
    }
    let directoryDescriptor = parentURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
    }
    guard directoryDescriptor >= 0 else { return false }
    defer { _ = Darwin.close(directoryDescriptor) }

    var openedInfo = stat()
    var pathInfo = stat()
    guard
      Darwin.fstat(snapshot.descriptor, &openedInfo) == 0,
      name.withCString({
        Darwin.fstatat(
          directoryDescriptor,
          $0,
          &pathInfo,
          AT_SYMLINK_NOFOLLOW
        ) == 0
      }),
      proxyStateFileInfo(openedInfo, matches: snapshot.fileInfo),
      proxyStateFileInfo(pathInfo, matches: snapshot.fileInfo)
    else {
      return false
    }

    guard name.withCString({
      Darwin.unlinkat(directoryDescriptor, $0, 0)
    }) == 0 else {
      return false
    }

    var removedInfo = stat()
    guard
      Darwin.fstat(snapshot.descriptor, &removedInfo) == 0,
      removedInfo.st_nlink == 0
    else {
      return false
    }
    var replacementInfo = stat()
    let pathStillExists = name.withCString {
      Darwin.fstatat(
        directoryDescriptor,
        $0,
        &replacementInfo,
        AT_SYMLINK_NOFOLLOW
      ) == 0
    }
    if pathStillExists || errno != ENOENT {
      return false
    }
    if Darwin.fsync(directoryDescriptor) != 0 {
      NSLog("[AppDelegate] Proxy restore state directory flush failed")
    }
    return true
  }

  private func proxyStateFileInfo(
    _ current: stat,
    matches expected: stat
  ) -> Bool {
    current.st_dev == expected.st_dev
      && current.st_ino == expected.st_ino
      && current.st_mode & S_IFMT == S_IFREG
      && current.st_uid == expected.st_uid
      && current.st_uid == geteuid()
      && current.st_nlink == 1
      && current.st_mode & (S_IWGRP | S_IWOTH) == 0
      && current.st_size == expected.st_size
      && current.st_mtimespec.tv_sec == expected.st_mtimespec.tv_sec
      && current.st_mtimespec.tv_nsec == expected.st_mtimespec.tv_nsec
      && current.st_ctimespec.tv_sec == expected.st_ctimespec.tv_sec
      && current.st_ctimespec.tv_nsec == expected.st_ctimespec.tv_nsec
  }

  private func restoreProxyState(
    service: String,
    value: Any?,
    setCommand: String,
    stateCommand: String,
    proxyCommandRunner: ((String, [String]) -> ProxyCommandResult)?
  ) -> Bool {
    guard let state = value as? [String: Any] else {
      return true
    }
    let enabled = state["enabled"] as? Bool ?? false
    let server = state["server"] as? String ?? ""
    let portValue = state["port"]
    let port: Int
    if let number = portValue as? NSNumber {
      port = number.intValue
    } else if let text = portValue as? String, let parsed = Int(text) {
      port = parsed
    } else {
      port = 0
    }

    if enabled && !server.isEmpty && port > 0 {
      let setOk = executeProxyCommand(
        "/usr/sbin/networksetup",
        [setCommand, service, server, "\(port)"],
        proxyCommandRunner: proxyCommandRunner
      ).succeeded
      let stateOk = executeProxyCommand(
        "/usr/sbin/networksetup",
        [stateCommand, service, "on"],
        proxyCommandRunner: proxyCommandRunner
      ).succeeded
      return setOk && stateOk
    }
    return executeProxyCommand(
      "/usr/sbin/networksetup",
      [stateCommand, service, "off"],
      proxyCommandRunner: proxyCommandRunner
    ).succeeded
  }

  private func proxyMatchesOwnership(
    service: String,
    getCommand: String,
    ownedHost: String,
    ownedPort: Int,
    proxyCommandRunner: ((String, [String]) -> ProxyCommandResult)?
  ) -> Bool? {
    let result = executeProxyCommand(
      "/usr/sbin/networksetup",
      [getCommand, service],
      proxyCommandRunner: proxyCommandRunner
    )
    guard result.succeeded, let output = result.output else {
      return nil
    }
    let enabled = proxyLineValue(output, key: "Enabled").lowercased() == "yes"
    let server = proxyLineValue(output, key: "Server")
    let port = Int(proxyLineValue(output, key: "Port")) ?? 0
    return enabled && server == ownedHost && port == ownedPort
  }

  private func executeProxyCommand(
    _ executable: String,
    _ arguments: [String],
    proxyCommandRunner: ((String, [String]) -> ProxyCommandResult)?
  ) -> ProxyCommandResult {
    if let proxyCommandRunner {
      return proxyCommandRunner(executable, arguments)
    }
    if arguments.first?.hasPrefix("-get") == true ||
      arguments.first == "-listallnetworkservices"
    {
      guard let output = runProcessOutput(executable, arguments) else {
        return ProxyCommandResult(succeeded: false, output: nil)
      }
      return ProxyCommandResult(succeeded: true, output: output)
    }
    return ProxyCommandResult(
      succeeded: runProcess(executable, arguments),
      output: nil
    )
  }

  private func proxyLineValue(_ output: String, key: String) -> String {
    let prefix = "\(key):"
    for line in output.split(separator: "\n") {
      let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if value.hasPrefix(prefix) {
        return String(value.dropFirst(prefix.count))
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return ""
  }

  private func runProcess(
    _ executable: String,
    _ arguments: [String],
    timeout: TimeInterval = 4
  ) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in semaphore.signal() }
    do {
      try process.run()
      if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        return false
      }
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  private func runProcessOutput(
    _ executable: String,
    _ arguments: [String],
    timeout: TimeInterval = 4
  ) -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = Pipe()
    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in semaphore.signal() }
    do {
      try process.run()
      if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        return nil
      }
      guard process.terminationStatus == 0 else { return nil }
      return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    } catch {
      return nil
    }
  }
}
