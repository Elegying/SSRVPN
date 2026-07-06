import Cocoa
import FlutterMacOS

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

  // Cmd+Q 等退出路径不经过 Flutter 侧的清理逻辑，
  // 在这里兜底：杀掉核心进程，并优先恢复 Dart 侧保存的系统代理备份。
  override func applicationWillTerminate(_ notification: Notification) {
    _ = runProcess("/usr/bin/pkill", ["-f", "SSRVPN.*/AtlasCore"], timeout: 3)
    if !restoreSavedProxyState() {
      disableLocalhostProxyOnly()
    }
    super.applicationWillTerminate(notification)
  }

  private func restoreSavedProxyState() -> Bool {
    guard let stateURL = findProxyStateFile() else { return false }
    do {
      let data = try Data(contentsOf: stateURL)
      guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
      }
      var restoredAll = true
      for (service, rawValue) in root {
        guard let value = rawValue as? [String: Any] else { continue }
        restoredAll = restoreProxyState(
          service: service,
          value: value["web"],
          setCommand: "-setwebproxy",
          stateCommand: "-setwebproxystate"
        ) && restoredAll
        restoredAll = restoreProxyState(
          service: service,
          value: value["secureWeb"],
          setCommand: "-setsecurewebproxy",
          stateCommand: "-setsecurewebproxystate"
        ) && restoredAll
        restoredAll = restoreProxyState(
          service: service,
          value: value["socks"],
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
      return runProcess("/usr/sbin/networksetup", [stateCommand, service, "off"])
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

  private func disableLocalhostProxyOnly() {
    guard let services = listNetworkServices() else { return }
    for service in services {
      for item in [
        ("-getwebproxy", "-setwebproxystate"),
        ("-getsecurewebproxy", "-setsecurewebproxystate"),
        ("-getsocksfirewallproxy", "-setsocksfirewallproxystate")
      ] {
        if let server = proxyServer(service: service, getCommand: item.0),
           server == "127.0.0.1" || server == "localhost" {
          _ = runProcess("/usr/sbin/networksetup", [item.1, service, "off"])
        }
      }
    }
  }

  private func listNetworkServices() -> [String]? {
    let output = runProcessOutput(
      "/usr/sbin/networksetup",
      ["-listallnetworkservices"]
    )
    return output?
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") && !$0.hasPrefix("*") }
  }

  private func proxyServer(service: String, getCommand: String) -> String? {
    let output = runProcessOutput("/usr/sbin/networksetup", [getCommand, service])
    return output?
      .split(separator: "\n")
      .first { $0.hasPrefix("Server:") }?
      .split(separator: ":", maxSplits: 1)
      .last?
      .trimmingCharacters(in: .whitespacesAndNewlines)
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
