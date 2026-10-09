import AppKit
import CleanerCore
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let dashboard = Dashboard()
  private var panel: NSWindow?
  func applicationDidFinishLaunching(_ notification: Notification) {
    dashboard.start()
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    if !ProcessInfo.processInfo.arguments.contains("--background") { showPanel() }
  }
  @objc private func willSleep() { dashboard.sleep() }
  @objc private func didWake() { dashboard.wake() }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showPanel()
    return true
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationWillTerminate(_ notification: Notification) { dashboard.stopMonitoring() }
  func windowWillClose(_ notification: Notification) {
    // Release charts and list views while the window is closed; sampling continues.
    panel?.contentViewController = nil
    panel = nil
  }
  func showPanel() {
    if panel == nil {
      let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
      let window = NSWindow(
        contentRect: NSRect(
          x: 0, y: 0, width: min(1200, available.width), height: min(820, available.height)),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.title = L10n.text("AgenticClean — Kaynak kullanımı", "AgenticClean — Resource usage")
      window.contentViewController = NSHostingController(
        rootView: DashboardView(
          model: dashboard,
          languageChanged: { [weak self] in
            self?.panel?.title = L10n.text("AgenticClean — Kaynak kullanımı", "AgenticClean — Resource usage")
          }))
      window.setContentSize(
        NSSize(width: min(1200, available.width), height: min(800, available.height - 30)))
      window.minSize = NSSize(width: 940, height: 600)
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.center()
      panel = window
    }
    panel?.deminiaturize(nil)
    panel?.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}
@main struct CleanerApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @AppStorage("cleanerLanguage") private var language = "tr"
  var body: some Scene {
    MenuBarExtra {
      Button(L10n.text("Kontrol panelini aç", "Open dashboard")) { delegate.showPanel() }
        .keyboardShortcut("o")
      Divider()
      Text(L10n.core(delegate.dashboard.snapshot?.diagnosis ?? "İlk ölçüm bekleniyor"))
      ForEach(Array(delegate.dashboard.presentation.workloads.prefix(3))) { work in
        Button {
          if let row = work.primary { delegate.dashboard.selection = .process(row.id) }
          delegate.showPanel()
        } label: {
          Text("\(L10n.core(work.group.name)) · \(Format.bytes(work.group.memory))")
        }
      }
      Divider()
      Button(
        delegate.dashboard.paused
          ? L10n.text("Ölçüme devam et", "Resume monitoring")
          : L10n.text("Ölçümü duraklat", "Pause monitoring")
      ) {
        delegate.dashboard.paused.toggle()
      }
      Button(L10n.text("Şimdi tara", "Scan now")) { Task { await delegate.dashboard.refresh() } }
      Divider()
      Button(L10n.text("AgenticClean’den çık", "Quit AgenticClean")) { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    } label: {
      Label("AgenticClean", systemImage: "waveform.path.ecg")
    }
  }
}
