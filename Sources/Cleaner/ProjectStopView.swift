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
  @State private var selectedHelpers: Set<ProcessIdentity> = []
  @State private var helperConfirmation: ProjectStopPlan?
  @State private var confirmingHelpers = false

  init(model: Dashboard, plan: ProjectStopPlan) {
    self.model = model
    _plan = State(initialValue: plan)
  }
  private var events: [OperationEvent] { model.events.filter { $0.projectBatchID == plan.id } }
  private var showingResults: Bool { submitted || running }
  private var excludedGroups: [String: [ProjectStopEntry]] {
    Dictionary(
      grouping: plan.entries.filter { $0.exclusion != nil && !$0.requiresSeparateApproval },
      by: { $0.exclusion ?? "" })
  }
  private var excludedCount: Int { excludedGroups.values.reduce(0) { $0 + $1.count } }
  private var resultSummary: String {
    if !running, let result = model.projectResults.first(where: { $0.id == plan.id }) {
      return L10n.text(
        "\(result.closed) kapandı · \(result.stillRunning) hâlâ çalışıyor · \(result.unverified) doğrulanamadı · \(result.failed) başarısız",
        "\(result.closed) closed · \(result.stillRunning) still running · \(result.unverified) unverified · \(result.failed) failed")
    }
    let closed = events.filter { $0.state == .closed }.count
    let active = events.filter { $0.state == .stillRunning }.count
    let uncertain = events.filter { $0.state == .unverified }.count
    let failed = events.filter { if case .failed = $0.state { true } else { false } }.count
    let pending = events.filter { $0.state == .requested }.count
    let waiting = max(0, plan.targets.count - events.count)
    let progress = running ? L10n.text(" · \(pending) kontrol ediliyor · \(waiting) sırada", " · \(pending) checking · \(waiting) queued") : ""
    return L10n.text(
      "\(closed) kapandı · \(active) hâlâ çalışıyor · \(uncertain) doğrulanamadı · \(failed) başarısız",
      "\(closed) closed · \(active) still running · \(uncertain) unverified · \(failed) failed") + progress
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(
        showingResults
          ? (plan.mode == .managedHelpers
            ? L10n.text("Yardımcı süreç durdurma sonucu", "Helper stop results")
            : L10n.text("Proje durdurma sonucu", "Project stop results"))
          : plan.targets.isEmpty
            ? (plan.helperEntries.isEmpty
              ? L10n.text("Bu projede durdurulabilecek iş bulunmuyor", "No tasks in this project can be stopped")
              : L10n.text("Codex yardımcılarını ayrı incele", "Review Codex helpers separately"))
            : L10n.text("Projenin \(plan.targets.count) işini durdur?", "Stop \(plan.targets.count) tasks in this project?")
      )
      .font(.title2.bold())
      VStack(alignment: .leading, spacing: 5) {
        Text(plan.request.mode == .projects ? plan.name : "\(plan.application) · \(plan.name)")
          .font(.headline)
        Text(plan.path).font(.caption).foregroundStyle(AgenticPalette.secondaryText).textSelection(.enabled)
        Text(
          showingResults
            ? resultSummary
            : L10n.text(
              "\(plan.targets.count) proje işi · \(plan.helperEntries.count) yardımcı ayrı onay bekliyor · \(excludedCount) kapsam dışında",
              "\(plan.targets.count) project tasks · \(plan.helperEntries.count) helpers need separate approval · \(excludedCount) excluded")
        )
        .font(.callout.weight(.medium))
        .accessibilityIdentifier(showingResults ? "project.results" : "project.summary")
      }
      if !showingResults && !plan.targets.isEmpty {
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
        LazyVStack(alignment: .leading, spacing: 16) {
          if !showingResults && !plan.helperEntries.isEmpty {
            helperReview
          }
          if excludedCount > 0 {
            VStack(alignment: .leading, spacing: 12) {
              Label(L10n.text("Kapatma isteği gönderilmeyecek", "No stop request will be sent"), systemImage: "lock.shield")
                .font(.headline)
              Text(L10n.text("\(excludedCount) süreç · nedenlere göre gruplandı. Süreçleri görmek için bir grubu aç.", "\(excludedCount) processes · grouped by reason. Expand a group to see its processes."))
                .font(.caption).foregroundStyle(AgenticPalette.secondaryText)
              ForEach(excludedGroups.keys.sorted(), id: \.self) { reason in
                DisclosureGroup {
                  ForEach(excludedGroups[reason] ?? []) { entry in
                    processRow(entry).padding(.vertical, 5)
                  }
                } label: {
                  HStack(alignment: .top, spacing: 10) {
                    Text("\(excludedGroups[reason]?.count ?? 0)")
                      .font(.callout.bold()).monospacedDigit()
                      .padding(.horizontal, 8).padding(.vertical, 4)
                      .background(AgenticPalette.field, in: Capsule())
                    Text(L10n.core(reason)).font(.callout).fixedSize(horizontal: false, vertical: true)
                  }
                }
                Divider()
              }
            }.padding(16).background(AgenticPalette.surface, in: RoundedRectangle(cornerRadius: 10))
          }
          if !plan.targets.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              Label(showingResults ? L10n.text("İşlem sonuçları", "Action results") : L10n.text("Durdurulacak işler", "Tasks to stop"),
                    systemImage: showingResults ? "checklist" : "stop.circle")
                .font(.headline)
              ForEach(plan.entries.filter { $0.exclusion == nil }) { entry in
                processRow(entry)
                Divider()
              }
            }.padding(16).background(AgenticPalette.list, in: RoundedRectangle(cornerRadius: 10))
          }
        }
      }
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
            .foregroundStyle(AgenticPalette.secondaryText)
          }.font(.caption)
        }
        Text(
          L10n.text(
            "Sonuçlar, uygulamadan çıkana kadar Bu oturumdaki işlemler bölümünde görünür. Kapanan bir süreç yeniden başlayabilir; güncel durumu ana listeden kontrol edebilirsin.",
            "Results appear in This session’s operations until you quit the app. A closed process may restart; check the main list for its current state."
          )
        )
        .font(.caption).foregroundStyle(AgenticPalette.secondaryText)
      }
      HStack {
        Button(submitted || (plan.targets.isEmpty && plan.helperEntries.isEmpty) ? L10n.text("Kapat", "Close") : L10n.text("Vazgeç", "Cancel")) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction).disabled(running || refreshing)
        .accessibilityIdentifier("project.dismiss")
        Spacer()
        if !submitted {
          if model.paused {
            Button(L10n.text("Ölçüme devam et", "Resume monitoring")) { model.paused = false }
          }
          Button(L10n.text("Listeyi yenile", "Refresh list")) { refreshPlan() }
            .disabled(running || refreshing || model.paused)
            .accessibilityIdentifier("project.refresh")
          if !plan.targets.isEmpty {
          TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .trailing, spacing: 4) {
              if let reason = model.projectStopBlockReason(plan) {
                Text(L10n.core(reason))
                .font(.caption).foregroundStyle(AgenticPalette.secondaryText)
              }
              Button(
                L10n.text(
                  "\(plan.targets.count) süreci durdur", "Stop \(plan.targets.count) processes"),
                role: .destructive
              ) {
                submit()
              }.disabled(running || refreshing || !model.canConfirmProjectStop(plan))
                .accessibilityIdentifier("project.stop")
            }
          }
          }
        }
      }
    }.padding(24).frame(width: 680, height: 620)
    .alert(
      L10n.text("Seçilen Codex yardımcıları durdurulsun mu?", "Stop the selected Codex helpers?"),
      isPresented: $confirmingHelpers, presenting: helperConfirmation
    ) { confirmed in
      Button(L10n.text("Vazgeç", "Cancel"), role: .cancel) {}
        .accessibilityIdentifier("helpers.cancel")
      Button(
        L10n.text("\(confirmed.targets.count) yardımcıyı durdur", "Stop \(confirmed.targets.count) helpers"),
        role: .destructive
      ) { submit(confirmed) }.accessibilityIdentifier("helpers.confirm")
    } message: { confirmed in
      Text(L10n.text(
        "Hangi Codex sohbetinin kullandığı bilinmiyor. Bağlı araç çağrıları ve devam eden işler kesilebilir; yeniden bağlantı gerekebilir. Yalnızca seçtiğin yardımcılara kapatma isteği gönderilir. Diğer proje işleri bu işleme dahil değildir.",
        "Their Codex chat ownership is unknown. Connected tool calls and ongoing work may be interrupted; reconnection may be needed. Only the selected helpers receive a stop request. Other project tasks are not included."
      ) + "\n\n" + confirmed.path + "\nPID: "
        + confirmed.targets.map { String($0.id.pid) }.joined(separator: ", "))
    }
    .onChange(of: running || refreshing) { _, value in
      setPanelBusy(value)
    }
  }
  private var helperReview: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(L10n.text("Ayrı onay gerekiyor", "Separate approval required"), systemImage: "exclamationmark.shield")
        .font(.headline)
      Text(L10n.text(
        "Codex yardımcı süreçleri · Hangi sohbetin kullandığı bilinmiyor. Bu klasörde çalışmaları, yalnızca bu projeye hizmet ettiklerini göstermez. Durdurmak istediklerini tek tek seç; proje durdurma düğmesi bu yardımcıları kapsamaz.",
        "Codex helper processes · Chat ownership is unknown. Working in this folder does not establish exclusive ownership by this project. Select helpers individually; the project stop button does not include them."
      )).font(.callout).foregroundStyle(AgenticPalette.secondaryText)
      ForEach(plan.helperEntries) { entry in
        Toggle(isOn: Binding(
          get: { selectedHelpers.contains(entry.id) },
          set: { selected in
            if selected { selectedHelpers.insert(entry.id) }
            else { selectedHelpers.remove(entry.id) }
          }
        )) {
          VStack(alignment: .leading, spacing: 5) {
            processRow(entry)
            if let cwd = entry.row.sample.cwd {
              Text(cwd).font(.caption).foregroundStyle(AgenticPalette.secondaryText)
                .textSelection(.enabled)
            }
          }
        }.toggleStyle(.checkbox).disabled(running || refreshing)
          .accessibilityIdentifier("helpers.choice.\(entry.id.pid)")
        Divider()
      }
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        if let reason = helperReviewBlockReason {
          Text(L10n.core(reason)).font(.caption).foregroundStyle(AgenticPalette.secondaryText)
            .accessibilityIdentifier("helpers.disabledReason")
        }
        Button(L10n.text(
          "Seçilen \(selectedHelpers.count) yardımcıyı incele…",
          "Review \(selectedHelpers.count) selected helpers…"
        )) {
          helperConfirmation = plan.selectingHelpers(selectedHelpers)
          confirmingHelpers = helperConfirmation != nil
        }.disabled(running || refreshing || helperReviewBlockReason != nil)
          .accessibilityIdentifier("helpers.review")
      }
    }.padding(16).background(AgenticPalette.surface, in: RoundedRectangle(cornerRadius: 10))
  }
  private var helperReviewBlockReason: String? {
    guard !selectedHelpers.isEmpty else { return "Önce durdurmak istediğin yardımcıyı seç." }
    guard let selectedPlan = plan.selectingHelpers(selectedHelpers) else {
      return "Liste veya seçim değişti. Projeyi yeniden seçip güncel listeyi kontrol et."
    }
    return model.projectStopBlockReason(selectedPlan)
  }
  private func processRow(_ entry: ProjectStopEntry) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.core(entry.row.title)).font(.callout.weight(.semibold))
      Text(WorkIdentityText.summary(entry.row)).font(.caption).foregroundStyle(AgenticPalette.secondaryText)
      Text("PID \(entry.id.pid) · " + Format.bytes(entry.row.sample.footprint))
        .font(.caption).foregroundStyle(AgenticPalette.secondaryText)
      if entry.exclusion == nil {
        if let event = events.first(where: { $0.process == entry.id }) {
          EventStatus(event: event)
        } else if running {
          Text(L10n.text("İstek sırası bekleniyor", "Waiting to send request")).font(.caption)
        } else if showingResults {
          Text(L10n.text(
            "Bu işlemin ayrıntılı kaydı oturum sınırı nedeniyle kaldırıldı; toplam sonuç yukarıdaki özette korunur.",
            "This operation’s detailed record was removed by the session limit; its outcome is retained in the summary above."
          )).font(.caption).foregroundStyle(AgenticPalette.secondaryText)
        }
        if !showingResults {
          Text(L10n.core(entry.row.stopImpact)).font(.caption).foregroundStyle(AgenticPalette.secondaryText)
        } else {
        DisclosureGroup(L10n.text("Etkisi ve ayrıntılar", "Impact and details")) {
          Text(L10n.core(entry.row.stopImpact)).font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.font(.caption).foregroundStyle(AgenticPalette.secondaryText)
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func submit(_ confirmed: ProjectStopPlan? = nil) {
    if let confirmed { plan = confirmed }
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
    selectedHelpers.removeAll()
    helperConfirmation = nil
    Task {
      await model.refresh()
      let refreshed: ProjectStopPlan?
      if case .process(let identity) = plan.originSelection {
        refreshed = model.selectedRow.flatMap { row in
          row.id == identity ? model.helperStopPlan(for: row) : nil
        }
      } else {
        refreshed = model.projectStopPlan(for: plan.groupKey)
      }
      if let refreshed {
        plan = refreshed
        model.selection = refreshed.originSelection ?? .group(refreshed.groupKey)
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
