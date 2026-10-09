import Charts
import CleanerCore
import SwiftUI

/// Uses the existing in-memory samples; opening these views never starts another sampler.
struct ResourceVisuals: View {
  let model: Dashboard
  var compact = false
  @AppStorage("chartWindowMinutes") private var minutes = 5
  private var window: Int { [5, 15, 30].contains(minutes) ? minutes : 5 }
  private var points: [HistoryPoint] {
    let end = model.history.points.last?.date ?? Date()
    return model.history.points.filter { $0.date >= end.addingTimeInterval(-Double(window * 60)) }
  }
  private var pressureColor: Color {
    switch model.snapshot?.system.pressure {
    case 1: .teal
    case 2: .orange
    case 4: .red
    default: .secondary
    }
  }
  var body: some View {
    VStack(spacing: 10) {
      HStack {
        Label(L10n.text("Kaynak görünümü", "Resource overview"), systemImage: "chart.xyaxis.line")
          .font(.caption.weight(.semibold))
        Text(L10n.text("Tüm bilgisayar · bu oturum", "Whole Mac · this session")).font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Picker(L10n.text("Grafik zaman aralığı", "Chart time range"), selection: $minutes) {
          Text(L10n.text("5 dk", "5 min")).tag(5)
          Text(L10n.text("15 dk", "15 min")).tag(15)
          Text(L10n.text("30 dk", "30 min")).tag(30)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 175)
      }
      HStack(spacing: 12) {
        metricCard(title: L10n.text("İşlemci", "Processor"), symbol: "cpu", color: .blue) {
          HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
              Text(Format.cpu(model.snapshot?.cpu)).font(
                .system(size: 28, weight: .semibold, design: .rounded)
              ).monospacedDigit()
              Text(L10n.text("Toplam CPU kapasitesi", "Total CPU capacity")).font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            ZStack {
              Circle().stroke(.blue.opacity(0.12), lineWidth: 6)
              if let cpu = model.snapshot?.cpu {
                Circle().trim(from: 0, to: min(1, max(0, cpu / 100)))
                  .stroke(.blue.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                  .rotationEffect(.degrees(-90))
              }
              Image(systemName: "cpu").foregroundStyle(.blue)
            }.frame(width: 40, height: 40).accessibilityHidden(true)
          }
          MiniHistory(points: points, metric: .cpu, color: .blue)
        }
        metricCard(title: L10n.text("Bellek", "Memory"), symbol: "memorychip", color: pressureColor)
        {
          HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
              Text(pressureName).font(.system(size: 28, weight: .semibold, design: .rounded))
              Text(
                L10n.text(
                  "Bellek baskısı · \(Format.bytes(ProcessInfo.processInfo.physicalMemory)) RAM",
                  "Memory pressure · \(Format.bytes(ProcessInfo.processInfo.physicalMemory)) RAM")
              )
              .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "memorychip").font(.title2).foregroundStyle(pressureColor)
              .accessibilityHidden(true)
          }
          MiniHistory(points: points, metric: .pressure, color: pressureColor)
        }
        if !compact {
          metricCard(
            title: L10n.text("Swap hareketi", "Swap activity"), symbol: "arrow.up.arrow.down",
            color: .purple
          ) {
            VStack(alignment: .leading, spacing: 3) {
              Text(Format.rate(model.snapshot?.paging?[1]))
                .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
              HStack(spacing: 8) {
                Text(L10n.text("↑ Diske giden", "↑ To disk")).foregroundStyle(.purple)
                Text(
                  L10n.text(
                    "↓ \(Format.rate(model.snapshot?.paging?.first)) gelen",
                    "↓ \(Format.rate(model.snapshot?.paging?.first)) in")
                ).foregroundStyle(.blue)
              }.font(.caption).lineLimit(1)
            }
            MiniHistory(points: points, metric: .swap, color: .purple)
          }
        }
      }
    }.padding(.horizontal, 16).padding(.vertical, 12)
  }
  private var pressureName: String {
    switch model.snapshot?.system.pressure {
    case 1: L10n.text("Normal", "Normal")
    case 2: L10n.text("Yüksek", "High")
    case 4: L10n.text("Kritik", "Critical")
    default: L10n.text("Bilinmiyor", "Unknown")
    }
  }
  private func metricCard<Content: View>(
    title: String, symbol: String, color: Color, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(color)
        Spacer()
        if model.paused || model.quality == .stale || model.quality == .failed {
          Text(L10n.text("Son ölçüm", "Last measurement")).font(.caption2).foregroundStyle(
            .secondary)
        }
      }
      content()
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    .overlay(alignment: .top) {
      RoundedRectangle(cornerRadius: 14).fill(
        LinearGradient(
          colors: [color.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
      )
      .allowsHitTesting(false).accessibilityHidden(true)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.22), lineWidth: 1)
        .allowsHitTesting(false)
    }
  }
}

