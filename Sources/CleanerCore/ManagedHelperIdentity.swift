import Darwin
import Foundation
import Security

/// An identity obtained from a vendor-signed application and its exact bundled executable.
/// Stored on a process sample: presentation never performs filesystem or signing work.
struct ManagedHelperIdentity: Equatable, Sendable {
  enum Component: String, Sendable {
    case node = "cua_node/bin/node"
    case nodeREPL = "cua_node/bin/node_repl"
    case coordinator = "codex-cli/CodexCLI.app/Contents/MacOS/codex"

    var signingIdentifier: String {
      switch self {
      case .node: "node"
      case .nodeREPL: "node_repl"
      case .coordinator: "codex"
      }
    }
    var allowsSeparateStop: Bool { self != .coordinator }
  }

  let executablePath: String
  let applicationPath: String
  let component: Component

  static func candidate(for path: String) -> Self? {
    // Canonical spelling and exact suffix prevent sibling directories or path traversal
    // from being treated as the application's managed runtime.
    guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardized.path == path else {
      return nil
    }
    for component in [Component.node, .nodeREPL, .coordinator] {
      let suffix = "/Contents/Resources/" + component.rawValue
      guard path.hasSuffix(suffix) else { continue }
      let application = String(path.dropLast(suffix.count))
      guard application.hasSuffix(".app"), application != ".app" else { return nil }
      return Self(executablePath: path, applicationPath: application, component: component)
    }
    return nil
  }
}

/// Reads are performed during process sampling, never by UI computed properties. The
/// small cache is shared across scans and invalidated by inode, size, mtime and ctime
/// of the application executable, Info.plist and helper. A changed file is reverified.
final class ManagedHelperIdentityResolver: @unchecked Sendable {
  static let shared = ManagedHelperIdentityResolver()
  typealias Verify = @Sendable (ManagedHelperIdentity) -> Bool

  private struct FileStamp: Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int

    init?(path: String) {
      var value = stat()
      guard lstat(path, &value) == 0,
        value.st_mode & S_IFMT == S_IFREG else { return nil }
      device = value.st_dev
      inode = value.st_ino
      size = value.st_size
      modifiedSeconds = value.st_mtimespec.tv_sec
      modifiedNanos = value.st_mtimespec.tv_nsec
      changedSeconds = value.st_ctimespec.tv_sec
      changedNanos = value.st_ctimespec.tv_nsec
    }
  }
  private struct Fingerprint: Equatable {
    let executablePath: String
    let applicationExecutable: FileStamp
    let info: FileStamp
    let helper: FileStamp

    init?(_ identity: ManagedHelperIdentity) {
      let infoPath = identity.applicationPath + "/Contents/Info.plist"
      guard let info = FileStamp(path: infoPath), info.size <= 1_048_576,
        let data = FileManager.default.contents(atPath: infoPath),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let dictionary = plist as? [String: Any],
        let executable = dictionary["CFBundleExecutable"] as? String,
        !executable.isEmpty, executable != ".", executable != "..",
        !executable.contains("/"),
        let applicationExecutable = FileStamp(
          path: identity.applicationPath + "/Contents/MacOS/" + executable),
        let helper = FileStamp(path: identity.executablePath)
      else { return nil }
      self.executablePath = executable
      self.info = info
      self.applicationExecutable = applicationExecutable
      self.helper = helper
    }
  }
  private struct Entry {
    let fingerprint: Fingerprint
    let accepted: Bool
  }
  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private let verify: Verify

  init(verify: @escaping Verify = ManagedHelperIdentityResolver.verifySignature) {
    self.verify = verify
  }

  func resolve(path: String) -> ManagedHelperIdentity? {
    guard let identity = ManagedHelperIdentity.candidate(for: path) else { return nil }
    lock.lock()
    defer { lock.unlock() }
    guard let before = Fingerprint(identity) else {
      entries.removeValue(forKey: path)
      return nil
    }
    if let cached = entries[path], cached.fingerprint == before {
      return cached.accepted ? identity : nil
    }
    let accepted = verify(identity)
    // Do not cache or authorize a bundle altered while the signature was checked.
    guard Fingerprint(identity) == before else {
      entries.removeValue(forKey: path)
      return nil
    }
    if entries.count >= 64 { entries.removeAll(keepingCapacity: true) }
    entries[path] = Entry(fingerprint: before, accepted: accepted)
    return accepted ? identity : nil
  }

  private static func verifySignature(_ identity: ManagedHelperIdentity) -> Bool {
    let vendor = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"2DC432GLL2\""
    let application = "(identifier \"com.openai.codex\" or identifier \"com.openai.chat\") and " + vendor
    let helper = "identifier \"\(identity.component.signingIdentifier)\" and " + vendor
    return check(path: identity.applicationPath, requirement: application)
      && check(path: identity.executablePath, requirement: helper)
  }

  private static func check(path: String, requirement: String) -> Bool {
    var code: SecStaticCode?
    var rule: SecRequirement?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
      let code,
      SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess,
      let rule else { return false }
    // Validate executable bytes and Developer ID trust. Resources unrelated to the
    // selected helper are deliberately excluded; that helper is validated separately.
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSDoNotValidateResources)
    return SecStaticCodeCheckValidity(code, flags, rule) == errSecSuccess
  }
}
