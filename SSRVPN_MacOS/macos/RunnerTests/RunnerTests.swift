import Cocoa
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

  func testTerminationMatchesOnlyTheExactOwnedCorePath() {
    let delegate = AppDelegate()
    let core = "/Users/test/Library/Application Support/SSRVPN/AtlasCore"

    XCTAssertTrue(delegate.isOwnedCoreCommand(core + " -d data", corePath: core))
    XCTAssertFalse(
      delegate.isOwnedCoreCommand(
        "/tmp/SSRVPN-helper/bin/AtlasCore -d data",
        corePath: core
      )
    )
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

}
