import Foundation
import os

/// Every language model Myna Flow can download. Hashes and byte sizes are
/// pinned from the Hugging Face API (`lfs.oid` / `lfs.size`) — never guessed.
///
/// **URLs pin a commit revision, never `main`.** `resolve/main/...` follows
/// whatever the publisher uploaded most recently, so a re-upload silently
/// changes the bytes under a fixed hash and every fresh download starts
/// failing verification. `resolve/<sha>/...` is immutable, so the URL and the
/// hash can no longer disagree. Moving to a newer revision is a deliberate
/// code change — no model reaches a user without someone deciding it should.
///
/// (Parakeet is not listed here: FluidAudio's ModelHub owns that download.)
public enum DefaultModelCatalog {
  public static let gemma4E4BQ4 = ModelDescriptor(
    id: "gemma-4-e4b-it-qat-ud-q4-k-xl",
    displayName: "Gemma 4 E4B",
    kind: .languageModel,
    variant: "UD-Q4_K_XL",
    downloadURL: URL(
      string:
        "https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF/resolve/8c5a9e4fd5482e2be20fe0bf013b4c262a8f4265/gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf?download=true"
    )!,
    expectedSHA256: "df0fd4ee07072c607c29a0a1cb4f98918426cca12f45a2776bdd6ee6d09a4de3",
    expectedBytes: 4_215_695_776,
    fileName: "gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf",
    tier: "Fastest"
  )

  public static let gemma4TwelveBQ4 = ModelDescriptor(
    id: "gemma-4-12b-it-qat-ud-q4-k-xl",
    displayName: "Gemma 4 12B",
    kind: .languageModel,
    variant: "UD-Q4_K_XL",
    downloadURL: URL(
      string:
        "https://huggingface.co/unsloth/gemma-4-12B-it-qat-GGUF/resolve/980b060c40a8539ac159e0501a3e0f66a6365af3/gemma-4-12B-it-qat-UD-Q4_K_XL.gguf?download=true"
    )!,
    expectedSHA256: "90fd44e29e0d7cffeb0fd00dc73cfdab9ed0b0e95306ecf7821ea634c940c370",
    expectedBytes: 6_716_356_800,
    fileName: "gemma-4-12B-it-qat-UD-Q4_K_XL.gguf",
    tier: "Balanced"
  )

  /// Mixture-of-experts: 26B-class quality with only ~4B active parameters
  /// per token, so generation is fast despite the large download.
  public static let gemma4TwentySixBA4BQ4 = ModelDescriptor(
    id: "gemma-4-26b-a4b-it-qat-ud-q4-k-xl",
    displayName: "Gemma 4 26B",
    kind: .languageModel,
    variant: "UD-Q4_K_XL",
    downloadURL: URL(
      string:
        "https://huggingface.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF/resolve/7b92b5b28818151e8669af2e45e88d6086f490dd/gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf?download=true"
    )!,
    expectedSHA256: "a7c5bc715f5ff8e99a3e8901ce7d2b42b402c669bf24f7c5250747633d0f5891",
    expectedBytes: 14_249_047_104,
    fileName: "gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf",
    tier: "Best quality"
  )

  public static let language = [gemma4E4BQ4, gemma4TwelveBQ4, gemma4TwentySixBA4BQ4]
  public static let all = language

  public static func descriptor(id: String) -> ModelDescriptor? {
    all.first { $0.id == id }
  }
}

