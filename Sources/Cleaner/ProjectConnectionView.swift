import AppKit
import CleanerCore
import SwiftUI

struct ProjectConnectionView: View {
  let row: ProcessRow
  @Binding var manualPath: String?
  @State private var result: ProjectInvestigation?
  @State private var error: String?
  @State private var busy = false
  @State private var investigation: Task<Void, Never>?
  private var kind: ProjectConnectionKind { .identify(row) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.text("Proje bağlantısı", "Project connection")).font(.headline)
      Text(row.project?.path ?? title).font(.callout).textSelection(.enabled)
      Text(explanation).font(.caption).foregroundStyle(.secondary)
      DisclosureGroup(L10n.text("Bu bağlantıyı neden gösteriyoruz?", "Why is this connection shown?")) {
        Text(row.project.map { L10n.core($0.evidence) } ?? explanation)
        Text(L10n.core(row.ownershipExplanation))
      }.font(.caption)
      if row.sample.isDevelopment || row.sample.agentSession != nil || row.project != nil {
        Button(busy ? L10n.text("Araştırılıyor…", "Investigating…") : L10n.text("Bağlantıyı araştır", "Investigate connection")) {
          investigation?.cancel()
          busy = true
          error = nil
          result = nil
          investigation = Task {
            defer { busy = false }
            do {
              let found = try await ProjectInvestigation.inspect(row.sample)
              guard !Task.isCancelled else { return }
              result = found
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = L10n.core(error.localizedDescription) } }
          }
        }.disabled(busy)
        Text(L10n.text("Yalnızca bu süreç ve üst zinciri incelenir. Komut satırı veya sohbet içeriği kaydedilmez.", "Inspects only this process and its parent chain. Command lines and chat content are not saved."))
          .font(.caption2).foregroundStyle(.secondary)
      }
      if let error { Text(error).font(.caption).foregroundStyle(.orange) }
      if let result {
        VStack(alignment: .leading, spacing: 6) {
          if result.clues.isEmpty {
            Text(L10n.text("Ek proje kanıtı bulunamadı.", "No additional project evidence found."))
          }
          if result.conflicting {
            Text(L10n.text("Farklı klasörlere işaret eden kanıtlar var; kesin eşleştirme yapılmadı.", "Evidence points to different directories; no definitive attribution was made.")).foregroundStyle(.orange)
          }
          ForEach(result.clues) { clue in
            VStack(alignment: .leading, spacing: 2) {
              Text(clue.path).textSelection(.enabled)
              Text(source(clue) + " · PID \(clue.pid)").foregroundStyle(.secondary)
              if !clue.marked { Text(L10n.text("Proje işaretçisi yok; yalnızca klasör kanıtı.", "No project marker; directory evidence only.")).foregroundStyle(.secondary) }
            }
          }
          if result.partial { Text(L10n.text("Bazı kanıtlar okunamadı veya inceleme sınırına ulaşıldı.", "Some evidence was unavailable or the inspection limit was reached.")).foregroundStyle(.orange) }
          Text(L10n.text("Bu bulgular kapatma kapsamını değiştirmez; dosya yolu proje sahipliğini kanıtlamaz.", "These findings do not change stop scope; a path does not prove project ownership.")).foregroundStyle(.secondary)
        }.font(.caption)
      }
      if kind == .unknown || manualPath != nil {
        if let manualPath {
          Text(L10n.text("Senin eşleştirmen", "Your attribution")).font(.caption.bold())
          Text(manualPath).font(.caption).textSelection(.enabled)
          Button(L10n.text("Eşleştirmeyi kaldır", "Remove attribution")) { self.manualPath = nil }
        } else {
          Button(L10n.text("Proje klasörünü ben seçeyim…", "Choose a project folder…")) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.begin { response in
              if response == .OK { manualPath = panel.url?.path }
            }
          }
        }
        Text(L10n.text("Yalnızca bu süreç kimliği ve bu oturum için nottur. Proje toplamlarını ve kapatma yetkisini değiştirmez.", "A note for this process identity and this session only. It does not change project totals or stop permissions.")).font(.caption2).foregroundStyle(.secondary)
      }
    }
    .onDisappear { investigation?.cancel() }
  }
  private func source(_ clue: ProjectClue) -> String {
    switch clue.source {
    case .directory: L10n.text("Doğrudan çalışma klasörü", "Direct working directory")
    case .ancestor: L10n.text("Üst sürecin klasörü · çıkarım", "Parent working directory · inference")
    case .argument: L10n.text("Başlatma argümanında yol · sahiplik kanıtı değil", "Launch argument path · not ownership evidence")
    }
  }
  private var title: String {
    switch kind {
    case .direct, .inherited: L10n.text("Proje klasörü", "Project directory")
    case .application: L10n.text("Uygulama bileşeni", "Application component")
    case .service: L10n.text("Yerel AI servisi", "Local AI service")
    case .system: L10n.text("macOS / geliştirici altyapısı", "macOS / developer infrastructure")
    case .unknown: L10n.text("Proje bağlantısı bulunamadı", "Project connection not found")
    }
  }
  private var explanation: String {
    switch kind {
    case .direct: L10n.text("Bu klasörde çalışıyor; bu bilgi sohbet sahipliğini veya kapatmanın güvenli olduğunu kanıtlamaz.", "Runs in this directory; this does not prove chat ownership or safe termination.")
    case .inherited: L10n.text("Üst sürecin klasöründen çıkarıldı; doğrudan proje kanıtı değildir.", "Inferred from the parent directory; not direct project evidence.")
    case .application: L10n.text("Uygulaması biliniyor. Proje düzeyinde tüketim ayrımı yapılamıyor; bir projeye keyfî dağıtılmıyor.", "Its application is known. Project-level usage cannot be separated and is not arbitrarily assigned.")
    case .service: L10n.text("Servis türü tanındı. Hangi projelerin kullandığı doğrulanmadı; birden fazla işe hizmet verebilir.", "The service type is recognized. Client projects are unverified; it may serve multiple jobs.")
    case .system: L10n.text("Sistem konumundan tanınan bileşen. Bir geliştirme projesine ait olması beklenmez.", "Component identified by its system location. It is not expected to belong to a development project.")
    case .unknown: L10n.text("Çalışma klasörü ve süreç ilişkileri yeterli kanıt sağlamadı. Bu, sürecin gereksiz olduğu anlamına gelmez.", "Working directory and process relationships provided insufficient evidence. This does not mean the process is unnecessary.")
    }
  }
}
