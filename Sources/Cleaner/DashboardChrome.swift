import CleanerCore
import SwiftUI

/// Restrained graphite surfaces, one accent; warm colors are reserved for status.
enum AgenticPalette {
  static let canvas = Color(red: 0.155, green: 0.175, blue: 0.20)
  static let sidebar = Color(red: 0.105, green: 0.125, blue: 0.15)
  static let list = Color(red: 0.18, green: 0.205, blue: 0.235)
  static let surface = Color(red: 0.225, green: 0.255, blue: 0.295)
  static let field = Color(red: 0.26, green: 0.295, blue: 0.34)
  static let border = Color(red: 0.39, green: 0.44, blue: 0.50)
  static let text = Color(red: 0.96, green: 0.97, blue: 0.98)
  static let secondaryText = Color(red: 0.76, green: 0.80, blue: 0.85)
  static let accent = Color(red: 0.32, green: 0.85, blue: 0.78)
  static let secondaryTrace = Color(red: 0.70, green: 0.76, blue: 0.83)
  static let warning = Color(red: 0.98, green: 0.77, blue: 0.44)
  static let critical = Color(red: 0.98, green: 0.57, blue: 0.55)
}

struct DashboardTab: View {
  let title: String
  let symbol: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .font(.system(size: 12, weight: selected ? .semibold : .medium))
        .padding(.horizontal, 11).padding(.vertical, 9)
        .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.8))
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear,
          in: RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .bottom) {
          if selected {
            Capsule().fill(Color.accentColor).frame(width: 18, height: 2).padding(.bottom, 2)
          }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }.buttonStyle(.plain)
      .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}

/// Compact, live summary. Partial data remains available through measurement details.
struct DashboardStatusBar: View {
  @Bindable var model: Dashboard
  var showMetrics = true
  var showSystem: () -> Void
  var showMemory: () -> Void

  private var current: Bool { !model.paused && model.quality != .stale && model.quality != .failed }
  private var pressureColor: Color {
    guard current else { return .secondary }
    switch model.snapshot?.system.pressure {
    case 2: return AgenticPalette.warning
    case 4: return AgenticPalette.critical
    default: return .secondary
    }
  }
  private var pressure: String {
    switch model.snapshot?.system.pressure {
    case 1: L10n.text("Normal", "Normal")
    case 2: L10n.text("Yüksek", "High")
    case 4: L10n.text("Kritik", "Critical")
    default: L10n.text("Bilinmiyor", "Unknown")
    }
  }
  private var freshness: String {
    if model.paused { return L10n.text("Duraklatıldı", "Paused") }
    guard let snapshot = model.snapshot else { return L10n.text("İlk ölçüm bekleniyor", "Waiting for first sample") }
    let seconds = max(0, Int(Date().timeIntervalSince(snapshot.date)))
    if model.quality == .failed { return L10n.text("Ölçüm hatası · son değerler", "Measurement failed · previous values") }
    if model.quality == .stale { return L10n.text("Eski veri · \(seconds) sn önce", "Stale data · \(seconds)s ago") }
    return L10n.text("Canlı · \(seconds) sn önce", "Live · \(seconds)s ago")
  }
  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 14) {
          if showMetrics {
          Button(action: showMemory) {
            HStack(spacing: 7) {
              Image(systemName: "memorychip")
              Text(L10n.text("Bellek baskısı", "Memory pressure"))
              Text(pressure).fontWeight(.semibold)
              Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
            }.foregroundStyle(pressureColor)
          }.buttonStyle(.plain)
            .help(L10n.text("Bellek kullanan işleri göster", "Show work using memory"))
          Divider().frame(height: 14)
          Label(Format.cpu(model.snapshot?.cpu), systemImage: "cpu")
            .monospacedDigit().foregroundStyle(AgenticPalette.secondaryText)
            .accessibilityLabel("CPU " + Format.cpu(model.snapshot?.cpu))
          }
          if current && model.snapshot?.sustainedCPU == true {
            Text(L10n.text("CPU sürekli yüksek", "Sustained high CPU")).foregroundStyle(AgenticPalette.warning)
          }
          Spacer(minLength: 8)
          HStack(spacing: 6) {
            Circle().fill(current && model.snapshot != nil ? Color.accentColor : Color.secondary)
              .frame(width: 5, height: 5).accessibilityHidden(true)
            Text(freshness).monospacedDigit()
          }.foregroundStyle(model.quality == .failed ? AgenticPalette.critical : Color.secondary)
          if model.paused {
            Button(L10n.text("Devam et", "Resume")) { model.paused = false }.buttonStyle(.borderless)
          }
          Button(action: showSystem) { Image(systemName: "info.circle").frame(width: 22, height: 22) }
            .buttonStyle(.borderless).foregroundStyle(AgenticPalette.secondaryText)
            .accessibilityLabel(L10n.text("Ölçüm ayrıntıları", "Measurement details"))
            .help(L10n.text("Ölçüm ayrıntıları", "Measurement details"))
        }
        if let error = model.scanError {
          HStack {
            Label(L10n.text("Ölçüm alınamadı. Son değerler gösteriliyor.", "Measurement failed. Showing previous values."), systemImage: "exclamationmark.triangle")
              .foregroundStyle(AgenticPalette.critical).help(L10n.core(error))
            Spacer()
            Button(L10n.text("Tekrar dene", "Try again")) { Task { await model.refresh() } }.disabled(model.scanning)
          }
        }
        if model.snapshot?.macContext.thermal.isConstrained == true {
          Label(L10n.text("Mac yüksek termal baskı bildiriyor; performans etkilenebilir.", "Mac reports elevated thermal pressure; performance may be affected."), systemImage: "thermometer.high").foregroundStyle(AgenticPalette.warning)
        }
        if model.snapshot?.macContext.lowPowerMode == true {
          Label(L10n.text("Düşük Güç Modu açık", "Low Power Mode is on"), systemImage: "battery.50percent").foregroundStyle(AgenticPalette.secondaryText)
        }
      }.font(.caption).padding(.horizontal, 20).padding(.vertical, 10)
        .background(showMetrics ? Color.primary.opacity(0.025) : Color.clear)
    }
  }
}
