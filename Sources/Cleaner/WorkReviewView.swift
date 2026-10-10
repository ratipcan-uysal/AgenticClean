import CleanerCore
import SwiftUI

struct WorkReviewView: View {
  let model: Dashboard
  let inspectProject: (String) -> Void
  let inspectProcess: (ProcessRow) -> Void
  let showSimulators: () -> Void
  private var work: [Workload] { Workload.prepare(model.snapshot?.rows ?? [], sort: .memory).filter { $0.kind != .application } }
  private var paths: [String] { Array(Set(work.compactMap(\.projectPath))).sorted() }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(L10n.text("İş sonrası kontrol", "After-work review")).font(.title2.bold())
      Text(L10n.text("Bitirdiğin projeyi seçip açık kalan işleri incele. Bu liste gereksiz süreç listesi değildir; hiçbir şey otomatik durdurulmaz.", "Choose a finished project and review its open work. This is not a list of unnecessary processes; nothing stops automatically."))
      if model.paused || model.quality == .failed || model.quality == .stale {
        Text(L10n.text("Son ölçüm gösteriliyor; işlem öncesinde ana ekrandan güncel tarama yap.", "Showing the last reading; refresh from the main screen before acting.")).foregroundStyle(.orange)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(paths, id: \.self) { path in
            VStack(alignment: .leading, spacing: 5) {
              Text(URL(fileURLWithPath: path).lastPathComponent).font(.headline)
              Text(path).font(.caption).textSelection(.enabled)
              Text(L10n.text("Proje bağlantısı kanıttır; kullanımın bittiğini doğrulamaz.", "A project connection is evidence, not proof that work has finished.")).font(.caption).foregroundStyle(.secondary)
              Button(L10n.text("Projeyi ve kapatma etkisini incele", "Review project and stop impact")) { inspectProject(path) }
            }
            Divider()
          }
          Text(L10n.text("Ortak servisler ve proje bağlantısı olmayan işler", "Shared services and work without a project connection")).font(.headline)
          ForEach(work.filter { $0.projectPath == nil || $0.kind == .localAI }) { item in
            if let row = item.primary {
              HStack {
                VStack(alignment: .leading) {
                  Text(L10n.core(row.title))
                  Text(Format.bytes(row.sample.footprint)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("Ayrı incele", "Inspect separately")) { inspectProcess(row) }
              }
            }
          }
          if work.isEmpty { Text(L10n.text("Bu ölçümde tanınan geliştirme işi bulunamadı.", "No recognized development work in this reading.")) }
        }
      }
      Button(L10n.text("Simülatörleri incele", "Review simulators"), action: showSimulators)
    }.padding(24).frame(width: 680, height: 520)
  }
}
