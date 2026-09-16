import MynaFlowCore
import SwiftUI

struct HistoryView: View {
  let coordinator: AppCoordinator
  @State private var searchText = ""
  @State private var appFilter: String?
  @State private var engineFilter: String?
  @State private var records: [DictationRecord] = []
  @State private var apps: [String] = []
  @State private var confirmRange: DeletionRange?

  var body: some View {
    Page(title: "History", subtitle: "Everything you've dictated, kept on this Mac.") {
      controls
      if records.isEmpty {
        Text(searchText.isEmpty && appFilter == nil ? "No dictations yet." : "No matches.")
          .font(Theme.Fonts.body)
          .foregroundStyle(Theme.Colors.textTertiary)
          .frame(maxWidth: .infinity, minHeight: 120)
          .inset()
      } else {
        LazyVStack(spacing: Theme.Spacing.sm) {
          ForEach(records) { record in
            HistoryRow(record: record, coordinator: coordinator, styles: coordinator.styles) {
              await reload()
            }
          }
        }
      }
    }
    .task { await reload() }
    .onChange(of: searchText) { Task { await reload() } }
    .onChange(of: appFilter) { Task { await reload() } }
    .onChange(of: engineFilter) { Task { await reload() } }
    .confirmationDialog(
      "Delete dictations from \(confirmRange?.displayName.lowercased() ?? "")?",
      isPresented: Binding(get: { confirmRange != nil }, set: { if !$0 { confirmRange = nil } }),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        if let range = confirmRange {
          Task {
            await coordinator.deleteHistory(range)
            await reload()
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  private var controls: some View {
    HStack(spacing: Theme.Spacing.sm) {
      HStack(spacing: Theme.Spacing.sm) {
        Image(systemName: "magnifyingglass").foregroundStyle(Theme.Colors.textTertiary)
        TextField("Search", text: $searchText)
          .textFieldStyle(.plain)
          .font(Theme.Fonts.body)
          .foregroundStyle(Theme.Colors.textPrimary)
      }
      .inset(padding: Theme.Spacing.sm + 2)
      .frame(maxWidth: 300)

      Picker("App", selection: $appFilter) {
        Text("All apps").tag(String?.none)
        ForEach(apps, id: \.self) { app in
          Text(AppNames.display(app)).tag(String?.some(app))
        }
      }
      .labelsHidden()
      Picker("Engine", selection: $engineFilter) {
        Text("All engines").tag(String?.none)
        Text("Apple Speech").tag(String?.some("apple"))
        Text("Parakeet").tag(String?.some("parakeet"))
      }
      .labelsHidden()
      Spacer()
      Menu {
        ForEach(DeletionRange.allCases, id: \.self) { range in
          Button(range.displayName, role: range == .allTime ? .destructive : nil) {
            confirmRange = range
          }
        }
      } label: {
        Label("Delete…", systemImage: "trash")
      }
      .menuStyle(.borderlessButton)
      .foregroundStyle(Theme.Colors.textSecondary)
      .fixedSize()
    }
  }

  private func reload() async {
    records = await coordinator.searchHistory(
      HistoryQuery(text: searchText, targetApp: appFilter, engine: engineFilter), limit: 300)
    apps = await coordinator.historyApps()
  }
}

private struct HistoryRow: View {
  let record: DictationRecord
  let coordinator: AppCoordinator
  let styles: [Style]
  let changed: () async -> Void
  @State private var busy = false

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(spacing: Theme.Spacing.sm) {
        Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
          .font(Theme.Fonts.caption)
          .foregroundStyle(Theme.Colors.textTertiary)
        if let app = record.targetApp {
          Text(AppNames.display(app))
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
        }
        EngineBadge(engine: record.engineUsed, fallback: record.fallbackOccurred)
        if let style = record.styleApplied {
          Text(style)
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.accent)
        }
        if record.insertionMethod == .historyOnly {
          Image(systemName: "doc.on.clipboard")
            .font(.system(size: 10))
            .foregroundStyle(Theme.Colors.warning)
            .help("Saved to history and clipboard — no text field was focused")
        }
        Spacer()
        Text("\(record.wordCount)w · \(record.processingMs)ms")
          .font(Theme.Fonts.mono)
          .foregroundStyle(Theme.Colors.textTertiary)
      }
      Text(record.finalText)
        .font(Theme.Fonts.body)
        .foregroundStyle(Theme.Colors.textPrimary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: Theme.Spacing.sm) {
        Button("Copy") { coordinator.copyToClipboard(record.finalText) }
        Button("Re-insert") { Task { await coordinator.reinsert(record) } }
        Menu("Re-polish") {
          ForEach(styles) { style in
            Button(style.name) {
              busy = true
              Task {
                await coordinator.repolish(record, style: style)
                busy = false
                await changed()
              }
            }
          }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!coordinator.polishAvailable)
        if busy { ProgressView().controlSize(.mini) }
        Spacer()
        Button("Delete") {
          Task {
            await coordinator.deleteHistoryEntry(record.id)
            await changed()
          }
        }
        .buttonStyle(NeuButtonStyle(destructive: true))
      }
      .buttonStyle(NeuButtonStyle())
      .font(Theme.Fonts.caption)
    }
    .raised(padding: Theme.Spacing.md)
  }
}

struct EngineBadge: View {
  let engine: String
  let fallback: Bool

  var body: some View {
    HStack(spacing: 3) {
      Text(engine == "parakeet" ? "Parakeet" : "Apple")
      if fallback {
        Image(systemName: "arrow.uturn.down").font(.system(size: 8))
      }
    }
    .font(Theme.Fonts.caption)
    .foregroundStyle(fallback ? Theme.Colors.warning : Theme.Colors.textTertiary)
    .help(fallback ? "Fell back to Apple Speech for this dictation" : "")
  }
}

enum AppNames {
  /// "com.apple.TextEdit" → "TextEdit" when the app is on disk, else the id.
  static func display(_ bundleID: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      return FileManager.default.displayName(atPath: url.path)
        .replacingOccurrences(of: ".app", with: "")
    }
    return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
  }
}
