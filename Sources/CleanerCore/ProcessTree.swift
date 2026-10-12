import Foundation

/// Display-only hierarchy; never expands the scope of a stop operation.
public struct ProcessTreeItem: Identifiable, Sendable {
  public let row: ProcessRow
  public let depth: Int
  public var id: ProcessIdentity { row.id }
  public static func ordered(_ rows: [ProcessRow]) -> [Self] {
    let byPID = Dictionary(rows.map { ($0.id.pid, $0) }, uniquingKeysWith: { first, _ in first })
    func parent(_ row: ProcessRow) -> ProcessRow? {
      guard let p = byPID[row.sample.parent], p.id != row.id,
        p.id.seconds < row.id.seconds || (p.id.seconds == row.id.seconds && p.id.microseconds <= row.id.microseconds)
      else { return nil }
      return p
    }
    var children: [ProcessIdentity: [ProcessRow]] = [:]
    for row in rows { if let p = parent(row) { children[p.id, default: []].append(row) } }
    var seen = Set<ProcessIdentity>()
    var result: [Self] = []
    func visit(_ row: ProcessRow, depth: Int) {
      guard seen.insert(row.id).inserted else { return }
      result.append(Self(row: row, depth: depth))
      for child in children[row.id] ?? [] { visit(child, depth: min(depth + 1, 8)) }
    }
    for row in rows where parent(row) == nil { visit(row, depth: 0) }
    for row in rows where !seen.contains(row.id) { visit(row, depth: 0) }
    return result
  }
}
