import Foundation
import ProcessKit

public struct SystemSample: Sendable {
  public let ticks: [UInt64]?
  public let memory: [MemoryPart]?
  public var pressure: Int = -1
  public var paging: [UInt64]? = nil
  public var pageSize: UInt64 = 0
  public var measuredAt: Double = ProcessInfo.processInfo.systemUptime
  public var pressureTitle: String {
    switch pressure {
    case 1: "Normal"
    case 2: "Bellek baskısı yüksek"
    case 4: "Bellek baskısı kritik"
    default: "Bilinmiyor"
    }
  }
  public func pagingRates(since old: SystemSample?) -> [Double]? {
    guard let old, let paging, let previous = old.paging, paging.count == 4, previous.count == 4,
      measuredAt > old.measuredAt, pageSize > 0, pageSize == old.pageSize,
      zip(paging, previous).allSatisfy({ $0 >= $1 })
    else { return nil }
    return zip(paging, previous).map {
      Double($0 - $1) * Double(pageSize) / (measuredAt - old.measuredAt)
    }
  }
  public static func capture() -> SystemSample {
    let raw = cleaner_system()
    var sample = SystemSample(
      ticks: raw.cpu_valid == 1 ? [raw.cpu_user, raw.cpu_system, raw.cpu_nice, raw.cpu_idle] : nil,
      memory: raw.memory_valid == 1
        ? [
          MemoryPart(
            name: "Sabit (wired)", bytes: raw.wired,
            explanation:
              "RAM’de sabit tutulan sayfalar; sistem/sürücü ve uygulama adına ayrılan alanları içerebilir."
          ),
          MemoryPart(
            name: "Sıkıştırılmış", bytes: raw.compressed,
            explanation: "RAM içinde sıkıştırılan verilerin kapladığı fiziksel alan."),
          MemoryPart(
            name: "Aktif", bytes: raw.active,
            explanation: "Aktif bellek sayfaları; tek bir uygulamayı temsil etmez."),
          MemoryPart(
            name: "İnaktif", bytes: raw.inactive,
            explanation: "Yakın zamanda kullanılmayan sayfalar; tamamı boş veya önbellek değildir."),
          MemoryPart(
            name: "Boş", bytes: raw.free_bytes,
            explanation: "Şu anda kullanılmayan fiziksel sayfalar."),
        ] : nil)
    sample.pressure = Int(raw.pressure)
    sample.pageSize = raw.page_size
    sample.paging =
      raw.memory_valid == 1
      ? [raw.swapins, raw.swapouts, raw.compressions, raw.decompressions] : nil
    return sample
  }
  public func cpuUsage(since old: SystemSample?) -> Double? {
    guard let old, measuredAt > old.measuredAt, let ticks, let previous = old.ticks,
      ticks.count == 4, previous.count == 4
    else { return nil }
    // Only accept a decrease near the 32-bit boundary as a wrap, not a reset.
    guard zip(ticks, previous).allSatisfy({ $0 >= $1 || ($1 > 0xF000_0000 && $0 < 0x1000_0000) })
    else { return nil }
    let delta = zip(ticks, previous).map {
      (UInt32(truncatingIfNeeded: $0) &- UInt32(truncatingIfNeeded: $1))
    }
    let total = delta.reduce(0.0) { $0 + Double($1) }
    return total > 0 ? (1 - Double(delta[3]) / total) * 100 : nil
  }
}
public struct MemoryPart: Identifiable, Sendable {
  public let name: String
  public let bytes: UInt64
  public let explanation: String
  public var id: String { name }
}
public struct ResourceGroup: Identifiable, Sendable {
  public let id: String
  public let name: String
  public let rows: [ProcessRow]
  public let cpu: Double?
  public let memory: UInt64?
  public let missingMemoryCount: Int
  public let missingCPUCount: Int
  public let oldestStart: UInt64?
  public let age: Double
  public var isProject: Bool { id.hasPrefix("/") && rows.allSatisfy { $0.project?.path == id } }
  public var projectSection: Int {
    if isProject { return 0 }
    if id == "context:unattributed" { return 3 }
    if id == "context:system" { return 2 }
    return 1
  }
  public init(id: String, name: String, rows: [ProcessRow]) {
    self.id = id
    self.name = name
    self.rows = rows
    let cpus = rows.compactMap(\.cpu)
    let memories = rows.compactMap(\.sample.footprint)
    cpu = cpus.isEmpty ? nil : cpus.reduce(0, +)
    memory = memories.isEmpty ? nil : memories.reduce(0, +)
    missingCPUCount = rows.count - cpus.count
    missingMemoryCount = rows.count - memories.count
    oldestStart = rows.map(\.id.seconds).min()
    age = rows.map(\.sample.age).max() ?? 0
  }
}
public enum ResourceSummary {
  public static func appPath(_ path: String) -> String? {
    guard let range = path.range(of: ".app/") else { return nil }
    return String(path[..<range.lowerBound]) + ".app"
  }
  public static func appName(_ path: String) -> String {
    let name = String(path.split(separator: "/").last ?? "").replacingOccurrences(
      of: ".app", with: "")
    return name == "ChatGPT" ? "Codex" : name
  }
  public static func groups(_ rows: [ProcessRow]) -> [ResourceGroup] {
    Dictionary(
      grouping: rows, by: { $0.applicationKey.isEmpty ? $0.sample.path : $0.applicationKey }
    ).map { key, values in
      ResourceGroup(
        id: key,
        name: values[0].applicationName.isEmpty ? values[0].sample.name : values[0].applicationName,
        rows: values)
    }
  }
  /// Presentation categories do not imply project ownership or permission to stop.
  public static func projectOverview(_ rows: [ProcessRow]) -> [ResourceGroup] {
    var apps: [ProcessRow] = []
    var system: [ProcessRow] = []
    var unknownWork: [ProcessRow] = []
    for row in rows where row.project == nil {
      let path = row.sample.path
      if ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains(where: path.hasPrefix) {
        system.append(row)
      } else if ["ollama", "llama-server", "llmster"].contains(row.sample.name) {
        var service = row
        service.applicationKey = path
        service.applicationName = row.title
        apps.append(service)
      } else if ResourceSummary.appPath(path) != nil {
        apps.append(row)
      } else if row.sample.isDevelopment || row.sample.agentSession != nil {
        unknownWork.append(row)
      } else {
        apps.append(row)
      }
    }
    var result = projectGroups(rows.filter { $0.project != nil })
    // Use executable application identity, not the launching agent, for independent services.
    result += groups(apps).map {
      ResourceGroup(id: "context:app:" + $0.id, name: $0.name, rows: $0.rows)
    }
    if !system.isEmpty {
      result.append(ResourceGroup(id: "context:system", name: "macOS ve sistem servisleri", rows: system))
    }
    if !unknownWork.isEmpty {
      result.append(ResourceGroup(id: "context:unattributed", name: "Projesi belirlenemeyen işler", rows: unknownWork))
    }
    return result
  }
  public static func projectGroups(_ rows: [ProcessRow]) -> [ResourceGroup] {
    Dictionary(grouping: rows, by: { $0.project?.path ?? "project:unknown" }).map { key, values in
      ResourceGroup(
        id: key, name: values[0].project?.name ?? "Paylaşılan / proje bilinmiyor", rows: values)
    }
  }
}