/// Downloads, verifies, and removes catalog models. Ported from Myna minus
/// the meeting-recording suspension machinery Flow has no use for.
public actor LocalModelManager {
  private static let log = Logger(subsystem: "com.itssrb24.MynaFlow", category: "models")

  private let modelsDirectory: URL
  private let verifier: ModelFileVerifier
  private var states: [String: ModelInstallState] = [:]
  private var activeDownloader: HTTPRangeDownloader?
  private var progressObserver: @Sendable (String, ModelInstallState) -> Void = { _, _ in }

  public init(modelsDirectory: URL, verifier: ModelFileVerifier = ModelFileVerifier()) {
    self.modelsDirectory = modelsDirectory
    self.verifier = verifier
  }

  public func setProgressObserver(
    _ observer: @escaping @Sendable (String, ModelInstallState) -> Void
  ) {
    progressObserver = observer
  }

  public func state(for descriptor: ModelDescriptor) -> ModelInstallState {
    if let state = states[descriptor.id] {
      // Every cached state is a claim about the filesystem, so every cached
      // state gets checked against it.
      let url = modelURL(for: descriptor)
      let exists = FileManager.default.fileExists(atPath: url.path)
      // A file deleted outside the app must lose its badge without a relaunch.
      if state == .installed, !exists {
        states[descriptor.id] = nil
        return .notInstalled
      }
      // A finished download must lose its progress bar the same way.
      if state.isTransient, exists,
        FileSizeReader.totalBytes(at: url) == descriptor.expectedBytes
      {
        states[descriptor.id] = .installed
        return .installed
      }
      return state
    }
    return FileManager.default.fileExists(atPath: modelURL(for: descriptor).path)
      ? .installed : .notInstalled
  }

  public func install(_ descriptor: ModelDescriptor) async throws {
    // `validate` names the precise problem for catalog tests; callers only
    // ever need to know the descriptor was refused.
    do { try descriptor.validate() } catch { throw ModelManagerError.invalidDescriptor }
    try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: modelsDirectory.path)
    setState(descriptor.id, .checkingDisk)
    Self.log.info("install started \(descriptor.id) (\(descriptor.expectedBytes) bytes)")
    let values = try modelsDirectory.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey
    ])
    let available = values.volumeAvailableCapacityForImportantUsage ?? 0
    let required = descriptor.expectedBytes + 1_000_000_000
    guard available >= required else {
      setState(descriptor.id, .failed(message: "Insufficient disk space"))
      Self.log.error("install refused \(descriptor.id): insufficient disk space")
      throw ModelManagerError.insufficientDiskSpace(required: required, available: available)
    }

    do {
      try await installFile(descriptor)
      setState(descriptor.id, .installed)
      Self.log.info("installed \(descriptor.id)")
    } catch {
      setState(descriptor.id, .failed(message: error.localizedDescription))
      Self.log.error("install failed \(descriptor.id): \(error.localizedDescription)")
      throw error
    }
  }

  public func cancelActiveInstall() {
    activeDownloader?.cancelTransfer()
  }

  public func remove(_ descriptor: ModelDescriptor) throws {
    let destination = modelURL(for: descriptor)
    let leftovers = [destination.appendingPathExtension("part")]
    for url in [destination] + leftovers
    where FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    setState(descriptor.id, .notInstalled)
  }

  public func modelURL(for descriptor: ModelDescriptor) -> URL {
    modelsDirectory.appendingPathComponent(descriptor.fileName, isDirectory: false)
  }

  // MARK: - Internals

  private func setState(_ id: String, _ state: ModelInstallState) {
    states[id] = state
    progressObserver(id, state)
  }

  /// Downloads with resume-aware retries. Each attempt re-reads the partial
  /// file's size, so a retry CONTINUES from where the wire went quiet — it
  /// never starts a multi-gigabyte transfer over. Only transport failures
  /// are retried; content failures (checksum) surface immediately.
  private func downloadWithRetry(
    id: String, from url: URL, to partial: URL, expectedTotalBytes: Int64,
    progress: @escaping @Sendable (Int64, Int64) -> Void
  ) async throws {
    var attempt = 0
    while true {
      do {
        let downloader = HTTPRangeDownloader()
        activeDownloader = downloader
        defer { activeDownloader = nil }
        try await downloader.download(
          from: url, to: partial, expectedTotalBytes: expectedTotalBytes, progress: progress)
        return
      } catch {
        attempt += 1
        guard attempt <= DownloadRetryPolicy.maxRetries, DownloadRetryPolicy.isRetryable(error)
        else { throw error }
        Self.log.warning(
          "install retry \(attempt)/\(DownloadRetryPolicy.maxRetries) for \(id): \(error.localizedDescription)"
        )
        try await Task.sleep(for: .seconds(DownloadRetryPolicy.delay(beforeRetry: attempt)))
      }
    }
  }

  private func installFile(_ descriptor: ModelDescriptor) async throws {
    let destination = modelURL(for: descriptor)
    let partial = destination.appendingPathExtension("part")
    let existing =
      (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    setState(
      descriptor.id, .downloading(bytesReceived: existing, totalBytes: descriptor.expectedBytes))
    try await downloadWithRetry(
      id: descriptor.id,
      from: descriptor.downloadURL,
      to: partial,
      expectedTotalBytes: descriptor.expectedBytes,
      progress: { [weak self] received, total in
        // Throttled upstream to ~8 MB steps — safe to hop to the actor per call.
        Task {
          await self?.setState(
            descriptor.id, .downloading(bytesReceived: received, totalBytes: total))
        }
      }
    )
    setState(descriptor.id, .verifying)
    let digest = try verifier.sha256Hex(ofFile: partial)
    guard digest == descriptor.expectedSHA256 else {
      try? FileManager.default.removeItem(at: partial)
      throw ModelManagerError.checksumMismatch
    }
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: partial, to: destination)
  }
}

