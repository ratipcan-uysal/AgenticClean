import CleanerCore
import SwiftUI

private enum WorkTableColumns {
  static let memory: CGFloat = 100
  static let cpu: CGFloat = 67
  static let age: CGFloat = 57
  static let action: CGFloat = 72
  static let spacing: CGFloat = 8
}

struct DashboardView: View {
  @Bindable var model: Dashboard
  var languageChanged: () -> Void = {}
  @FocusState private var listFocused: Bool
  @AppStorage("mainSection") private var section = "overview"
  @State private var expanded = Set<String>()
  @State private var collapsedSearch = Set<String>()
  @State private var stopTarget: ProcessRow?
  @State private var sheet: DashboardSheet?
  @State private var detailWindow = DetailWindowPresenter()
  @AppStorage("cleanerLanguage") private var language = "tr"

  var body: some View {
    GeometryReader { geometry in
    VStack(spacing: 0) {
      SystemHeader(model: model, showSystem: { sheet = .system }, compact: true)
      Divider()
      actionBar.padding(.horizontal, 16).padding(.top, 12)
      if section != "disk" {
        if geometry.size.height >= 780 {
          ResourceVisuals(model: model, showMemoryConsumers: showMemoryConsumers)
            .padding(.horizontal, 16).padding(.top, 8)
        } else {
          HStack {
            Text(L10n.text("Listeye daha fazla alan ayrıldı", "More room for your running work"))
              .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(L10n.text("Bellek kullananları göster", "Show memory consumers"), action: showMemoryConsumers)
            Button(L10n.text("Grafikleri aç", "Open charts")) { sheet = .history }
          }.padding(.horizontal, 16).padding(.top, 10)
        }
      }
      if section != "disk" { controls.padding(16) }
      Divider()
      HSplitView {
        Group {
          if section == "disk" { diskLanding } else { processList }
        }.frame(
          minWidth: 510, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        if section != "disk" && (model.selectedRow != nil || selectedGroup != nil) {
          Group {
            if model.selectedRow != nil {
              inspector
            } else if let group = selectedGroup {
              groupInspector(group)
            }
          }.frame(
            minWidth: 320, idealWidth: 350, maxWidth: 420,
            maxHeight: .infinity, alignment: .top)
        }
      }.frame(maxHeight: .infinity)
      Divider()
      footer
    }
    }
    .environment(\.locale, Locale(identifier: language))
    .frame(
      minWidth: 920, maxWidth: .infinity, minHeight: 570, maxHeight: .infinity, alignment: .top
    )
    .onAppear {
      // Retire the three mutually exclusive views without restoring a hidden filter.
      model.request.mode = section == "projects" ? .projects : .applications
      model.request.project = "all"
      model.request.filter = .all
    }
    .onChange(of: section) { _, value in
      model.selection = nil
      model.request.mode = value == "projects" ? .projects : .applications
    }
    .onChange(of: language) { _, _ in
      languageChanged()
      if let sheet { detailWindow.updateTitle(sheet.title) }
    }
    .onChange(of: model.request.query) { _, _ in collapsedSearch.removeAll() }
    .onChange(of: sheet?.id) { _, _ in
      if let destination = sheet {
        detailWindow.show(
          title: destination.title,
          content: sheetContent(destination).environment(\.locale, Locale(identifier: language))
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
    case .cleanup: CacheCleanupView()
    case .docker: DockerInspector(model: model)
    case .groupHistory: GroupHistoryView(model: model)
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
        .font(.caption).foregroundStyle(.secondary)
        ResourceVisuals(model: model, showMemoryConsumers: showMemoryConsumers)
        Divider()
        Text(L10n.text("Son 30 dakika", "Last 30 minutes")).font(.headline)
        HistoryView(points: model.history.points)
        HStack {
          Spacer()
          Button(L10n.text("Kapat", "Close")) { sheet = nil }.keyboardShortcut(.cancelAction)
        }
      }.padding(24).frame(width: 880)
    }
  }
  private var actionBar: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(L10n.text("Mac’inde neler çalışıyor?", "What is running on your Mac?")).font(
          .title3.bold())
        Text(
          L10n.text(
            "Çalışan işlerini tanı, kaynak kullanımını anla ve etkisini görerek durdur.",
            "Recognize your work, understand resource use, and review the impact before stopping.")
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      Button {
        Task { await model.refresh() }
      } label: {
        Label(
          L10n.text(
            model.scanning ? "Taranıyor…" : "Şimdi tara", model.scanning ? "Scanning…" : "Scan now"),
          systemImage: "arrow.clockwise")
      }.disabled(model.scanning).keyboardShortcut("r", modifiers: .command)
      Picker(L10n.text("Bölüm", "Section"), selection: $section) {
        Text(L10n.text("Genel Bakış", "Overview")).tag("overview")
        Text(L10n.text("Projeler", "Projects")).tag("projects")
        Text(L10n.text("Disk Alanı", "Disk Space")).tag("disk")
      }.pickerStyle(.segmented).frame(width: 300)
      Button("Docker", systemImage: "shippingbox") { sheet = .docker }
      Button {
        sheet = .simulators
      } label: {
        Label(L10n.text("Simülatörler", "Simulators"), systemImage: "iphone")
      }
    }.controlSize(.regular)
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
      Text(
        model.request.query.isEmpty
          ? L10n.text(
            section == "projects" ? "Projeler" : "Çalışan işler",
            section == "projects" ? "Projects" : "Running work")
          : L10n.text("Arama sonuçları", "Search results")
      ).font(
        .headline)
      Spacer(minLength: 8)
      Picker(L10n.text("Büyükten küçüğe", "Highest first"), selection: $model.request.sort) {
        ForEach(SortOrder.allCases, id: \.self) {
          Text(
            L10n.text($0.rawValue, $0 == .memory ? "Memory" : $0 == .cpu ? "CPU" : "Running time")
          ).tag($0)
        }
      }.frame(width: 205)
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField(
          L10n.text("Uygulama, proje veya süreç ara", "Search apps, projects or processes"),
          text: $model.request.query
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
      }.padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        .frame(width: 285)
    }
  }
  private var footer: some View {
    HStack(spacing: 16) {
      Text(
        "\(model.presentation.rows.count) "
          + (model.request.query.isEmpty
            ? L10n.text("süreç izleniyor", "processes monitored")
            : L10n.text("eşleşen süreç", "matching processes"))
      )
      .foregroundStyle(.secondary)
      Spacer()
      Button(
        L10n.text("Grafikler", "Charts"), systemImage: "chart.xyaxis.line"
      ) {
        sheet = .history
      }.buttonStyle(.borderless)
      Menu {
        Button(L10n.text("İş sonrası kontrol", "After-work review")) { sheet = .workReview }
        Button(L10n.text("Yavaşlama anlarını incele", "Review pressure periods")) { sheet = .episodes }
        Divider()
        Button(L10n.text("Uygulama / proje geçmişi", "App / project history")) {
          sheet = .groupHistory
        }
        Button(
          L10n.text(
            "İşlem geçmişi (\(model.events.count))", "Operation history (\(model.events.count))")
        ) { sheet = .operations }
        Button(L10n.text("Simülatörler", "Simulators")) { sheet = .simulators }
        Divider()
        Button(L10n.text("Ölçüm ayrıntıları", "Measurement details")) { sheet = .system }
        Button(L10n.text("Şimdi tara", "Scan now")) { Task { await model.refresh() } }.disabled(
          model.scanning)
      } label: {
        Text(
          L10n.text("Diğer işlemler", "More")
            + (model.events.isEmpty ? "" : " (\(model.events.count))"))
      }.fixedSize()
      Button(L10n.text("Ayarlar", "Settings"), systemImage: "gearshape") { sheet = .settings }
        .buttonStyle(.borderless)
      Text(BuildInfo.label).foregroundStyle(.tertiary).help(BuildInfo.detail)
    }.font(.caption).padding(12)
  }
  private var processList: some View {
    ScrollViewReader { proxy in
      VStack(spacing: 0) {
        HStack(spacing: WorkTableColumns.spacing) {
          Text(L10n.text("İş / proje", "Work / project")).frame(
            maxWidth: .infinity, alignment: .leading)
          Text(L10n.text("Bellek", "Memory")).frame(width: WorkTableColumns.memory, alignment: .trailing)
          Text("CPU").frame(width: WorkTableColumns.cpu, alignment: .trailing)
          Text(L10n.text("Süre", "Age")).frame(width: WorkTableColumns.age, alignment: .trailing)
          if section == "projects" {
            Text(L10n.text("İşlem", "Action")).frame(width: WorkTableColumns.action)
          }
        }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
          .padding(.horizontal, 16).padding(.vertical, 10)
        if model.presentation.rows.isEmpty && departedSelection == nil {
          VStack(spacing: 12) {
            ContentUnavailableView(
              model.scanning
                ? L10n.text("Ölçüm alınıyor", "Taking measurements")
                : L10n.text("Sonuç bulunamadı", "No results"),
              systemImage: "magnifyingglass",
              description: model.scanning ? nil : Text(
                model.request.query.isEmpty
                  ? L10n.text(
                    section == "projects" ? "Henüz gösterilecek proje veya süreç yok. Yeniden tarayabilirsin."
                      : "Henüz gösterilecek çalışan iş yok. Yeniden tarayabilirsin.",
                    section == "projects" ? "No projects or processes to show yet. Try scanning again."
                      : "No running work to show yet. Try scanning again.")
                  : L10n.text(
                    "“\(model.request.query)” aramasıyla eşleşen süreç bulunamadı. Tüm süreçleri görmek için aramayı temizle.",
                    "No processes match “\(model.request.query)”. Clear the search to see all processes.")
              ))
            if !model.request.query.isEmpty {
              Button(L10n.text("Aramayı temizle", "Clear search")) { model.request.query = "" }
            } else {
              Button(L10n.text("Yeniden tara", "Scan again")) { Task { await model.refresh() } }
                .disabled(model.scanning)
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          List(selection: $model.selection) {
            // Keep the initial viewport anchored to a stable row as live rankings change.
            // Once scrolled away, List can retain the user's visible process instead.
            Text(
              L10n.text(
                "Canlı kullanım · ayrıntı ve işlemler için bir iş seç",
                "Live usage · select work to inspect details and actions")
            )
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
            .id("cleaner-consumers-top")
            if let row = departedSelection {
              VStack(alignment: .leading, spacing: 4) {
                Text(L10n.core(row.title)).fontWeight(.medium)
                Text(L10n.text("Son seçilen · ", "Last selected · ") + presenceText).font(.caption)
                  .foregroundStyle(.secondary)
              }.tag(Selection.process(row.id)).accessibilityElement(children: .combine)
            }
            if section == "projects" {
              ForEach(model.presentation.groups) { project in
                ZStack(alignment: .trailing) {
                  branchCell(
                    project, key: project.id, depth: 0,
                    subtitle: projectSubtitle(project))
                  if project.isProject {
                    Button(L10n.text("Durdur…", "Stop…")) {
                      model.selection = .group(project.id)
                      if let plan = model.projectStopPlan(for: project.id) {
                        sheet = .project(plan)
                      }
                    }.frame(width: WorkTableColumns.action)
                      .disabled(model.pendingProjects.contains(project.id))
                  }
                }.tag(Selection.group(project.id))
                if isExpanded(project.id) {
                  ForEach(project.rows) { row in
                    processCell(row).tag(Selection.process(row.id))
                  }
                }
              }
            } else {
              ForEach(model.presentation.workloads) { work in
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
          }.listStyle(.inset).accessibilityLabel(
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
          .font(.caption2).foregroundStyle(.secondary).frame(
            maxWidth: .infinity, alignment: .leading)
          Button {
            proxy.scrollTo("cleaner-consumers-top", anchor: .top)
          } label: {
            Label(L10n.text("En üste", "Back to top"), systemImage: "arrow.up.to.line")
          }.buttonStyle(.borderless).font(.caption)
            .disabled(model.presentation.rows.isEmpty)
        }.padding(.horizontal, 16).padding(.vertical, 8)
      }
    }
  }
  private var diskLanding: some View {
    DiskSpaceOverview { sheet = .cleanup }
  }
  private func workloadCell(_ work: Workload, row: ProcessRow) -> some View {
    HStack(spacing: 12) {
      Image(systemName: work.symbol).font(.title3).foregroundStyle(.blue)
        .frame(width: 32, height: 32).background(
          .blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 5) {
        Text((row.project.map { $0.name + " · " } ?? "") + L10n.core(row.title)).fontWeight(
          .semibold
        ).lineLimit(1)
        Text(
          row.project?.path
            ?? L10n.text("Paylaşılan / proje bilinmiyor", "Shared / unknown project")
        )
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Text(
          L10n.text(
            "Çalışıyor · etkin iş durumu bilinmiyor", "Running · active task status unknown")
        )
        .font(.caption2).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading)
      quantities(cpu: row.cpu, memory: row.sample.footprint, age: row.sample.age)
    }.padding(.vertical, 8).contentShape(Rectangle()).accessibilityElement(children: .combine)
      .accessibilityHint(
        L10n.text(
          "İşi incele ve kullanılabilir işlemleri gör", "Inspect this work and available actions"))
  }
  private var departedSelection: ProcessRow? {
    guard let row = model.selectedRow, !model.presentation.rows.contains(where: { $0.id == row.id })
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
    guard case .group(let key) = model.selection, model.presentation.containsGroup(key) else {
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
        let group = model.presentation.groups.first(where: { $0.rows.contains { $0.id == id } })
      {
        model.selection = .group(group.id)
        return .handled
      }
      if section == "overview",
        let work = model.presentation.workloads.first(where: {
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
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 12)
        Image(systemName: group.isProject ? "folder.fill" : group.id == "context:system" ? "gearshape.2" : group.id == "context:unattributed" ? "terminal" : "app")
          .foregroundStyle(depth == 0 ? Color.blue : Color.purple)
          .frame(width: 26, height: 26)
          .background(
            (depth == 0 ? Color.blue : Color.purple).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 7))
        VStack(alignment: .leading, spacing: 4) {
          Text(groupTitle(group)).fontWeight(depth == 0 ? .semibold : .medium).lineLimit(1)
            .help(groupTitle(group))
          Text(
            subtitle
              + (group.missingMemoryCount == 0
                ? ""
                : L10n.text(
                  " · \(group.missingMemoryCount) bellek bilinmiyor",
                  " · \(group.missingMemoryCount) memory readings unavailable"))
          )
          .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(subtitle)
        }.frame(maxWidth: .infinity, alignment: .leading)
        quantities(
          cpu: group.cpu, memory: group.memory, age: group.age,
          missingCPU: group.missingCPUCount, missingMemory: group.missingMemoryCount, grouped: true)
      }.padding(.leading, CGFloat(depth) * 22).padding(.vertical, depth == 0 ? 9 : 6)
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
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
  private func processCell(_ row: ProcessRow) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 20)
      VStack(alignment: .leading, spacing: 4) {
        Text(L10n.core(row.title)).lineLimit(1).help(L10n.core(row.title))
        Text(L10n.core(row.applicationComponent)).font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading)
      quantities(cpu: row.cpu, memory: row.sample.footprint, age: row.sample.age)
    }.padding(.leading, 44).padding(.vertical, 7).accessibilityElement(children: .combine)
      .accessibilityHint(
        L10n.text(
          "İşlev, proje bağlantısı ve durdurma ayrıntılarını aç",
          "Open function, project connection, and stop details"))
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
    missingCPU: Int = 0, missingMemory: Int = 0, grouped: Bool = false
  ) -> some View {
    HStack(spacing: WorkTableColumns.spacing) {
      VStack(alignment: .trailing, spacing: 5) {
        Text(Format.bytes(memory) + (missingMemory > 0 && memory != nil ? "*" : ""))
        ResourceMeter(fraction: memory.map { Double($0) / max(1, memoryScale) }, color: .purple)
      }.frame(width: WorkTableColumns.memory, alignment: .trailing)
        .help(
          L10n.text(
            "Çubuk: fiziksel RAM kapasitesindeki pay. Arama ölçeği değiştirmez.",
            "Bar: share of physical RAM capacity. Searching does not change the scale.")
        )
      VStack(alignment: .trailing, spacing: 5) {
        Text(Format.cpu(capacityCPU(cpu)) + (missingCPU > 0 && cpu != nil ? "*" : ""))
        ResourceMeter(
          fraction: cpu.map { $0 / Double(ProcessInfo.processInfo.activeProcessorCount * 100) },
          color: .blue)
      }.frame(width: WorkTableColumns.cpu, alignment: .trailing)
        .help(
          L10n.text(
            "Sayı ve çubuk: tüm işlemci kapasitesindeki pay.",
            "Number and bar: share of total CPU capacity."))
      VStack(alignment: .trailing, spacing: 3) {
        Text(Format.age(age))
        if grouped { Text(L10n.text("En eski", "Oldest")).font(.caption2).foregroundStyle(.secondary) }
      }.frame(width: WorkTableColumns.age, alignment: .trailing)
      if section == "projects" {
        Color.clear.frame(width: WorkTableColumns.action, height: 1).accessibilityHidden(true)
      }
    }.font(.callout).monospacedDigit().help(
      L10n.text(
        "* Bilinen süreçlerin toplamı; eksik ölçümler var.",
        "* Sum of known processes; some measurements are missing."))
  }
  private func projectSectionTitle(_ section: Int) -> String {
    switch section {
    case 0: L10n.text("Projeler", "Projects")
    case 1: L10n.text("Uygulamalar ve ortak servisler", "Applications and shared services")
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
    return projectSectionTitle(group.projectSection) + " · " + L10n.text("Proje bağlantısı doğrulanamadı", "Project connection unverified")
  }
  private var selectedGroup: ResourceGroup? {
    guard case .group(let key) = model.selection else { return nil }
    if section == "projects" { return model.presentation.groups.first { $0.id == key } }
    return model.presentation.workloads.first { $0.id == key }?.group
  }
  private func groupInspector(_ group: ResourceGroup) -> some View {
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
        Text(group.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      LabeledContent(L10n.text("Süreç sayısı", "Processes"), value: String(group.rows.count))
      LabeledContent(
        L10n.text("Bellek yükü", "Memory footprint"), value: Format.bytes(group.memory))
      LabeledContent(
        L10n.text("CPU · toplam kapasite", "CPU · total capacity"),
        value: Format.cpu(capacityCPU(group.cpu)))
      Text(measurementDescription(group)).font(.caption).foregroundStyle(.secondary)
      LabeledContent(L10n.text("En eski süreç", "Oldest process"), value: Format.age(group.age))
      Text(L10n.text("Bu toplam, temizlenebilir bellek değildir.", "This total is not reclaimable memory.")).font(.caption).foregroundStyle(.secondary)
      Divider()
      if section == "projects" && group.isProject {
        Text(
          L10n.text(
            "Onay ekranında durdurulacak işleri ve açık kalacak paylaşılan veya belirsiz süreçleri ayrı ayrı görebilirsin.",
            "Review which work will stop and which shared or uncertain processes will remain running."
          )
        )
        .font(.callout).foregroundStyle(.secondary)
        Button(L10n.text("Projenin işlerini durdur…", "Stop this project’s work…")) {
          if let plan = model.projectStopPlan(for: group.id) { sheet = .project(plan) }
        }.buttonStyle(.borderedProminent).disabled(
          model.pendingProjects.contains(group.id) || model.preparing)
      } else {
        Text(
          L10n.text(
            "Bileşenleri genişleterek belirli bir işi incele. Paylaşılan uygulama veya yardımcılar topluca kapatılmaz.",
            "Expand the components to inspect a specific task. Shared apps and helpers are not stopped in bulk."
          )
        )
        .font(.callout).foregroundStyle(.secondary)
      }
    }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
    }.frame(maxHeight: .infinity, alignment: .top).background(.background)
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
            ).foregroundStyle(.secondary)
            if !model.presentation.rows.contains(where: { $0.id == row.id }) {
              Label(presenceText, systemImage: "info.circle").foregroundStyle(.orange)
            }
            WorkExplanationView(row: row)
            if LocalAIProvider.recognize(executablePath: row.sample.path) != nil {
              ProviderInspector(row: row, model: model).id(row.id)
            }
            ListenerInspector(row: row).id(row.id)

            Divider()
            Text(L10n.text("Proje bağlantısı", "Project connection")).font(.headline)
            Text(
              row.project?.path
                ?? L10n.text("Paylaşılan / proje bilinmiyor", "Shared / unknown project")
            ).textSelection(.enabled).font(
              .callout)
            Text(
              L10n.core(
                row.project?.evidence
                  ?? "Bu süreç birden fazla projeye hizmet edebilir. Proje ve sohbet sahipliği bilinmiyor."
              )
            ).font(.caption).foregroundStyle(.secondary)
            Text(L10n.core(row.ownershipExplanation)).font(.caption).foregroundStyle(.secondary)
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
            ).font(.caption2).foregroundStyle(.secondary)
            if !row.reasons.isEmpty {
              Text(row.reasons.map(L10n.core).joined(separator: " · ")).font(.caption)
                .foregroundStyle(.orange)
            }
            Text(
              L10n.text(
                "Yüksek kullanım, bu sürecin gereksiz olduğunu göstermez.",
                "High usage does not mean this process is unnecessary.")
            ).font(.caption2)
              .foregroundStyle(.secondary)
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
            if !row.sample.isDevelopment && row.sample.protection == nil {
              Text(
                L10n.text(
                  "Manuel kapatma bu süreç türünde açık değil.",
                  "Manual stopping is unavailable for this process type.")
              ).font(.caption2)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { _ in
              Button(L10n.text("Durdur…", "Stop…"), role: .destructive) { stopTarget = row }
                .disabled(
                  !model.canStop(row))
            }
          }
        }.padding(12)
      }
    }.font(.callout).background(.background)
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
    value.map { String(format: "%.1f%%", locale: L10n.locale, $0) } ?? "—"
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
    case .operations: L10n.text("AgenticClean — İşlem geçmişi", "AgenticClean — Operation history")
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
