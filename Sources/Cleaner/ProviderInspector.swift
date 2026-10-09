import CleanerCore
import SwiftUI

/// Provider reads are explicit and scoped to this selected process. No default-port probing.
struct ProviderInspector: View {
  let row: ProcessRow
  @Bindable var model: Dashboard
  @State private var inventories: [ProviderInventory] = []
  @State private var plan: ModelUnloadPlan?
  @State private var busy = false
  @State private var message: String?
  private let service = LocalProviderService()
  private var actionable: Bool {
    model.selection == .process(row.id) && model.selectedPresence == .sameIdentity
      && !model.paused && !model.preparing && model.quality != .stale && model.quality != .failed
      && !model.events.contains { $0.process == row.id && $0.state == .requested }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(L10n.text("Yerel AI modelleri", "Local AI models"), systemImage: "brain").font(
        .headline)
      Text(
        L10n.text(
          "Bellekte yüklü model, etkin istek veya proje sahipliği anlamına gelmez.",
          "A loaded model does not establish active requests or project ownership.")
      )
      .font(.caption).foregroundStyle(.secondary)
      Button(L10n.text("Modelleri incele", "Inspect models")) { Task { await inspect() } }
        .disabled(busy || !actionable)
      if busy { ProgressView().controlSize(.small) }
      if let message { Text(message).font(.caption).textSelection(.enabled) }
      ForEach(inventories, id: \.endpoint) { inventory in
        Text(
          inventory.endpoint.baseURL.absoluteString + " · "
            + inventory.observedAt.formatted(date: .omitted, time: .standard)
        ).font(.caption).foregroundStyle(.secondary)
        if let active = inventory.activeRequests {
          Text(
            L10n.text(
              "Son gözlemde etkin istek: \(active)",
              "Active requests at last observation: \(active)")
          )
          .font(.caption)
        }
        ForEach(inventory.models) { item in
          VStack(alignment: .leading, spacing: 5) {
            Text(item.name).fontWeight(.medium).textSelection(.enabled)
            Text(L10n.text("Bellekte yüklü", "Loaded in memory")).font(.caption)
            if let bytes = item.reportedMemoryBytes {
              Text(
                L10n.text(
                  "Sağlayıcı ölçümü: \(Format.bytes(bytes)) · süreç toplamına eklenmez",
                  "Provider measurement: \(Format.bytes(bytes)) · not added to process totals")
              )
              .font(.caption2).foregroundStyle(.secondary)
            }
            if item.canUnload {
              Button(L10n.text("Bellekten çıkar…", "Unload from memory…")) {
                Task {
                  busy = true
                  defer { busy = false }
                  do {
                    plan = try await service.prepareUnload(inventory.endpoint, modelID: item.id)
                  } catch { message = errorText(error) }
                }
              }.disabled(busy || !actionable)
            }
          }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
      }
    }
    .alert(
      L10n.text("Modeli bellekten çıkar?", "Unload this model?"),
      isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } }), presenting: plan
    ) { current in
      Button(L10n.text("Vazgeç", "Cancel"), role: .cancel) { plan = nil }
      Button(L10n.text("Bellekten çıkar", "Unload"), role: .destructive) {
        Task { await unload(current) }
        plan = nil
      }.disabled(!actionable || busy)
    } message: { current in
      Text(
        current.model.name + "\n"
          + L10n.text(
            "Diğer projeler veya etkin istekler etkilenebilir; etkin kullanımın tamamı doğrulanamıyor. Model dosyası silinmez. Sonraki kullanımda yeniden yükleme gerekebilir.",
            "Other projects or active requests may be affected; all active use cannot be verified. The model file is not deleted. Subsequent use may require reloading."
          ))
    }
  }
  private func inspect() async {
    busy = true
    defer { busy = false }
    message = nil
    inventories = []
    let endpoints: [LocalProviderEndpoint]
    do { endpoints = try await LocalProviderService.endpoints(for: row.sample) } catch {
      message = L10n.text(
        "Dinleyici bilgisi okunamadı; API yokluğu olarak yorumlanamaz.",
        "Listener data could not be read; this does not mean no API exists.")
      return
    }
    guard !endpoints.isEmpty else {
      message = L10n.text(
        "Doğrulanmış yerel API dinleyicisi bulunamadı. API kapalı olabilir veya bu süreç tarafından sunulmuyor olabilir.",
        "No verified local API listener was found. The API may be disabled or hosted by another process."
      )
      return
    }
    for endpoint in endpoints.prefix(4) {
      do { inventories.append(try await service.inventory(endpoint)) } catch {
        message = errorText(error)
      }
    }
    if message == nil && !inventories.isEmpty
      && inventories.allSatisfy({ $0.models.isEmpty && $0.activeRequests == nil })
    {
      message = L10n.text(
        "Bu gözlemde bellekte yüklü model yok.", "No models loaded in memory at this observation.")
    }
  }
  private func unload(_ current: ModelUnloadPlan) async {
    guard actionable else { return }
    busy = true
    defer { busy = false }
    let event = model.record(
      process: row.id,
      name: current.model.name + " · " + L10n.text("Bellekten çıkarma", "Model unload"),
      state: .requested)
    do {
      let result = try await service.unload(current)
      switch result {
      case .unloaded:
        model.setEvent(event, state: .modelUnloaded)
        message = L10n.text(
          "Model artık sağlayıcının bellek listesinde değil. Sunucu açık kalır.",
          "The model is no longer in the provider’s loaded list. The server remains running.")
      case .stillResident:
        model.setEvent(event, state: .modelStillLoaded)
        message = L10n.text(
          "Model hâlâ bellekte; yeniden yüklenmiş de olabilir.",
          "The model remains loaded; it may also have reloaded.")
      case .unverified:
        model.setEvent(event, state: .unverified)
        message = L10n.text(
          "İstek gönderildi; sonuç doğrulanamadı.",
          "Request sent; the result could not be verified.")
      }
      inventories = []
    } catch {
      message = errorText(error)
      model.setEvent(event, state: .failed(message ?? ""))
    }
  }
  private func errorText(_ error: Error) -> String {
    switch error {
    case ProviderError.httpStatus(401), ProviderError.httpStatus(403):
      L10n.text(
        "API kimlik doğrulaması istiyor. Bu sürüm erişim anahtarı kullanmıyor; sağlayıcının kendi arayüzünden yönetebilirsin.",
        "The API requires authentication. This version does not use access keys; manage models in the provider’s app."
      )
    case ProviderError.httpStatus(404), ProviderError.unsupported:
      L10n.text(
        "Bu API veya işlem kurulu sağlayıcı sürümünde desteklenmiyor.",
        "This API or action is not supported by the installed provider version.")
    case ProviderError.identityChanged:
      L10n.text(
        "Süreç veya dinleme portunun kimliği değişti. Güncel işi yeniden seçip incele.",
        "The process or listener identity changed. Select and inspect the current work again.")
    case ProviderError.expiredPreview, ProviderError.modelChanged:
      L10n.text(
        "Onay süresi doldu veya model değişti. Listeyi yeniden incele.",
        "The preview expired or the model changed. Inspect the list again.")
    case ProviderError.invalidResponse, ProviderError.responseTooLarge:
      L10n.text(
        "Sağlayıcı yanıtı doğrulanamadı. Bilinmeyen veri boş liste sayılmadı.",
        "The provider response could not be validated. Unknown data was not treated as an empty list."
      )
    default:
      L10n.text(
        "Sağlayıcıya erişilemedi veya işlem doğrulanamadı. Bağlantıyı kontrol edip yeniden incele.",
        "The provider could not be reached or the operation verified. Check the connection and inspect again."
      )
    }
  }
}
