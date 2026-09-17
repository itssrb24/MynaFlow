import Charts
import MynaFlowCore
import SwiftUI

struct InsightsView: View {
  let coordinator: AppCoordinator
  @State private var period: InsightsPeriod = .week
  @State private var insights: Insights?
  @State private var typingWPMText = ""

  var body: some View {
    Page(title: "Insights", subtitle: "What dictation is doing for you.") {
      HStack {
        Picker("Period", selection: $period) {
          ForEach(InsightsPeriod.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
        Spacer()
        HStack(spacing: Theme.Spacing.sm) {
          Text("Typing speed").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
          TextField("40", text: $typingWPMText)
            .textFieldStyle(.plain)
            .font(Theme.Fonts.mono)
            .foregroundStyle(Theme.Colors.textPrimary)
            .frame(width: 44)
            .inset(padding: Theme.Spacing.xs + 2)
            .onSubmit { commitTypingSpeed() }
          Text("WPM").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
        }
      }

      if let insights {
        HStack(spacing: Theme.Spacing.md) {
          tile("Words", "\(insights.totalWords)")
          tile("Dictations", "\(insights.totalDictations)")
          tile("Time saved", duration(insights.timeSavedSeconds))
          tile("Speaking pace", insights.speakingWPM > 0 ? "\(Int(insights.speakingWPM)) wpm" : "—")
        }

        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
          SectionLabel(text: "Last 14 days · words")
          Chart(insights.dailyWords, id: \.day) { day in
            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Words", day.words))
              .foregroundStyle(Theme.Colors.accent.gradient)
              .cornerRadius(3)
          }
          .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
              AxisValueLabel(format: .dateTime.day(), centered: true)
                .foregroundStyle(Theme.Colors.textTertiary)
            }
          }
          .chartYAxis {
            AxisMarks(position: .leading) { _ in
              AxisGridLine().foregroundStyle(Theme.Colors.hairline)
              AxisValueLabel().foregroundStyle(Theme.Colors.textTertiary)
            }
          }
          .frame(height: 160)
        }
        .raised()

        HStack(alignment: .top, spacing: Theme.Spacing.md) {
          VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionLabel(text: "Top apps")
            if insights.topApps.isEmpty {
              emptyNote
            }
            ForEach(insights.topApps.prefix(5), id: \.bundleID) { app in
              HStack {
                Text(AppNames.display(app.bundleID)).font(Theme.Fonts.body)
                  .foregroundStyle(Theme.Colors.textPrimary)
                Spacer()
                Text("\(app.words) words").font(Theme.Fonts.mono)
                  .foregroundStyle(Theme.Colors.textTertiary)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .raised(padding: Theme.Spacing.md)

          VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionLabel(text: "Engines")
            ForEach(insights.engineSplit, id: \.engine) { share in
              HStack {
                Text((EngineID(rawValue: share.engine) ?? .apple).displayName)
                  .font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textPrimary)
                Spacer()
                Text("\(share.count)").font(Theme.Fonts.mono).foregroundStyle(Theme.Colors.textTertiary)
              }
            }
            if insights.fallbackRate > 0 {
              Text("Fallback rate \(Int(insights.fallbackRate * 100))%")
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.warning)
            }
            Divider().overlay(Theme.Colors.hairline)
            SectionLabel(text: "Latency")
            HStack {
              Text("avg \(insights.averageProcessingMs) ms · p95 \(insights.p95ProcessingMs) ms")
                .font(Theme.Fonts.mono).foregroundStyle(Theme.Colors.textPrimary)
              Spacer()
              Text(insights.p95ProcessingMs <= 800 ? "within budget" : "over 800 ms budget")
                .font(Theme.Fonts.caption)
                .foregroundStyle(insights.p95ProcessingMs <= 800 ? Theme.Colors.success : Theme.Colors.warning)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .raised(padding: Theme.Spacing.md)
        }

        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
          SectionLabel(text: "Polish styles used")
          if insights.styleUsage.isEmpty { emptyNote }
          ForEach(insights.styleUsage, id: \.style) { usage in
            HStack {
              Text(usage.style).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textPrimary)
              Spacer()
              Text("\(usage.count)").font(Theme.Fonts.mono).foregroundStyle(Theme.Colors.textTertiary)
            }
          }
        }
        .raised(padding: Theme.Spacing.md)
      }
    }
    .task {
      typingWPMText = "\(Int(coordinator.typingWPM))"
      await reload()
    }
    .onChange(of: period) { Task { await reload() } }
  }

  private var emptyNote: some View {
    Text("Nothing yet.").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
  }

  private func tile(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
      SectionLabel(text: label)
      Text(value).font(Theme.Fonts.display).foregroundStyle(Theme.Colors.textPrimary)
        .lineLimit(1).minimumScaleFactor(0.6)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .raised(padding: Theme.Spacing.md)
  }

  private func duration(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes) min" }
    return String(format: "%.1f h", seconds / 3_600)
  }

  private func commitTypingSpeed() {
    guard let value = Double(typingWPMText), value > 0 else {
      typingWPMText = "\(Int(coordinator.typingWPM))"
      return
    }
    coordinator.setTypingWPM(value)
    Task { await reload() }
  }

  private func reload() async {
    insights = await coordinator.loadInsights(period: period)
  }
}
