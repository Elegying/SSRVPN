import Darwin
import Foundation

struct ProxyGuardianOwnerIdentity: Equatable {
  let pid: Int32
  let startSeconds: UInt64
  let startMicroseconds: UInt64
  let executablePath: String
}

struct ProxyGuardianArguments: Equatable {
  let stateURL: URL
  let nonce: String
  let owner: ProxyGuardianOwnerIdentity

  var readyURL: URL {
    stateURL.deletingLastPathComponent()
      .appendingPathComponent(".system_proxy.guardian.\(nonce).ready")
  }
}

struct ProxyGuardianDependencies {
  let validateSnapshot: (URL, String, Int32) -> Bool
  let ownerMatches: (ProxyGuardianOwnerIdentity) -> Bool
  let publishReady: (URL, String) -> Bool
  let statePathEntryExists: (URL) -> Bool
  let restoreProxy: (URL, String, Int32) -> Bool
  let terminateCore: (URL) -> Bool
  let sleep: (TimeInterval) -> Void
}

enum ProxyGuardianCommand {
  static let modeArgument = "--ssrvpn-proxy-guardian"
  private static let allowedKeys: Set<String> = [
    "--state",
    "--nonce",
    "--owner-pid",
    "--owner-start-seconds",
    "--owner-start-microseconds",
    "--owner-executable",
  ]

  static func isRequested(_ arguments: [String] = CommandLine.arguments) -> Bool {
    arguments.count > 1 && arguments[1] == modeArgument
  }

  static func parse(_ arguments: [String]) -> ProxyGuardianArguments? {
    guard arguments.count == 14, arguments[1] == modeArgument else {
      return nil
    }
    var values: [String: String] = [:]
    var index = 2
    while index < arguments.count {
      let key = arguments[index]
      let value = arguments[index + 1]
      guard
        allowedKeys.contains(key),
        values[key] == nil,
        !value.isEmpty
      else {
        return nil
      }
      values[key] = value
      index += 2
    }
    guard
      values.count == allowedKeys.count,
      let statePath = values["--state"],
      (statePath as NSString).isAbsolutePath,
      let nonce = values["--nonce"],
      isValidNonce(nonce),
      let rawPid = values["--owner-pid"],
      let pid = Int32(rawPid),
      pid > 1,
      let rawStartSeconds = values["--owner-start-seconds"],
      let startSeconds = UInt64(rawStartSeconds),
      startSeconds > 0,
      let rawStartMicroseconds = values["--owner-start-microseconds"],
      let startMicroseconds = UInt64(rawStartMicroseconds),
      startMicroseconds < 1_000_000,
      let executablePath = values["--owner-executable"],
      (executablePath as NSString).isAbsolutePath
    else {
      return nil
    }
    return ProxyGuardianArguments(
      stateURL: URL(fileURLWithPath: statePath).standardizedFileURL,
      nonce: nonce,
      owner: ProxyGuardianOwnerIdentity(
        pid: pid,
        startSeconds: startSeconds,
        startMicroseconds: startMicroseconds,
        executablePath: URL(fileURLWithPath: executablePath)
          .standardizedFileURL.resolvingSymlinksInPath().path
      )
    )
  }

  static func arguments(
    stateURL: URL,
    nonce: String,
    owner: ProxyGuardianOwnerIdentity
  ) -> [String] {
    [
      modeArgument,
      "--state", stateURL.standardizedFileURL.path,
      "--nonce", nonce,
      "--owner-pid", "\(owner.pid)",
      "--owner-start-seconds", "\(owner.startSeconds)",
      "--owner-start-microseconds", "\(owner.startMicroseconds)",
      "--owner-executable", owner.executablePath,
    ]
  }

