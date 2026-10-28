// Native read-only acceptance: a parseable Alias is not necessarily resolvable.
import AppKit
import CoreFoundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard CommandLine.arguments.count == 3 else { fail("Expected mount and alias file") }
let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let expected = root.appendingPathComponent(".background/background.png")
do {
    let alias = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    guard let bookmark = CFURLCreateBookmarkDataFromAliasRecord(kCFAllocatorDefault,
                                                                alias as CFData) else {
        fail("DMG background alias cannot be converted")
    }
    var stale = false
    let resolved = try URL(resolvingBookmarkData: bookmark.takeRetainedValue() as Data,
                          options: [.withoutUI, .withoutMounting], relativeTo: nil,
                          bookmarkDataIsStale: &stale).resolvingSymlinksInPath()
    guard resolved.path == expected.path else {
        fail("DMG background resolves outside its mounted image: \(resolved.path) != \(expected.path)")
    }
    guard let image = NSImage(contentsOf: resolved),
          image.size == NSSize(width: 720, height: 460),
          image.representations.contains(where: { $0.pixelsWide == 1440 && $0.pixelsHigh == 920 })
    else { fail("DMG background must be a readable 720x460 point Retina image") }
    print("DMG native background verified: local alias, readable image and Retina canvas.")
} catch { fail("DMG native background verification failed: \(error)") }
