import CleanerCore
import SwiftUI

private enum WorkTableColumns {
  static let memory: CGFloat = 100
  static let cpu: CGFloat = 67
  static let age: CGFloat = 57
  static let spacing: CGFloat = 8
}

struct DashboardView: View {
  @Bindable var model: Dashboard
  var languageChanged: () -> Void = {}
  @FocusState private var listFocused: Bool
  @AppStorage("mainSection") private var section = "overview"
  @State private var diskModel = DiskWorkspaceModel()
  @State private var historyGroup: ResourceGroup?
  @State private var expanded = Set<String>()
  @State private var manualProjects: [ProcessIdentity: String] = [:]
  @State private var collapsedSearch = Set<String>()
  @State private var stopTarget: ProcessRow?
  @State private var sheet: DashboardSheet?
  @State private var detailWindow = DetailWindowPresenter()
  @AppStorage("cleanerLanguage") private var language = "tr"

  var body: some View {
    GeometryReader { geometry in
    HStack(spacing: 0) {
      sidebar.frame(width: 180)
      Divider()
      VStack(spacing: 0) {
        workspaceHeader.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
        if section != "disk" {
          ResourceRibbon(model: model, showHistory: { sheet = .history }, compact: section != "overview" || geometry.size.height < 700)
            .padding(.horizontal, 16).padding(.bottom, 10)
          controls.padding(.horizontal, 16).padding(.vertical, 10)
        }
        if section == "projects" {
          Text(L10n.text("Üstteki CPU tüm Mac’i kapsar. Bu liste yalnızca proje bağlantısı bulunan işleri gösterir; sistem ve diğer uygulamalar için Diğer işler’i aç.", "CPU above covers your whole Mac. This list shows work linked to projects; enable Other work for system processes and other apps."))
            .font(.caption).foregroundStyle(AgenticPalette.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
          HStack {
            Text(L10n.text("Sıralama her bölümde uygulanır; alt süreçler başlatan işin altında tutulur.", "Each section is sorted independently; child processes stay under their parent."))
              .font(.caption).foregroundStyle(AgenticPalette.secondaryText)
            Spacer()
            Toggle(L10n.text("Diğer işler (\(model.presentation.projectContextCount))", "Other work (\(model.presentation.projectContextCount))"), isOn: $model.request.showProjectContext)
              .toggleStyle(.checkbox).font(.caption)
          }.padding(.horizontal, 16).padding(.bottom, 10)
        }
        Divider()
        if section != "disk" && hasSelection && geometry.size.width < 1120 {
          selectionInspector.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          HSplitView {
            Group {
              if section == "disk" { diskLanding } else { processList }
            }.frame(minWidth: 490, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if section != "disk" && hasSelection {
              selectionInspector.frame(minWidth: 320, idealWidth: 350, maxWidth: 420,
                maxHeight: .infinity, alignment: .top)
            }
          }.frame(maxHeight: .infinity)
        }
        Divider()
        footer
      }
    }
    .background(AgenticPalette.canvas)
    }
    .preferredColorScheme(.dark)
    .foregroundStyle(AgenticPalette.text)
    .tint(AgenticPalette.accent).accentColor(AgenticPalette.accent)
    .environment(\.locale, Locale(identifier: language))
    .frame(
      minWidth: 920, maxWidth: .infinity, minHeight: 570, maxHeight: .infinity, alignment: .top
    )
    .onAppear {
      // Retire the three mutually exclusive views without restoring a hidden filter.
      model.request.mode = section == "projects" ? .projects : .applications
      model.request.project = "all"
      model.request.filter = section == "ai" ? .localAI : .all
    }
    .onChange(of: section) { _, value in
      model.selection = nil
      model.request.mode = value == "projects" ? .projects : .applications
      model.request.filter = value == "ai" ? .localAI : .all
      model.request.project = "all"
      model.request.query = ""
    }
    .onChange(of: language) { _, _ in
      languageChanged()
      if let sheet { detailWindow.updateTitle(sheet.title) }
    }
    .onChange(of: model.request.query) { _, _ in collapsedSearch.removeAll() }
    .onChange(of: sheet?.id) { _, _ in
      if case .cleanup? = sheet {
        section = "disk"; sheet = nil
      } else if let destination = sheet {
        detailWindow.show(
          title: destination.title,
          content: sheetContent(destination).background(AgenticPalette.canvas).foregroundStyle(AgenticPalette.text).tint(AgenticPalette.accent).environment(\.locale, Locale(identifier: language)).preferredColorScheme(.dark)
        ) {
          sheet = nil
        }
      } else {
        detailWindow.close()
      }
    }
    .onDisappear { detailWindow.close(force: true) }
    .alert(
      L10n.text("Bu süreci durdur?", "Stop this process?"),
      isPresented: Binding(get: { stopTarget != nil }, set: { if !$0 { stopTarget = nil } }),
      presenting: stopTarget
    ) { row in
      Button(L10n.text("Vazgeç", "Cancel"), role: .cancel) { stopTarget = nil }
      Button(L10n.text("Durdur", "Stop"), role: .destructive) {
        Task { await model.stop(row) }
        stopTarget = nil
      }
    } message: { row in
      Text(
        "\(L10n.core(row.title)) · PID \(row.id.pid)\n\(row.applicationName) · \(row.project?.path ?? L10n.text("Proje bilinmiyor", "Unknown project"))\n\(L10n.core(row.stopImpact))\n"
          + L10n.text(
            "Kibar kapatma isteği gönderilecek; sonuç 15 saniye içinde kontrol edilecek.",
            "A graceful stop request will be sent; the result is checked for 15 seconds.")
      )
    }
  }
  @ViewBuilder private func sheetContent(_ destination: DashboardSheet) -> some View {
    switch destination {
    case .cleanup: EmptyView()
    case .docker: DockerInspector(model: model)
    case .groupHistory: GroupHistoryView(model: model, initialGroup: historyGroup)
    case .episodes: PressureEpisodesView(model: model)
    case .workReview:
      WorkReviewView(model: model, inspectProject: { path in
        sheet = nil
        section = "projects"
        model.request.query = ""
        model.request.filter = .all
        model.request.project = path
        model.request.mode = .projects
      }, inspectProcess: { row in
        sheet = nil
        section = "overview"
        model.request.project = "all"
        model.request.filter = .all
        model.request.query = String(row.id.pid)
        model.request.mode = .applications
      }, showSimulators: { sheet = .simulators })
    case .operations: OperationsView(model: model)
    case .simulators: SimulatorsView(model: model)
    case .system: SystemDetails(model: model)
    case .settings: MonitoringSettings(model: model)
    case .project(let plan): ProjectStopView(model: model, plan: plan)
    case .history:
      VStack(alignment: .leading, spacing: 16) {
        Text(L10n.text("Kaynak geçmişi", "Resource history")).font(.title2.bold())
        Text(
          L10n.text(
            "Yalnızca bu oturum · eksik ölçümler ve duraklamalar çizgide boşluk bırakır.",
            "This session only · missing measurements and pauses leave gaps.")
        )
        .font(.caption).foregroundStyle(AgenticPalette.secondaryText)
        ResourceVisuals(model: model, showMemoryConsumers: showMemoryConsumers)
        HStack {
          Spacer()
          Button(L10n.text("Kapat", "Close")) { sheet = nil }.keyboardShortcut(.cancelAction)
        }
      }.padding(24).frame(width: 880)
    }
  }
  private var hasSelection: Bool { model.selectedRow != nil || selectedGroup != nil }
  @ViewBuilder private var selectionInspector: some View {
    if model.selectedRow != nil { inspector }
    else if let group = selectedGroup { groupInspector(group) }
  }
  private var sectionTitle: String {
    switch section {
    case "projects": L10n.text("Projeler", "Projects")
    case "disk": L10n.text("Disk Alanı", "Disk Space")
    case "ai": L10n.text("Yerel AI", "Local AI")
    default: L10n.text("Genel Bakış", "Overview")
    }
  }
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 9) {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .frame(width: 32, height: 32)
          .accessibilityHidden(true)
        Text("AgenticClean").font(.headline)
      }.padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 24)
      sidebarItem(L10n.text("Genel Bakış", "Overview"), icon: "square.grid.2x2", active: section == "overview") { section = "overview" }
        .keyboardShortcut("1", modifiers: .command)
      sidebarItem(L10n.text("Projeler", "Projects"), icon: "folder", active: section == "projects") { section = "projects" }
        .keyboardShortcut("2", modifiers: .command)
      sidebarItem(L10n.text("Disk Alanı", "Disk Space"), icon: "internaldrive", active: section == "disk") { section = "disk" }
        .keyboardShortcut("3", modifiers: .command)
      Text(L10n.text("ARAÇLAR", "TOOLS")).font(.caption2.weight(.semibold)).foregroundStyle(AgenticPalette.secondaryText)
        .padding(.leading, 12).padding(.top, 24).padding(.bottom, 4)
      sidebarItem("Docker", icon: "shippingbox", active: sheet?.id == "docker") { sheet = .docker }
      sidebarItem(L10n.text("Simülatörler", "Simulators"), icon: "iphone", active: sheet?.id == "simulators") { sheet = .simulators }
      sidebarItem(L10n.text("Yerel AI", "Local AI"), icon: "cpu", active: section == "ai") { section = "ai" }
      Spacer()
      sidebarItem(L10n.text("Ayarlar", "Settings"), icon: "gearshape", active: sheet?.id == "settings") { sheet = .settings }
      Text(BuildInfo.label).font(.caption2).foregroundStyle(AgenticPalette.secondaryText).help(BuildInfo.detail)
        .padding(.horizontal, 12).padding(.bottom, 12)
    }.padding(.horizontal, 10)
      .background(AgenticPalette.sidebar)
  }
  private func sidebarItem(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: icon).frame(width: 20)
        Text(title).font(.callout.weight(active ? .semibold : .regular))
        Spacer(minLength: 0)
      }.padding(.horizontal, 12).padding(.vertical, 11)
        .foregroundStyle(active ? Color.white : AgenticPalette.secondaryText)
        .background(active ? AgenticPalette.accent.opacity(0.26) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityAddTraits(active ? [.isSelected] : [])
  }
  private var workspaceHeader: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(sectionTitle).font(.system(size: 25, weight: .bold))
        Text(L10n.text(section == "disk" ? "Projelerinin kapladığı alanı gör, yeniden oluşturulabilir çıktıları incele." : section == "projects" ? "Çalışan işleri, ait oldukları yerden yönet." : "Kaynak kullanımını gör, etkisini inceleyerek yönet.",
          section == "disk" ? "See project disk usage and review reproducible outputs." : section == "projects" ? "Manage running work by the project it belongs to." : "Understand resource use and review the impact of your actions."))
          .font(.caption).foregroundStyle(AgenticPalette.secondaryText)
      }
      Spacer()
      Button {
        if section == "disk" { diskModel.scan(discovered: diskProjects) }
        else { Task { await model.refresh() } }
      } label: {
        ZStack {
          Image(systemName: "arrow.clockwise").opacity((section == "disk" ? diskModel.busy : model.scanning) ? 0 : 1)
          if section == "disk" ? diskModel.busy : model.scanning { ProgressView().controlSize(.small) }
        }.frame(width: 28, height: 28)
      }.buttonStyle(.borderless).disabled(section == "disk" ? diskModel.busy || diskModel.moving : model.scanning).keyboardShortcut("r", modifiers: .command)
        .accessibilityLabel(L10n.text("Şimdi yenile", "Refresh now"))
        .help(L10n.text("Şimdi yenile · ⌘R", "Refresh now · ⌘R"))
      if section != "disk" {
        DashboardStatusBar(model: model, showMetrics: false, showSystem: { sheet = .system }, showMemory: showMemoryConsumers).frame(width: 280)
      }
    }
  }
  private func showMemoryConsumers() {
    sheet = nil
    section = "overview"
    model.request.mode = .applications
    model.request.sort = .memory
    model.request.query = ""
    model.request.filter = .all
    model.request.project = "all"
  }
  private var controls: some View {
    HStack(spacing: 16) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(AgenticPalette.secondaryText)
        TextField(
          "", text: $model.request.query,
          prompt: Text(L10n.text("Uygulama, proje veya süreç ara", "Search apps, projects or processes"))
            .foregroundStyle(AgenticPalette.secondaryText)
        )
        .textFieldStyle(.plain).accessibilityLabel(L10n.text("Süreç ara", "Search processes"))
        if !model.request.query.isEmpty {
          Button {
            model.request.query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).accessibilityLabel(L10n.text("Aramayı temizle", "Clear search"))
        }
      }.padding(8).background(AgenticPalette.field, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AgenticPalette.border.opacity(0.7)))
        .frame(maxWidth: .infinity)
      VStack(alignment: .trailing, spacing: 4) {
        Picker(L10n.text("Sıralama", "Sort by"), selection: $model.request.sort) {
          Text(L10n.text("Bellek", "Memory")).tag(SortOrder.memory)
          Text("CPU").tag(SortOrder.cpu)
          Text(L10n.text("Süre", "Age")).tag(SortOrder.age)
        }.pickerStyle(.segmented).frame(width: 230)
        Text(L10n.text("Son sıralama", "Last ranking"))
          .font(.caption2).foregroundStyle(AgenticPalette.secondaryText)
      }
    }
  }
  private var footer: some View {
    HStack(spacing: 16) {
      Text(
        section == "disk" ? L10n.text("\(diskModel.results.count) proje ölçümü · istek üzerine tarama", "\(diskModel.results.count) project measurements · scan on request") : "\(model.presentation.rows.count) "
          + (model.request.query.isEmpty
            ? L10n.text("süreç izleniyor", "processes monitored")
            : L10n.text("eşleşen süreç", "matching processes"))
      )
      .foregroundStyle(AgenticPalette.secondaryText)
      Spacer()
      Button(
        L10n.text("Sistem geçmişi", "System history"), systemImage: "chart.xyaxis.line"
      ) {
        sheet = .history
      }.buttonStyle(.borderless)
      Menu {
        Button(L10n.text("İş sonrası kontrol", "After-work review")) { sheet = .workReview }
        Button(L10n.text("Yavaşlama anlarını incele", "Review pressure periods")) { sheet = .episodes }
        Divider()
        Button(L10n.text("Uygulama / proje geçmişi", "App / project history")) {
          historyGroup = nil
          sheet = .groupHistory
        }
        Button(
          L10n.text(
            "Bu oturumdaki işlemler (\(model.events.count))", "This session’s operations (\(model.events.count))")
        ) { sheet = .operations }.accessibilityIdentifier("nav.operations")
        Button(L10n.text("Simülatörler", "Simulators")) { sheet = .simulators }
        Divider()
        Button(L10n.text("Ölçüm ayrıntıları", "Measurement details")) { sheet = .system }
        Button(L10n.text("Şimdi tara", "Scan now")) {
          if section == "disk" { diskModel.scan(discovered: diskProjects) }
          else { Task { await model.refresh() } }
        }.disabled(section == "disk" ? diskModel.busy || diskModel.moving : model.scanning)
      } label: {
        Text(
          L10n.text("Diğer işlemler", "More")
            + (model.events.isEmpty ? "" : " (\(model.events.count))"))
      }.fixedSize()
      Text(BuildInfo.label).foregroundStyle(.tertiary).help(BuildInfo.detail)
    }.font(.caption).padding(12)
  }
  private var hiddenProjectContext: Bool { section == "projects" && !model.request.showProjectContext && model.presentation.projectContextCount > 0 }
  private var listStatus: String {
    if model.paused { return L10n.text("Ölçüm duraklatıldı · Sıra sabit", "Measurements paused · Fixed order") }
    if model.scanError != nil { return L10n.text("Tarama başarısız · Sıra sabit", "Scan failed · Fixed order") }
    if model.quality == .stale { return L10n.text("Ölçüm güncel değil · Sıra sabit", "Measurements stale · Fixed order") }
    return L10n.text("Ölçümler canlı · Sıra sabit", "Live measurements · Fixed order")
  }
  private var listOrderControls: some View {
    HStack(spacing: 10) {
      Text(listStatus)
        .font(.caption).foregroundStyle(AgenticPalette.secondaryText)
        .accessibilityIdentifier("list.stableStatus")
      Spacer(minLength: 4)
      if model.list.pendingCount > 0 {
        Text(L10n.text("\(model.list.pendingCount) yeni iş", "\(model.list.pendingCount) new tasks"))
          .font(.caption.weight(.medium))
          .accessibilityIdentifier("list.pending")
      }
      Button(L10n.text("Yeniden sırala", "Re-sort")) {
        Task { await model.resortList() }
      }
      .accessibilityIdentifier("list.resort")
      .disabled(model.snapshot == nil || model.preparing)
      .help(L10n.text(
        "Yeni işleri ekle, son taramada olmayanları kaldır ve güncel değerlere göre sırala.",
        "Add new tasks, remove tasks missing from the latest scan and rank by current values."))
    }
    .padding(.horizontal, 16).padding(.vertical, 8).background(AgenticPalette.surface)
  }
  private var processList: some View {
    ScrollViewReader { proxy in
      VStack(spacing: 0) {
        listOrderControls
        HStack(spacing: WorkTableColumns.spacing) {
          Text(L10n.text("İş / proje", "Work / project")).frame(
            maxWidth: .infinity, alignment: .leading)
          Text(L10n.text("Bellek", "Memory") + (model.request.sort == .memory ? " ↓" : "")).frame(width: WorkTableColumns.memory, alignment: .trailing)
          Text("CPU" + (model.request.sort == .cpu ? " ↓" : "")).frame(width: WorkTableColumns.cpu, alignment: .trailing)
          Text(L10n.text("Süre", "Age") + (model.request.sort == .age ? " ↓" : "")).frame(width: WorkTableColumns.age, alignment: .trailing)
        }.font(.caption.weight(.medium)).foregroundStyle(AgenticPalette.secondaryText)
          .padding(.horizontal, 16).padding(.vertical, 12).background(AgenticPalette.surface)
        if model.list.presentation.rows.isEmpty && departedSelection == nil {
          VStack(spacing: 12) {
            ContentUnavailableView(
              model.scanning
                ? L10n.text("Ölçüm alınıyor", "Taking measurements")
                : L10n.text(hiddenProjectContext ? "Proje dışı eşleşmeler var" : section == "ai" && model.request.query.isEmpty ? "Yerel AI servisi bulunamadı" : "Sonuç bulunamadı", hiddenProjectContext ? "Matches exist outside projects" : section == "ai" && model.request.query.isEmpty ? "No local AI service detected" : "No results"),
              systemImage: "magnifyingglass",
              description: model.scanning ? nil : Text(
                hiddenProjectContext
                  ? L10n.text("\(model.presentation.projectContextCount) süreç eşleşiyor, ancak proje bağlantısı yok. Uygulama bileşeni olması bir hata değildir.", "\(model.presentation.projectContextCount) processes match, but have no project attribution. Being an application component is not an error.")
                  : model.request.query.isEmpty
                  ? L10n.text(
                    section == "projects" ? "Proje bağlantılı eşleşme yok. Diğer eşleşmeler için üstteki proje dışı süreçler seçeneğini aç."
                      : section == "ai" ? "Ollama, LM Studio veya llama-server çalıştığında burada görünür. Diğer işleri Genel Bakış’ta görebilirsin." : "Henüz gösterilecek çalışan iş yok. Yeniden tarayabilirsin.",
                    section == "projects" ? "No project-linked matches. Enable other processes above to inspect other matches."
                      : section == "ai" ? "Ollama, LM Studio or llama-server will appear here when detected. Find other work in Overview." : "No running work to show yet. Try scanning again.")
                  : L10n.text(
                    "“\(model.request.query)” aramasıyla eşleşen süreç bulunamadı. Tüm süreçleri görmek için aramayı temizle.",
                    "No processes match “\(model.request.query)”. Clear the search to see all processes.")
              ))
            if section == "ai" && model.request.query.isEmpty {
              Button(L10n.text("Genel Bakış’a git", "Go to Overview")) { section = "overview" }.buttonStyle(.borderedProminent)
            }
            if hiddenProjectContext {
              Button(L10n.text("Diğer eşleşmeleri göster", "Show other matches")) { model.request.showProjectContext = true }
            }
            if !model.request.query.isEmpty {
              Button(L10n.text("Aramayı temizle", "Clear search")) { model.request.query = "" }
            } else {
              Button(L10n.text("Yeniden tara", "Scan again")) { Task { await model.refresh() } }
                .disabled(model.scanning)
            }
          }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(AgenticPalette.list)
        } else {
          List(selection: $model.selection) {
            // Keep the initial viewport anchored to a stable row as live rankings change.
            // Once scrolled away, List can retain the user's visible process instead.
            Text(
              L10n.text(
                "Sabit sıra · ayrıntı ve işlemler için bir iş seç",
                "Fixed order · select work to inspect details and actions")
            )
            .font(.caption).foregroundStyle(AgenticPalette.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
            .id("cleaner-consumers-top")
            if let row = departedSelection {
              VStack(alignment: .leading, spacing: 4) {
                Text(L10n.core(row.title)).fontWeight(.medium)
                Text(L10n.text("Son seçilen · ", "Last selected · ") + presenceText).font(.caption)
                  .foregroundStyle(AgenticPalette.secondaryText)
              }.tag(Selection.process(row.id)).accessibilityElement(children: .combine)
            }
            if section == "projects" {
              ForEach(model.list.presentation.groups.filter(\.isProject)) { project in
                branchCell(project, key: project.id, depth: 0, subtitle: projectSubtitle(project))
                  .tag(Selection.group(project.id))
                if isExpanded(project.id) {
                  ForEach(model.list.tree(for: project)) { item in
                    processCell(item.row, depth: item.depth).tag(Selection.process(item.id))
                  }
                }
              }
              if model.request.showProjectContext {
                ForEach([1, 4, 2, 3], id: \.self) { category in
                  let groups = model.list.presentation.groups.filter { !$0.isProject && $0.projectSection == category }
                  if !groups.isEmpty {
                    Section(projectSectionTitle(category)) {
                      ForEach(groups) { group in
                        branchCell(group, key: group.id, depth: 0, subtitle: projectSubtitle(group))
                          .tag(Selection.group(group.id))
                        if isExpanded(group.id) {
                          ForEach(group.rows) { row in
                            processCell(row).tag(Selection.process(row.id))
                          }
                        }
                      }
                    }
                  }
                }
              }
            } else {
              ForEach(model.list.presentation.workloads) { work in
                if let row = work.primary {
                  workloadCell(work, row: row).tag(Selection.process(row.id))
                } else {
                  branchCell(
                    work.group, key: work.id, depth: 0,
                    subtitle: L10n.text(
                      "\(work.group.rows.count) süreç · uygulama",
                      "\(work.group.rows.count) processes · application")
                  )
                  .tag(Selection.group(work.id))
                  if isExpanded(work.id) {
                    ForEach(work.group.rows) { row in
                      processCell(row).tag(Selection.process(row.id))
                    }
                  }
                }
              }
            }
          }.id(section).listStyle(.inset).scrollContentBackground(.hidden).background(AgenticPalette.list).accessibilityLabel(
            L10n.text("Çalışan işler ve projeler", "Running work and projects")
          )
          .focused($listFocused)
          .onKeyPress(.rightArrow) { navigateBranch(expand: true) }
          .onKeyPress(.leftArrow) { navigateBranch(expand: false) }
          .onKeyPress(.space) { toggleSelectedBranch() }
          .onKeyPress(.return) { toggleSelectedBranch() }

        }
        HStack(spacing: 12) {
          Text(
            L10n.text(
              "CPU: tüm kapasitenin yüzdesi. Bellek çubuğu: fiziksel RAM payı. * Eksik ölçüm.",
              "CPU: share of total capacity. Memory bar: share of physical RAM. * Incomplete measurement."
            )
          )
          .font(.caption2).foregroundStyle(AgenticPalette.secondaryText).frame(
            maxWidth: .infinity, alignment: .leading)
          Button {
            proxy.scrollTo("cleaner-consumers-top", anchor: .top)
          } label: {
            Label(L10n.text("En üste", "Back to top"), systemImage: "arrow.up.to.line")
          }.buttonStyle(.borderless).font(.caption)
            .disabled(model.list.presentation.rows.isEmpty)
        }.padding(.horizontal, 16).padding(.vertical, 8)
      }
    }
  }
  private var diskLanding: some View {
    DiskSpaceOverview(model: diskModel, discovered: diskProjects)
  }
  private var diskProjects: [String] {
    Array(Set((model.snapshot?.rows ?? []).compactMap { row in row.project.flatMap { $0.hasProjectMarker ? $0.path : nil } }))
  }
  private func workloadCell(_ work: Workload, row: ProcessRow) -> some View {
    HStack(spacing: 12) {
      Image(systemName: work.symbol).font(.title3).foregroundStyle(AgenticPalette.accent)
        .frame(width: 32, height: 32).background(
          AgenticPalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 5) {
        Text((row.project.map { $0.name + " · " } ?? "") + L10n.core(row.title)).fontWeight(
          .semibold
        ).lineLimit(1)
        Text(
          row.project?.path
            ?? L10n.text("Proje bağlantısı bulunamadı", "Project connection not found")
        )
        .font(.caption).foregroundStyle(AgenticPalette.secondaryText).lineLimit(1)
        Text(missingStatus(row) ?? L10n.text(
          "Çalışıyor · etkin iş durumu bilinmiyor", "Running · active task status unknown"))
        .font(.caption2).foregroundStyle(AgenticPalette.secondaryText)
      }.frame(maxWidth: .infinity, alignment: .leading)
      quantities(cpu: row.cpu, memory: row.sample.footprint, age: row.sample.age,
                 unavailable: model.list.missing.contains(row.id))
    }.padding(.vertical, 8).contentShape(Rectangle()).accessibilityElement(children: .combine)
      .opacity(model.list.missing.contains(row.id) ? 0.55 : 1)
      .accessibilityIdentifier("process.row.\(row.id.pid)")
      .accessibilityHint(
        L10n.text(
          "İşi incele ve kullanılabilir işlemleri gör", "Inspect this work and available actions"))
  }
  private var departedSelection: ProcessRow? {
    guard let row = model.selectedRow, !model.list.presentation.rows.contains(where: { $0.id == row.id })
    else { return nil }
    return row
  }
  private func isExpanded(_ key: String) -> Bool {
    model.request.query.isEmpty ? expanded.contains(key) : !collapsedSearch.contains(key)
  }
  private func toggle(_ key: String) {
    let collapsing = isExpanded(key)
    if model.request.query.isEmpty {
      if collapsing { expanded.remove(key) } else { expanded.insert(key) }
    } else {
      if collapsing { collapsedSearch.insert(key) } else { collapsedSearch.remove(key) }
    }
    model.selection = .group(key)
  }
  private func selectedBranch() -> String? {
    guard case .group(let key) = model.selection, model.list.presentation.containsGroup(key) else {
      return nil
    }
    return key
  }
  private func toggleSelectedBranch() -> KeyPress.Result {
    guard let key = selectedBranch() else { return .ignored }
    toggle(key)
    return .handled
  }
  private func navigateBranch(expand: Bool) -> KeyPress.Result {
    if let key = selectedBranch() {
      if isExpanded(key) != expand { toggle(key) }
      return .handled
    }
    if !expand, case .process(let id) = model.selection {
      if section == "projects",
        let group = model.list.presentation.groups.first(where: { $0.rows.contains { $0.id == id } })
      {
        model.selection = .group(group.id)
        return .handled
      }
      if section == "overview",
        let work = model.list.presentation.workloads.first(where: {
          $0.primary == nil && $0.group.rows.contains { $0.id == id }
        })
      {
        model.selection = .group(work.id)
        return .handled
      }
    }
    return .ignored
  }
  private func branchCell(_ group: ResourceGroup, key: String, depth: Int, subtitle: String)
    -> some View
  {
    Button {
      toggle(key)
      listFocused = true
    } label: {
      HStack(spacing: 10) {
        Image(systemName: isExpanded(key) ? "chevron.down" : "chevron.right")
          .font(.caption.weight(.semibold)).foregroundStyle(AgenticPalette.secondaryText).frame(width: 12)
        Image(systemName: group.isProject ? "folder.fill" : group.id == "context:system" ? "gearshape.2" : group.id == "context:unattributed" ? "terminal" : "app")
          .foregroundStyle(depth == 0 ? AgenticPalette.accent : AgenticPalette.accent)
          .frame(width: 26, height: 26)
          .background(
            (depth == 0 ? AgenticPalette.accent : AgenticPalette.accent).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 7))
        VStack(alignment: .leading, spacing: 4) {
          Text(groupTitle(group)).fontWeight(depth == 0 ? .semibold : .medium).lineLimit(1)
            .help(groupTitle(group))
          Text(
            (model.list.isMissing(group)
              ? L10n.text("Son taramada yok · Yeniden sıralanana kadar tutuluyor",
                          "Missing from latest scan · Kept until re-sort") : subtitle)
              + (group.missingMemoryCount == 0
                ? ""
                : L10n.text(
                  " · \(group.missingMemoryCount) bellek bilinmiyor",
                  " · \(group.missingMemoryCount) memory readings unavailable"))
          )
          .font(.caption).foregroundStyle(AgenticPalette.secondaryText).lineLimit(1).help(subtitle)
        }.frame(maxWidth: .infinity, alignment: .leading)
        quantities(
          cpu: group.cpu, memory: group.memory, age: group.age,
          missingCPU: group.missingCPUCount, missingMemory: group.missingMemoryCount,
          grouped: true, unavailable: model.list.isMissing(group))
      }.padding(.leading, CGFloat(depth) * 22).padding(.vertical, depth == 0 ? 12 : 6)
        .background {
          if section == "projects" && depth == 0 {
            RoundedRectangle(cornerRadius: 10).fill(AgenticPalette.surface.opacity(0.35))
              .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AgenticPalette.border.opacity(0.25)))
          }
        }
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
      .opacity(model.list.isMissing(group) ? 0.55 : 1)
      .accessibilityIdentifier("group.row.\(key)")
      .listRowSeparator(section == "projects" && depth == 0 ? .hidden : .automatic)
      .accessibilityLabel(
        groupTitle(group)
          + (depth == 0
            ? L10n.text(" bileşenleri", " components") : L10n.text(" süreçleri", " processes"))
      )
      .accessibilityValue(
        L10n.text(
          "\(isExpanded(key) ? "Açık" : "Kapalı"), \(group.rows.count) süreç, bellek \(Format.bytes(group.memory)), CPU \(Format.cpu(capacityCPU(group.cpu))). \(subtitle). \(measurementDescription(group))",
          "\(isExpanded(key) ? "Expanded" : "Collapsed"), \(group.rows.count) processes, memory \(Format.bytes(group.memory)), CPU \(Format.cpu(capacityCPU(group.cpu))). \(subtitle). \(measurementDescription(group))"
        )
      )
      .accessibilityHint(
        isExpanded(key) ? L10n.text("Daralt", "Collapse") : L10n.text("Genişlet", "Expand"))
  }
  private func processCell(_ row: ProcessRow, depth: Int = 0) -> some View {
    HStack(spacing: 10) {
      Image(systemName: depth > 0 ? "arrow.turn.down.right" : "terminal").foregroundStyle(AgenticPalette.secondaryText).frame(width: 20)
      VStack(alignment: .leading, spacing: 4) {
        Text(L10n.core(row.title)).lineLimit(1).help(L10n.core(row.title))
        Text(missingStatus(row) ?? WorkIdentityText.summary(row))
          .lineLimit(2, reservesSpace: true).font(.caption).foregroundStyle(AgenticPalette.secondaryText)
      }.frame(maxWidth: .infinity, alignment: .leading)
      quantities(cpu: row.cpu, memory: row.sample.footprint, age: row.sample.age,
                 unavailable: model.list.missing.contains(row.id))
    }.padding(.leading, 44 + CGFloat(depth) * 14).padding(.vertical, 7).accessibilityElement(children: .combine)
      .opacity(model.list.missing.contains(row.id) ? 0.55 : 1)
      .accessibilityIdentifier("process.row.\(row.id.pid)")
      .accessibilityHint(
        L10n.text(
          "İşlev, proje bağlantısı ve durdurma ayrıntılarını aç",
          "Open function, project connection, and stop details"))
  }
  private func missingStatus(_ row: ProcessRow) -> String? {
    guard model.list.missing.contains(row.id) else { return nil }
    switch model.list.presence[row.id] {
    case .absent?, .differentIdentity?:
      return L10n.text("Kapandı · Yeniden sıralanana kadar tutuluyor",
                       "Closed · Kept until re-sort")
    default:
      return L10n.text("Son taramada yok · Kapanışı doğrulanamadı",
                       "Missing from latest scan · Exit unverified")
    }
  }
  private var memoryScale: Double {
    Double(ProcessInfo.processInfo.physicalMemory)
  }
  private func capacityCPU(_ value: Double?) -> Double? {
    value.map { $0 / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) }
  }
  private func measurementDescription(_ group: ResourceGroup) -> String {
    L10n.text(
      "\(group.missingMemoryCount) süreçte bellek, \(group.missingCPUCount) süreçte CPU ölçülemedi. Eksik değerler toplamda yok.",
      "Memory unavailable for \(group.missingMemoryCount) processes; CPU unavailable for \(group.missingCPUCount). Missing values are excluded from totals."
    )
  }
  private func quantities(
    cpu: Double?, memory: UInt64?, age: Double,
    missingCPU: Int = 0, missingMemory: Int = 0, grouped: Bool = false,
    unavailable: Bool = false
  ) -> some View {
    HStack(spacing: WorkTableColumns.spacing) {
      VStack(alignment: .trailing, spacing: 5) {
        Text(unavailable ? "—" : Format.bytes(memory) + (missingMemory > 0 && memory != nil ? "*" : ""))
        ResourceMeter(fraction: unavailable ? nil : memory.map { Double($0) / max(1, memoryScale) }, color: AgenticPalette.accent)
      }.frame(width: WorkTableColumns.memory, alignment: .trailing)
        .help(
          L10n.text(
            "Çubuk: fiziksel RAM kapasitesindeki pay. Arama ölçeği değiştirmez.",
            "Bar: share of physical RAM capacity. Searching does not change the scale.")
        )
      VStack(alignment: .trailing, spacing: 5) {
        Text(unavailable ? "—" : Format.cpu(capacityCPU(cpu)) + (missingCPU > 0 && cpu != nil ? "*" : ""))
        ResourceMeter(
          fraction: unavailable ? nil : cpu.map { $0 / Double(ProcessInfo.processInfo.activeProcessorCount * 100) },
          color: AgenticPalette.accent)
      }.frame(width: WorkTableColumns.cpu, alignment: .trailing)
        .help(
          L10n.text(
            "Sayı ve çubuk: tüm işlemci kapasitesindeki pay.",
            "Number and bar: share of total CPU capacity."))
      VStack(alignment: .trailing, spacing: 3) {
        Text(unavailable ? "—" : Format.age(age))
        if grouped { Text(L10n.text("En eski", "Oldest")).font(.caption2).foregroundStyle(AgenticPalette.secondaryText) }
      }.frame(width: WorkTableColumns.age, alignment: .trailing)

    }.font(.callout).monospacedDigit().help(
      L10n.text(
        "* Bilinen süreçlerin toplamı; eksik ölçümler var.",
        "* Sum of known processes; some measurements are missing."))
  }
  private func projectSectionTitle(_ section: Int) -> String {
    switch section {
    case 0: L10n.text("Projeler", "Projects")
    case 1: L10n.text("Uygulama bileşenleri", "Application components")
    case 4: L10n.text("Yerel AI servisleri · istemci projeleri bilinmiyor", "Local AI services · client projects unknown")
    case 2: L10n.text("macOS ve sistem servisleri", "macOS and system services")
    default: L10n.text("Projesi belirlenemeyen işler", "Work without a verified project")
    }
  }
  private func groupTitle(_ group: ResourceGroup) -> String {
    if group.id == "context:system" || group.id == "context:unattributed" {
      return projectSectionTitle(group.projectSection)
    }
    return L10n.core(group.name)
  }
  private func projectSubtitle(_ group: ResourceGroup) -> String {
    if group.isProject { return group.id }
    if group.id == "context:system" {
      return L10n.text("macOS konumlarından tanınan bileşenler", "Components identified by macOS locations")
    }
    if group.projectSection == 4 {
      return L10n.text("Birden fazla işe hizmet verebilir; kullanım sahipliği doğrulanmadı", "May serve multiple jobs; client ownership unverified")
    }
    if group.projectSection == 1 {
      return L10n.text("Uygulama / servis biliniyor; proje bazında ayrıştırılmıyor", "Known application / service; not split by project")
    }
    return L10n.text("Bağlantıyı araştırmak için bir süreç seç", "Select a process to investigate its connection")
  }
  private var selectedGroup: ResourceGroup? {
    guard case .group(let key) = model.selection else { return nil }
    if section == "projects" {
      return model.presentation.groups.first { $0.id == key }
        ?? model.list.presentation.groups.first { $0.id == key }
    }
    return model.presentation.workloads.first { $0.id == key }?.group
      ?? model.list.presentation.workloads.first { $0.id == key }?.group
  }
  private func groupInspector(_ group: ResourceGroup) -> some View {
    VStack(spacing: 0) {
    ScrollView {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(groupTitle(group)).font(.title2.bold()).textSelection(.enabled)
        Spacer()
        Button {
          model.selection = nil
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless).accessibilityLabel(L10n.text("Ayrıntıyı kapat", "Close details"))
      }
      if section == "projects" && group.isProject {
        Text(group.id).font(.caption).foregroundStyle(AgenticPalette.secondaryText).textSelection(.enabled)
      }
      LabeledContent(L10n.text("Süreç sayısı", "Processes"), value: String(group.rows.count))
      LabeledContent(
        L10n.text("Bellek yükü", "Memory footprint"), value: Format.bytes(group.memory))
      LabeledContent(
        L10n.text("CPU · toplam kapasite", "CPU · total capacity"),
        value: Format.cpu(capacityCPU(group.cpu)))
      DisclosureGroup(L10n.text("Ölçüm ayrıntıları", "Measurement details")) {
        Text(measurementDescription(group)).font(.caption).foregroundStyle(AgenticPalette.secondaryText)
        LabeledContent(L10n.text("En eski süreç", "Oldest process"), value: Format.age(group.age))
        Text(L10n.text("Bu toplam, temizlenebilir bellek değildir.", "This total is not reclaimable memory.")).font(.caption).foregroundStyle(AgenticPalette.secondaryText)
      }
      Divider()
      Text(L10n.text("Bu grupta ne var?", "What is in this group?")).font(.headline)
      Text(L10n.text("İşleri soldaki listede genişleterek incele. Buradaki toplamlar seçili gruba aittir.", "Expand the main list to inspect individual jobs. These totals belong to the selected group."))
        .font(.callout).foregroundStyle(AgenticPalette.secondaryText)
      if group.isProject, let plan = model.projectStopPlan(for: group.id) {
        LabeledContent(L10n.text("Durdurmaya uygun", "Eligible to stop"), value: String(plan.targets.count))
        if !plan.helperEntries.isEmpty {
          LabeledContent(L10n.text("Yardımcılar · ayrı onay", "Helpers · separate approval"), value: String(plan.helperEntries.count))
        }
        LabeledContent(L10n.text("Kapsam dışında", "Excluded"), value: String(plan.excludedCount - plan.helperEntries.count))
        Text(L10n.text("Durdurmak bu işlere bağlı önizlemeleri, testleri veya AI yanıtlarını kesebilir. Sonraki adımda işleri ve istisnaları inceleyebilirsin.", "Stopping may interrupt previews, tests, or AI responses that depend on these jobs. Review the jobs and exclusions in the next step."))
          .font(.callout).foregroundStyle(AgenticPalette.secondaryText)
      }
      Button {
        historyGroup = group
        sheet = .groupHistory
      } label: {
        Label(L10n.text("Bu grubun kaynak geçmişi", "Resource history for this group"), systemImage: "chart.xyaxis.line")
      }.buttonStyle(.bordered)
      Text(L10n.text("Proje bağlantısı", "Project connection")).font(.headline)
      Text(projectSubtitle(group)).font(.callout).textSelection(.enabled)
      DisclosureGroup(L10n.text("Bağlantı ayrıntıları", "Connection details")) {
        Text(projectSubtitle(group)).font(.caption).textSelection(.enabled)
        if group.isProject {
          let direct = group.rows.filter { $0.project?.inherited == false }.count
          let inherited = group.rows.filter { $0.project?.inherited == true }.count
          Text(L10n.text("\(direct) süreç: doğrudan çalışma klasörü", "\(direct) processes: direct working directory")).font(.caption)
          Text(L10n.text("\(inherited) süreç: üst süreçten çıkarım", "\(inherited) processes: inherited from parent")).font(.caption)
        }
        Text(L10n.text("Proje bağlantısı, sohbet sahipliğini göstermez.", "A project connection does not establish chat ownership.")).font(.caption).foregroundStyle(AgenticPalette.secondaryText)
      }
      Divider()
      if section == "projects" && group.isProject {
        Text(
          L10n.text(
            "Onay ekranında kapatma isteği gönderilecek işleri ve kapsam dışındaki süreçlerin nedenlerini görebilirsin.",
            "Review which work receives a stop request and why other processes are excluded."
          )
        )
        .font(.callout).foregroundStyle(AgenticPalette.secondaryText)

      } else {
        Text(
          L10n.text(
            "Bileşenleri genişleterek belirli bir işi incele. Paylaşılan uygulama veya yardımcılar topluca kapatılmaz.",
            "Expand the components to inspect a specific task. Shared apps and helpers are not stopped in bulk."
          )
        )
        .font(.callout).foregroundStyle(AgenticPalette.secondaryText)
      }
    }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
    }.frame(maxHeight: .infinity, alignment: .top)
    if section == "projects" && group.isProject {
      Divider()
        Button(L10n.text("Durdurmayı incele…", "Review stopping…")) {
          if let plan = model.projectStopPlan(for: group.id) { sheet = .project(plan) }
        }.buttonStyle(.borderedProminent).disabled(
          model.pendingProjects.contains(group.id) || model.preparing
            || model.projectStopPlan(for: group.id) == nil).padding(16).frame(maxWidth: .infinity, alignment: .trailing)
    }
    }.background(AgenticPalette.surface)
  }
  private var inspector: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let row = model.selectedRow {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
              Text(L10n.core(row.title)).font(.title3.bold()).textSelection(.enabled)
              Spacer()
              Button {
                model.selection = nil
              } label: {
                Image(systemName: "xmark")
              }
              .buttonStyle(.borderless).accessibilityLabel(
                L10n.text("Ayrıntıyı kapat", "Close details"))
            }
            Text("\(row.applicationName) · \(L10n.core(row.applicationComponent))").font(
              .caption
            ).foregroundStyle(AgenticPalette.secondaryText)
            if model.snapshot?.rows.contains(where: { $0.id == row.id }) != true {
              Label(presenceText, systemImage: "info.circle").foregroundStyle(AgenticPalette.warning)
            }
            Text(WorkIdentityText.summary(row)).font(.caption).foregroundStyle(AgenticPalette.secondaryText)
            Text(L10n.text("Başlangıç zamanı süreci ayırt eder; hangi sohbetin kullandığı doğrulanmadı.", "Start time distinguishes this process; its chat ownership has not been verified."))
              .font(.caption).foregroundStyle(AgenticPalette.secondaryText)
            WorkExplanationView(row: row)
            if LocalAIProvider.recognize(executablePath: row.sample.path) != nil {
              ProviderInspector(row: row, model: model).id(row.id)
            }
            ListenerInspector(row: row).id(row.id)

            Divider()
            ProjectConnectionView(row: row, manualPath: Binding(
              get: { manualProjects[row.id] },
              set: { manualProjects[row.id] = $0 }
            )).id(row.id)
            Divider()
            LabeledContent(
              L10n.text("Bellek yükü (footprint)", "Memory footprint"),
              value: Format.bytes(row.sample.footprint))
            LabeledContent(
              L10n.text("CPU · toplam kapasite", "CPU · total capacity"),
              value: Format.cpu(capacityCPU(row.cpu)))
            LabeledContent(
              L10n.text("Çalışma süresi", "Running time"), value: Format.age(row.sample.age))

            LabeledContent(
              L10n.text("Disk okuma", "Disk reads"),
              value: Format.rate(row.diskActivity?.readBytesPerSecond))
            LabeledContent(
              L10n.text("Disk yazma", "Disk writes"),
              value: Format.rate(row.diskActivity?.writtenBytesPerSecond))
            Text(
              L10n.text(
                "Aktarılan veri hızı; disk gecikmesini ölçmez.",
                "Transfer rate; does not measure disk latency.")
            ).font(.caption2).foregroundStyle(AgenticPalette.secondaryText)
            if !row.reasons.isEmpty {
              Text(row.reasons.map(L10n.core).joined(separator: " · ")).font(.caption)
                .foregroundStyle(AgenticPalette.warning)
            }
            Text(
              L10n.text(
                "Yüksek kullanım, bu sürecin gereksiz olduğunu göstermez.",
                "High usage does not mean this process is unnecessary.")
            ).font(.caption2)
              .foregroundStyle(AgenticPalette.secondaryText)
            DisclosureGroup(L10n.text("Teknik ayrıntılar", "Technical details")) {
              VStack(alignment: .leading, spacing: 6) {
                LabeledContent("PID", value: String(row.id.pid))
                LabeledContent(
                  L10n.text("CPU · bir çekirdek %100", "CPU · one core is 100%"),
                  value: Format.cpu(row.cpu))
                LabeledContent(
                  L10n.text("RAM’de yerleşik (RSS)", "Resident memory (RSS)"),
                  value: Format.bytes(row.sample.memory))
                Text(L10n.text("Dosya: \(row.sample.path)", "Executable: \(row.sample.path)"))
                Text(
                  L10n.text(
                    "Çalışma klasörü: \(row.sample.cwd ?? "Okunamadı")",
                    "Working directory: \(row.sample.cwd ?? "Unreadable")"))
                Text(
                  L10n.text(
                    "Üst süreç PID: \(row.sample.parent)", "Parent PID: \(row.sample.parent)"))
              }.font(.caption).textSelection(.enabled).padding(.top, 6)
            }
          }.padding(16)
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          if let event = model.events.first(where: { $0.process == row.id }) {
            EventStatus(event: event)
          }
          Text(L10n.core(row.sample.protection ?? row.stopImpact)).font(.caption).foregroundStyle(
            .secondary)
          HStack {
            if let plan = model.helperStopPlan(for: row) {
              Button(L10n.text("Yardımcıyı ayrı incele…", "Review helper separately…")) {
                sheet = .project(plan)
              }.accessibilityIdentifier("process.helperReview")
            }
            if !row.sample.isDevelopment && row.sample.protection == nil {
              Text(
                L10n.text(
                  "Manuel kapatma bu süreç türünde açık değil.",
                  "Manual stopping is unavailable for this process type.")
              ).font(.caption2)
            }
            Spacer()
            if model.helperStopPlan(for: row) == nil {
              TimelineView(.periodic(from: .now, by: 1)) { _ in
                Button(L10n.text("Durdur…", "Stop…"), role: .destructive) { stopTarget = row }
                  .disabled(!model.canStop(row))
              }
            }
          }
        }.padding(12)
      }
    }.font(.callout).background(AgenticPalette.surface)
  }
  private var presenceText: String {
    switch model.selectedPresence {
    case .absent, .differentIdentity:
      L10n.text(
        "Bu süreç kapandı. Son ölçüm gösteriliyor.",
        "This process closed. Showing its last measurement.")
    case .sameIdentity:
      L10n.text(
        "Süreç çalışıyor; son taramada bilgisi okunamadı.",
        "The process is running; its details could not be read in the latest scan.")
    case .unreadable:
      L10n.text(
        "Süreç bu taramada yok; kapanıp kapanmadığı doğrulanamadı.",
        "The process is absent from this scan; shutdown could not be verified.")
    }
  }
}
enum Format {
  static func bytes(_ value: UInt64?) -> String {
    value.map { Int64(clamping: $0).formatted(.byteCount(style: .binary).locale(L10n.locale)) }
      ?? L10n.text("Bilinmiyor", "Unknown")
  }
  static func cpu(_ value: Double?) -> String {
    CPUDisplay.format(value, locale: L10n.locale)
  }
  static func rate(_ value: Double?) -> String {
    value.map {
      String(format: "%.2f", locale: L10n.locale, $0 / 1_048_576) + " "
        + L10n.text("MiB/sn", "MiB/s")
    } ?? "—"
  }
  static func age(_ seconds: Double) -> String {
    if seconds >= 86400 { return L10n.text("\(Int(seconds/86400)) gün", "\(Int(seconds/86400)) d") }
    if seconds >= 3600 { return L10n.text("\(Int(seconds/3600)) sa", "\(Int(seconds/3600)) hr") }
    if seconds >= 60 { return L10n.text("\(Int(seconds/60)) dk", "\(Int(seconds/60)) min") }
    return L10n.text("\(Int(seconds)) sn", "\(Int(seconds)) sec")
  }
}
enum BuildInfo {
  static let label =
    "v"
    + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
  static var detail: String {
    label + " · "
      + (Bundle.main.object(forInfoDictionaryKey: "CleanerBuildID") as? String
        ?? L10n.text("yerel derleme", "local build"))
  }
}

