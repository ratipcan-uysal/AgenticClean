import Foundation

/// Display membership and topology from the last explicit sort. Never used to
/// authorize actions: Dashboard.presentation and snapshot remain live.
public struct StableList: Sendable {
  public private(set) var presentation = Presentation()
  public private(set) var missing = Set<ProcessIdentity>()
  public private(set) var presence: [ProcessIdentity: ProcessPresence] = [:]
  public private(set) var pendingCount = 0
  private var template: Presentation?
  private var lastRows: [ProcessIdentity: ProcessRow] = [:]
  private var projectTrees: [String: [ProcessTreeItem]] = [:]

  public init() {}

  public mutating func update(
    _ live: Presentation, snapshotRows: [ProcessRow]? = nil, reset: Bool = false
  ) {
    let matching = Set(live.rows.map(\.id))
    let current = Dictionary((snapshotRows ?? live.rows).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    if reset || template == nil {
      template = live
      lastRows = current.filter { matching.contains($0.key) }
      projectTrees = Dictionary(live.groups.map { ($0.id, ProcessTreeItem.ordered($0.rows)) },
                                uniquingKeysWith: { first, _ in first })
      presence = [:]
    }
    guard let template else { return }
    for id in lastRows.keys {
      if let row = current[id] { lastRows[id] = row; presence.removeValue(forKey: id) }
    }
    missing = Set(lastRows.keys).subtracting(current.keys)
    pendingCount = matching.subtracting(lastRows.keys).count
    func row(_ old: ProcessRow) -> ProcessRow { lastRows[old.id] ?? old }
    func group(_ old: ResourceGroup) -> ResourceGroup {
      let rows = old.rows.map(row)
      return ResourceGroup(
        id: old.id, name: old.name, rows: rows,
        measurementRows: rows.filter { !missing.contains($0.id) },
        projectClassification: old.isProject)
    }
    var visible = Presentation()
    visible.rows = template.rows.map(row)
    visible.projectContextCount = live.projectContextCount
    visible.projectChoices = live.projectChoices
    visible.groups = template.groups.map(group)
    visible.workloads = template.workloads.map {
      Workload(id: $0.id, kind: $0.kind, group: group($0.group), primary: $0.primary.map(row))
    }
    visible.applications = template.applications.map {
      ApplicationBranch(group: group($0.group), projects: $0.projects.map(group))
    }
    presentation = visible
  }

  public func row(_ id: ProcessIdentity) -> ProcessRow? { lastRows[id] }
  public func tree(for group: ResourceGroup) -> [ProcessTreeItem] {
    (projectTrees[group.id] ?? []).map {
      ProcessTreeItem(row: lastRows[$0.id] ?? $0.row, depth: $0.depth)
    }
  }
  public func isMissing(_ group: ResourceGroup) -> Bool {
    !group.rows.isEmpty && group.rows.allSatisfy { missing.contains($0.id) }
  }
  public mutating func recordPresence(_ value: ProcessPresence, for id: ProcessIdentity) {
    guard missing.contains(id) else { return }
    presence[id] = value
  }
}