  static func isValidNonce(_ value: String) -> Bool {
    value.utf8.count == 32 && value.utf8.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
    }
  }

  static func run(
    arguments: [String] = CommandLine.arguments,
    dependencies injectedDependencies: ProxyGuardianDependencies? = nil
  ) -> Int32 {
    guard let parsed = parse(arguments) else { return 64 }
    let dependencies = injectedDependencies ?? productionDependencies()
    guard dependencies.validateSnapshot(
      parsed.stateURL,
      parsed.nonce,
      parsed.owner.pid
    ) else {
      return 65
    }
    guard dependencies.ownerMatches(parsed.owner) else { return 66 }
    guard dependencies.publishReady(parsed.readyURL, parsed.nonce) else {
      return 67
    }

    while dependencies.statePathEntryExists(parsed.stateURL) {
      if !dependencies.ownerMatches(parsed.owner) {
        guard dependencies.validateSnapshot(
          parsed.stateURL,
          parsed.nonce,
          parsed.owner.pid
        ) else {
          return 68
        }
        guard dependencies.restoreProxy(
          parsed.stateURL,
          parsed.nonce,
          parsed.owner.pid
        ) else {
          return 69
        }
        guard !dependencies.statePathEntryExists(parsed.stateURL) else {
          return 70
        }
        return dependencies.terminateCore(
          parsed.stateURL.deletingLastPathComponent()
        ) ? 0 : 71
      }
      dependencies.sleep(0.25)
    }
    return 0
  }

  static func consumeReadyFile(at url: URL, nonce: String) -> Bool {
    let delegate = AppDelegate()
    guard
      let data = delegate.readProxyStateData(at: url),
      String(data: data, encoding: .utf8) == "\(nonce)\n"
    else {
      return false
    }
    do {
      try FileManager.default.removeItem(at: url)
      return !delegate.proxyStatePathEntryExists(at: url)
    } catch {
      return false
    }
  }

  private static func productionDependencies() -> ProxyGuardianDependencies {
    let delegate = AppDelegate()
    return ProxyGuardianDependencies(
      validateSnapshot: { url, nonce, ownerPid in
        guard
          let data = delegate.readProxyStateData(at: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          root["_guardianNonce"] as? String == nonce,
          let ownerPidNumber = root["_ownerPid"] as? NSNumber,
          CFGetTypeID(ownerPidNumber) != CFBooleanGetTypeID(),
          ownerPidNumber.doubleValue == Double(ownerPidNumber.intValue),
          ownerPidNumber.intValue == Int(ownerPid)
        else {
          return false
        }
        return true
      },
      ownerMatches: processMatchesOwner,
      publishReady: publishReadyFile,
      statePathEntryExists: delegate.proxyStatePathEntryExists,
      restoreProxy: { url, nonce, ownerPid in
        delegate.restoreSavedProxyState(
          at: url,
          expectedGuardianNonce: nonce,
          expectedOwnerPid: ownerPid
        )
      },
      terminateCore: { directory in
        delegate.terminateOwnedCore(in: directory)
      },
      sleep: Thread.sleep(forTimeInterval:)
    )
  }

  private static func processMatchesOwner(
    _ owner: ProxyGuardianOwnerIdentity
  ) -> Bool {
    var processInfo = proc_bsdinfo()
    let expectedInfoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    let infoSize = withUnsafeMutablePointer(to: &processInfo) {
      proc_pidinfo(owner.pid, PROC_PIDTBSDINFO, 0, $0, expectedInfoSize)
    }
    guard
      infoSize == expectedInfoSize,
      processInfo.pbi_pid == UInt32(owner.pid),
      processInfo.pbi_start_tvsec == owner.startSeconds,
      processInfo.pbi_start_tvusec == owner.startMicroseconds
    else {
      return false
    }
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let pathLength = pathBuffer.withUnsafeMutableBufferPointer {
      proc_pidpath(owner.pid, $0.baseAddress, UInt32($0.count))
    }
    guard pathLength > 0 else { return false }
    let path = URL(fileURLWithPath: String(cString: pathBuffer))
      .standardizedFileURL.resolvingSymlinksInPath().path
    return path == owner.executablePath
  }

  private static func publishReadyFile(_ url: URL, nonce: String) -> Bool {
    let descriptor = url.path.withCString {
      Darwin.open(
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode_t(S_IRUSR | S_IWUSR)
      )
    }
    guard descriptor >= 0 else { return false }
    defer { _ = Darwin.close(descriptor) }
    let data = Data("\(nonce)\n".utf8)
    let written = data.withUnsafeBytes { buffer -> Bool in
      guard let baseAddress = buffer.baseAddress else { return false }
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          buffer.count - offset
        )
        if count < 0 {
          if errno == EINTR { continue }
          return false
        }
        offset += count
      }
      return true
    }
    return written && Darwin.fsync(descriptor) == 0
  }
}
