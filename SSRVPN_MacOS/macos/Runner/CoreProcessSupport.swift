import Darwin
import Foundation

struct CoreProcessIdentity: Equatable {
  let pid: Int32
  let executablePath: String
  let startSeconds: UInt64
  let startMicroseconds: UInt64
}

struct CoreProcessGeneration: Equatable {
  let pid: Int32
  let startSeconds: UInt64
  let startMicroseconds: UInt64
}

struct CorePidRecord: Equatable {
  let pid: Int32
  let startSeconds: UInt64
  let startMicroseconds: UInt64

  init(identity: CoreProcessIdentity) {
    pid = identity.pid
    startSeconds = identity.startSeconds
    startMicroseconds = identity.startMicroseconds
  }

  init?(text: String) {
    let fields = text.split(separator: " ", omittingEmptySubsequences: false)
    guard
      fields.count == 4,
      fields[0] == "v2",
      let pid = Int32(fields[1]),
      pid > 1,
      let startSeconds = UInt64(fields[2]),
      startSeconds > 0,
      fields[3].last == "\n",
      let startMicroseconds = UInt64(fields[3].dropLast()),
      startMicroseconds < 1_000_000
    else {
      return nil
    }

    self.pid = pid
    self.startSeconds = startSeconds
    self.startMicroseconds = startMicroseconds
    guard serialized == text else { return nil }
  }

  var serialized: String {
    "v2 \(pid) \(startSeconds) \(startMicroseconds)\n"
  }

  func identity(executablePath: String) -> CoreProcessIdentity {
    CoreProcessIdentity(
      pid: pid,
      executablePath: executablePath,
      startSeconds: startSeconds,
      startMicroseconds: startMicroseconds
    )
  }
}

struct CoreLaunchResult: Equatable {
  let pid: Int32
  let pidRecordContents: String

  var dictionary: [String: Any] {
    ["pid": Int(pid), "pidRecordContents": pidRecordContents]
  }
}

struct CoreProcessStatus: Equatable {
  let isRunning: Bool
  let exitCode: Int32?
  let standardOutput: String
  let standardError: String

  var dictionary: [String: Any] {
    var value: [String: Any] = [
      "isRunning": isRunning,
      "standardOutput": standardOutput,
      "standardError": standardError,
    ]
    if let exitCode { value["exitCode"] = Int(exitCode) }
    return value
  }
}

struct ProxyCommandResult {
  let succeeded: Bool
  let output: String?
}

final class ProxyStateFileSnapshot {
  init(descriptor: Int32, data: Data, fileInfo: stat) {
    self.descriptor = descriptor
    self.data = data
    self.fileInfo = fileInfo
  }

  deinit {
    _ = Darwin.close(descriptor)
  }

  let descriptor: Int32
  let data: Data
  let fileInfo: stat
}

enum ApplicationTerminationLeaseState: Equatable {
  case idle
  case pending(UUID)
  case committed
}

final class CoreOutputCapture {
  let standardOutputPipe = Pipe()
  let standardErrorPipe = Pipe()
  private let lock = NSLock()
  private var standardOutputData = Data()
  private var standardErrorData = Data()
  private let maximumBufferedBytes = 64 * 1024

  init() {
    standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
      } else {
        self?.capture(data, isError: false)
      }
    }
    standardErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
      } else {
        self?.capture(data, isError: true)
      }
    }
  }

  func closeParentWriteHandles() {
    standardOutputPipe.fileHandleForWriting.closeFile()
    standardErrorPipe.fileHandleForWriting.closeFile()
  }

  func drain(flushIncomplete: Bool = false) -> (String, String) {
    lock.lock()
    let stdout = decodeAvailableUTF8(
      from: &standardOutputData,
      flushIncomplete: flushIncomplete
    )
    let stderr = decodeAvailableUTF8(
      from: &standardErrorData,
      flushIncomplete: flushIncomplete
    )
    lock.unlock()
    return (stdout, stderr)
  }

  func closeAfterExit() {
    standardOutputPipe.fileHandleForReading.readabilityHandler = nil
    standardErrorPipe.fileHandleForReading.readabilityHandler = nil
    standardOutputPipe.fileHandleForReading.closeFile()
    standardErrorPipe.fileHandleForReading.closeFile()
  }

  private func capture(_ data: Data, isError: Bool) {
    guard !data.isEmpty else { return }
    lock.lock()
    if isError {
      append(data, to: &standardErrorData)
    } else {
      append(data, to: &standardOutputData)
    }
    lock.unlock()
  }

  private func append(_ data: Data, to buffer: inout Data) {
    buffer.append(data)
    if buffer.count > maximumBufferedBytes {
      buffer.removeFirst(buffer.count - maximumBufferedBytes)
      // If the bounded prefix trim landed inside a scalar, discard only the
      // orphaned continuation bytes. A complete future scalar is never
      // decoded as U+FFFD merely because the diagnostic window rolled over.
      while let first = buffer.first, first & 0xC0 == 0x80 {
        buffer.removeFirst()
      }
    }
  }

  private func decodeAvailableUTF8(
    from buffer: inout Data,
    flushIncomplete: Bool
  ) -> String {
    guard !buffer.isEmpty else { return "" }
    let prefixLength = flushIncomplete
      ? buffer.count
      : completeUTF8PrefixLength(in: buffer)
    guard prefixLength > 0 else { return "" }
    let prefix = buffer.prefix(prefixLength)
    buffer.removeFirst(prefixLength)
    return String(decoding: prefix, as: UTF8.self)
  }

  private func completeUTF8PrefixLength(in data: Data) -> Int {
    guard !data.isEmpty else { return 0 }
    var leadIndex = data.index(before: data.endIndex)
    var continuationCount = 0
    while data[leadIndex] & 0xC0 == 0x80, continuationCount < 3 {
      continuationCount += 1
      guard leadIndex != data.startIndex else {
        // A continuation-only suffix is invalid input, not a potentially
        // completable scalar. Decode it with the standard replacement policy.
        return data.count
      }
      leadIndex = data.index(before: leadIndex)
    }

    let lead = data[leadIndex]
    let expectedLength: Int
    switch lead {
    case 0xC2...0xDF:
      expectedLength = 2
    case 0xE0...0xEF:
      expectedLength = 3
    case 0xF0...0xF4:
      expectedLength = 4
    default:
      return data.count
    }
    let availableLength = data.distance(from: leadIndex, to: data.endIndex)
    guard availableLength < expectedLength else { return data.count }
    return data.distance(from: data.startIndex, to: leadIndex)
  }
}

final class NativeOwnedCoreProcess {
  let process: Process
  let pidRecordContents: String
  let outputCapture: CoreOutputCapture

  init(
    process: Process,
    pidRecordContents: String,
    outputCapture: CoreOutputCapture
  ) {
    self.process = process
    self.pidRecordContents = pidRecordContents
    self.outputCapture = outputCapture
  }

  func takeStatus() -> CoreProcessStatus {
    let running = process.isRunning
    let output = outputCapture.drain(flushIncomplete: !running)
    return CoreProcessStatus(
      isRunning: running,
      exitCode: running ? nil : process.terminationStatus,
      standardOutput: output.0,
      standardError: output.1
    )
  }
}