// @unchecked Sendable: URLSession serializes delegate callbacks and the
// FileHandle is touched only from them; completion is serialized by `lock`.
//
// Streams bytes straight into the `.part` file as they arrive. The previous
// download-task design materialized the file only at completion, so a
// mid-transfer failure discarded every byte and the Range "resume" had
// nothing to resume from — on a flaky link a multi-GB model could never
// finish. Now a retry continues from the byte where the wire went quiet.
private final class HTTPRangeDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = OSAllocatedUnfairLock()
  private var continuation: CheckedContinuation<Void, Error>?
  private var session: URLSession?
  private var handle: FileHandle?
  private var existingBytes: Int64 = 0
  private var receivedBytes: Int64 = 0
  private var expectedTotalBytes: Int64 = 0
  private var progress: (@Sendable (Int64, Int64) -> Void)?
  private var completed = false
  private var lastReportedBytes: Int64 = 0
  /// Stamped on every byte delivery; the watchdog reads it.
  private var lastActivity = Date()

  func cancelTransfer() {
    // The `.part` file keeps its bytes: a later install resumes, not restarts.
    session?.invalidateAndCancel()
    finish(.failure(URLError(.cancelled)))
  }

  func download(
    from url: URL,
    to destination: URL,
    expectedTotalBytes: Int64,
    progress: @escaping @Sendable (Int64, Int64) -> Void
  ) async throws {
    self.progress = progress
    self.expectedTotalBytes = expectedTotalBytes
    if !FileManager.default.fileExists(atPath: destination.path) {
      FileManager.default.createFile(
        atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    existingBytes =
      (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    receivedBytes = existingBytes
    let handle = try FileHandle(forWritingTo: destination)
    try handle.seekToEnd()
    self.handle = handle

    var request = URLRequest(url: url)
    request.timeoutInterval = 120
    if existingBytes > 0 {
      request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
    }

    // Watchdog for a connection that stays open but silently stops
    // delivering; URLSession's own timeouts do not catch that case.
    lock.withLock { lastActivity = Date() }
    let watchdog = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard let self else { return }
        let idle = self.lock.withLock { Date().timeIntervalSince(self.lastActivity) }
        if DownloadRetryPolicy.isStalled(idleSeconds: idle) {
          self.session?.invalidateAndCancel()
          self.finish(.failure(ModelManagerError.downloadStalled))
          return
        }
      }
    }
    defer {
      watchdog.cancel()
      try? handle.close()
      self.handle = nil
    }

    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      let configuration = URLSessionConfiguration.ephemeral
      configuration.waitsForConnectivity = false
      configuration.timeoutIntervalForRequest = 60
      configuration.httpCookieStorage = nil
      configuration.urlCache = nil
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      self.session = session
      session.dataTask(with: request).resume()
    }
    session?.finishTasksAndInvalidate()
    session = nil
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      finish(.failure(URLError(.badServerResponse)))
      return
    }
    switch http.statusCode {
    case 206:
      completionHandler(.allow)
    case 200:
      // Server ignored the Range header: start the file over rather than
      // appending a full body onto a partial one.
      if existingBytes > 0 {
        try? handle?.truncate(atOffset: 0)
        existingBytes = 0
        receivedBytes = 0
      }
      completionHandler(.allow)
    case 416:
      // Requested range not satisfiable: the part file is already complete.
      completionHandler(.cancel)
      finish(.success(()))
    default:
      completionHandler(.cancel)
      finish(.failure(URLError(.badServerResponse)))
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    do {
      try handle?.write(contentsOf: data)
    } catch {
      session.invalidateAndCancel()
      finish(.failure(error))
      return
    }
    receivedBytes += Int64(data.count)
    lock.withLock { lastActivity = Date() }
    // Throttle: forward at most every 8 MB of progress.
    let shouldForward = lock.withLock {
      guard receivedBytes - lastReportedBytes >= 8 * 1_024 * 1_024 || lastReportedBytes == 0 else {
        return false
      }
      lastReportedBytes = receivedBytes
      return true
    }
    if shouldForward {
      progress?(receivedBytes, expectedTotalBytes)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      finish(.failure(error))
    } else {
      try? handle?.synchronize()
      finish(.success(()))
    }
  }

  private func finish(_ result: Result<Void, Error>) {
    lock.withLock {
      guard !completed else { return }
      completed = true
      continuation?.resume(with: result)
      continuation = nil
    }
  }
}
