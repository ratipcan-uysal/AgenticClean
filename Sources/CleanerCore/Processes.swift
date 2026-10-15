import Darwin
import Foundation
import ProcessKit

public struct ProcessIdentity: Hashable, Sendable {
  public let pid: Int32
  public let seconds: UInt64
  public let microseconds: UInt64
  public init(pid: Int32, seconds: UInt64, microseconds: UInt64 = 0) {
    self.pid = pid
    self.seconds = seconds
    self.microseconds = microseconds
  }
}
public struct ProcessSample: Identifiable, Sendable {
  public var id: ProcessIdentity
  public var cwd: String?
  public var parent: Int32
  public var uid: UInt32
  public var path: String
  public var isMaestroMCP = false
  var managedHelperIdentity: ManagedHelperIdentity?
  public var cpuTime: UInt64
  public var footprint: UInt64?
  public var diskIO: DiskIOCounters?
  public var observedAt = Date()
  public var memoryLoad: UInt64? { footprint }
  public var memoryReading: MemoryReading { MemoryReading(footprint: footprint, rss: memory) }
  public var memory: UInt64
  public var name: String { String(path.split(separator: "/").last ?? "") }
  public var age: TimeInterval { max(0, observedAt.timeIntervalSince1970 - Double(id.seconds)) }
  public init(
    id: ProcessIdentity, parent: Int32, uid: UInt32, path: String, cpuTime: UInt64 = 0,
    memory: UInt64 = 0
  ) {
    self.id = id
    self.parent = parent
    self.uid = uid
    self.path = path
    self.cpuTime = cpuTime
    self.memory = memory
  }
  public var isBundledCodexHelper: Bool {
    managedHelperIdentity?.executablePath == path
  }
  /// Only vendor-verified exact Node runtimes can be reviewed separately. The
  /// coordinating executable and desktop app retain their normal protection.
  public var allowsSeparateHelperStop: Bool {
    infrastructureProtection == nil && isBundledCodexHelper
      && managedHelperIdentity?.component.allowsSeparateStop == true
  }
  public var isDevelopment: Bool {
    [
      "node", "node_repl", "python", "python3", "java", "ruby", "bun", "deno", "php", "ollama",
      "llama-server", "uvicorn", "Simulator", "qemu-system-aarch64", "emulator",
    ].contains(name) || name.hasPrefix("python3.")
  }
  /// CLI identity is intentionally separate from desktop applications and their managed helpers.
  public var agentSession: AgentSession? { AgentSession.identify(path: path) }
  public var projectStopProtection: String? {
    if let protection = infrastructureProtection { return protection }
    if path.contains("/Application Support/Claude/") || path.contains("/CoreSimulator/") {
      return "Ajan uygulaması veya yönetilen yardımcı süreç; etkinliği doğrulanmadı"
    }
    if agentSession != nil { return nil }
    return protection
  }
  private var infrastructureProtection: String? {
    if id.pid <= 1 || id.pid == getpid() { return "Cleaner veya temel sistem süreci" }
    if uid != getuid() { return "Başka kullanıcıya veya sisteme ait" }
    if [
      "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/Library/Developer/",
    ].contains(where: path.hasPrefix) {
      return "macOS / geliştirici altyapısı"
    }
    return nil
  }
  public var protection: String? {
    if let protection = infrastructureProtection { return protection }
    if isBundledCodexHelper {
      return "Ajan uygulaması veya yönetilen yardımcı süreç; etkinliği doğrulanmadı"
    }
    if [
      "/Applications/ChatGPT.app/", "/Applications/Codex.app/", "/Applications/Claude.app/",
      "/Application Support/Claude/", "/CoreSimulator/",
    ].contains(where: path.contains) {
      return "Ajan uygulaması veya yönetilen yardımcı süreç; etkinliği doğrulanmadı"
    }
    if agentSession != nil { return "Ajan oturumu; yalnızca onaylı proje işlemiyle kapatılabilir" }
    if path.contains(".app/Contents/") { return "Uygulamayı kendi Çıkış menüsünden kapat" }
    return nil
  }
}
public struct ProcessRow: Identifiable, Sendable {
  public let sample: ProcessSample
  public let cpu: Double?
  public let reasons: [String]
  public let owner: String
  public var project: ProjectHint?
  public var applicationKey = ""
  public var applicationName = ""
  public var applicationComponent = ""
  public var diskActivity: DiskActivity?
  public var attribution: ProjectAttribution { ProjectAttribution(hint: project) }
  public var id: ProcessIdentity { sample.id }
  public var title: String {
    if sample.isBundledCodexHelper {
      return sample.name == "codex" ? "Codex · Araç çalıştırıcısı" : "Codex araç yardımcısı · Node.js"
    }
    if sample.isMaestroMCP { return "Maestro · Mobil test bağlantısı" }
    if let agent = sample.agentSession { return agent.name + " · AI kodlama oturumu" }
    switch sample.name {
    case "java": return "Java · Görevi belirlenemedi"
    case "node", "node_repl": return "Node.js · JavaScript çalışma ortamı"
    case "llama-server": return "Yerel yapay zekâ sunucusu · llama-server"
    case "ollama": return "Ollama · Yerel yapay zekâ"
    case "Simulator": return "iOS simülatörü"
    default:
      if sample.name.hasPrefix("python") { return "Python · Betik / servis" }
      return sample.name
    }
  }
  public var connection: String {
    owner == "—" ? "Üst uygulama belirlenemedi" : "Üst uygulama: " + owner
  }
  public var explanation: String {
    if sample.isBundledCodexHelper {
      return "Codex uygulama paketindeki araç altyapısı. Bu klasörde çalışması, projenin sunucusu olduğunu göstermez. Hangi sohbetin kullandığı ve hâlâ gerekli olup olmadığı doğrulanamadı. Beklerken de çalışma ortamını bellekte tutabilir."
    }
    if sample.isMaestroMCP {
      return
        "Maestro’nun mobil uygulama test araçlarına erişim sağlayan MCP bağlantısı. Java bu aracı çalıştıran altyapıdır."
    }
    switch sample.name {
    case "java":
      return
        "Java ile çalışan bir araç. Hangi uygulama veya görevi yürüttüğü belirlenemedi; Java adı tek başına yeterli değil."
    case "node", "node_repl":
      return
        "JavaScript çalıştıran süreç. Bir geliştirme sunucusu, araç bağlantısı veya betik olabilir; tam görevi belirlenemedi."
    case "llama-server", "ollama":
      return
        "Bilgisayarda yapay zekâ modeli çalıştırmak için kullanılan süreç. Hangi isteğe hizmet ettiği bilinmiyor."
    default:
      return
        "Bu sürecin özel görevi belirlenemedi. Çalışma klasörü ve üst uygulama, neye bağlı olduğunu anlamana yardımcı olabilir."
    }
  }
  public var ownershipExplanation: String {
    if owner == "Codex" || owner == "Claude" {
      return
        "\(owner), bu sürecin üst süreç zincirinde bulundu. Hangi sohbetin veya görevin kullandığı bilinmiyor."
    }
    return owner == "—"
      ? "Üst süreç bağlantısı okunamadı."
      : "Üst süreç zincirindeki uygulama veya süreç: \(owner). Bu bilgi bir proje veya sohbet eşleştirmesi değildir."
  }
  public var stopImpact: String {
    if sample.allowsSeparateHelperStop {
      return "Hangi Codex sohbetinin kullandığı bilinmiyor. Durdurursan bağlı araç çağrıları ve devam eden işler kesilebilir; yeniden bağlantı gerekebilir."
    }
    if let agent = sample.agentSession {
      return
        "Durdurursan devam eden \(agent.name) AI kodlama oturumu ve araç çağrıları kesilir. Otomatik kaydedilmemiş çalışma kaybolabilir; oturumu yeniden başlatman gerekebilir."
    }
    if sample.isMaestroMCP {
      return
        "Durdurursan bağlı oturumun Maestro mobil test araçları kesilebilir. Yeniden bağlantı gerekebilir."
    }
    if sample.name == "llama-server" || sample.name == "ollama" {
      return "Durdurursan bu sunucuyu kullanan yapay zekâ istekleri kesilebilir."
    }
    return
      "Durdurursan bu sürece bağlı sunucu, betik veya devam eden iş kesilebilir. Tam etkisi bilinmiyor."
  }
}
public enum ProcessMonitor {
  public static func read(_ pid: Int32) -> ProcessSample? {
    var raw = CleanerProcess()
    guard cleaner_read(pid, &raw) == 1 else { return nil }
    let path = withUnsafeBytes(of: raw.path) { bytes in
      String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    var sample = ProcessSample(
      id: .init(pid: pid, seconds: raw.start_seconds, microseconds: raw.start_microseconds),
      parent: raw.parent, uid: raw.uid, path: path, cpuTime: raw.cpu_ns, memory: raw.resident)
    sample.managedHelperIdentity = ManagedHelperIdentityResolver.shared.resolve(path: path)
    sample.footprint = raw.footprint_valid == 1 ? raw.footprint : nil
    if raw.disk_valid == 1 {
      sample.diskIO = DiskIOCounters(
        readBytes: raw.disk_read_bytes, writtenBytes: raw.disk_write_bytes,
        measuredAt: ProcessInfo.processInfo.systemUptime)
    }
    return sample
  }
  public static func scan() throws -> ProcessScan {
    let count = cleaner_pids(nil, 0)
    guard count > 0 else { throw MonitorError.message("Süreç listesi okunamadı.") }
    var pids = [Int32](repeating: 0, count: Int(count) + 2048)
    let capacity = pids.count
    let found = pids.withUnsafeMutableBufferPointer {
      cleaner_pids($0.baseAddress, Int32(capacity * 4))
    }
    guard found > 0 else { throw MonitorError.message("Süreç listesi boş veya erişim engellendi.") }
    var unreadable = 0
    let result = pids.prefix(min(Int(found), capacity)).compactMap { pid -> ProcessSample? in
      guard pid > 0 else { return nil }
      guard var sample = read(pid) else {
        if cleaner_presence(pid, 0, 0) != 0 { unreadable += 1 }
        return nil
      }
      if sample.uid == getuid() {
        var buffer = [CChar](repeating: 0, count: 4096)
        if cleaner_cwd(pid, &buffer, 4096) == 1 {
          sample.cwd = buffer.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } }
        }
      }
      guard cleaner_presence(pid, sample.id.seconds, sample.id.microseconds) == 1 else {
        unreadable += 1
        return nil
      }
      return sample
    }
    guard !result.isEmpty else {
      throw MonitorError.message(
        "Süreç bilgileri okunamadı. Uygulamayı normal macOS oturumunda aç.")
    }
    // PROC_UID_ONLY returns bytes, unlike proc_listallpids, which returns a PID count.
    // Re-enumerating after the reads also catches processes created during the scan.
    let userBytes = cleaner_user_pids(getuid(), nil, 0)
    guard userBytes > 0 else {
      throw MonitorError.message("Bu kullanıcıya ait süreç listesi doğrulanamadı.")
    }
    var userPIDs = [Int32](repeating: 0, count: Int(userBytes) / MemoryLayout<Int32>.size + 2048)
    let userCapacityBytes = userPIDs.count * MemoryLayout<Int32>.size
    let returnedBytes = userPIDs.withUnsafeMutableBufferPointer {
      cleaner_user_pids(getuid(), $0.baseAddress, Int32(userCapacityBytes))
    }
    guard returnedBytes > 0, returnedBytes < userCapacityBytes,
      Int(returnedBytes) % MemoryLayout<Int32>.size == 0
    else {
      throw MonitorError.message(
        "Kullanıcı süreç listesi değişti veya tam okunamadı; yeniden tara.")
    }
    let expectedUsers = Set(
      userPIDs.prefix(Int(returnedBytes) / MemoryLayout<Int32>.size).filter { $0 > 0 })
    // Matching the PID alone is insufficient if it was reused while the list was read.
    let readUsers = Set(
      result.filter {
        $0.uid == getuid() && cleaner_presence($0.id.pid, $0.id.seconds, $0.id.microseconds) == 1
      }.map { $0.id.pid })
    let unreadableUsers = expectedUsers.subtracting(readUsers).filter {
      cleaner_presence($0, 0, 0) != 0
    }.count
    return ProcessScan(
      samples: result, unreadableCount: unreadable, unreadableUserCount: unreadableUsers)
  }
  public static func snapshot() throws -> [ProcessSample] { try scan().samples }
  public static func identifyMaestro(_ sample: ProcessSample) -> Bool {
    sample.name == "java" && sample.uid == getuid() && cleaner_is_maestro_mcp(sample.id.pid) == 1
  }
  public static func presence(_ id: ProcessIdentity) -> ProcessPresence {
    switch cleaner_presence(id.pid, id.seconds, id.microseconds) {
    case 0: .absent
    case 1: .sameIdentity
    case 2: .differentIdentity
    default: .unreadable
    }
  }
  public static func workingDirectory(_ expected: ProcessSample) -> String? {
    guard read(expected.id.pid)?.id == expected.id else { return nil }
    var buffer = [CChar](repeating: 0, count: 4096)
    guard cleaner_cwd(expected.id.pid, &buffer, 4096) == 1 else { return nil }
    return buffer.withUnsafeBufferPointer { pointer in
      pointer.baseAddress.map { String(cString: $0) }
    }
  }
  public static func swap() -> UInt64? {
    let value = cleaner_swap()
    return value == UInt64.max ? nil : value
  }
  public static func validateStop(_ expected: ProcessSample, current: ProcessSample?) throws {
    guard let current, current.id == expected.id, current.path == expected.path,
      current.uid == expected.uid
    else {
      throw MonitorError.message("Süreç kapanmış veya kimliği değişmiş. Listeyi yenile.")
    }
    guard current.protection == nil, current.isDevelopment else {
      throw MonitorError.message(
        current.protection ?? "Bu süreç geliştirme aracı olarak tanınmıyor.")
    }
  }
  public static func stop(_ expected: ProcessSample) throws {
    try validateStop(expected, current: read(expected.id.pid))
    guard kill(expected.id.pid, SIGTERM) == 0 else {
      throw MonitorError.message(String(cString: strerror(errno)))
    }
  }
  /// The nearest CLI or app boundary owns the grouping. An independently launched app
  /// keeps its identity even when its parent is an AI agent.
  private static func applicationIdentity(
    for sample: ProcessSample, samples: [Int32: ProcessSample],
    applications: [String: ApplicationIdentity]
  ) -> ApplicationIdentity? {
    var candidate: ProcessSample? = sample
    var seen = Set<ProcessIdentity>()
    for _ in 0..<32 {
      guard let current = candidate, seen.insert(current.id).inserted else { break }
      if let app = ResourceSummary.appPath(current.path) {
        return applications[app] ?? ApplicationIdentity(bundleID: nil, path: app)
      }
      if let agent = current.agentSession { return ApplicationIdentity(agent: agent) }
      candidate = samples[current.parent]
    }
    return nil
  }
  public static func rows(
    _ samples: [ProcessSample], previous: [ProcessIdentity: ProcessSample], elapsed: Double,
    hotCounts: inout [ProcessIdentity: Int], projectRoots: [String: ProjectRoot] = [:],
    applications: [String: ApplicationIdentity] = [:]
  ) -> [ProcessRow] {
    let lookup = Dictionary(uniqueKeysWithValues: samples.map { ($0.id.pid, $0) })
    let ids = Set(samples.map(\.id))
    hotCounts = hotCounts.filter { ids.contains($0.key) }
    return samples.map { sample in
      let cpu: Double? = previous[sample.id].flatMap { old in
        guard elapsed > 0, sample.cpuTime >= old.cpuTime else { return nil }
        return Double(sample.cpuTime - old.cpuTime) / (elapsed * 1_000_000_000) * 100
      }
      hotCounts[sample.id] = (cpu ?? 0) >= 25 ? (hotCounts[sample.id] ?? 0) + 1 : 0
      var reasons: [String] = []
      if let footprint = sample.footprint, footprint >= 1_073_741_824 {
        reasons.append("1 GiB üzerinde bellek yükü")
      }
      if (hotCounts[sample.id] ?? 0) >= 3 { reasons.append("3 ölçümdür CPU ≥ %25") }
      let identity = applicationIdentity(for: sample, samples: lookup, applications: applications)
      let parent = lookup[sample.parent]
      let owner =
        parent.map {
          applicationIdentity(for: $0, samples: lookup, applications: applications)?.familyName
            ?? $0.name
        } ?? "—"
      var row = ProcessRow(sample: sample, cpu: cpu, reasons: reasons, owner: owner)
      row.diskActivity = DiskActivity.between(previous[sample.id], sample)
      row.project = ProjectResolver.hint(for: sample, samples: lookup, roots: projectRoots)
      row.applicationKey = identity?.familyID ?? sample.path
      row.applicationName = identity?.familyName ?? sample.name
      row.applicationComponent = identity?.component ?? sample.name
      return row
    }
  }
}
public enum MonitorError: LocalizedError {
  case message(String)
  public var errorDescription: String? {
    switch self {
    case .message(let message): message
    }
  }
}
