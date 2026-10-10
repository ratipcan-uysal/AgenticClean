import CleanerCore
import SwiftUI

struct ProjectStopView: View {
  @Bindable var model: Dashboard
  @State private var plan: ProjectStopPlan
  @Environment(\.closeCleanerPanel) private var dismiss
  @Environment(\.setCleanerPanelBusy) private var setPanelBusy
  @State private var running = false
  @State private var refreshing = false
  @State private var submitted = false
  @State private var error: String?

  init(model: Dashboard, plan: ProjectStopPlan) {
    self.model = model
    _plan = State(initialValue: plan)
  }
  private var events: [OperationEvent] { model.events.filter { $0.projectBatchID == plan.id } }
  private var resultSummary: String {
    let closed = events.filter { $0.state == .closed }.count
    let active = events.filter { $0.state == .stillRunning }.count
    let uncertain = events.filter { $0.state == .unverified }.count
    let failed = events.filter { if case .failed = $0.state { true } else { false } }.count
    return L10n.text(
      "\(closed) kapandı · \(active) hâlâ çalışıyor · \(uncertain) doğrulanamadı · \(failed) başarısız",
      "\(closed) closed · \(active) still running · \(uncertain) unverified · \(failed) failed")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(
        submitted
          ? L10n.text("Proje durdurma sonucu", "Project stop results")
          : L10n.text("Projeyi durdur?", "Stop this project?")
      )
      .font(.title2.bold())
      VStack(alignment: .leading, spacing: 5) {
        Text(plan.request.mode == .projects ? plan.name : "\(plan.application) · \(plan.name)")
          .font(.headline)
        Text(plan.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        Text(
          submitted
            ? resultSummary
            : L10n.text(
              "\(plan.targets.count) süreç durdurulacak · \(plan.excludedCount) süreç açık kalacak",
              "\(plan.targets.count) processes to stop · \(plan.excludedCount) excluded")
        )
        .font(.callout.weight(.medium))
      }
      if !submitted {
        Text(
          L10n.text(
            "Listede AI oturumu varsa yanıt üretimi ve devam eden işler kesilir. Sunuculara bağlı önizlemeler kapanabilir. Yalnızca aşağıda onayladığın süreçlere kapatma isteği gönderilir; sonuç 15 saniye kontrol edilir.",
            "An AI session in this list will stop generating responses and running work. Server previews may stop. Only the processes reviewed below receive a stop request; results are checked for 15 seconds."
          )
        )
        .font(.callout)
        if !plan.request.query.isEmpty {
          Text(
            L10n.text(
              "Arama açık: yalnızca bu listede görünen eşleşmeler durdurulacak.",
              "Search is active: only the matching processes shown here will be stopped.")
          )
          .font(.callout).foregroundStyle(.orange)
        }
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(plan.entries) { entry in
            VStack(alignment: .leading, spacing: 4) {
              Text("\(L10n.core(entry.row.title)) · PID \(entry.id.pid)").font(
                .callout.weight(.medium))
              if entry.exclusion == nil {
                Text(L10n.core(entry.row.stopImpact)).font(.caption).foregroundStyle(.secondary)
              }
              if let exclusion = entry.exclusion {
                Label(
                  L10n.text("Açık kalacak: ", "Excluded: ") + L10n.core(exclusion),
                  systemImage: "lock"
                )
                .font(.caption).foregroundStyle(.secondary)
              } else if let event = events.first(where: { $0.process == entry.id }) {
                EventStatus(event: event)
              } else {
                Text(
                  L10n.text("Durdurulacak · ", "Will stop · ")
                    + Format.bytes(entry.row.sample.footprint)
                )
                .font(.caption).foregroundStyle(.secondary)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Divider()
          }
        }.padding(12)
      }.background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
      if let error { Text(error).font(.callout).foregroundStyle(.orange).accessibilityLabel(error) }
      if running || refreshing {
        HStack {
          ProgressView().controlSize(.small)
          Text(
            running
              ? L10n.text("Kapanma sonuçları kontrol ediliyor…", "Checking stop results…")
              : L10n.text("Güncel liste alınıyor…", "Refreshing the list…"))
        }
      } else if submitted {
        if let result = model.projectResults.first(where: { $0.id == plan.id }) {
          VStack(alignment: .leading, spacing: 4) {
            Text(
              L10n.text("Ölçülen bellek: ", "Measured memory: ") + Format.bytes(result.beforeMemory)
                + " → " + Format.bytes(result.afterMemory) + (result.incompleteMemory ? " *" : ""))
            if let count = result.replacementCount {
              Text(
                L10n.text(
                  "İşlem sonrası aynı konumda \(count) yeni süreç görüldü.",
                  "\(count) new processes at the same location were observed after the action."))
            } else {
              Text(
                L10n.text(
                  "İşlem sonrası yeni süreç kontrolü doğrulanamadı.",
                  "New-process detection could not be verified after the action."))
            }
            Text(
              L10n.text(
                "Bu fark hızlanma kanıtı değildir. * Eksik ölçümler toplamda yok.",
                "This change does not prove a speed improvement. * Missing measurements are excluded."
              )
            )
            .foregroundStyle(.secondary)
          }.font(.caption)
        }
        Text(
          L10n.text(
            "Sonuçlar İşlem geçmişi bölümünde saklanır. Kapanan bir süreç yeniden başlayabilir; güncel durumu ana listeden kontrol edebilirsin.",
            "Results remain in operation history. A closed process may restart; check the main list for its current state."
          )
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Button(submitted ? L10n.text("Kapat", "Close") : L10n.text("Vazgeç", "Cancel")) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction).disabled(running || refreshing)
        Spacer()
        if !submitted {
          if model.paused {
            Button(L10n.text("Ölçüme devam et", "Resume monitoring")) { model.paused = false }
          }
          Button(L10n.text("Listeyi yenile", "Refresh list")) { refreshPlan() }
            .disabled(running || refreshing || model.paused)
          TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .trailing, spacing: 4) {
              if !model.canConfirmProjectStop(plan) {
                Text(
                  plan.targets.isEmpty
                    ? L10n.text("Durdurmaya uygun süreç yok.", "No eligible processes.")
                    : model.paused
                      ? L10n.text(
                        "Ölçüm duraklatıldı; devam ettir.", "Monitoring is paused; resume it first."
                      )
                      : L10n.text(
                        "Güncel listeyi yenileyip tekrar incele.",
                        "Refresh and review the current list.")
                )
                .font(.caption).foregroundStyle(.secondary)
              }
              Button(
                L10n.text(
                  "\(plan.targets.count) süreci durdur", "Stop \(plan.targets.count) processes"),
                role: .destructive
              ) {
                submit()
              }.disabled(running || refreshing || !model.canConfirmProjectStop(plan))
            }
          }
        }
      }
    }.padding(24).frame(width: 640, height: 570).onChange(of: running || refreshing) { _, value in
      setPanelBusy(value)
    }
  }
  private func submit() {
    running = true
    error = nil
    Task {
      do {
        try await model.stopProject(plan)
        submitted = true
      } catch {
        self.error = L10n.core(error.localizedDescription)
        // A guard failure has no outcomes. Keep review controls available for recovery.
        submitted = !events.isEmpty
      }
      running = false
    }
  }
  private func refreshPlan() {
    refreshing = true
    error = nil
    Task {
      await model.refresh()
      if let refreshed = model.projectStopPlan(for: plan.groupKey) {
        plan = refreshed
        model.selection = .group(refreshed.groupKey)
      } else {
        error = L10n.text(
          "Proje artık listede yok. Süreçler kapanmış ya da arama değişmiş olabilir.",
          "This project is no longer listed. Its processes may have closed or the search may have changed."
        )
      }
      refreshing = false
    }
  }
}
