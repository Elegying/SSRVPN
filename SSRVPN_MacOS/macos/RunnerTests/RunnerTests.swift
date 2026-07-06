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

}
