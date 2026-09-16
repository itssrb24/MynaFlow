import Foundation

public struct ProcessResult: Equatable, Sendable {
  public let standardOutput: String
  public let terminationStatus: Int32

  public init(standardOutput: String, terminationStatus: Int32) {
    self.standardOutput = standardOutput
    self.terminationStatus = terminationStatus
  }
}

public protocol ProcessExecuting: Sendable {
  /// Runs a child to completion, or kills it at `timeout` and throws.
  ///
  /// `timeout` has no default on purpose. There is no value that suits both
  /// callers — transcribing an hour of audio legitimately runs for minutes,
  /// polishing a sentence of dictation takes seconds — and a default would let
  /// a new call site inherit a watchdog nobody chose for it. A compile error
  /// beats a wrong number.
  func run(
    executable: URL, arguments: [String], standardInput: Data?, timeout: TimeInterval
  ) async throws -> ProcessResult
  func cancel() async
}

public enum LocalProcessError: Error, LocalizedError, Sendable {
  case missingExecutable(URL)
  case failedToLaunch(String)
  case nonZeroExit(status: Int32, output: String)
  case emptyOutput
  case timedOut(seconds: TimeInterval)

  public var errorDescription: String? {
    switch self {
    case .missingExecutable(let url): "Local runtime is missing at \(url.path)."
    case .failedToLaunch(let message): "Local runtime could not start: \(message)"
    case .nonZeroExit(let status, let output): "Local runtime exited with \(status): \(output)"
    case .emptyOutput: "The local runtime returned no text."
    case .timedOut(let seconds):
      "Local runtime stopped responding after \(Int(seconds))s and was ended."
    }
  }
}

/// Set once when the watchdog kills a child, read once after the drain returns.
/// A plain `var` cannot cross into the detached watchdog task, and the actor's
/// own isolation is unavailable there — the whole point is that the watchdog
/// runs while `run` is suspended.
private final class TimeoutFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }

  var fired: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

/// Bridges `Process.terminationHandler` to an `await`. The handler can fire
/// before anyone waits (a child that exits instantly), so the flag is kept and
/// a late waiter returns at once.
private final class ExitSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  private var continuation: CheckedContinuation<Void, Never>?

  func signal() {
    lock.lock()
    fired = true
    let waiter = continuation
    continuation = nil
    lock.unlock()
    waiter?.resume()
  }

  func wait() async {
    await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
      lock.lock()
      if fired {
        lock.unlock()
        waiter.resume()
        return
      }
      continuation = waiter
      lock.unlock()
    }
  }
}

public actor LocalProcessExecutor: ProcessExecuting {
  private var currentProcess: Process?

  /// SIGPIPE's default disposition kills the whole process. If a child exits
  /// with its stdin pipe undrained (bad args, crash, OOM-kill), the next write
  /// to that pipe would otherwise terminate Myna instead of surfacing a
  /// catchable error. Ignored once, process-wide, on first executor use.
  private static let ignoreSIGPIPE: Void = {
    signal(SIGPIPE, SIG_IGN)
  }()

  public init() {
    _ = Self.ignoreSIGPIPE
  }

  public func run(
    executable: URL, arguments: [String], standardInput: Data?, timeout: TimeInterval
  ) async throws -> ProcessResult {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw LocalProcessError.missingExecutable(executable)
    }

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = [
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "NO_PROXY": "*",
      "no_proxy": "*",
    ]
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    let inputPipe: Pipe? = standardInput == nil ? nil : Pipe()
    if let inputPipe {
      process.standardInput = inputPipe
    }

    // Exit is awaited through the termination handler, never `waitUntilExit`.
    // That call pumps the calling thread's run loop until Foundation notices
    // the exit, and on an actor's cooperative thread the notice can be missed:
    // observed as a permanent hang with the child already gone and its output
    // fully written, on the sixth of ~2,800 whisper runs in a batch import,
    // and reproduced by `testManyShortChildrenInARowAllReturn`.
    let exited = ExitSignal()
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch {
      throw LocalProcessError.failedToLaunch(error.localizedDescription)
    }
    currentProcess = process

    // Drain stdout/stderr concurrently with the stdin write. FileHandle writes block
    // once the pipe's kernel buffer fills, so a child that streams output while still
    // reading input would otherwise deadlock this actor permanently.
    let outputHandle = outputPipe.fileHandleForReading
    let readTask = Task.detached { outputHandle.readDataToEndOfFile() }

    // Killing the child is what unblocks the drain. `readDataToEndOfFile()` is
    // a blocking syscall, so cancelling `readTask` does nothing — the read only
    // returns once the pipe's write end closes, which happens when the writer
    // dies. Measured: a `llama-cli` that stalls without exiting otherwise waits
    // forever, and neither the caller nor the log ever learns why.
    //
    // The Process is captured unsafely rather than signalling a captured pid:
    // a pid can be recycled between the child exiting and the watchdog firing,
    // and killing an unrelated process is a worse failure than the one being
    // fixed.
    let target = process
    let timedOut = TimeoutFlag()
    let watchdog = Task.detached {
      try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
      timedOut.set()
      target.terminate()
    }

    if let inputPipe, let standardInput {
      let writeHandle = inputPipe.fileHandleForWriting
      do {
        // Throwing write: with SIGPIPE ignored, a child that closed stdin
        // early produces EPIPE here — a typed error, not a process kill.
        try writeHandle.write(contentsOf: standardInput)
      } catch {
        try? writeHandle.close()
        watchdog.cancel()
        process.terminate()
        _ = await readTask.value
        currentProcess = nil
        throw LocalProcessError.failedToLaunch(
          "stdin write failed: \(error.localizedDescription)")
      }
      try? writeHandle.close()
    }

    let data = await readTask.value
    watchdog.cancel()
    await exited.wait()
    currentProcess = nil

    // Checked after the drain, not instead of it: the child is already dead by
    // the time the read returns, and reporting a partial answer as a success
    // would hand the caller a truncated summary it cannot tell from a whole one.
    if timedOut.fired {
      throw LocalProcessError.timedOut(seconds: timeout)
    }
    return ProcessResult(
      standardOutput: String(decoding: data, as: UTF8.self),
      terminationStatus: process.terminationStatus
    )
  }

  public func cancel() {
    currentProcess?.terminate()
    currentProcess = nil
  }
}

public struct SensitiveLogRedactor: Sendable {
  public init() {}

  public func redact(_ message: String) -> String {
    var result = message
    let patterns = [
      "(?i)(transcript|selectedText|nearbyText|prompt|audio|title|name|attendee|device)\\s*[:=]\\s*[^,;\\n]+",
      "(?i)<(input|selection|context)>[\\s\\S]*?</\\1>",
      "(?i)\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b",
    ]
    for pattern in patterns {
      result = result.replacingOccurrences(
        of: pattern,
        with: "[REDACTED]",
        options: .regularExpression
      )
    }
    return result
  }
}
