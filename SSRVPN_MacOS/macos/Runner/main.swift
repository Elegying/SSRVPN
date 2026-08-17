import Cocoa
import Darwin

if ProxyGuardianCommand.isRequested() {
  Darwin.exit(ProxyGuardianCommand.run())
}

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
