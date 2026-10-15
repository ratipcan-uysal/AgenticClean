import Foundation
import Observation

public enum ViewMode: String, CaseIterable, Sendable {
  case applications = "Uygulamalar"
  case projects = "Projeler"
  case processes = "Süreçler"
}
public enum SortOrder: String, CaseIterable, Sendable {
  case memory = "Bellek yükü"
  case cpu = "CPU"
  case age = "Çalışma süresi"
}
public enum ProcessFilter: String, CaseIterable, Sendable {
  case localAI = "Yerel AI"
  case all = "Tümü"
  case development = "Geliştirme"
  case attention = "Yüksek kullanım"
}
public enum Selection: Hashable, Sendable {
  case group(String)
  case process(ProcessIdentity)
}
public struct PresentationRequest: Equatable, Sendable {
  public var showProjectContext = false
  public var query = ""
  public var project = "all"
  public var filter = ProcessFilter.all
  public var mode = ViewMode.applications
  public var sort = SortOrder.memory
  public init() {}
}
public struct ApplicationBranch: Identifiable, Sendable {
  public let group: ResourceGroup
  public let projects: [ResourceGroup]
  public var id: String { group.id }
  public func projectKey(_ project: ResourceGroup) -> String { id + "\u{0}" + project.id }
}
public struct Presentation: Sendable {
  public var projectContextCount = 0
  public var rows: [ProcessRow] = []
  public var workloads: [Workload] = []
  public var groups: [ResourceGroup] = []
  public var projectChoices: [ResourceGroup] = []
  public var applications: [ApplicationBranch] = []
  public init() {}
  public func containsGroup(_ id: String) -> Bool {
    workloads.contains { $0.id == id } || groups.contains { $0.id == id }
      || applications.contains { app in app.projects.contains { app.projectKey($0) == id } }
  }
  @concurrent public static func prepare(_ snapshot: Snapshot, request: PresentationRequest) async
    -> Presentation
  {
    assert(!Thread.isMainThread, "Filtering, sorting and aggregation must run off the main thread")
    let matching = snapshot.rows.filter { row in
      let search =
        "\(row.title) \(row.applicationName) \(row.applicationComponent) \(row.sample.path) \(row.owner) \(row.project?.path ?? "") \(row.id.pid)"
      return (request.query.isEmpty || search.localizedCaseInsensitiveContains(request.query))
        && (request.project == "all" || (row.project?.path ?? "project:unknown") == request.project)
        && (request.filter == .all || (request.filter == .localAI && LocalAIProvider.recognize(executablePath: row.sample.path) != nil) || (request.filter == .development && row.sample.isDevelopment)
          || (request.filter == .attention && !row.reasons.isEmpty))
    }.sorted { lhs, rhs in
      switch request.sort {
      case .memory:
        if lhs.sample.footprint != rhs.sample.footprint {
          return (lhs.sample.footprint.map(Double.init) ?? -1)
            > (rhs.sample.footprint.map(Double.init) ?? -1)
        }
      case .cpu:
        if lhs.cpu != rhs.cpu { return (lhs.cpu ?? -1) > (rhs.cpu ?? -1) }
        if lhs.sample.footprint != rhs.sample.footprint {
          return (lhs.sample.footprint.map(Double.init) ?? -1) > (rhs.sample.footprint.map(Double.init) ?? -1)
        }
      case .age:
        if lhs.id.seconds != rhs.id.seconds { return lhs.id.seconds < rhs.id.seconds }
      }
      return lhs.id.pid < rhs.id.pid
    }
    let contextCount = matching.filter { $0.project == nil }.count
    let rows = request.mode == .projects && !request.showProjectContext
      ? matching.filter { $0.project != nil } : matching
    // Group once, off the main actor; input order also orders the children.
    func ordered(_ groups: [ResourceGroup]) -> [ResourceGroup] {
      groups.sorted { lhs, rhs in
        switch request.sort {
        case .memory:
          if lhs.memory != rhs.memory {
            return (lhs.memory.map(Double.init) ?? -1) > (rhs.memory.map(Double.init) ?? -1)
          }
        case .cpu:
          if lhs.cpu != rhs.cpu { return (lhs.cpu ?? -1) > (rhs.cpu ?? -1) }
          if lhs.memory != rhs.memory {
            return (lhs.memory.map(Double.init) ?? -1) > (rhs.memory.map(Double.init) ?? -1)
          }
        case .age:
          let l = lhs.oldestStart ?? UInt64.max
          let r = rhs.oldestStart ?? UInt64.max
          if l != r { return l < r }
        }
        return lhs.id < rhs.id
      }
    }
    let apps = ordered(ResourceSummary.groups(rows))
    let groups = request.mode == .projects ? ordered(ResourceSummary.projectOverview(rows)) : apps
    var result = Presentation()
    result.projectContextCount = contextCount
    result.rows = rows
    result.workloads = Workload.prepare(rows, sort: request.sort)
    result.groups = groups
    result.applications = apps.map {
      ApplicationBranch(group: $0, projects: ordered(ResourceSummary.projectGroups($0.rows)))
    }
    result.projectChoices = snapshot.projects.sorted {
      $0.id.localizedStandardCompare($1.id) == .orderedAscending
    }
    return result
  }
}
public protocol SnapshotSource: Sendable {
  func capture() async throws -> Snapshot
  func resetBaseline() async
}
extension MonitorEngine: SnapshotSource {}