public enum AgentSession: String, Sendable {
  case codex, claude
  public var name: String { self == .codex ? "Codex" : "Claude" }
  public var familyID: String { "family:" + rawValue }
  public static func identify(path: String) -> AgentSession? {
    // An embedded executable may coordinate many windows/projects; never treat it as a CLI session.
    guard ResourceSummary.appPath(path) == nil else { return nil }
    let name = URL(fileURLWithPath: path).lastPathComponent
    if name == "codex" { return .codex }
    if name == "claude" { return .claude }
    // Claude's native installer resolves the executable symlink to a versioned binary.
    let prefix = NSHomeDirectory() + "/.local/share/claude/versions/"
    if path.hasPrefix(prefix) {
      let version = String(path.dropFirst(prefix.count))
      if !version.isEmpty, !version.contains("/"),
        version.split(separator: ".").count >= 2,
        version.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" })
      {
        return .claude
      }
    }
    return nil
  }
}

public struct ApplicationIdentity: Sendable {
  public let familyID: String
  public let familyName: String
  public let component: String
  public init(agent: AgentSession) {
    familyID = agent.familyID
    familyName = agent.name
    component = agent == .claude ? "Claude Code / CLI" : "Codex CLI"
  }
  public init(bundleID: String?, path: String) {
    // A known app filename is a display fallback only. It never relaxes stop protection.
    let effectiveID =
      bundleID ?? (path.hasSuffix("/Cursor.app") ? "com.todesktop.230313mzl4w4u92" : nil)
    switch effectiveID {
    case "com.anthropic.claudefordesktop":
      familyID = "family:claude"
      familyName = "Claude"
      component = "Masaüstü"
    case "com.anthropic.claude-code":
      familyID = "family:claude"
      familyName = "Claude"
      component = "Claude Code / CLI"
    case "com.openai.codex":
      familyID = "family:codex"
      familyName = "Codex"
      component = "Masaüstü"
    case "com.todesktop.230313mzl4w4u92":
      familyID = "family:cursor"
      familyName = "Cursor"
      component = "Masaüstü"
    default:
      familyID = bundleID.map { "bundle:" + $0 } ?? path
      familyName = ResourceSummary.appName(path)
      component = familyName
    }
  }
  /// Called only by MonitorEngine, never from a view or the main actor.
  public static func read(_ path: String) -> ApplicationIdentity {
    let url = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(
      "Contents/Info.plist")
    let plist = (try? Data(contentsOf: url)).flatMap {
      try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
    }
    return ApplicationIdentity(bundleID: plist?["CFBundleIdentifier"] as? String, path: path)
  }
}
