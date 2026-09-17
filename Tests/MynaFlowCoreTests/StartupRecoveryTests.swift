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

  @Test("Sidecar files (-wal, -shm) are moved with the database")
  func sidecars() {
    let database = URL(fileURLWithPath: "/tmp/x/flow.sqlite")
    let names = StartupRecovery.sidecarURLs(for: database).map(\.lastPathComponent)
    #expect(names == ["flow.sqlite-wal", "flow.sqlite-shm"])
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
    #expect(await store.schemaVersion() == 4)
    await store.close()
  }
}
