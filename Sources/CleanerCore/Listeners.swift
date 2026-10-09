import Foundation
import ProcessKit

/// Observed loopback listener belonging to one process incarnation and socket generation.
/// Wildcard and externally bound sockets are intentionally not provider endpoints.
public struct LocalListener: Hashable, Identifiable, Sendable {
  public let identity: ProcessIdentity
  public let host: String
  public let port: UInt16
  public let generation: UInt64
  public var id: String {
    "\(identity.pid):\(identity.seconds):\(identity.microseconds):\(host):\(port):\(generation)"
  }
  public var url: URL? {
    var components = URLComponents()
    components.scheme = "http"
    components.host = host.contains(":") ? "[\(host)]" : host
    components.port = Int(port)
    return components.url
  }
}

public enum ListenerError: Error, Sendable {
  case unreadable, identityChanged, limitExceeded
}

extension ProcessMonitor {
  /// Read-only FD inspection. Call off the main thread and only for recognized providers/runtimes.
  public static func listeners(for sample: ProcessSample) throws -> [LocalListener] {
    var buffer = [CleanerListener](repeating: CleanerListener(), count: 64)
    let count = buffer.withUnsafeMutableBufferPointer {
      cleaner_listeners(
        sample.id.pid, sample.id.seconds, sample.id.microseconds,
        $0.baseAddress, Int32($0.count))
    }
    switch count {
    case -2: throw ListenerError.identityChanged
    case -3: throw ListenerError.limitExceeded
    case ..<0: throw ListenerError.unreadable
    default: break
    }
    return buffer.prefix(Int(count)).map { raw in
      let host = withUnsafeBytes(of: raw.host) {
        String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
      }
      return LocalListener(
        identity: sample.id, host: host, port: raw.port, generation: raw.generation)
    }.sorted { ($0.host, $0.port, $0.generation) < ($1.host, $1.port, $1.generation) }
  }
  public static func validateListener(_ listener: LocalListener) throws -> Bool {
    guard let sample = read(listener.identity.pid), sample.id == listener.identity else {
      return false
    }
    return try listeners(for: sample).contains(listener)
  }
}
