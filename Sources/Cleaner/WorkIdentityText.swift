import CleanerCore
import Foundation

/// Evidence only: a process start time is not a chat or session identity.
enum WorkIdentityText {
  static func summary(_ row: ProcessRow) -> String {
    let start = Date(timeIntervalSince1970: Double(row.id.seconds))
    let time = start.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.locale))
    return row.applicationName + " · " + L10n.text("Başlangıç: ", "Started: ") + time
  }
}
