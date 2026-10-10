import AppKit
import CleanerCore
import SwiftUI

struct ListenerInspector: View {
  let row: ProcessRow
  @State private var listeners: [LocalListener] = []
  @State private var inspected = false
  @State private var busy = false
  @State private var failed = false
  var body: some View {
    if row.sample.isDevelopment {
      VStack(alignment: .leading, spacing: 8) {
        Button(L10n.text("Bu işin kullandığı portları bul", "Find ports used by this work")) {
          Task {
            busy = true
            defer { busy = false }
            do {
              listeners = try await readListeners(row.sample)
              failed = false
            } catch {
              listeners = []
              failed = true
            }
            inspected = true
          }
        }.disabled(busy)
        if inspected && listeners.isEmpty {
          Text(
            failed
              ? L10n.text("Dinleyici bilgisi okunamadı.", "Listener information could not be read.")
              : L10n.text(
                "Bu süreçte doğrulanmış loopback TCP dinleyicisi yok.",
                "No verified loopback TCP listener on this process.")
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(listeners) { listener in
          if let url = listener.url {
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("Port \(listener.port) bu süreç tarafından kullanılıyor", "Port \(listener.port) is used by this process")).font(.caption.weight(.medium))
                Text(url.absoluteString).font(.caption).textSelection(.enabled)
              }
              Button(L10n.text("Tarayıcıda aç", "Open in browser")) {
                Task {
                  guard await stillValid(listener) else {
                    failed = true
                    listeners = []
                    return
                  }
                  NSWorkspace.shared.open(url)
                }
              }.font(.caption)
            }
          }
        }
        if !listeners.isEmpty {
          Text(
            L10n.text(
              "Dinlenen port; HTTP desteği veya proje sahipliği kanıtı değildir.",
              "A listening port does not prove HTTP support or project ownership.")
          )
          .font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
  }
  @concurrent private func readListeners(_ sample: ProcessSample) async throws -> [LocalListener] {
    try ProcessMonitor.listeners(for: sample)
  }
  @concurrent private func stillValid(_ listener: LocalListener) async -> Bool {
    (try? ProcessMonitor.validateListener(listener)) == true
  }
}
