import Cocoa
import Darwin

protocol WindowRevealTarget: AnyObject {
  var isMiniaturized: Bool { get }
  func deminiaturize(_ sender: Any?)
  func makeKeyAndOrderFront(_ sender: Any?)
}

extension NSWindow: WindowRevealTarget {}

enum WindowRevealController {
  @discardableResult
  static func reveal(_ window: WindowRevealTarget?) -> Bool {
    guard let window else { return false }
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
    return true
  }
}

final class AppInstanceLease {
  private var descriptor: Int32 = -1

  var isAcquired: Bool { descriptor >= 0 }

  @discardableResult
  func acquire(at url: URL) -> Bool {
    if isAcquired { return true }
    let candidate = url.path.withCString {
      Darwin.open(
        $0,
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
      )
    }
    guard candidate >= 0 else { return false }

    var fileInfo = stat()
    guard
      Darwin.fstat(candidate, &fileInfo) == 0,
      fileInfo.st_mode & S_IFMT == S_IFREG,
      fileInfo.st_uid == geteuid(),
      fileInfo.st_nlink == 1,
      Darwin.fchmod(candidate, S_IRUSR | S_IWUSR) == 0,
      flock(candidate, LOCK_EX | LOCK_NB) == 0
    else {
      _ = Darwin.close(candidate)
      return false
    }

    descriptor = candidate
    return true
  }

  func release() {
    guard descriptor >= 0 else { return }
    _ = flock(descriptor, LOCK_UN)
    _ = Darwin.close(descriptor)
    descriptor = -1
  }
}
