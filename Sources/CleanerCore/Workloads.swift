import Foundation

/// A presentation of observed work, never an additional ownership or stop permission.
public struct Workload: Identifiable, Sendable {
  public enum Kind: String, Sendable { case localAI, runtime, agent, simulator, build, application }
  public let id: String
  public let kind: Kind
  public let group: ResourceGroup
  public let primary: ProcessRow?
  public var projectPath: String? { primary?.project?.path }
  public var symbol: String {
    switch kind {
    case .localAI: "brain"
    case .runtime: "terminal"
    case .agent: "sparkles"
    case .simulator: "iphone"
    case .build: "hammer"
    case .application: "app"
    }
  }
  public static func prepare(_ rows: [ProcessRow], sort: SortOrder) -> [Workload] {
    var result: [Workload] = []
    var remaining: [ProcessRow] = []
    for row in rows {
      let kind: Kind?
      let name = row.sample.name.lowercased()
      if ["llama-server", "ollama", "llmster"].contains(name) {
        kind = .localAI
      } else if row.sample.agentSession != nil {
        kind = .agent
      } else if ["simulator", "emulator", "qemu-system-aarch64"].contains(name) {
        kind = .simulator
      } else if ["xcodebuild", "swift-build", "swift-frontend", "clang", "cargo", "gradle"]
        .contains(name)
      {
        kind = .build
      } else if row.sample.isDevelopment {
        kind = .runtime
      } else {
        kind = nil
      }
      if let kind {
        let id = "work:\(row.id.pid):\(row.id.seconds):\(row.id.microseconds)"
        result.append(
          Workload(
            id: id, kind: kind,
            group: ResourceGroup(id: id, name: row.title, rows: [row]), primary: row))
      } else {
        remaining.append(row)
      }
    }
    // Partition each process exactly once. Agent children classified above remain first-class work.
    result += ResourceSummary.groups(remaining).map {
      Workload(id: $0.id, kind: .application, group: $0, primary: nil)
    }
    return result.sorted { a, b in
      switch sort {
      case .memory:
        if a.group.memory != b.group.memory {
          return (a.group.memory.map(Double.init) ?? -1) > (b.group.memory.map(Double.init) ?? -1)
        }
      case .cpu:
        if a.group.cpu != b.group.cpu { return (a.group.cpu ?? -1) > (b.group.cpu ?? -1) }
        if a.group.memory != b.group.memory {
          return (a.group.memory.map(Double.init) ?? -1) > (b.group.memory.map(Double.init) ?? -1)
        }
      case .age:
        if a.group.age != b.group.age { return a.group.age > b.group.age }
      }
      return a.id < b.id
    }
  }
}