private struct MiniHistory: View {
  enum Metric { case cpu, pressure, swap }
  let points: [HistoryPoint]
  let metric: Metric
  let color: Color
  private var end: Date { points.last?.date ?? Date() }
  private var domain: ClosedRange<Date> {
    min(points.first?.date ?? end, end.addingTimeInterval(-60))...end
  }
  private var maximum: Double {
    switch metric {
    case .cpu: 100
    case .pressure: 4
    case .swap:
      max(
        0.01,
        points.flatMap { [$0.swapIn, $0.swapOut].compactMap { $0 }.map { $0 / 1_048_576 } }.max()
          ?? 0)
    }
  }
  private func value(_ point: HistoryPoint) -> Double? {
    switch metric {
    case .cpu: point.cpu
    case .pressure: point.pressure
    case .swap: point.swapOut.map { $0 / 1_048_576 }
    }
  }
  private var hasData: Bool {
    points.contains { value($0) != nil || (metric == .swap && $0.swapIn != nil) }
  }
  var body: some View {
    VStack(spacing: 3) {
      Chart(points) { point in
        if let value = value(point) {
          if metric == .cpu {
            AreaMark(
              x: .value(L10n.text("Zaman", "Time"), point.date),
              yStart: .value(L10n.text("Taban", "Base"), 0),
              yEnd: .value("CPU %", value),
              series: .value(L10n.text("Kesit", "Segment"), point.segment)
            )
            .foregroundStyle(
              LinearGradient(
                colors: [color.opacity(0.25), color.opacity(0.02)], startPoint: .top,
                endPoint: .bottom))
          }
          LineMark(
            x: .value(L10n.text("Zaman", "Time"), point.date),
            y: .value(L10n.text("Değer", "Value"), value),
            series: .value(L10n.text("Kesit", "Segment"), "main-\(point.segment)")
          )
          .interpolationMethod(metric == .pressure ? .stepEnd : .linear)
          .lineStyle(StrokeStyle(lineWidth: 2)).foregroundStyle(color)
          if point.id == points.last?.id {
            PointMark(
              x: .value(L10n.text("Zaman", "Time"), point.date),
              y: .value(L10n.text("Değer", "Value"), value)
            ).symbolSize(14)
              .foregroundStyle(color)
          }
        }
        if metric == .swap, let incoming = point.swapIn {
          LineMark(
            x: .value(L10n.text("Zaman", "Time"), point.date),
            y: .value(L10n.text("Gelen", "In"), incoming / 1_048_576),
            series: .value(L10n.text("Kesit", "Segment"), "in-\(point.segment)")
          )
          .lineStyle(StrokeStyle(lineWidth: 1.5)).foregroundStyle(.blue)
        }
      }
      .chartXScale(domain: domain).chartYScale(domain: 0...maximum)
      .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
      .chartPlotStyle { plot in plot.padding(.vertical, 3) }
      .frame(height: 38)
      .overlay {
        if !hasData {
          Text(L10n.text("İlk ölçüm bekleniyor", "Waiting for first measurement")).font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityLabel(
        metric == .cpu
          ? L10n.text("CPU geçmişi, yüzde 0 ile 100", "CPU history, 0 to 100 percent")
          : metric == .pressure
            ? L10n.text(
              "Bellek baskısı geçmişi: 1 normal, 2 yüksek, 4 kritik",
              "Memory pressure history: 1 normal, 2 high, 4 critical")
            : L10n.text(
              "Swap geçmişi: mor giden, mavi gelen, MiB saniye",
              "Swap history: purple out, blue in, MiB per second"))
      HStack {
        Text(domain.lowerBound, format: .dateTime.hour().minute().second())
        Spacer()
        Text(
          metric == .pressure
            ? L10n.text("Normal / yüksek / kritik", "Normal / high / critical")
            : metric == .cpu ? "0–100%" : "0–" + Format.rate(maximum * 1_048_576))
        Spacer()
        Text(end, format: .dateTime.hour().minute().second())
      }.font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
    }
  }
}

struct ResourceMeter: View {
  let fraction: Double?
  let color: Color
  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(color.opacity(0.10))
        if let fraction {
          Capsule().fill(color.gradient).frame(width: proxy.size.width * min(1, max(0, fraction)))
        }
      }
    }.frame(height: 3).accessibilityHidden(true)
  }
}
