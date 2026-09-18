import Foundation
import Testing

@testable import MynaFlowCore

@Suite("StartupRecovery")
struct StartupRecoveryTests {
  @Test("Move-aside name keeps the original beside it, stamped and unique")
  func moveAsideName() {
    let database = URL(fileURLWithPath: "/tmp/Myna Flow/flow.sqlite")
    let stamp = Date(timeIntervalSince1970: 1_789_486_200)  // 2026-09-15T15:30:00Z
    let aside = StartupRecovery.moveAsideURL(for: database, at: stamp)
    #expect(aside.deletingLastPathComponent() == database.deletingLastPathComponent())
    #expect(aside.lastPathComponent == "flow.corrupt-20260915-153000.sqlite")
  }

  @Test("Every sidecar moves with the database, including the rollback journal")
  func sidecars() {
    // -journal appears when WAL is unavailable (a network home directory), and
    // it holds the same dictated text as the database itself.
    let database = URL(fileURLWithPath: "/tmp/x/flow.sqlite")
    let names = StartupRecovery.sidecarURLs(for: database).map(\.lastPathComponent)
    #expect(names == ["flow.sqlite-wal", "flow.sqlite-shm", "flow.sqlite-journal"])
  }

  @Test("Recover moves a corrupt database aside and a fresh open succeeds")
  func recoverEndToEnd() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("flow-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = directory.appendingPathComponent("flow.sqlite")
    try Data("this is not a database".utf8).write(to: database)

    await #expect(throws: (any Error).self) { _ = try await FlowStore.open(at: database) }

    let aside = try StartupRecovery.moveAside(database: database, at: Date())
    #expect(FileManager.default.fileExists(atPath: aside.path))
    #expect(!FileManager.default.fileExists(atPath: database.path))
    let store = try await FlowStore.open(at: database)
    #expect(await store.schemaVersion() == 6)
    await store.close()
  }
}

@Suite("Scratch sweep")
struct ScratchSweepTests {
  @Test("Audio stranded by a crash is cleared at launch")
  func clearsStrandedAudio() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flow-scratch-\(UUID().uuidString)", isDirectory: true)
    let paths = ApplicationPaths(root: root)
    try FileManager.default.createDirectory(at: paths.scratch, withIntermediateDirectories: true)
    let stranded = paths.scratch.appendingPathComponent("dictation-abc.wav")
    try Data("not really audio".utf8).write(to: stranded)

    #expect(paths.clearScratch() == 1)
    #expect(!FileManager.default.fileExists(atPath: stranded.path))
    // The directory itself survives, and sweeping again is harmless.
    #expect(paths.clearScratch() == 0)
    #expect(FileManager.default.fileExists(atPath: paths.scratch.path))
  }

  @Test("Sweeping a directory that does not exist yet is a no-op")
  func toleratesMissingDirectory() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flow-none-\(UUID().uuidString)", isDirectory: true)
    #expect(ApplicationPaths(root: root).clearScratch() == 0)
  }
}

@Suite("Corruption classification")
struct CorruptionClassificationTests {
  @Test(
    "Only a genuinely unusable file earns a move-aside",
    arguments: [
      ("database disk image is malformed", true),
      ("file is not a database", true),
      ("file is encrypted or is not a database", true),
      ("database corruption detected", true),
      ("database is locked", false),
      ("disk I/O error", false),
      ("unable to open database file", false),
      ("attempt to write a readonly database", false),
    ])
  func classifies(message: String, isCorrupt: Bool) {
    // Renaming someone's entire history because the disk was briefly full
    // looks exactly like losing it, so only real corruption qualifies.
    #expect(StartupRecovery.isCorruption(FlowStoreError(message: message)) == isCorrupt)
  }

  @Test("A non-store error never triggers recovery")
  func ignoresOtherErrors() {
    #expect(!StartupRecovery.isCorruption(CocoaError(.fileNoSuchFile)))
  }
}
