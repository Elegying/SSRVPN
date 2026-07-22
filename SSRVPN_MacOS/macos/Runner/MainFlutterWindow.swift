import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  static let integratedBackgroundColor = NSColor(
    srgbRed: 24.0 / 255.0,
    green: 27.0 / 255.0,
    blue: 59.0 / 255.0,
    alpha: 1.0
  )

  func configureIntegratedTitlebar() {
    title = ""
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    styleMask.insert(.fullSizeContentView)
    backgroundColor = Self.integratedBackgroundColor
    if #available(macOS 11.0, *) {
      titlebarSeparatorStyle = .none
    }
  }

  override func awakeFromNib() {
    configureIntegratedTitlebar()

    guard let delegate = NSApp.delegate as? AppDelegate else {
      super.awakeFromNib()
      orderOut(nil)
      DispatchQueue.main.async { NSApp.terminate(nil) }
      return
    }
    guard delegate.acquireInstanceLease() else {
      super.awakeFromNib()
      orderOut(nil)
      delegate.requestPrimaryInstanceActivation()
      DispatchQueue.main.async { NSApp.terminate(nil) }
      return
    }

    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerCoreProcessChannel(with: flutterViewController.engine.binaryMessenger)
    super.awakeFromNib()
  }

  private func registerCoreProcessChannel(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "ssrvpn/core_process",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard let delegate = NSApp.delegate as? AppDelegate else {
        result(FlutterError(
          code: "core_process_unavailable",
          message: "SSRVPN process lifecycle delegate is unavailable",
          details: nil
        ))
        return
      }

      if call.method == "beginProxyLifecycleTransaction" {
        var token: String?
        delegate.performCoreProcessOperationAndWait {
          token = delegate.beginProxyLifecycleTransaction()
        }
        guard let token else {
          result(FlutterError(
            code: "application_termination_pending",
            message: "SSRVPN is already committed to application termination",
            details: nil
          ))
          return
        }
        result(token)
        return
      }
      if call.method == "endProxyLifecycleTransaction" {
        guard
          let arguments = call.arguments as? [String: Any],
          let token = arguments["token"] as? String,
          !token.isEmpty
        else {
          result(FlutterError(
            code: "invalid_proxy_lifecycle_token",
            message: "A proxy lifecycle token is required",
            details: nil
          ))
          return
        }
        delegate.enqueueCoreProcessOperation {
          let ended = delegate.endProxyLifecycleTransaction(token: token)
          DispatchQueue.main.async { result(ended) }
        }
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let directoryPath = arguments["directory"] as? String,
        !directoryPath.isEmpty,
        (directoryPath as NSString).isAbsolutePath
      else {
        result(FlutterError(
          code: "invalid_core_process_arguments",
          message: "An absolute runtime directory is required",
          details: nil
        ))
        return
      }
      let directory = URL(
        fileURLWithPath: directoryPath,
        isDirectory: true
      ).standardizedFileURL

      switch call.method {
      case "launchOwnedCore":
        delegate.enqueueCoreProcessOperation {
          do {
            let launch = try delegate.launchOwnedCore(in: directory)
            DispatchQueue.main.async { result(launch.dictionary) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(
                code: "core_launch_failed",
                message: "AtlasCore could not be launched with a durable identity",
                details: error.localizedDescription
              ))
            }
          }
        }

      case "ownedCoreStatus":
        guard let expectedContents = arguments["expectedContents"] as? String else {
          result(FlutterError(
            code: "invalid_core_pid_record",
            message: "The expected AtlasCore PID record is required",
            details: nil
          ))
          return
        }
        delegate.enqueueCoreProcessOperation {
          let status = delegate.statusForOwnedCore(
            in: directory,
            expectedContents: expectedContents
          )
          DispatchQueue.main.async { result(status?.dictionary) }
        }

      case "terminateOwnedCore":
        delegate.enqueueCoreProcessOperation {
          let stopped = delegate.terminateOwnedCore(in: directory)
          DispatchQueue.main.async { result(stopped) }
        }

      case "terminateOwnedCoreRecord":
        guard let expectedContents = arguments["expectedContents"] as? String else {
          result(FlutterError(
            code: "invalid_core_pid_record",
            message: "The expected AtlasCore PID record is required",
            details: nil
          ))
          return
        }
        delegate.enqueueCoreProcessOperation {
          let stopped = delegate.terminateOwnedCoreRecord(
            in: directory,
            expectedContents: expectedContents
          )
          DispatchQueue.main.async { result(stopped) }
        }

      case "removeOwnedCorePidRecord":
        guard let expectedContents = arguments["expectedContents"] as? String else {
          result(FlutterError(
            code: "invalid_core_pid_record",
            message: "The expected AtlasCore PID record is required",
            details: nil
          ))
          return
        }
        delegate.enqueueCoreProcessOperation {
          let removed = delegate.removeOwnedCorePidRecord(
            in: directory,
            expectedContents: expectedContents
          )
          DispatchQueue.main.async { result(removed) }
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
