import Charts
import CleanerCore
import SwiftUI

struct GroupHistoryView: View {
  let model: Dashboard
  @Environment(\.closeCleanerPanel) private var dismiss
  @State private var projects = false
  @State private var selected = ""
  @State private var memory = true
  init(model: Dashboard, initialGroup: ResourceGroup? = nil) {
    self.model = model
    _projects = State(initialValue: initialGroup?.isProject ?? false)
    _selected = State(initialValue: initialGroup?.id ?? "")
  }
  private var choices: [GroupUsage] {
    var found: [String: GroupUsage] = [:]
    for frame in model.groupHistory.frames {
      for usage in projects ? frame.projects : frame.applications { found[usage.id] = usage }
    }
    return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  private var selectedID: String {
    selected.isEmpty ? choices.first?.id ?? "" : selected
  }
  private var samples: [PlotPoint] {
    let selectedGroupID = selectedID
    var segment = 0
    var previousSegment: Int?
    var previousPartial: Bool?
    return model.groupHistory.frames.compactMap { frame in
      let group = (projects ? frame.projects : frame.applications).first {
        $0.id == selectedGroupID
      }
      let value: Double?
      if memory {
        value = group.flatMap {
          $0.memory.map { Double($0) / 1_073_741_824 }
        }
      } else {
        value = group.flatMap {
          $0.cpu.map { $0 / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) }
        }
      }
      if previousSegment != frame.segment { segment += 1 }
      previousSegment = frame.segment
      guard let value else {
        segment += 1
        return nil
      }
      let partial =
        group.map {
          !$0.membershipComplete || (memory ? $0.missingMemoryCount : $0.missingCPUCount) > 0
        } ?? true
      if previousPartial != partial { segment += 1 }
      previousPartial = partial
      return PlotPoint(
        id: frame.id, date: frame.date, segment: segment, value: value, partial: partial)
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(
        L10n.text("Hangi uygulama ne zaman yük oluşturdu?", "Which app used resources, and when?")
      )
      .font(.title2.bold())
      HStack {
        Picker(L10n.text("Gruplama", "Group by"), selection: $projects) {
          Text(L10n.text("Uygulamalar", "Applications")).tag(false)
          Text(L10n.text("Projeler", "Projects")).tag(true)
        }.pickerStyle(.segmented).frame(width: 240)
          .onChange(of: projects) { _, _ in selected = "" }
        Picker(L10n.text("Ölçüm", "Metric"), selection: $memory) {
          Text(L10n.text("Bellek (GiB)", "Memory (GiB)")).tag(true)
          Text(L10n.text("CPU (% kapasite)", "CPU (% capacity)")).tag(false)
        }.pickerStyle(.segmented)
      }
      Picker(
        L10n.text("İncele", "Inspect"),
        selection: Binding(get: { selectedID }, set: { selected = $0 })
      ) {
        if !selected.isEmpty && !choices.contains(where: { $0.id == selected }) {
          Text(selected + L10n.text(" · henüz ölçüm yok", " · no samples yet")).tag(selected)
        }
        ForEach(choices) { usage in
          Text(
            projects
              ? (usage.id == "project:unknown" ? L10n.core(usage.name) : usage.id)
              : L10n.core(usage.name)
          ).tag(usage.id)
        }
      }.disabled(choices.isEmpty)
      if samples.isEmpty {
        ContentUnavailableView(
          L10n.text("Henüz yeterli ölçüm yok", "No measurements yet"),
          systemImage: "chart.xyaxis.line"
        )
        .frame(height: 230)
      } else {
        Chart(samples) { sample in
          LineMark(
            x: .value(L10n.text("Zaman", "Time"), sample.date),
            y: .value(L10n.text("Kullanım", "Usage"), sample.value),
            series: .value(L10n.text("Kesit", "Segment"), sample.segment)
          )
          .foregroundStyle(memory ? AgenticPalette.secondaryTrace : AgenticPalette.accent)
          .lineStyle(StrokeStyle(lineWidth: 2, dash: sample.partial ? [4, 4] : []))
          PointMark(
            x: .value(L10n.text("Zaman", "Time"), sample.date),
            y: .value(L10n.text("Kullanım", "Usage"), sample.value)
          )
          .foregroundStyle(memory ? AgenticPalette.secondaryTrace : AgenticPalette.accent).symbolSize(10)
        }.chartYScale(domain: .automatic(includesZero: true)).frame(height: 230)
      }
      Text(
        L10n.text(
          "Kesikli çizgi: yalnızca ölçülebilen kullanım; toplam daha yüksek olabilir. Boşluk: ölçüm yok.",
          "Dashed line: measured usage only; the total may be higher. Gap: no measurement.")
      )
      .font(.callout).foregroundStyle(.secondary)
      Text(
        L10n.text(
          "Son 30 dakika · ölçümler arasında en az 15 saniye. Her ölçümde CPU ve bellekte ilk 20 uygulama/proje tutulur. Eksik veya tutulmayan değerler çizgiyi keser; sıfır sayılmaz. Yalnızca bu oturumda bellekte saklanır.",
          "Last 30 minutes · at least 15 seconds between samples. Each sample keeps the top 20 apps/projects for CPU and memory. Missing or omitted values break the line; they are not zero. Stored only in memory for this session."
        )
      )
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button(L10n.text("Kapat", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }.padding(24).frame(width: 760)
      .onAppear { chooseDefault() }
      .onChange(of: projects) { _, _ in
        selected = ""
        chooseDefault()
      }
      .onChange(of: choices.isEmpty) { _, empty in if !empty { chooseDefault() } }
  }
  private func chooseDefault() {
    guard selected.isEmpty else { return }
    selected = choices.max { ($0.memory ?? 0) < ($1.memory ?? 0) }?.id ?? ""
  }
  private struct PlotPoint: Identifiable {
    let id: UUID
    let date: Date
    let segment: Int
    let value: Double
    let partial: Bool
  }
}
