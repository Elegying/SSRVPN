import Foundation
import Network

/// Network.framework scopes name resolution and TCP to the required interface.
/// No route, DNS preference, or process-wide binding is changed.
enum PhysicalTcpLatencyProbe {
  private static let queue = DispatchQueue(label: "ssrvpn.physical-latency")
  private static var active = 0
  // An interface can still have fake-IP answers cached by the TUN DNS
  // hijacker. Require encrypted resolution without changing system DNS.
  // Reuse the context so batch probes can share resolver/TLS cache state.
  private static let dnsContext: NWParameters.PrivacyContext = {
    let context = NWParameters.PrivacyContext(description: "ssrvpn.physical-latency")
    context.requireEncryptedNameResolution(true, fallbackResolver: .https(
      URL(string: "https://dns.alidns.com/dns-query")!,
      serverAddresses: [.hostPort(host: "223.5.5.5", port: 443)]))
    return context
  }()

  static func validArguments(host: String, port: Int, timeoutMs: Int) -> Bool {
    !host.isEmpty && host.utf8.count <= 253 &&
      !host.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value == 0 } &&
      (1...65535).contains(port) && (1...60000).contains(timeoutMs)
  }

  static func usableAddress(_ address: IPv4Address) -> Bool {
    let b = Array(address.rawValue)
    return b[0] != 0 && b[0] != 127 && b[0] < 224 &&
      !(b[0] == 169 && b[1] == 254) && !(b[0] == 198 && (18...19).contains(b[1]))
  }

  static func measure(host: String, port: Int, timeoutMs: Int, completion: @escaping (Int) -> Void) {
    let start = DispatchTime.now().uptimeNanoseconds
    queue.async {
      guard validArguments(host: host, port: port, timeoutMs: timeoutMs) else {
        DispatchQueue.main.async { completion(-1) }
        return
      }
      guard active < 16 else {
        DispatchQueue.main.async { completion(-14) }
        return
      }
      active += 1
      let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
      var connection: NWConnection?
      var settled = false
      var started = false
      var deadline: DispatchWorkItem?
      func finish(_ value: Int) {
        guard !settled else { return }
        settled = true
        active -= 1
        deadline?.cancel()
        deadline = nil
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        DispatchQueue.main.async { completion(value) }
      }
      let timeout = DispatchWorkItem { finish(-10) }
      deadline = timeout
      queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: start) + .milliseconds(timeoutMs), execute: timeout)
      monitor.pathUpdateHandler = { path in
        guard !settled, !started else { return }
        guard path.status == .satisfied, let physical = path.availableInterfaces.first(where: {
          $0.type == .wifi || $0.type == .wiredEthernet
        }) else {
          finish(-12)
          return
        }
        started = true
        let parameters = NWParameters.tcp
        parameters.requiredInterface = physical
        parameters.prohibitedInterfaceTypes = [.other, .loopback]
        parameters.preferNoProxies = true
        parameters.setPrivacyContext(dnsContext)
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let probe = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: parameters)
        connection = probe
        probe.stateUpdateHandler = { state in
          switch state {
          case .ready:
            guard let actualPath = probe.currentPath,
                  actualPath.availableInterfaces.contains(where: { $0.index == physical.index }),
                  case .hostPort(let endpoint, _) = actualPath.remoteEndpoint,
                  case .ipv4(let address) = endpoint,
                  usableAddress(address) else {
              finish(-1)
              return
            }
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            finish(elapsed < timeoutMs ? max(1, elapsed) : -10)
          case .failed(let error):
            if case .dns = error { finish(-11) } else { finish(-13) }
          case .cancelled:
            finish(-1)
          default:
            break
          }
        }
        probe.start(queue: queue)
      }
      monitor.start(queue: queue)
    }
  }
}
