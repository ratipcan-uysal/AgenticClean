import CleanerCore
import SwiftUI

struct SimulatorsView: View {
  @Bindable var model: Dashboard
  @Environment(\.closeCleanerPanel) private var close
  @State private var storage: Bool
  init(model: Dashboard, storageInitially: Bool = false) {
    self.model = model
    _storage = State(initialValue: storageInitially)
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker(L10n.text("Simülatörler", "Simulators"), selection: $storage) {
          Text(L10n.text("Açık cihazlar", "Running devices")).tag(false)
          Text(L10n.text("Disk alanı", "Disk space")).tag(true)
        }.pickerStyle(.segmented).frame(width: 320)
          .accessibilityIdentifier("simulators.mode")
        Spacer()
        Button(L10n.text("Kapat", "Close")) { close() }.keyboardShortcut(.cancelAction)
      }.padding(16)
      Divider()
      if storage { SimulatorStorageView(model: model.simulatorStorage) }
      else { RunningSimulatorsView(model: model) }
    }.frame(width: 850, height: 590)
  }
}

struct SimulatorStorageView: View {
  @Bindable var model: SimulatorStorage
  @State private var query = ""
  @State private var shutdownOnly = false
  private var visible: [SimulatorDevice] {
    model.devices.filter {
      (!shutdownOnly || $0.canReviewStorage) && (query.isEmpty ||
        ($0.name + " " + runtime($0) + " " + $0.udid).localizedCaseInsensitiveContains(query))
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      HStack {
        TextField(L10n.text("Cihaz, sürüm veya kimlik ara", "Search device, runtime or identity"), text: $query)
          .textFieldStyle(.roundedBorder).accessibilityIdentifier("simstorage.search")
        Toggle(L10n.text("Yalnız kapalı", "Shutdown only"), isOn: $shutdownOnly)
      }
      if let error = model.error {
        Label(L10n.text("Envanter okunamadı. Xcode konumunu kontrol edip yeniden dene.",
                             "Inventory unavailable. Check the selected Xcode and refresh."), systemImage: "exclamationmark.circle")
          .foregroundStyle(AgenticPalette.warning)
        DisclosureGroup(L10n.text("Teknik ayrıntılar", "Technical details")) {
          Text(L10n.core(error)).font(.caption).textSelection(.enabled)
        }
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          if !model.results.isEmpty { results }
          ForEach(visible) { device in deviceRow(device) }
          if visible.isEmpty && !model.loading && model.error == nil {
            Text(L10n.text("Eşleşen cihaz yok", "No matching devices")).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity).padding(30)
          }
        }
      }.frame(maxHeight: .infinity).layoutPriority(1)
      footer
    }.padding(18)
      .task { await model.refresh() }
      .sheet(item: Binding(get: { model.plan }, set: { if $0 == nil { model.dismissReview() } })) { plan in
        confirmation(plan)
      }
  }
  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(L10n.text("Simülatör cihazlarının alanı", "Simulator device storage")).font(.title2.bold())
        Spacer()
        Button(L10n.text("Yenile", "Refresh")) { Task { await model.refresh() } }
          .disabled(model.running || model.loading || model.plan != nil)
          .accessibilityIdentifier("simstorage.refresh")
      }
      if model.loading { ProgressView(L10n.text("Envanter okunuyor…", "Reading inventory…")) }
      else {
        Text(L10n.text("\(model.devices.count) cihaz · ölçülen veri ", "\(model.devices.count) devices · measured data ")
          + (model.date == nil ? "—" : Format.bytes(model.measuredBytes))
          + L10n.text(" · \(model.unknownSizeCount) boyut bilinmiyor", " · \(model.unknownSizeCount) sizes unknown"))
          .font(.callout).accessibilityIdentifier("simstorage.summary")
      }
      if let date = model.date {
        Text(date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
      }
      Text(L10n.text("Boyuta göre sabit sıra · Kapalı olması gereksiz olduğunu göstermez. Başka bir test oturumu cihazı kullanmayı planlıyor olabilir.",
                     "Fixed order by size · Shutdown does not mean unused. Another test session may intend to use a device."))
        .font(.caption).foregroundStyle(.secondary)
    }
  }
  private func deviceRow(_ device: SimulatorDevice) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Toggle(isOn: Binding(get: { model.checked.contains(device.id) },
                           set: { model.select(device, checked: $0) })) {
        Text(device.name).fontWeight(.semibold)
      }.toggleStyle(.checkbox)
        .disabled(!device.canReviewStorage || model.running || model.loading || model.error != nil)
        .accessibilityIdentifier("simstorage.choice.\(device.id)")
      VStack(alignment: .leading, spacing: 4) {
        Text(runtime(device) + " · " + state(device)).font(.caption)
        Text(L10n.text("Son kullanım: ", "Last used: ") + lastUsed(device)).font(.caption).foregroundStyle(.secondary)
        if !device.canReviewStorage {
          Text(L10n.text("Açık veya geçiş durumundaki cihazlar temizlenemez.", "Running or transitioning devices cannot be cleaned."))
            .font(.caption).foregroundStyle(AgenticPalette.warning)
        }
        DisclosureGroup(L10n.text("Teknik kimlik", "Technical identity")) {
          Text(device.udid).font(.caption2).textSelection(.enabled)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      Text(Format.bytes(device.measuredBytes)).monospacedDigit()
    }.padding(12).background(AgenticPalette.surface, in: RoundedRectangle(cornerRadius: 8))
  }
  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.text("Ölçüm cihaz verisi ve bildirilen günlükleri kapsar; ortak iOS runtime alanını içermez. APFS nedeniyle kesin boşalacak alan değildir. Yenile seçimleri temizler.",
                     "Measurements include device data and reported logs, excluding shared iOS runtimes. APFS means this is not guaranteed recoverable space. Refresh clears selection."))
        .font(.caption).foregroundStyle(.secondary)
      if model.running {
        HStack {
          ProgressView().controlSize(.small)
          Text(model.currentDevice ?? L10n.text("Sonuçlar okunuyor…", "Reading results…")).lineLimit(1)
          Spacer()
          Button(L10n.text("Kalanları iptal et", "Cancel remaining")) { model.cancelRemaining() }
            .disabled(model.cancellationRequested).accessibilityIdentifier("simstorage.cancelRemaining")
        }
        Text(L10n.text("Başlatılan cihaz işlemi tamamlanır. Pencereyi kapatmak işlemi durdurmaz.",
                       "The in-flight device operation finishes. Closing this window does not stop it."))
          .font(.caption).foregroundStyle(.secondary)
      } else {
        HStack {
          Text(L10n.text("\(model.selected.count) cihaz seçili", "\(model.selected.count) devices selected"))
            .accessibilityIdentifier("simstorage.selection")
          Spacer()
          Button(L10n.text("İçeriği sıfırla…", "Erase contents…")) { model.review(.erase) }
            .accessibilityIdentifier("simstorage.reviewErase")
          Button(L10n.text("Cihazı sil…", "Delete devices…")) { model.review(.delete) }
            .accessibilityIdentifier("simstorage.reviewDelete")
        }.disabled(model.selected.isEmpty || model.loading || model.error != nil)
      }
    }
  }
  private func confirmation(_ plan: SimulatorStoragePlan) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(plan.action == .delete ? L10n.text("Seçilen cihazları sil?", "Delete selected devices?")
           : L10n.text("Seçilen cihazların içeriğini sıfırla?", "Erase selected devices' contents?"))
        .font(.title2.bold()).accessibilityIdentifier("simstorage.approval")
      Text(plan.action == .delete
           ? L10n.text("Cihazlar, uygulamaları ve verileri kalıcı olarak kaldırılır. Çöp Sepeti’nden geri alınamaz.", "Devices, their apps and data are permanently removed. They cannot be restored from Trash.")
           : L10n.text("Cihaz tanımları kalır; içlerindeki uygulamalar, veriler ve ayarlar kalıcı olarak silinir. Çöp Sepeti’nden geri alınamaz.", "Device definitions remain; their apps, data and settings are permanently erased. They cannot be restored from Trash."))
      Text(L10n.text("\(plan.devices.count) cihaz · ölçülen veri ", "\(plan.devices.count) devices · measured data ")
           + Format.bytes(plan.measuredBytes)
           + L10n.text(" · \(plan.unknownSizeCount) boyut bilinmiyor", " · \(plan.unknownSizeCount) sizes unknown"))
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(plan.devices) { device in
            VStack(alignment: .leading, spacing: 4) {
              Text(device.name).fontWeight(.semibold)
              Text(runtime(device) + " · " + Format.bytes(device.measuredBytes))
              Text(device.udid).font(.caption).textSelection(.enabled)
            }.accessibilityElement(children: .combine)
              .accessibilityIdentifier("simstorage.approved.\(device.id)")
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      Text(L10n.text("Her cihazın kimliği ve kapalı durumu tekrar kontrol edilir. Başka bir oturumun gelecek kullanım niyeti doğrulanamaz. Boyut toplamı kesin alan kazancı değildir.",
                     "Each device's identity and shutdown state are checked again. Another session's future intent cannot be verified. Measured size is not guaranteed recovered space."))
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(L10n.text("Vazgeç", "Cancel")) { model.dismissReview() }
          .keyboardShortcut(.cancelAction).accessibilityIdentifier("simstorage.cancel")
        Spacer()
        Button(plan.action == .delete ? L10n.text("Cihazları kalıcı sil", "Permanently delete devices")
               : L10n.text("İçeriği kalıcı sıfırla", "Permanently erase contents"), role: .destructive) {
          model.confirm(plan)
        }.accessibilityIdentifier("simstorage.confirm")
      }
    }.padding(24).frame(width: 600, height: 470).preferredColorScheme(.dark)
      .background(AgenticPalette.canvas).foregroundStyle(AgenticPalette.text)
  }
  private var results: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.text("Son işlem sonuçları", "Latest action results")).font(.headline)
      ForEach(model.results) { result in
        VStack(alignment: .leading, spacing: 4) {
          Text(result.device.name + " · " + status(result)).font(.callout)
            .accessibilityIdentifier("simstorage.result.\(result.id)")
          if let detail = result.detail {
            DisclosureGroup(L10n.text("Teknik ayrıntılar", "Technical details")) {
              Text(L10n.core(detail)).font(.caption).textSelection(.enabled)
            }
          }
        }
      }
      Divider()
    }.padding(8)
  }
  private func status(_ result: SimulatorStorageResult) -> String {
    switch result.status {
    case .completed: result.action == .delete ? L10n.text("Silindi · envanterde yok", "Deleted · absent from inventory") : L10n.text("İçerik sıfırlandı · cihaz korundu", "Contents erased · device retained")
    case .blocked: L10n.text("Atlandı · cihaz artık kapalı değil", "Skipped · device is no longer shut down")
    case .changed: L10n.text("Atlandı · cihaz bilgileri değişti", "Skipped · device metadata changed")
    case .missing: L10n.text("Atlandı · cihaz artık bulunamıyor", "Skipped · device no longer exists")
    case .unverified: L10n.text("Sonuç doğrulanamadı · yeniden tara", "Outcome unverified · refresh inventory")
    case .cancelled: L10n.text("İşlem başlatılmadı", "Not started")
    }
  }
  private func runtime(_ device: SimulatorDevice) -> String {
    guard let runtime = device.runtime else { return L10n.text("Sürüm bilinmiyor", "Runtime unknown") }
    return runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "").replacingOccurrences(of: "-", with: " ")
  }
  private func state(_ device: SimulatorDevice) -> String {
    if device.isAvailable == false { return L10n.text("Runtime kullanılamıyor", "Runtime unavailable") + " · " + device.state }
    if device.state == "Booted" { return L10n.text("Açık", "Running") }
    if device.state == "Shutdown" { return L10n.text("Kapalı", "Shutdown") }
    return device.state
  }
  private func lastUsed(_ device: SimulatorDevice) -> String {
    guard let raw = device.lastUsedAt else { return L10n.text("Bilinmiyor", "Unknown") }
    let formatter = ISO8601DateFormatter()
    var parsed = formatter.date(from: raw)
    if parsed == nil {
      formatter.formatOptions.insert(.withFractionalSeconds)
      parsed = formatter.date(from: raw)
    }
    guard let date = parsed else { return L10n.text("Bilinmiyor", "Unknown") }
    return date.formatted(date: .abbreviated, time: .shortened)
  }
}
