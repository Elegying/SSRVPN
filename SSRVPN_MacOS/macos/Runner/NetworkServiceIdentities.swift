import Foundation
import SystemConfiguration

extension AppDelegate {
  // Unlike the current location, this includes inactive locations and orphaned
  // services. Only absence here proves that a saved service was deleted.
  func allNetworkServiceIDs() -> [String]? {
    guard let preferences = SCPreferencesCreate(nil, "com.ssrvpn.service-existence" as CFString, nil),
      let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService]
    else { return nil }
    var ids: [String] = []
    for service in services {
      guard let id = SCNetworkServiceGetServiceID(service) as String?, !id.isEmpty else { return nil }
      ids.append(id)
    }
    return ids
  }

  func currentNetworkServiceIdentities(enabledOnly: Bool = false) -> [String: String]? {
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
    for case let service as SCNetworkService in services where !enabledOnly || SCNetworkServiceGetEnabled(service) {
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
}
