import AppKit
import SwiftUI

private struct CloseCleanerPanelKey: EnvironmentKey {
  nonisolated static let defaultValue: @MainActor @Sendable () -> Void = {}
}
private struct CleanerPanelBusyKey: EnvironmentKey {
  nonisolated static let defaultValue: @MainActor @Sendable (Bool) -> Void = { _ in }
}
extension EnvironmentValues {
  var closeCleanerPanel: @MainActor @Sendable () -> Void {
    get { self[CloseCleanerPanelKey.self] }
    set { self[CloseCleanerPanelKey.self] = newValue }
  }
  var setCleanerPanelBusy: @MainActor @Sendable (Bool) -> Void {
    get { self[CleanerPanelBusyKey.self] }
    set { self[CleanerPanelBusyKey.self] = newValue }
  }
}

/// Keeps auxiliary content in an independent AppKit window instead of a SwiftUI sheet graph.
@MainActor final class DetailWindowPresenter: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private var didClose: (() -> Void)?
  private var busy = false

  func show<Content: View>(title: String, content: Content, onClose: @escaping () -> Void) {
    if window != nil {
      guard !busy else {
        window?.makeKeyAndOrderFront(nil)
        return
      }
      // Replacing a panel must not clear the newly requested destination.
      didClose = nil
      window?.close()
    }
    let parent = NSApp.keyWindow
    let panel = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    panel.title = title
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    let root =
      content
      .environment(\.closeCleanerPanel, { [weak self] in self?.close() })
      .environment(\.setCleanerPanelBusy, { [weak self] value in self?.setBusy(value) })
    let controller = NSHostingController(rootView: root)
    panel.contentViewController = controller
    let size = controller.view.fittingSize
    if size.width > 0 && size.height > 0 { panel.setContentSize(size) }
    if let parent {
      panel.setFrameOrigin(
        NSPoint(
          x: parent.frame.midX - panel.frame.width / 2,
          y: parent.frame.midY - panel.frame.height / 2))
    } else {
      panel.center()
    }
    window = panel
    didClose = onClose
    busy = false
    panel.makeKeyAndOrderFront(nil)
  }

  func updateTitle(_ title: String) { window?.title = title }

  func close(force: Bool = false) {
    guard force || !busy else { return }
    window?.close()
  }
  private func setBusy(_ value: Bool) {
    busy = value
    window?.standardWindowButton(.closeButton)?.isEnabled = !value
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
  func windowWillClose(_ notification: Notification) {
    let callback = didClose
    window?.delegate = nil
    window?.contentViewController = nil
    window = nil
    didClose = nil
    busy = false
    callback?()
  }
}
