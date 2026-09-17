import Foundation
import Security
import os

public enum LlamaServerError: Error, LocalizedError, Sendable {
  case executableMissing
  case modelMissing
  case noFreePort
  case failedToLaunch(String)
  case healthTimeout
  case badResponse(Int)
  case emptyOutput

  public var errorDescription: String? {
    switch self {
    case .executableMissing: "The bundled llama-server is missing."
    case .modelMissing: "The selected model file is not installed."
    case .noFreePort: "Could not reserve a loopback port for the model server."
    case .failedToLaunch(let m): "The model server failed to start: \(m)"
    case .healthTimeout: "The model server did not become ready in time."
    case .badResponse(let code): "The model server returned an unexpected response (\(code))."
    case .emptyOutput: "The model server returned no text."
    }
  }
}

/// A persistent, loopback-only `llama-server` process. The model loads once and
/// stays resident between requests, eliminating the multi-second cold-spawn
/// tax paid per utterance today. Memory-safe by design: the process is spawned
/// lazily on the first request, auto-unloaded after an idle timeout, and torn
/// down on app quit — so an idle app holds no model memory.
///
/// Binds 127.0.0.1 on an OS-assigned ephemeral port and never a public
/// interface, preserving Myna's on-device guarantee (ADR-001).
public actor LlamaServerHost {
  public struct Configuration: Sendable {
    public var executableURL: URL
    public var modelURL: URL
    public var modelIdentifier: String
    public var idleTimeout: TimeInterval
    /// Where to drop the server's stderr tail on failure (diagnostics export
    /// picks it up). nil (tests) skips the dump, never the capture.
    public var diagnosticsDirectory: URL?

    public init(
      executableURL: URL, modelURL: URL, modelIdentifier: String,
      idleTimeout: TimeInterval = 300, diagnosticsDirectory: URL? = nil
    ) {
      self.executableURL = executableURL
      self.modelURL = modelURL
      self.modelIdentifier = modelIdentifier
      self.idleTimeout = idleTimeout
      self.diagnosticsDirectory = diagnosticsDirectory
    }
  }

  private var configuration: Configuration
  private var process: Process?
  private var port: Int?
  /// Random per-spawn credential shared only with the child process. It is
  /// never persisted or included in process arguments/logs.
  private var apiToken: String?
  private var ready = false
  private var lastUsed = Date.distantPast
  private var supervisor: Task<Void, Never>?
  private var loadTask: Task<URL, Error>?
  private let session: URLSession
  /// Tail of the child's stderr. A lock (not actor state) because the pipe's
  /// readabilityHandler fires on a dispatch queue outside actor isolation.
  private let stderrTail = OSAllocatedUnfairLock(initialState: CappedByteBuffer())

  public init(configuration: Configuration) {
    self.configuration = configuration
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 120
    config.waitsForConnectivity = false
    config.httpCookieStorage = nil
    config.urlCache = nil
    session = URLSession(configuration: config)
  }

  public var isLoaded: Bool { process?.isRunning == true && ready }

  /// Pure idle decision — extracted so the timeout policy is unit-testable.
  public static func shouldUnload(now: Date, lastUsed: Date, idleTimeout: TimeInterval) -> Bool {
    now.timeIntervalSince(lastUsed) >= idleTimeout
  }

  // MARK: Public request path

  /// Runs one completion against the warm server, spawning it first if needed.
  /// `stop` strings tell the server where to stop generating cleanly.
  public func complete(
    prompt: String, maxTokens: Int, temperature: Double = 0.2, stop: [String]
  ) async throws -> String {
    let base = try await ensureReady()
    guard let apiToken else {
      throw LlamaServerError.failedToLaunch("server authentication was not initialized")
    }
    lastUsed = Date()

    var request = Self.authenticatedRequest(
      url: base.appendingPathComponent("completion"), apiToken: apiToken)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "prompt": prompt,
      "n_predict": maxTokens,
      "temperature": temperature,
      "stop": stop,
      "cache_prompt": true,
    ])

    let (data, response) = try await session.data(for: request)
    lastUsed = Date()
    guard let http = response as? HTTPURLResponse else { throw LlamaServerError.badResponse(-1) }
    guard http.statusCode == 200 else { throw LlamaServerError.badResponse(http.statusCode) }
    guard
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let content = object["content"] as? String
    else { throw LlamaServerError.badResponse(200) }
    return content
  }

  // MARK: Configuration changes

  /// Swap the active model (or idle timeout). A model change tears the current
  /// server down; it re-spawns lazily on the next request with the new model.
  public func update(modelURL: URL, modelIdentifier: String) {
    guard modelURL != configuration.modelURL else { return }
    configuration.modelURL = modelURL
    configuration.modelIdentifier = modelIdentifier
    terminate()
  }

  public func setIdleTimeout(_ timeout: TimeInterval) {
    configuration.idleTimeout = timeout
  }

  /// Tear the server down (app quit / warm-server disabled). Idempotent.
  public func stop() {
    terminate()
  }

  // MARK: Lifecycle

  private func ensureReady() async throws -> URL {
    if let port, let process, process.isRunning, ready,
      Self.processOwnsListeningPort(processIdentifier: process.processIdentifier, port: port)
    {
      return Self.baseURL(port: port)
    }
    if let loadTask { return try await loadTask.value }

    let task = Task { try await performSpawn() }
    loadTask = task
    defer { loadTask = nil }
    return try await task.value
  }

  private func performSpawn() async throws -> URL {
    terminate()

    let modelBytes =
      (try? FileManager.default.attributesOfItem(atPath: configuration.modelURL.path)[.size]
        as? Int64) ?? 0
    MynaLog.info(
      .server,
      "spawn: model=\(configuration.modelIdentifier) fileBytes=\(modelBytes) "
        + "ramTotal=\(SystemInfoReader.memoryTotalBytes()) ramFree=\(SystemInfoReader.memoryFreeBytes())"
    )
    guard FileManager.default.isExecutableFile(atPath: configuration.executableURL.path) else {
      MynaLog.error(.server, "spawn failed: executable missing")
      throw LlamaServerError.executableMissing
    }
    guard FileManager.default.fileExists(atPath: configuration.modelURL.path) else {
      MynaLog.error(.server, "spawn failed: model file missing for \(configuration.modelIdentifier)")
      throw LlamaServerError.modelMissing
    }
    // Crash safety: kill any orphaned server from a previous run of *our exact*
    // binary before starting a fresh one (the quit hook covers clean exits).
    killOrphans(executablePath: configuration.executableURL.path)

    let token = try Self.makeAPIToken()
    apiToken = token

    let process = Process()
    process.executableURL = configuration.executableURL
    process.arguments = Self.serverArguments(configuration: configuration)
    // dyld resolves the adjacent libllama-server-impl.dylib via @rpath; the
    // fallback path makes that robust regardless of launch cwd.
    let runtimesDir = configuration.executableURL.deletingLastPathComponent().path
    process.environment = Self.serverEnvironment(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      runtimesDirectory: URL(fileURLWithPath: runtimesDir, isDirectory: true),
      apiToken: token)
    // stdout stays discarded, but stderr is captured into a bounded tail:
    // the readabilityHandler always drains the pipe, so a long-lived process
    // can never deadlock on a full buffer, and the last ~64 KB of server
    // errors (GGUF parse failure, Metal init, OOM) survive for diagnostics.
    process.standardOutput = FileHandle.nullDevice
    let stderrPipe = Pipe()
    let tail = stderrTail
    tail.withLock { $0 = CappedByteBuffer() }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      tail.withLock { $0.append(data) }
    }
    process.standardError = stderrPipe

    do { try process.run() } catch {
      apiToken = nil
      MynaLog.error(.server, "spawn failed: process.run: \(error.localizedDescription)")
      throw LlamaServerError.failedToLaunch(error.localizedDescription)
    }
    self.process = process

    do {
      let chosenPort = try await waitForListeningPort(process: process)
      self.port = chosenPort
      try await waitForHealth(port: chosenPort, process: process)
      guard process.isRunning,
        Self.processOwnsListeningPort(
          processIdentifier: process.processIdentifier, port: chosenPort)
      else {
        throw LlamaServerError.failedToLaunch("server did not retain ownership of its port")
      }
      MynaLog.info(.server, "ready: port=\(chosenPort) model=\(configuration.modelIdentifier)")
      ready = true
      startSupervisor()
      return Self.baseURL(port: chosenPort)
    } catch {
      dumpServerStderr(reason: "startup-failure")
      terminate()
      throw error
    }
  }

  /// Writes the captured stderr tail to Diagnostics/llama-server.stderr.log
  /// so the export carries the server's own words for its last failure.
  private func dumpServerStderr(reason: String) {
    guard let directory = configuration.diagnosticsDirectory else { return }
    let data = stderrTail.withLock { $0.data }
    guard !data.isEmpty else { return }
    let manager = FileManager.default
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("llama-server.stderr.log")
    try? data.write(to: url, options: .atomic)
    MynaLog.warn(.server, "stderr tail saved (\(data.count) bytes, reason=\(reason))")
  }

  private func waitForListeningPort(process: Process) async throws -> Int {
    let startedAt = Date()
    let deadline = startedAt.addingTimeInterval(45)
    while Date() < deadline {
      if !process.isRunning {
        MynaLog.error(
          .server,
          "exited during startup: status=\(process.terminationStatus) "
            + "after=\(Int(Date().timeIntervalSince(startedAt)))s")
        throw LlamaServerError.failedToLaunch("server exited during startup")
      }
      let output = stderrTail.withLock { String(decoding: $0.data, as: UTF8.self) }
      if let port = Self.reportedListeningPort(in: output),
        Self.processOwnsListeningPort(processIdentifier: process.processIdentifier, port: port)
      {
        return port
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    MynaLog.error(.server, "listening-port timeout after 45s: model=\(configuration.modelIdentifier)")
    throw LlamaServerError.healthTimeout
  }

  private func waitForHealth(port: Int, process: Process) async throws {
    let startedAt = Date()
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
      if !process.isRunning {
        MynaLog.error(
          .server,
          "exited during startup: status=\(process.terminationStatus) "
            + "after=\(Int(Date().timeIntervalSince(startedAt)))s")
        throw LlamaServerError.failedToLaunch("server exited during startup")
      }
      let request = Self.healthRequest(port: port)
      if let (_, response) = try? await session.data(for: request),
        (response as? HTTPURLResponse)?.statusCode == 200
      {
        return
      }
      try? await Task.sleep(for: .milliseconds(400))
    }
    MynaLog.error(.server, "health timeout after 45s: model=\(configuration.modelIdentifier)")
    terminate()
    throw LlamaServerError.healthTimeout
  }

  private func startSupervisor() {
    supervisor?.cancel()
    supervisor = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        await self?.unloadIfIdle()
      }
    }
  }

  private func unloadIfIdle() {
    guard process?.isRunning == true,
      Self.shouldUnload(now: Date(), lastUsed: lastUsed, idleTimeout: configuration.idleTimeout)
    else { return }
    MynaLog.info(.server, "idle unload after \(Int(configuration.idleTimeout))s")
    terminate()
  }

  private func terminate() {
    supervisor?.cancel()
    supervisor = nil
    if let process, process.isRunning { process.terminate() }
    process = nil
    port = nil
    apiToken = nil
    ready = false
  }

  // MARK: Helpers

  private static func baseURL(port: Int) -> URL {
    URL(string: "http://127.0.0.1:\(port)/")!
  }

  /// A fresh 256-bit secret for each child-process launch. Base64 is safe in
  /// an HTTP authorization header and avoids reducing the random byte space.
  static func makeAPIToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw LlamaServerError.failedToLaunch("could not create a server credential")
    }
    return Data(bytes).base64EncodedString()
  }

  static func authenticatedRequest(url: URL, apiToken: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
    return request
  }

  static func serverArguments(configuration: Configuration) -> [String] {
    [
      "--model", configuration.modelURL.path,
      "--host", "127.0.0.1",
      // Let llama-server keep ownership of its OS-assigned port from bind
      // through accept; reserving and releasing a probe port creates a TOCTOU
      // window in which another local process can impersonate the server.
      "--port", "0",
      "--ctx-size", "8192",
      "--n-gpu-layers", "99",
      "--flash-attn", "on",
      "--threads", String(max(4, ProcessInfo.processInfo.activeProcessorCount - 2)),
      "--no-webui",
      // Retain startup/runtime errors without request-level output that could
      // disclose prompt or generated text in the bounded stderr tail.
      // The pinned runtime reports its selected endpoint at info level. The
      // bounded stderr tail never includes request bodies or the API token.
      "--log-verbosity", "3",
    ]
  }

  static func healthRequest(port: Int) -> URLRequest {
    var request = URLRequest(url: baseURL(port: port).appendingPathComponent("health"))
    request.timeoutInterval = 2
    return request
  }

  /// Extracts only a complete loopback listening announcement emitted by the
  /// pinned llama-server. Partial pipe reads and unrelated text are ignored.
  static func reportedListeningPort(in output: String) -> Int? {
    let completeLines = output.components(separatedBy: .newlines).dropLast()
    let pattern =
      #"^[0-9]+\.[0-9]{2}\.[0-9]{3}\.[0-9]{3} I srv  llama_server: listening on http://127\.0\.0\.1:([0-9]{1,5})$"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    for line in completeLines.reversed() {
      let range = NSRange(line.startIndex..., in: line)
      guard let match = expression.firstMatch(in: line, range: range), match.range == range,
        let portRange = Range(match.range(at: 1), in: line),
        let port = Int(line[portRange]), (1...65_535).contains(port)
      else { continue }
      return port
    }
    return nil
  }

  /// Confirms that the selected listener belongs to the exact child PID. This
  /// prevents a forged stderr line from redirecting authenticated requests to
  /// another same-user loopback process.
  static func processOwnsListeningPort(processIdentifier: Int32, port: Int) -> Bool {
    guard processIdentifier > 0, (1...65_535).contains(port) else { return false }
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    probe.arguments = listeningPortOwnerArguments(
      processIdentifier: processIdentifier, port: port)
    probe.standardOutput = FileHandle.nullDevice
    probe.standardError = FileHandle.nullDevice
    do {
      try probe.run()
      probe.waitUntilExit()
      return probe.terminationStatus == 0
    } catch {
      return false
    }
  }

  static func listeningPortOwnerArguments(processIdentifier: Int32, port: Int) -> [String] {
    [
      "-nP", "-a", "-p", String(processIdentifier),
      "-iTCP@127.0.0.1:\(port)", "-sTCP:LISTEN",
    ]
  }

  static func serverEnvironment(
    homeDirectory: URL, runtimesDirectory: URL, apiToken: String
  ) -> [String: String] {
    [
      "HOME": homeDirectory.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "NO_PROXY": "*",
      "no_proxy": "*",
      "DYLD_FALLBACK_LIBRARY_PATH": runtimesDirectory.path,
      // llama.cpp b10042 reads this as if --api-key were supplied. Keeping it
      // out of argv prevents the credential appearing in ordinary process lists.
      "LLAMA_API_KEY": apiToken,
    ]
  }

  /// Ask the OS for an unused loopback TCP port by binding to port 0 and
  /// reading back the assignment. A tiny reuse race is covered by respawn.
  static func freeLoopbackPort() -> Int? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { return nil }
    var result = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &result) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &length)
      }
    }
    guard named == 0 else { return nil }
    let assigned = Int(UInt16(bigEndian: result.sin_port))
    return assigned > 0 ? assigned : nil
  }

  /// Best-effort: terminate any process whose executable is exactly ours.
  private func killOrphans(executablePath: String) {
    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    pkill.arguments = ["-f", Self.orphanProcessPattern(executablePath: executablePath)]
    pkill.standardOutput = FileHandle.nullDevice
    pkill.standardError = FileHandle.nullDevice
    try? pkill.run()
    pkill.waitUntilExit()
  }

  /// `pkill -f` consumes an extended regular expression. Escape the executable
  /// path and anchor it to argv[0], otherwise dots, brackets, or other regex
  /// metacharacters in a user's home path can match and terminate unrelated
  /// processes.
  static func orphanProcessPattern(executablePath: String) -> String {
    let metacharacters = Set<Character>("\\.^$|?*+()[]{}")
    var escaped = ""
    escaped.reserveCapacity(executablePath.count)
    for character in executablePath {
      if metacharacters.contains(character) { escaped.append("\\") }
      escaped.append(character)
    }
    return "^\(escaped)( |$)"
  }
}

// MARK: - Port shims (Myna Flow)

/// Logging shim keeping the port line-for-line comparable with Myna's file.
enum MynaLog {
  enum Category { case server, provider }
  private static let logger = Logger(
    subsystem: "com.itssrb24.MynaFlow", category: "llm")

  static func info(_ category: Category, _ message: String) {
    logger.info("\(message, privacy: .public)")
  }
  static func warn(_ category: Category, _ message: String) {
    logger.warning("\(message, privacy: .public)")
  }
  static func error(_ category: Category, _ message: String) {
    logger.error("\(message, privacy: .public)")
  }
}

/// Bounded byte tail for the child's stderr.
public struct CappedByteBuffer: Sendable {
  public let capacity: Int
  public private(set) var data = Data()

  public init(capacity: Int = 65_536) {
    self.capacity = capacity
  }

  public mutating func append(_ incoming: Data) {
    data.append(incoming)
    if data.count > capacity {
      data.removeFirst(data.count - capacity)
    }
  }
}
