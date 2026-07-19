import Cocoa
import Darwin
import FlutterMacOS

struct CoreProcessIdentity: Equatable {
  let pid: Int32
  let executablePath: String
  let startSeconds: UInt64
  let startMicroseconds: UInt64
}

@main
class AppDelegate: FlutterAppDelegate {
  // 返回 false：退出由 Flutter 侧 _quitApp() 主动调用 SystemNavigator.pop() 控制，
  // 避免系统在窗口关闭时自动终止应用，窗口关闭由 Flutter 层统一处理。
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    revealMainWindow(in: sender)
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
  func revealWindow(_ window: NSWindow?) -> Bool {
    guard let window else { return false }
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
    return true
  }

  // Cmd+Q 等退出路径不经过 Flutter 侧的清理逻辑，
  // 在这里兜底：先恢复代理；只有恢复成功后才终止已记录 PID 的自有核心。
  override func applicationWillTerminate(_ notification: Notification) {
    removeTunSessionRequests()
    let proxyStateURL = findProxyStateFile()
    let runtimeDirectory = runtimeDirectoryForTermination(proxyStateURL: proxyStateURL)
    let hadProxyState = proxyStateURL != nil
    let proxyRestored = restoreSavedProxyState()
    if !hadProxyState || proxyRestored {
      _ = terminateOwnedCore(in: runtimeDirectory)
    } else {
      NSLog("[AppDelegate] Keeping AtlasCore alive because proxy restore failed")
    }
    super.applicationWillTerminate(notification)
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

  private func removeTunSessionRequests() {
    let fm = FileManager.default
    guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return
    }
    for url in tunRequestURLs(in: support) {
      try? fm.removeItem(at: url)
    }
  }

