import Charts
import CleanerCore
import SwiftUI

struct SystemHeader: View {
  @Bindable var model: Dashboard
  var showSystem: () -> Void
  var compact = false
  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 24) {
          if !compact {
            Label(L10n.text("Sistem özeti", "System overview"), systemImage: "waveform.path.ecg")
              .font(.headline)
          } else {
            HStack(spacing: 6) {
              Text("CPU").foregroundStyle(.secondary)
              Text(Format.cpu(model.snapshot?.cpu)).fontWeight(.semibold).monospacedDigit()
            }.help(
              L10n.text("Tüm bilgisayarın toplam CPU kapasitesi", "Total CPU capacity of this Mac"))
            HStack(spacing: 6) {
              Text(L10n.text("Bellek baskısı", "Memory pressure")).foregroundStyle(.secondary)
              Text(pressureTitle).fontWeight(.semibold)
            }
          }
          Spacer()
          if model.paused {
            Text(L10n.text("Ölçüm duraklatıldı", "Monitoring paused")).foregroundStyle(.secondary)
            Button(L10n.text("Devam et", "Resume")) { model.paused = false }
          } else {
            Text(freshness).font(.caption).foregroundStyle(.secondary)
          }
          Button {
            showSystem()
          } label: {
            Label(statusTitle, systemImage: statusIcon)
          }.buttonStyle(.borderless).font(.caption).foregroundStyle(statusColor)
        }
        if let context = model.snapshot?.macContext {
          if context.thermal.isConstrained {
            Label(
              L10n.text(
                "Mac yüksek termal baskı bildiriyor; performans etkilenebilir.",
                "Mac reports elevated thermal pressure; performance may be affected."),
              systemImage: "thermometer.high"
            ).font(.caption).foregroundStyle(.orange)
          }
          if context.lowPowerMode == true {
            Label(
              L10n.text("Düşük Güç Modu açık", "Low Power Mode is on"),
              systemImage: "battery.50percent"
            ).font(.caption).foregroundStyle(.secondary)
          }
        }
        if let error = model.scanError {
          HStack {
            Label(
              L10n.text(
                "Ölçüm alınamadı. Son değerler gösteriliyor.",
                "Measurement failed. Showing previous values."),
              systemImage: "exclamationmark.triangle"
            )
            .help(L10n.core(error))
            Spacer()
            Button(L10n.text("Tekrar dene", "Try again")) { Task { await model.refresh() } }
              .disabled(model.scanning)
          }.font(.caption).foregroundStyle(.red)
        } else if model.quality != .stale && model.quality != .failed,
          model.snapshot?.sustainedCPU == true
            || [2, 4].contains(model.snapshot?.system.pressure ?? 0)
        {
          Text(L10n.core(model.snapshot?.diagnosis ?? "")).font(.caption.weight(.medium))
            .foregroundStyle(
              .orange)
        }
      }.font(.callout).padding(.horizontal, 20).padding(.vertical, 14)
    }
  }
  private var pressureTitle: String {
    switch model.snapshot?.system.pressure {
    case 1: L10n.text("Normal", "Normal")
    case 2: L10n.text("Yüksek", "High")
    case 4: L10n.text("Kritik", "Critical")
    default: L10n.text("Bilinmiyor", "Unknown")
    }
  }
  private var freshness: String {
    guard let value = model.snapshot else {
      return L10n.text("İlk ölçüm bekleniyor", "Waiting for first measurement")
    }
    let seconds = max(0, Int(Date().timeIntervalSince(value.date)))
    return L10n.text("\(seconds) sn önce ölçüldü", "Measured \(seconds) sec ago")
      + (model.quality == .stale ? L10n.text(" · eski veri", " · stale data") : "")
  }
  private var statusTitle: String {
    switch model.quality {
    case .fresh: L10n.text("Ölçüm ayrıntıları", "Measurement details")
    case .partial: L10n.text("Bazı ölçümler eksik", "Some measurements unavailable")
    case .stale: L10n.text("Eski ölçüm", "Stale measurement")
    case .failed: L10n.text("Ölçüm hatası", "Measurement error")
    }
  }
  private var statusIcon: String {
    model.quality == .fresh ? "info.circle" : "exclamationmark.circle"
  }
  private var statusColor: Color {
    switch model.quality {
    case .failed: .red
    case .partial: .orange
    default: .secondary
    }
  }
}
struct MonitoringSettings: View {
  @AppStorage("cleanerLanguage") private var language = "tr"
  @Bindable var model: Dashboard
  @Environment(\.closeCleanerPanel) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(L10n.text("Ayarlar", "Settings")).font(.title2.bold())
      Picker("Language / Dil", selection: $language) {
        Text("Türkçe").tag("tr")
        Text("English").tag("en")
      }
      Picker(L10n.text("Yenileme aralığı", "Refresh interval"), selection: $model.interval) {
        ForEach([5, 15, 30, 60, 300], id: \.self) {
          Text(L10n.text("\($0) saniye", "\($0) seconds")).tag($0)
        }
      }
      Text(
        L10n.text(
          "Pencere kapalıyken ölçüm sürer. Geçmiş yalnızca bu oturumun son 30 dakikasını tutar.",
          "Monitoring continues with the window closed. History keeps only the last 30 minutes of this session."
        )
      )
      .font(.callout).foregroundStyle(.secondary)
      HStack {
        Button(
          model.paused
            ? L10n.text("Ölçüme devam et", "Resume monitoring")
            : L10n.text("Ölçümü duraklat", "Pause monitoring")
        ) { model.paused.toggle() }
        Spacer()
        Button(L10n.text("Bitti", "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }.padding(24).frame(width: 420)
      .environment(\.locale, Locale(identifier: language))
  }
}
struct HistoryView: View {
  let points: [HistoryPoint]
  private var domain: ClosedRange<Date> {
    let end = points.last?.date ?? Date()
    return end.addingTimeInterval(-1800)...end
  }
  var body: some View {
    HStack(spacing: 22) {
      VStack(alignment: .leading, spacing: 4) {
        Text(L10n.text("CPU · son 30 dk", "CPU · last 30 min")).font(.caption.weight(.medium))
        Chart(points) { point in
          if let cpu = point.cpu {
            LineMark(
              x: .value(L10n.text("Zaman", "Time"), point.date), y: .value("CPU %", cpu),
              series: .value(L10n.text("Kesit", "Segment"), point.segment)
            ).foregroundStyle(.orange)
          }
        }.chartYScale(domain: 0...100).chartXAxis {
          AxisMarks(values: .stride(by: .minute, count: 15)) {
            AxisValueLabel(format: .dateTime.hour().minute())
          }
        }
        .chartXScale(domain: domain).frame(height: 64).accessibilityLabel(
          L10n.text(
            "Son 30 dakika CPU, toplam kapasitenin yüzdesi; eksik ölçümler boşluk",
            "Last 30 minutes CPU as a share of total capacity; missing samples leave gaps"))
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(
          L10n.text(
            "Bellek baskısı · N normal / Y yüksek / K kritik",
            "Memory pressure · N normal / H high / C critical")
        ).font(.caption.weight(.medium))
        Chart(points) { point in
          if let pressure = point.pressure {
            LineMark(
              x: .value(L10n.text("Zaman", "Time"), point.date),
              y: .value(L10n.text("Baskı", "Pressure"), pressure),
              series: .value(L10n.text("Kesit", "Segment"), point.segment)
            ).interpolationMethod(.stepEnd).foregroundStyle(.teal)
          }
        }.chartYScale(domain: 0...4).chartYAxis {
          AxisMarks(values: [1, 2, 4]) { axis in
            AxisValueLabel {
              Text(
                axis.as(Int.self) == 4
                  ? L10n.text("K", "C") : axis.as(Int.self) == 2 ? L10n.text("Y", "H") : "N")
            }
          }
        }.chartXAxis {
          AxisMarks(values: .stride(by: .minute, count: 15)) {
            AxisValueLabel(format: .dateTime.hour().minute())
          }
        }
        .chartXScale(domain: domain).frame(height: 64).accessibilityLabel(
          L10n.text(
            "Son 30 dakika macOS bellek baskısı; eksik ölçümler boşluk",
            "Last 30 minutes macOS memory pressure; missing samples leave gaps"))
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(L10n.text("Swap · MiB/sn   ↓ gelen / ↑ giden", "Swap · MiB/sec   ↓ in / ↑ out")).font(
          .caption.weight(.medium))
        Chart(points) { point in
          if let value = point.swapIn {
            LineMark(
              x: .value(L10n.text("Zaman", "Time"), point.date),
              y: .value(L10n.text("MiB/sn", "MiB/s"), value / 1_048_576),
              series: .value(L10n.text("Kesit", "Segment"), "in-\(point.segment)")
            ).foregroundStyle(
              by: .value(L10n.text("Yön", "Direction"), L10n.text("↓ gelen", "↓ in")))
          }
          if let value = point.swapOut {
            LineMark(
              x: .value(L10n.text("Zaman", "Time"), point.date),
              y: .value(L10n.text("MiB/sn", "MiB/s"), value / 1_048_576),
              series: .value(L10n.text("Kesit", "Segment"), "out-\(point.segment)")
            ).foregroundStyle(
              by: .value(L10n.text("Yön", "Direction"), L10n.text("↑ giden", "↑ out")))
          }
        }.chartForegroundStyleScale([
          L10n.text("↓ gelen", "↓ in"): Color.blue, L10n.text("↑ giden", "↑ out"): Color.purple,
        ]).chartLegend(
          .hidden
        )
        .chartXAxis {
          AxisMarks(values: .stride(by: .minute, count: 15)) {
            AxisValueLabel(format: .dateTime.hour().minute())
          }
        }
        .chartXScale(domain: domain).frame(height: 64).accessibilityLabel(
          L10n.text(
            "Son 30 dakika swap, mavi diskten gelen, mor diske giden; MiB saniye",
            "Last 30 minutes swap: blue from disk, purple to disk; MiB per second"))
      }
    }.padding(.top, 8)
  }
}
struct SystemDetails: View {
  let model: Dashboard
  @Environment(\.closeCleanerPanel) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text(L10n.text("Ölçüm ayrıntıları", "Measurement details")).font(.title2.bold())
          if let value = model.snapshot {
            Text(
              L10n.text("Son ölçüm: ", "Last measurement: ")
                + value.date.formatted(.dateTime.hour().minute().second().locale(L10n.locale))
                + " · "
                + (value.interval.map {
                  String(format: "%.1f", locale: L10n.locale, $0)
                    + L10n.text(" sn aralık", " sec interval")
                } ?? L10n.text("Başlangıç örneği", "Baseline sample"))
            )
            .font(.caption).foregroundStyle(.secondary)
          }

          Text(
            model.quality == .stale || model.quality == .failed
              ? L10n.text(
                "Güncel teşhis için ölçüm gerekli", "A current measurement is needed for diagnosis")
              : model.snapshot.map { L10n.core($0.diagnosis) }
                ?? L10n.text("İlk ölçüm bekleniyor", "Waiting for first measurement")
          )
          .font(.headline)
          Text(
            L10n.text(
              "CPU, bellek baskısı ve swap izleniyor. Disk gecikmesi, GPU ve arayüz donmaları ölçülmüyor.",
              "CPU, memory pressure, and swap are monitored. Disk latency, GPU usage, and UI freezes are not measured."
            )
          )
          .font(.caption).foregroundStyle(.secondary)
          Text(
            L10n.text(
              "\(model.snapshot?.unreadableCount ?? 0) süreç okunamadı. Bilinmeyen değerler sıfır sayılmaz; eksik ölçümler toplamlara dahil edilmez.",
              "\(model.snapshot?.unreadableCount ?? 0) processes could not be read. Unknown values are not zero; missing measurements are excluded from totals."
            )
          )
          .font(.caption)
          if let error = model.scanError {
            Text(L10n.core(error)).foregroundStyle(.red).textSelection(.enabled)
          }
          LabeledContent(
            L10n.text("Swap’a giden", "Swap out"), value: Format.rate(model.snapshot?.paging?[1]))
          LabeledContent(
            L10n.text("Swap’tan gelen", "Swap in"),
            value: Format.rate(model.snapshot?.paging?.first))

          Text(
            L10n.text(
              "Fiziksel RAM: \(Format.bytes(ProcessInfo.processInfo.physicalMemory)) · Diskte swap: \(Format.bytes(model.snapshot?.swap))",
              "Physical RAM: \(Format.bytes(ProcessInfo.processInfo.physicalMemory)) · Swap on disk: \(Format.bytes(model.snapshot?.swap))"
            )
          )
          if let snapshot = model.snapshot {
            LabeledContent(
              L10n.text("Bellek baskısı kaynağı", "Memory pressure source"),
              value:
                snapshot.pressureSource == .kernelSnapshot
                ? L10n.text("macOS anlık ölçümü", "macOS snapshot")
                : snapshot.pressureSource == .dispatchEvent
                  ? L10n.text("Son macOS basınç bildirimi", "Last macOS pressure event")
                  : L10n.text("Bilinmiyor", "Unknown"))
            DisclosureGroup(L10n.text("Çekirdek başına CPU", "CPU per logical core")) {
              Text(
                L10n.text(
                  "Tek çekirdek yoğunken toplam CPU düşük görünebilir. Bu görünüm işin neden beklediğini tek başına kanıtlamaz.",
                  "Total CPU can remain low while one core is busy. This alone does not prove why a task is waiting."
                )
              )
              .font(.caption).foregroundStyle(.secondary)
              ForEach(Array(snapshot.perCoreCPU.enumerated()), id: \.offset) { index, cpu in
                LabeledContent(
                  L10n.text("Çekirdek \(index + 1)", "Core \(index + 1)"), value: Format.cpu(cpu))
              }
            }
          }
          ForEach(model.snapshot?.system.memory ?? []) { part in
            VStack(alignment: .leading, spacing: 4) {
              LabeledContent(L10n.core(part.name), value: Format.bytes(part.bytes))
              Text(L10n.core(part.explanation)).font(.caption).foregroundStyle(.secondary)
            }
          }
          Divider()
          Text(
            L10n.text(
              "Footprint, macOS’un sürece yazdığı bellek yüküdür; RSS yalnızca yerleşik kısmıdır. Uygulama toplamları footprint değerlerini toplar; fiziksel RAM toplamıyla bire bir eşleşmez.",
              "Footprint is the memory load macOS attributes to a process; RSS is its resident portion. App totals sum footprints and do not match physical RAM exactly."
            )
          )
          Text(
            L10n.text(
              "Swap hızı iki ölçüm arasındaki sayfa eşdeğeridir; SSD’nin fiziksel aktarım hızı değildir. Birikmiş swap miktarı tek başına mevcut yavaşlamayı göstermez.",
              "Swap rate is a page-equivalent change between measurements, not the physical SSD transfer rate. Accumulated swap alone does not establish a current slowdown."
            )
          )
          Text(
            L10n.text(
              "CPU sürekli yüksek: en az 15 saniye boyunca ardışık ölçümlerde toplam kapasitenin en az %85’i. Duraklama, uyku veya eksik örnek bu diziyi keser.",
              "Sustained high CPU means at least 85% of total capacity across consecutive samples for at least 15 seconds. Pauses, sleep, and missing samples interrupt this sequence."
            )
          )
          Text(
            L10n.text(
              "Grafik yalnızca bu oturumun son 30 dakikasını bellekte tutar. Duraklamalar ve eksik örnekler çizgide boşluktur. Proje bağlantısı sohbet sahipliği değildir.",
              "Charts keep only this session’s last 30 minutes in memory. Pauses and missing samples leave gaps. A project connection does not establish chat ownership."
            )
          )
          Text(BuildInfo.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Spacer()
        Button(L10n.text("Kapat", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }.font(.callout).padding(24).frame(width: 620, height: 540)
  }
}
struct EventStatus: View {
  let event: OperationEvent
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(statusTitle).font(.callout.weight(.medium)).foregroundStyle(color)
      Text(event.date.formatted(.dateTime.hour().minute().second().locale(L10n.locale))).font(
        .caption2
      ).foregroundStyle(
        .secondary)
      if let deviceID = event.simulatorID {
        Text(deviceID).font(.caption2).foregroundStyle(.secondary)
      }
    }.textSelection(.enabled).accessibilityElement(children: .combine)
  }
  private var statusTitle: String {
    switch event.state {
    case .requested: L10n.text("İstek gönderildi", "Request sent")
    case .closed: L10n.text("Kapandı", "Closed")
    case .modelUnloaded: L10n.text("Model bellekten çıkarıldı", "Model unloaded")
    case .modelStillLoaded: L10n.text("Model hâlâ bellekte", "Model still loaded")
    case .stillRunning:
      L10n.text("Hâlâ çalışıyor · 15 saniyede kapanmadı", "Still running after 15 seconds")
    case .unverified: L10n.text("İşlem sonucu doğrulanamadı", "Could not verify result")
    case .failed(let reason):
      L10n.text("İşlem başarısız: ", "Operation failed: ") + L10n.core(reason)
    }
  }
  private var color: Color {
    switch event.state {
    case .failed, .unverified, .stillRunning, .modelStillLoaded: .orange
    case .closed, .modelUnloaded: .teal
    case .requested: .secondary
    }
  }
}
struct OperationsView: View {
  @Bindable var model: Dashboard
  @Environment(\.closeCleanerPanel) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.text("İşlem geçmişi", "Operation history")).font(.title2.bold())
      Text(
        L10n.text(
          "İşlem sonuçları tarama yenilendiğinde silinmez. Kapatılan kayıtlar ve uygulamadan çıkınca tüm geçmiş kaldırılır.",
          "Refreshing does not clear operation results. Dismissed records are removed; quitting the app clears all history."
        )
      ).font(.caption).foregroundStyle(.secondary)
      if model.events.isEmpty && model.projectResults.isEmpty {
        ContentUnavailableView(
          L10n.text("Henüz işlem yok", "No operations yet"), systemImage: "clock")
      } else {
        ScrollView {
          LazyVStack(spacing: 12) {
            ForEach(model.projectResults) { result in
              VStack(alignment: .leading, spacing: 6) {
                Text(result.name).font(.headline)
                Text(result.date.formatted(.dateTime.hour().minute().second().locale(L10n.locale)))
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(
                  L10n.text(
                    "\(result.closed) kapandı · \(result.stillRunning) hâlâ çalışıyor · \(result.unverified) doğrulanamadı · \(result.failed) başarısız",
                    "\(result.closed) closed · \(result.stillRunning) still running · \(result.unverified) unverified · \(result.failed) failed"
                  ))
                Text(
                  L10n.text("Ölçülen bellek: ", "Measured memory: ")
                    + Format.bytes(result.beforeMemory) + " → " + Format.bytes(result.afterMemory))
                Text(
                  result.replacementCount.map { count in
                    L10n.text(
                      "İşlem sonrası aynı konumda \(count) yeni süreç görüldü.",
                      "\(count) new processes at the same location were observed after the action.")
                  }
                    ?? L10n.text(
                      "Yeni süreç kontrolü doğrulanamadı.",
                      "New-process detection could not be verified."))
                Text(
                  L10n.text(
                    "Bellek farkı hızlanma kanıtı değildir; eksik değerler bilinmiyor gösterilir.",
                    "A memory change does not prove a speed improvement; missing values are shown as unknown."
                  )
                )
                .font(.caption).foregroundStyle(.secondary)
              }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(model.events) { event in
              HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                  Text(L10n.eventName(event.name)).fontWeight(.semibold)
                  EventStatus(event: event)
                }
                Spacer()
                Button(L10n.text("Kaydı kapat", "Dismiss record")) { model.dismissEvent(event.id) }
                  .disabled(event.state == .requested)
                  .accessibilityLabel(
                    L10n.text(
                      event.name + " işlem kaydını kapat",
                      "Dismiss operation record: " + L10n.eventName(event.name)
                    ))
              }.padding(10).background(
                .quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
          }
        }.frame(maxHeight: .infinity)
      }
      HStack {
        Spacer()
        Button(L10n.text("Kapat", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }.padding(20).frame(width: 650, height: 430)
  }
}
struct SimulatorsView: View {
  @Bindable var model: Dashboard
  @Environment(\.closeCleanerPanel) private var dismiss
  @State private var target: SimulatorDevice?
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(L10n.text("Açık iOS simülatörleri", "Running iOS simulators")).font(.title2.bold())
        Spacer()
        Button(L10n.text("Yenile", "Refresh")) { Task { await model.refreshSimulators() } }
          .disabled(
            model.scanningDevices)
      }
      if let error = model.simulatorError {
        Text(L10n.core(error)).foregroundStyle(.red).font(.caption).textSelection(.enabled)
      }
      if model.scanningDevices { ProgressView(L10n.text("Cihazlar okunuyor…", "Reading devices…")) }
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(model.devices) { device in
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(device.name)
                Spacer()
                Button(L10n.text("Kapat…", "Shut down…")) { target = device }.disabled(
                  model.pendingDevices.contains(device.id)
                )
                .accessibilityLabel(
                  L10n.text(device.name + " simülatörünü kapat", "Shut down " + device.name))
              }
              Text(device.udid).font(.caption2).foregroundStyle(.secondary)
              if let event = model.events.first(where: {
                $0.simulatorID == device.id
              }) {
                EventStatus(event: event)
              }
            }.padding(10).background(
              .quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }.frame(maxHeight: .infinity).overlay {
        if model.devices.isEmpty && !model.scanningDevices && model.simulatorError == nil {
          Text(L10n.text("Açık cihaz bulunamadı.", "No running devices found.")).foregroundStyle(
            .secondary)
        }
      }
      ForEach(model.events.filter { $0.process == nil }.prefix(3)) { event in
        HStack {
          Text(L10n.eventName(event.name)).font(.caption)
          Spacer()
          EventStatus(event: event)
        }
      }
      Text(
        L10n.text(
          "Yalnızca seçilen cihaza simctl kapatma isteği gönderilir. Yardımcı komut 15 saniyede zaman aşımına uğrar; en geç 20 saniyede sonuç döner.",
          "Only the selected device receives a simctl shutdown request. The helper times out after 15 seconds and returns a result within 20 seconds."
        )
      ).font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button(L10n.text("Kapat", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }.padding(20).frame(width: 650, height: 450)
      .task { await model.refreshSimulators() }
      .alert(
        L10n.text("Simülatörü kapat?", "Shut down this simulator?"),
        isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
        presenting: target
      ) { device in
        Button(L10n.text("Vazgeç", "Cancel"), role: .cancel) { target = nil }
        Button(L10n.text("Cihazı kapat", "Shut down device"), role: .destructive) {
          Task { await model.shutdown(device) }
          target = nil
        }
      } message: { device in
        Text(
          L10n.text(
            "\(device.name) üzerindeki çalışan uygulama ve testler kesilebilir.",
            "Apps and tests running on \(device.name) may be interrupted."))
      }
  }
}
