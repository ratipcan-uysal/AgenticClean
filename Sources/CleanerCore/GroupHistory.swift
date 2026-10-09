import Foundation

public struct GroupUsage: Identifiable, Sendable {
  public let id: String
  public let name: String
  public let cpu: Double?
  public let memory: UInt64?
  public let missingCPUCount: Int
  public let missingMemoryCount: Int
  public let membershipComplete: Bool
  public init(_ group: ResourceGroup, membershipComplete: Bool = true) {
    id = group.id
    name = group.name
    cpu = group.cpu
    memory = group.memory
    self.membershipComplete = membershipComplete
    missingCPUCount = group.missingCPUCount
    missingMemoryCount = group.missingMemoryCount
  }
}

public struct GroupHistoryFrame: Identifiable, Sendable {
  public let id: UUID
  public let date: Date
  public let segment: Int
  public let applications: [GroupUsage]
  public let projects: [GroupUsage]
}

/// In-memory only: at most 121 frames, each with up to 40 applications and 40 projects.
/// Omitted groups are unknown, never zero. Sampling is independent of the visible search.
public struct GroupHistoryBuffer: Sendable {
  public private(set) var frames: [GroupHistoryFrame] = []
  private var segment = 0
  private var lastMeasurement: Date?
  public init() {}
  public mutating func gap(at date: Date = Date()) {
    segment += 1
    lastMeasurement = nil
    append(.init(id: UUID(), date: date, segment: segment, applications: [], projects: []))
  }
  public mutating func record(_ snapshot: Snapshot) {
    if let lastMeasurement, snapshot.date.timeIntervalSince(lastMeasurement) < 15 { return }
    lastMeasurement = snapshot.date
    func bounded(_ groups: [ResourceGroup]) -> [GroupUsage] {
      // Keep both CPU and memory leaders; stable tie-break makes history deterministic.
      let memory = groups.sorted {
        if $0.memory != $1.memory { return ($0.memory ?? 0) > ($1.memory ?? 0) }
        return $0.id < $1.id
      }.prefix(20)
      let cpu = groups.sorted {
        if $0.cpu != $1.cpu { return ($0.cpu ?? -1) > ($1.cpu ?? -1) }
        return $0.id < $1.id
      }.prefix(20)
      var seen = Set<String>()
      return (Array(memory) + Array(cpu)).filter { seen.insert($0.id).inserted }.map {
        GroupUsage($0, membershipComplete: snapshot.unreadableUserCount == 0)
      }
    }
    append(
      .init(
        id: UUID(), date: snapshot.date, segment: segment,
        applications: bounded(snapshot.applications), projects: bounded(snapshot.projects)))
  }
  private mutating func append(_ frame: GroupHistoryFrame) {
    frames.append(frame)
    frames.removeAll { $0.date < frame.date.addingTimeInterval(-1800) }
    if frames.count > 121 { frames.removeFirst(frames.count - 121) }
  }
}

public struct ProjectOperationResult: Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let date: Date
  public let closed: Int
  public let stillRunning: Int
  public let failed: Int
  public let unverified: Int
  /// New identities with the same executable + cwd as a confirmed target. This is evidence of
  /// a replacement process, not proof that the old session or service resumed.
  public let replacementCount: Int?
  public let beforeMemory: UInt64?
  public let afterMemory: UInt64?
  public let incompleteMemory: Bool

  public static func evaluate(
    plan: ProjectStopPlan, events: [OperationEvent], before: Snapshot?, after: Snapshot?
  ) -> Self {
    let states = events.filter { $0.projectBatchID == plan.id }.map(\.state)
    let prior = before?.rows.filter {
      (plan.request.mode == .projects || $0.applicationKey == plan.applicationKey)
        && $0.project?.path == plan.path
    }
    let current = after?.rows.filter {
      (plan.request.mode == .projects || $0.applicationKey == plan.applicationKey)
        && $0.project?.path == plan.path
    }
    let previousIDs = Set(before?.rows.map(\.id) ?? [])
    let observedReplacements = current?.filter { row in
      !previousIDs.contains(row.id)
        && plan.targets.contains {
          $0.applicationKey == row.applicationKey && $0.sample.path == row.sample.path
            && $0.sample.cwd == row.sample.cwd
        }
    }.count
    let replacements =
      before?.unreadableUserCount == 0 && after?.unreadableUserCount == 0
      ? observedReplacements : nil
    func measured(_ rows: [ProcessRow]?) -> UInt64? {
      guard let rows, !rows.isEmpty, rows.allSatisfy({ $0.sample.footprint != nil }) else {
        return nil
      }
      return rows.compactMap(\.sample.footprint).reduce(0, +)
    }
    let beforeMemory = before?.unreadableUserCount == 0 ? measured(prior) : nil
    let afterMemory = after?.unreadableUserCount == 0 ? measured(current) : nil
    return Self(
      id: plan.id, name: plan.name, date: Date(),
      closed: states.filter { $0 == .closed }.count,
      stillRunning: states.filter { $0 == .stillRunning }.count,
      failed: states.filter { if case .failed = $0 { true } else { false } }.count,
      unverified: states.filter { $0 == .unverified || $0 == .requested }.count,
      replacementCount: replacements, beforeMemory: beforeMemory, afterMemory: afterMemory,
      incompleteMemory: beforeMemory == nil || afterMemory == nil)
  }
}
