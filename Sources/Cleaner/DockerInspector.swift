import CleanerCore
import SwiftUI

struct DockerInspector: View {
  @Bindable var model: Dashboard
  @Environment(\.setCleanerPanelBusy) private var panelBusy
  @State private var endpoint: DockerLocalEndpoint?
  @State private var containers: [DockerWorkload] = []
  @State private var plan: DockerStopPlan?
  @State private var busy = false
  @State private var message: String?
  private let service = DockerProviderService()
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Docker", systemImage: "shippingbox").font(.title2.bold())
      Text(
        L10n.text(
          "Compose proje ve servis adları Docker’dan okunur. Bir servis başka projeler tarafından da kullanılabilir. Konteynerler VM belleğine ayrıca eklenmez.",
          "Compose project and service names come from Docker. Other projects may also use a service. Container usage is not added on top of VM memory."
        )
      )
      .font(.callout).foregroundStyle(.secondary)
      Button(L10n.text("Çalışan konteynerleri incele", "Inspect running containers")) {
        Task { await inspect() }
      }.disabled(busy)
      if busy { ProgressView().controlSize(.small) }
      if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(containers) { item in
            HStack {
              VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.headline)
                Text(
                  (item.project ?? L10n.text("Proje bilinmiyor", "Unknown project")) + " · "
                    + (item.service ?? "Docker")
                )
                .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button(L10n.text("Durdur…", "Stop…")) {
                guard let endpoint else { return }
                Task {
                  busy = true
                  defer { busy = false }
                  do { plan = try await service.prepareStop(endpoint, containerID: item.id) } catch
                  {
                    message = L10n.text(
                      "Hedef doğrulanamadı; listeyi yenile.",
                      "Target could not be verified; refresh the list.")
                  }
                }
              }.disabled(busy)
            }.padding(12).background(
              .quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
          }
        }
      }.frame(minHeight: 150, maxHeight: 350)
      Text(
        L10n.text(
          "Durdurma verileri silmez. Veritabanı veya önizleme bağlantıları kesilebilir. Zorla kapatmaya geçilmez.",
          "Stopping does not delete data. Database or preview connections may be interrupted. No forced termination follows."
        )
      )
      .font(.caption).foregroundStyle(.secondary)
    }.padding(24).frame(width: 660)
      .alert(
        L10n.text("Konteyneri durdur?", "Stop this container?"),
        isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } }), presenting: plan
      ) { current in
        Button(L10n.text("Vazgeç", "Cancel"), role: .cancel) { plan = nil }
        Button(L10n.text("Durdur", "Stop"), role: .destructive) {
          Task { await stop(current) }
          plan = nil
        }
      } message: { current in
        Text(
          current.container.name + "\n"
            + L10n.text(
              "Bağlı işler kesilebilir. Yalnızca bu konteynere SIGTERM gönderilir. Dosyaları veya volume’ları silmez.",
              "Connected work may be interrupted. Only this container receives SIGTERM. Files and volumes are not deleted."
            ))
      }
  }
  @concurrent private func discover() async throws -> DockerLocalEndpoint {
    try DockerLocalEndpoint.discover()
  }
  private func inspect() async {
    busy = true
    defer { busy = false }
    message = nil
    do {
      let found = try await discover()
      endpoint = found
      containers = try await service.inventory(found)
      if containers.isEmpty {
        message = L10n.text("Çalışan konteyner yok.", "No running containers.")
      }
    } catch {
      containers = []
      message = L10n.text(
        "Docker Desktop’ın yerel bağlantısı okunamadı. Docker’ı başlatmıyoruz; desteklenen kurulum açıkken yeniden deneyebilirsin.",
        "Docker Desktop’s local connection could not be read. Docker is not started automatically; retry with a supported installation running."
      )
    }
  }
  private func stop(_ plan: DockerStopPlan) async {
    busy = true
    panelBusy(true)
    defer {
      busy = false
      panelBusy(false)
    }
    let event = model.record(
      process: nil, name: "Docker · " + plan.container.name, state: .requested)
    do {
      switch try await service.stop(plan) {
      case .stopped:
        model.setEvent(event, state: .closed)
        containers.removeAll { $0.id == plan.container.id }
        message = L10n.text(
          "Konteyner durdu. Verileri silinmedi.", "Container stopped. Its data was not deleted.")
      case .stillRunning:
        model.setEvent(event, state: .stillRunning)
        message = L10n.text(
          "Konteyner hâlâ çalışıyor; zorla kapatma yapılmadı.",
          "Container is still running; it was not forcibly terminated.")
      case .unverified:
        model.setEvent(event, state: .unverified)
        message = L10n.text(
          "İstek gönderilmiş olabilir; sonuç doğrulanamadı. Yeniden durdurmadan önce listeyi incele.",
          "The request may have been sent; the result could not be verified. Inspect the list before retrying."
        )
      }

    } catch {
      let detail = L10n.text(
        "Hedef değişti veya işlem doğrulanamadı; yeniden incele.",
        "Target changed or operation could not be verified; inspect again.")
      model.setEvent(event, state: .failed(detail))
      message = detail
    }
  }
}