private enum DashboardSheet: Identifiable {
  case cleanup, groupHistory, operations, simulators, history, system, settings, docker, episodes, workReview
  case project(ProjectStopPlan)
  var title: String {
    switch self {
    case .episodes: L10n.text("AgenticClean — Yavaşlama geçmişi", "AgenticClean — Pressure periods")
    case .workReview: L10n.text("AgenticClean — İş sonrası kontrol", "AgenticClean — After-work review")
    case .cleanup: L10n.text("AgenticClean — Disk alanı", "AgenticClean — Disk space")
    case .docker: "AgenticClean — Docker"
    case .groupHistory: L10n.text("AgenticClean — Proje geçmişi", "AgenticClean — Project history")
    case .operations: L10n.text("AgenticClean — Bu oturumdaki işlemler", "AgenticClean — This session’s operations")
    case .simulators: L10n.text("AgenticClean — Simülatörler", "AgenticClean — Simulators")
    case .history: L10n.text("AgenticClean — Grafikler", "AgenticClean — Charts")
    case .system: L10n.text("AgenticClean — Ölçüm ayrıntıları", "AgenticClean — Measurement details")
    case .settings: L10n.text("AgenticClean — Ayarlar", "AgenticClean — Settings")
    case .project(let plan): "AgenticClean — " + plan.name
    }
  }
  var id: String {
    switch self {
    case .episodes: "episodes"
    case .workReview: "work-review"
    case .cleanup: "cleanup"
    case .docker: "docker"
    case .groupHistory: "group-history"
    case .operations: "operations"
    case .simulators: "simulators"
    case .history: "history"
    case .system: "system"
    case .settings: "settings"
    case .project(let plan): "project-" + plan.id.uuidString
    }
  }
}