  @discardableResult
  func terminateOwnedCore(
    in directory: URL?,
    identityForProcess: (Int32, String) -> CoreProcessIdentity? = {
      AppDelegate.currentCoreProcessIdentity(pid: $0, expectedExecutablePath: $1)
    },
    signalProcess: (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) },
    isProcessAlive: (Int32) -> Bool = { AppDelegate.processIsAlive($0) },
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
  ) -> Bool {
    guard let directory else { return false }
    let pidURL = directory.appendingPathComponent("AtlasCore.pid")
    let corePath = directory.appendingPathComponent("AtlasCore").path
    guard let text = try? String(contentsOf: pidURL, encoding: .utf8) else {
      NSLog("[AppDelegate] AtlasCore PID file is unreadable; preserving it")
      return false
    }
    guard
      let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
      pid > 1
    else {
      NSLog("[AppDelegate] AtlasCore PID file is invalid; preserving it")
      return false
    }
    guard let identity = identityForProcess(pid, corePath) else {
      if !isProcessAlive(pid) {
        _ = removePidFileIfMatching(at: pidURL, expectedPid: pid)
        return true
      }
      NSLog("[AppDelegate] AtlasCore identity could not be confirmed; preserving PID file")
      return false
    }
    return terminateConfirmedCoreProcess(
      pid: pid,
      pidURL: pidURL,
      signalProcess: signalProcess,
      isProcessAlive: isProcessAlive,
      canSignalProcess: { pid, _ in identityForProcess(pid, corePath) == identity },
      sleep: sleep
    )
  }

  @discardableResult
  func terminateConfirmedCoreProcess(
    pid: Int32,
    pidURL: URL,
    signalProcess: (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) },
    isProcessAlive: (Int32) -> Bool = { AppDelegate.processIsAlive($0) },
    canSignalProcess: (Int32, Int32) -> Bool,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    gracefulPollCount: Int = 21,
    forcedPollCount: Int = 11,
    pollInterval: TimeInterval = 0.1
  ) -> Bool {
    // A delivered signal is not proof that the process exited. The default
    // polling budget is bounded to 2 seconds for TERM and 1 second for KILL.
    guard canSignalProcess(pid, SIGTERM) else {
      if !isProcessAlive(pid) {
        _ = removePidFileIfMatching(at: pidURL, expectedPid: pid)
        return true
      }
      NSLog("[AppDelegate] AtlasCore ownership changed before SIGTERM; preserving PID file")
      return false
    }

    let termResult = signalProcess(pid, SIGTERM)
    if termResult != 0 {
      let signalError = errno
      if signalError == ESRCH || !isProcessAlive(pid) {
        _ = removePidFileIfMatching(at: pidURL, expectedPid: pid)
        return true
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
      _ = removePidFileIfMatching(at: pidURL, expectedPid: pid)
      return true
    }

    guard canSignalProcess(pid, SIGKILL) else {
      if !isProcessAlive(pid) {
        _ = removePidFileIfMatching(at: pidURL, expectedPid: pid)
        return true
      }
      NSLog("[AppDelegate] AtlasCore ownership changed before SIGKILL; preserving PID file")
      return false
    }

    let killResult = signalProcess(pid, SIGKILL)
    if killResult != 0 {
      let signalError = errno
      if signalError == ESRCH || !isProcessAlive(pid) {
        _ = removePidFileIfMatching(at: pidURL, expectedPid: pid)
        return true
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
      _ = removePidFileIfMatching(at: pidURL, expectedPid: pid)
      return true
    }

    NSLog("[AppDelegate] AtlasCore exit could not be confirmed; preserving PID file")
    return false
  }

  @discardableResult
  func removePidFileIfMatching(
    at pidURL: URL,
    expectedPid: Int32,
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
      let text = try? String(contentsOf: quarantineURL, encoding: .utf8),
      Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) == expectedPid
    else {
      if renameExclusively(from: quarantineURL, to: pidURL) != 0 {
        NSLog("[AppDelegate] Newer AtlasCore PID state preserved in quarantine")
      }
      return false
    }

    do {
      try FileManager.default.removeItem(at: quarantineURL)
      return true
    } catch {
      NSLog("[AppDelegate] Quarantined AtlasCore PID file could not be removed")
      return false
    }
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
    expectedExecutablePath: String
  ) -> CoreProcessIdentity? {
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

    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let pathLength = pathBuffer.withUnsafeMutableBufferPointer {
      proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
    }
    guard pathLength > 0 else { return nil }
    let executablePath = String(cString: pathBuffer)
    guard executablePath == expectedExecutablePath else { return nil }

    return CoreProcessIdentity(
      pid: pid,
      executablePath: executablePath,
      startSeconds: processInfo.pbi_start_tvsec,
      startMicroseconds: processInfo.pbi_start_tvusec
    )
  }

  func runtimeDirectoryForTermination(proxyStateURL: URL?) -> URL? {
    if let proxyStateURL {
      return proxyStateURL.deletingLastPathComponent()
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
      fm.fileExists(atPath: $0.appendingPathComponent("AtlasCore.pid").path)
    }
  }

  private func restoreSavedProxyState() -> Bool {
    guard let stateURL = findProxyStateFile() else { return false }
    do {
      let data = try Data(contentsOf: stateURL)
      guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
      }
      guard
        let ownedHost = root["_ownedProxyHost"] as? String,
        !ownedHost.isEmpty,
        let ownedPort = (root["_ownedProxyPort"] as? NSNumber)?.intValue,
        ownedPort > 0
      else {
        // Legacy state cannot prove which localhost proxy SSRVPN installed.
        // Preserve the user's current settings instead of guessing.
        try? FileManager.default.removeItem(at: stateURL)
        return true
      }
      var restoredAll = true
      for (service, rawValue) in root {
        if service.hasPrefix("_") { continue }
        guard let value = rawValue as? [String: Any] else { continue }
        restoredAll = restoreProxyStateIfOwned(
          service: service,
          value: value["web"],
          ownedHost: ownedHost,
          ownedPort: ownedPort,
          getCommand: "-getwebproxy",
          setCommand: "-setwebproxy",
          stateCommand: "-setwebproxystate"
        ) && restoredAll
        restoredAll = restoreProxyStateIfOwned(
          service: service,
          value: value["secureWeb"],
          ownedHost: ownedHost,
          ownedPort: ownedPort,
          getCommand: "-getsecurewebproxy",
          setCommand: "-setsecurewebproxy",
          stateCommand: "-setsecurewebproxystate"
        ) && restoredAll
        restoredAll = restoreProxyStateIfOwned(
          service: service,
          value: value["socks"],
          ownedHost: ownedHost,
          ownedPort: ownedPort,
          getCommand: "-getsocksfirewallproxy",
          setCommand: "-setsocksfirewallproxy",
          stateCommand: "-setsocksfirewallproxystate"
        ) && restoredAll
      }
      if restoredAll {
        try? FileManager.default.removeItem(at: stateURL)
      }
      return restoredAll
    } catch {
      NSLog("[AppDelegate] Proxy restore failed: \(error)")
      return false
    }
  }

  private func restoreProxyStateIfOwned(
    service: String,
    value: Any?,
    ownedHost: String,
    ownedPort: Int,
    getCommand: String,
    setCommand: String,
    stateCommand: String
  ) -> Bool {
    guard let isOwned = proxyMatchesOwnership(
      service: service,
      getCommand: getCommand,
      ownedHost: ownedHost,
      ownedPort: ownedPort
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
      stateCommand: stateCommand
    )
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
    for url in candidates where fm.fileExists(atPath: url.path) {
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
      if url.path.hasSuffix("/SSRVPN/system_proxy.json") {
        return url
      }
    }
    return nil
  }

  private func restoreProxyState(
    service: String,
    value: Any?,
    setCommand: String,
    stateCommand: String
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
      let setOk = runProcess(
        "/usr/sbin/networksetup",
        [setCommand, service, server, "\(port)"]
      )
      let stateOk = runProcess(
        "/usr/sbin/networksetup",
        [stateCommand, service, "on"]
      )
      return setOk && stateOk
    }
    return runProcess("/usr/sbin/networksetup", [stateCommand, service, "off"])
  }

  private func proxyMatchesOwnership(
    service: String,
    getCommand: String,
    ownedHost: String,
    ownedPort: Int
  ) -> Bool? {
    guard let output = runProcessOutput(
      "/usr/sbin/networksetup",
      [getCommand, service]
    ) else {
      return nil
    }
    let enabled = proxyLineValue(output, key: "Enabled").lowercased() == "yes"
    let server = proxyLineValue(output, key: "Server")
    let port = Int(proxyLineValue(output, key: "Port")) ?? 0
    return enabled && server == ownedHost && port == ownedPort
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