@MainActor @Observable public final class Dashboard {
  public static let completedEventLimit = 200
  public static let projectResultLimit = 50
  public private(set) var snapshot: Snapshot?
  public private(set) var presentation = Presentation()
  public private(set) var history = HistoryBuffer()
  public private(set) var groupHistory = GroupHistoryBuffer()
  public private(set) var projectResults: [ProjectOperationResult] = []
  public private(set) var scanError: String?
  public private(set) var scanning = false
  public private(set) var preparing = false
  public private(set) var events: [OperationEvent] = []
  public private(set) var selectedRow: ProcessRow?
  public private(set) var selectedPresence: ProcessPresence = .unreadable
  public var selection: Selection? { didSet { updateSelection() } }
  public var request = PresentationRequest() {
    didSet {
      guard request != oldValue else { return }
      defaults.set(request.mode.rawValue, forKey: "viewMode")
      defaults.set(request.sort.rawValue, forKey: "sortOrder")
      if request.query != oldValue.query || request.project != oldValue.project
        || request.filter != oldValue.filter || request.mode != oldValue.mode
        || request.showProjectContext != oldValue.showProjectContext
      {
        selection = nil
      }
      prepareCurrent()
    }
  }
  public var interval: Int {
    didSet {
      guard interval != oldValue else { return }
      defaults.set(interval, forKey: "interval")
      if running { restart() }
    }
  }
  public var paused = false { didSet { if paused != oldValue && running { restart() } } }
  public private(set) var devices: [SimulatorDevice] = []
  public private(set) var simulatorError: String?
  public private(set) var simulatorToolIssue: SimulatorToolIssue?
  public private(set) var scanningDevices = false
  public private(set) var pendingDevices = Set<String>()
  public private(set) var pendingProjects = Set<String>()
  @ObservationIgnored private var startedProjectPlans = Set<UUID>()
  @ObservationIgnored private var activeProjectBatches = Set<UUID>()
  @ObservationIgnored private let projectActions: any ProjectProcessActions
  @ObservationIgnored private let source: any SnapshotSource
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var schedule = SamplingSchedule()
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var preparation: Task<Void, Never>?
  @ObservationIgnored private var revision: UInt64 = 0
  @ObservationIgnored private var running = false
  @ObservationIgnored private var sleeping = false
  public init(
    source: any SnapshotSource = MonitorEngine(), defaults: UserDefaults = .standard,
    projectActions: any ProjectProcessActions = NativeProjectProcessActions()
  ) {
    self.projectActions = projectActions
    self.source = source
    self.defaults = defaults
    let saved = defaults.integer(forKey: "interval")
    interval = [5, 15, 30, 60, 300].contains(saved) ? saved : 5
    var restored = PresentationRequest()
    restored.mode = ViewMode(rawValue: defaults.string(forKey: "viewMode") ?? "") ?? .applications
    restored.sort = SortOrder(rawValue: defaults.string(forKey: "sortOrder") ?? "") ?? .memory
    request = restored
  }
  public var flagged: Int { snapshot?.rows.filter { !$0.reasons.isEmpty }.count ?? 0 }
  public var quality: SnapshotQuality {
    if scanError != nil { return .failed }
    return snapshot?.state(
      now: ProcessInfo.processInfo.systemUptime, cadence: Double(interval),
      paused: paused || sleeping) ?? .stale
  }
  public func start() {
    guard !running else { return }
    running = true
    restart()
  }
  public func stopMonitoring() {
    running = false
    loop?.cancel()
    preparation?.cancel()
    schedule.wake()
  }
  public func sleep() {
    sleeping = true
    restart()
  }
  public func wake() {
    sleeping = false
    restart()
  }
  private func restart() {
    loop?.cancel()
    schedule.wake()
    _ = schedule.configure(interval: interval, paused: paused || sleeping)
    let epoch = schedule.epoch
    history.gap()
    groupHistory.gap()
    scanning = false
    guard running, !paused, !sleeping else { return }
    loop = Task { [weak self, source] in
      await source.resetBaseline()
      guard let self, !Task.isCancelled else { return }
      await self.refresh(epoch: epoch)
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      await self.refresh(epoch: epoch)
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(self.interval)) } catch { return }
        await self.refresh(epoch: epoch)
      }
    }
  }
  public func refresh() async {
    if paused { await source.resetBaseline() }
    await refresh(epoch: schedule.epoch)
  }
  private func refresh(epoch: UInt64) async {
    guard !scanning, epoch == schedule.epoch, !sleeping else { return }
    scanning = true
    defer { if epoch == schedule.epoch { scanning = false } }
    do {
      if let snapshot,
        ProcessInfo.processInfo.systemUptime - snapshot.uptime > max(Double(interval) * 2, 10)
      {
        await source.resetBaseline()
        history.gap()
        groupHistory.gap()
      }
      let value = try await source.capture()
      guard epoch == schedule.epoch, !Task.isCancelled else { return }
      snapshot = value
      scanError = nil
      if paused {
        history.gap(at: value.date)
        groupHistory.gap(at: value.date)
      } else {
        history.record(value)
        groupHistory.record(value)
      }
      await applyPresentation(value)
      if case .process(let id) = selection, !value.rows.contains(where: { $0.id == id }) {
        let presence = await MonitorActions.presence(id)
        if selection == .process(id) { selectedPresence = presence }
      }
    } catch {
      guard epoch == schedule.epoch, !Task.isCancelled else { return }
      scanError = error.localizedDescription
      history.gap()
      groupHistory.gap()
      await source.resetBaseline()
    }
  }
  private func prepareCurrent() {
    preparing = true
    preparation?.cancel()
    preparation = Task { [weak self] in
      guard let self else { return }
      if let snapshot = self.snapshot {
        await self.applyPresentation(snapshot)
      } else {
        self.preparing = false
      }
    }
  }
  private func applyPresentation(_ value: Snapshot) async {
    revision &+= 1
    let ticket = revision
    let config = request
    preparing = true
    let result = await Presentation.prepare(value, request: config)
    guard ticket == revision, config == request, !Task.isCancelled else { return }
    presentation = result
    preparing = false
    if case .process(let id) = selection {
      if let live = result.rows.first(where: { $0.id == id }) {
        selectedRow = live
        selectedPresence = .sameIdentity
      } else if value.rows.contains(where: { $0.id == id }) {
        selection = nil
      } else {
        selectedPresence = .unreadable
      }  // Absence from one scan is not proof of exit.
    } else if case .group(let id) = selection, !result.containsGroup(id) {
      selection = nil
    }
  }
  private func updateSelection() {
    if case .process(let id) = selection, let row = presentation.rows.first(where: { $0.id == id })
    {
      selectedRow = row
      selectedPresence = .sameIdentity
    } else {
      selectedRow = nil
      selectedPresence = .unreadable
    }
  }
  public func canStop(_ row: ProcessRow) -> Bool {
    selection == .process(row.id) && selectedPresence == .sameIdentity && !preparing && !paused
      && scanError == nil && quality != .stale && quality != .failed
      && presentation.rows.contains { $0.id == row.id }
      && snapshot?.rows.contains { $0.id == row.id } == true
      && row.sample.protection == nil && row.sample.isDevelopment
      && !events.contains { $0.process == row.id && $0.state == .requested }
  }
  public func dismissEvent(_ id: UUID) {
    events.removeAll { $0.id == id && $0.state != .requested }
  }
  public func record(
    process: ProcessIdentity?, name: String, state: StopState, simulatorID: String? = nil,
    projectBatchID: UUID? = nil
  ) -> UUID {
    let id = UUID()
    events.insert(
      OperationEvent(
        id: id, process: process, name: name, date: Date(), state: state, simulatorID: simulatorID,
        projectBatchID: projectBatchID),
      at: 0)
    trimOperationEvents()
    return id
  }
  public func setEvent(_ id: UUID, state: StopState) {
    if let index = events.firstIndex(where: { $0.id == id }) { events[index].state = state }
    trimOperationEvents()
  }
  private func trimOperationEvents() {
    var completed = 0
    events.removeAll { event in
      // Keep in-flight records and every result of an active project batch until
      // its aggregate has been computed. These are not expendable history yet.
      if event.state == .requested { return false }
      if let batch = event.projectBatchID, activeProjectBatches.contains(batch) { return false }
      completed += 1
      return completed > Self.completedEventLimit
    }
  }
  public func stop(_ row: ProcessRow) async {
    guard canStop(row) else { return }
    let event = record(process: row.id, name: row.title, state: .requested)
    do {
      try await MonitorActions.stop(row.sample)
      let start = ProcessInfo.processInfo.systemUptime
      while true {
        let presence = await MonitorActions.presence(row.id)
        let state = StopState.resolve(
          presence, elapsed: ProcessInfo.processInfo.systemUptime - start)
        setEvent(event, state: state)
        if selection == .process(row.id) { selectedPresence = presence }
        if state != .requested { break }
        do { try await Task.sleep(for: .milliseconds(200)) } catch {
          setEvent(event, state: .unverified)
          break
        }
      }
      await refresh()
    } catch { setEvent(event, state: .failed(error.localizedDescription)) }
  }
  public func projectStopPlan(for groupKey: String) -> ProjectStopPlan? {
    if request.mode == .projects,
      let project = presentation.groups.first(where: { $0.id == groupKey }),
      project.isProject
    {
      return ProjectStopPlan(
        groupKey: groupKey, application: project.name, applicationKey: "", path: project.id,
        name: project.name, request: request,
        entries: project.rows.map { row in
          ProjectStopEntry(
            row: row,
            exclusion:
              ProjectStopPlan.exclusion(
                for: row,
                pending: events.contains { $0.process == row.id && $0.state == .requested })
              ?? ProjectStopPlan.sessionExclusion(for: row, among: snapshot?.rows ?? [])
              ?? (row.sample.agentSession != nil && (snapshot?.unreadableUserCount ?? 1) > 0
                ? "Bazı kullanıcı süreçleri okunamadı; AI oturumunun kapsamı doğrulanamıyor" : nil))
        })
    }
    for app in presentation.applications {
      guard let project = app.projects.first(where: { app.projectKey($0) == groupKey }),
        project.isProject
      else { continue }
      return ProjectStopPlan(
        groupKey: groupKey, application: app.group.name,
        applicationKey: app.id, path: project.id, name: project.name, request: request,
        entries: project.rows.map { row in
          ProjectStopEntry(
            row: row,
            exclusion: ProjectStopPlan.exclusion(
              for: row,
              pending: events.contains { $0.process == row.id && $0.state == .requested })
              ?? ProjectStopPlan.sessionExclusion(for: row, among: snapshot?.rows ?? [])
              ?? (row.sample.agentSession != nil && (snapshot?.unreadableUserCount ?? 1) > 0
                ? "Bazı kullanıcı süreçleri okunamadı; AI oturumunun kapsamı doğrulanamıyor" : nil))
        })
    }
    return nil
  }
  public func canConfirmProjectStop(_ plan: ProjectStopPlan) -> Bool {
    projectStopBlockReason(plan) == nil
  }
  public func projectStopBlockReason(_ plan: ProjectStopPlan) -> String? {
    if paused { return "Ölçüm duraklatıldı; devam ettir." }
    if scanError != nil || quality == .failed { return "Tarama başarısız; listeyi yeniden tara." }
    if preparing { return "Liste hazırlanıyor; tamamlanmasını bekle." }
    if quality == .stale { return "Ölçüm güncel değil; listeyi yenile." }
    if selection != (plan.originSelection ?? .group(plan.groupKey)) || request != plan.request
      || !presentation.containsGroup(plan.groupKey) {
      return "Liste veya seçim değişti. Projeyi yeniden seçip güncel listeyi kontrol et."
    }
    if pendingProjects.contains(plan.groupKey) { return "Bu proje için işlem sürüyor; sonucu bekle." }
    if startedProjectPlans.contains(plan.id) { return "Bu işlem zaten gönderildi; güncel listeyi yeniden incele." }
    if plan.targets.isEmpty { return "Durdurmaya uygun süreç yok." }
    return nil
  }
  public func helperStopPlan(for row: ProcessRow) -> ProjectStopPlan? {
    guard selection == .process(row.id), selectedPresence == .sameIdentity,
      let current = presentation.rows.first(where: { $0.id == row.id }),
      current.sample.path == row.sample.path, current.sample.uid == row.sample.uid,
      let path = current.project?.path
    else { return nil }
    let key = request.mode == .projects ? path : current.applicationKey + "\u{0}" + path
    return projectStopPlan(for: key)?.reviewingHelper(row.id)
  }
  public func stopProject(_ plan: ProjectStopPlan) async throws {
    guard canConfirmProjectStop(plan) else {
      throw MonitorError.message(
        "Liste veya seçim değişti. Projeyi yeniden seçip güncel listeyi kontrol et.")
    }
    let before = snapshot
    startedProjectPlans.insert(plan.id)
    pendingProjects.insert(plan.groupKey)
    activeProjectBatches.insert(plan.id)
    defer {
      pendingProjects.remove(plan.groupKey)
      activeProjectBatches.remove(plan.id)
      trimOperationEvents()
    }
    // Reserve the fixed confirmation set before yielding; another action cannot double-submit it.
    let reservations = plan.targets.map { row in
      (
        row,
        record(
          process: row.id, name: "\(plan.name) · \(row.title) · PID \(row.id.pid)",
          state: .requested, projectBatchID: plan.id)
      )
    }
    var waiting: [(ProcessIdentity, UUID, Double)] = []
    for (row, event) in reservations {
      guard !Task.isCancelled else {
        setEvent(event, state: .unverified)
        continue
      }
      guard quality != .stale && quality != .failed, !paused,
        let current = snapshot?.rows.first(where: { $0.id == row.id }),
        current.applicationKey == row.applicationKey, current.project?.path == plan.path,
        current.sample.path == row.sample.path, current.sample.cwd == row.sample.cwd,
        current.sample.uid == row.sample.uid,
        ProjectStopPlan.exclusion(for: current, pending: false, mode: plan.mode) == nil,
        ProjectStopPlan.sessionExclusion(for: current, among: snapshot?.rows ?? []) == nil,
        current.sample.agentSession == nil || snapshot?.unreadableUserCount == 0,
        !events.contains(where: { $0.process == row.id && $0.state == .requested && $0.id != event }
        )
      else {
        // A previously stopped parent may already have closed this target. A newer scan
        // can remove it before this iteration; absence from that scan alone proves nothing.
        switch await projectActions.presence(row.id) {
        case .absent, .differentIdentity: setEvent(event, state: .closed)
        case .unreadable: setEvent(event, state: .unverified)
        case .sameIdentity:
          setEvent(
            event, state: .failed("Süreç veya proje bağlantısı değişti; sinyal gönderilmedi."))
        }
        continue
      }
      do {
        switch plan.mode {
        case .project: try await projectActions.stop(row.sample, projectPath: plan.path)
        case .managedHelpers:
          try await projectActions.stopManagedHelper(row.sample, projectPath: plan.path)
        }
        waiting.append((row.id, event, ProcessInfo.processInfo.systemUptime))
      } catch {
        let message = error.localizedDescription
        switch await projectActions.presence(row.id) {
        case .absent, .differentIdentity: setEvent(event, state: .closed)
        case .unreadable: setEvent(event, state: .unverified)
        case .sameIdentity: setEvent(event, state: .failed(message))
        }
      }
    }
    // Poll all signalled PIDs together. One resistant process does not postpone the others' signals.
    while !waiting.isEmpty {
      if Task.isCancelled {
        for (_, event, _) in waiting { setEvent(event, state: .unverified) }
        break
      }
      var remaining: [(ProcessIdentity, UUID, Double)] = []
      for (identity, event, started) in waiting {
        let presence = await projectActions.presence(identity)
        let state = StopState.resolve(
          presence, elapsed: ProcessInfo.processInfo.systemUptime - started)
        setEvent(event, state: state)
        if state == .requested { remaining.append((identity, event, started)) }
      }
      waiting = remaining
      if !waiting.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
    }
    let completedAt = Date()
    await refresh()
    let after = snapshot.flatMap { scanError == nil && $0.date >= completedAt ? $0 : nil }
    projectResults.insert(
      .evaluate(plan: plan, events: events, before: before, after: after), at: 0)
    if projectResults.count > Self.projectResultLimit {
      projectResults.removeLast(projectResults.count - Self.projectResultLimit)
    }
  }
  public func refreshSimulators() async {
    guard !scanningDevices else { return }
    scanningDevices = true
    defer { scanningDevices = false }
    do {
      devices = try await SimulatorControl.devices()
      simulatorError = nil
      simulatorToolIssue = nil
    } catch {
      devices = []
      simulatorToolIssue = error as? SimulatorToolIssue
      simulatorError = error.localizedDescription
    }
  }
  public func shutdown(_ device: SimulatorDevice) async {
    guard pendingDevices.insert(device.id).inserted else { return }
    defer { pendingDevices.remove(device.id) }
    let event = record(process: nil, name: device.name, state: .requested, simulatorID: device.id)
    do {
      try await SimulatorControl.shutdown(device)
      // Re-read device state before claiming success.
      let booted = try await SimulatorControl.devices()
      devices = booted
      setEvent(event, state: booted.contains { $0.id == device.id } ? .unverified : .closed)
    } catch { setEvent(event, state: .failed(error.localizedDescription)) }
  }
}
