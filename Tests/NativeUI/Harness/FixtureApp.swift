import AppKit
import Darwin
import SwiftUI
@testable import CleanerCore

/// A synthetic source and action sink. No native process is created, signalled or terminated.
/// Production view/core files are compiled unchanged into this separate test application.
actor FixtureWorld: SnapshotSource, ProjectProcessActions {
  static let projectPath = "/synthetic/cleaner-native-ui-project"
  private var rows: [ProcessRow]
  private var stopped: Set<ProcessIdentity> = []
  private var calls: [[String: String]] = []
  private var failScan = false
  private let logURL: URL

  init(logURL: URL) {
    self.logURL = logURL
    rows = [Self.row(900001, helper: true), Self.row(900002, helper: true),
            Self.row(900003, helper: false)]
    try? Data("[]".utf8).write(to: logURL, options: .atomic)
  }
  nonisolated private static func row(
    _ pid: Int32, helper: Bool, megabytes: UInt64 = 8, cpu: Double = 0
  ) -> ProcessRow {
    let path = helper
      ? "/SyntheticApps/VerifiedFixture.app/Contents/Resources/cua_node/bin/node"
      : "/synthetic/bin/python3"
    var sample = ProcessSample(
      id: ProcessIdentity(pid: pid, seconds: 1), parent: 1, uid: getuid(), path: path,
      memory: 8 * 1_048_576)
    sample.cwd = projectPath
    sample.footprint = megabytes * 1_048_576
    // Internal, test-only identity construction; native production scans still require signatures.
    if helper { sample.managedHelperIdentity = ManagedHelperIdentity.candidate(for: path) }
    var row = ProcessRow(
      sample: sample, cpu: cpu, reasons: [], owner: "Codex",
      project: ProjectHint(path: projectPath, sourcePID: pid, inherited: false,
                           hasProjectMarker: true))
    row.applicationKey = "fixture.codex"
    row.applicationName = "Codex"
    row.applicationComponent = "Synthetic fixture"
    return row
  }
  func capture() throws -> Snapshot {
    if failScan { throw MonitorError.message("Synthetic scan failure") }
    let visible = rows.filter { !stopped.contains($0.id) }
    return Snapshot(
      date: Date(), uptime: ProcessInfo.processInfo.systemUptime, interval: 5, duration: 0,
      system: SystemSample(ticks: nil, memory: nil), swap: nil, cpu: nil, paging: nil,
      rows: visible, applications: ResourceSummary.groups(visible),
      projects: ResourceSummary.projectGroups(visible), unreadableCount: 0,
      quality: .partial, sustainedCPU: false)
  }
  func resetBaseline() {}
  func setScanFailure(_ value: Bool) { failScan = value }
  func changeReadings() {
    rows = [Self.row(900001, helper: true, megabytes: 4, cpu: 20),
            Self.row(900002, helper: true, megabytes: 64, cpu: 40),
            Self.row(900003, helper: false),
            Self.row(900004, helper: false, megabytes: 128)]
  }
  func removeFirstTask() { stopped.insert(rows[0].id) }
  func stop(_ sample: ProcessSample) throws { try record(sample, kind: "project") }
  func stop(_ sample: ProcessSample, projectPath: String) throws {
    guard projectPath == Self.projectPath else { throw MonitorError.message("Wrong fixture project") }
    try record(sample, kind: "project")
  }
  func stopManagedHelper(_ sample: ProcessSample, projectPath: String) throws {
    guard projectPath == Self.projectPath, sample.allowsSeparateHelperStop else {
      throw MonitorError.message("Invalid fixture helper action")
    }
    try record(sample, kind: "helper")
  }
  private func record(_ sample: ProcessSample, kind: String) throws {
    guard rows.contains(where: { $0.id == sample.id }) else {
      throw MonitorError.message("Identity is outside the fixture")
    }
    stopped.insert(sample.id)
    calls.append(["kind": kind, "pid": String(sample.id.pid)])
    try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys])
      .write(to: logURL, options: .atomic)
  }
  func presence(_ identity: ProcessIdentity) -> ProcessPresence {
    stopped.contains(identity) ? .absent : .sameIdentity
  }
}

@MainActor final class FixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var window: NSWindow?
  private let world: FixtureWorld
  private let model: Dashboard
  private let identityURL: URL

  override init() {
    // This bundle's preferences are separate from the real AgenticClean application's domain.
    UserDefaults.standard.set("en", forKey: "cleanerLanguage")
    UserDefaults.standard.set("overview", forKey: "mainSection")
    UserDefaults.standard.set(ViewMode.applications.rawValue, forKey: "viewMode")
    UserDefaults.standard.set(SortOrder.memory.rawValue, forKey: "sortOrder")
    let path = ProcessInfo.processInfo.environment["CLEANER_UI_FIXTURE_LOG"]
      ?? NSTemporaryDirectory() + "cleaner-ui-fixture-" + UUID().uuidString + ".json"
    let world = FixtureWorld(logURL: URL(fileURLWithPath: path))
    self.world = world
    self.identityURL = URL(fileURLWithPath: path + ".identity.json")
    self.model = Dashboard(source: world, defaults: .standard, projectActions: world)
    self.model.interval = 300
    super.init()
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    let menu = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit Native UI Fixture", action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")
    appItem.submenu = appMenu
    menu.addItem(appItem)
    // Fixture controls must remain reachable while a production detail window
    // covers the main toolbar on smaller CI displays.
    let fixtureItem = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")
    let fixtureMenu = NSMenu(title: "Fixture")
    for (title, action) in [
      ("Pause monitoring", #selector(pauseMonitoring)),
      ("Resume monitoring", #selector(resumeMonitoring)),
      ("Fail scan", #selector(failScan)),
      ("Show list", #selector(showList)),
      ("Change readings", #selector(changeReadings)),
      ("Remove first task", #selector(removeFirstTask)),
    ] {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      fixtureMenu.addItem(item)
    }
    fixtureItem.submenu = fixtureMenu
    menu.addItem(fixtureItem)
    NSApp.mainMenu = menu
    showWindow()
  }
  @objc private func pauseMonitoring() { model.paused = true }
  @objc private func resumeMonitoring() { model.paused = false }
  @objc private func failScan() {
    Task { await world.setScanFailure(true); await model.refresh() }
  }
  @objc private func showList() { model.selection = nil }
  @objc private func changeReadings() {
    Task { await world.changeReadings(); await model.refresh() }
  }
  @objc private func removeFirstTask() {
    Task { await world.removeFirstTask(); await model.refresh() }
  }
  private func showWindow() {
    if window == nil {
      let controller = NSHostingController(
        rootView: FixtureRoot(model: model, world: world).frame(minWidth: 1000, minHeight: 700))
      // Available since macOS 13: prevent SwiftUI's ideal content size from resizing
      // this explicitly bounded fixture window when the process inspector appears.
      controller.sizingOptions = []
      let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
      let width = min(1200, max(1000, visible.width - 40))
      let height = min(800, max(700, visible.height - 60))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.title = "AgenticClean Native UI Fixture"
      window.identifier = NSUserInterfaceItemIdentifier("native-ui-fixture-window")
      window.isReleasedWhenClosed = false
      window.contentViewController = controller
      // Assigning an NSHostingController can immediately adopt its ideal size.
      // Apply the actual host bounds afterwards, as the production AppDelegate does.
      window.contentMinSize = NSSize(width: min(1000, width), height: min(700, height))
      window.contentMaxSize = NSSize(width: width, height: height)
      window.setContentSize(NSSize(width: width, height: height))
      controller.view.layoutSubtreeIfNeeded()
      window.delegate = self
      window.setFrameOrigin(NSPoint(
        x: max(visible.minX, visible.midX - window.frame.width / 2),
        y: max(visible.minY, visible.midY - window.frame.height / 2)))
      self.window = window
    }
    window?.makeKeyAndOrderFront(nil)
    if let window, let content = window.contentView {
      let visible = window.screen?.visibleFrame ?? .zero
      let metadata: [String: Any] = [
        "buildID": Bundle.main.object(forInfoDictionaryKey: "CleanerNativeUIBuildID") as? String ?? "missing",
        "bundleIdentifier": Bundle.main.bundleIdentifier ?? "missing",
        "bundlePath": Bundle.main.bundleURL.resolvingSymlinksInPath().path,
        "executablePath": Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? "missing",
        "pid": ProcessInfo.processInfo.processIdentifier,
        "contentWidth": content.bounds.width, "contentHeight": content.bounds.height,
        "frameX": window.frame.minX, "frameY": window.frame.minY,
        "frameWidth": window.frame.width, "frameHeight": window.frame.height,
        "screenX": visible.minX, "screenY": visible.minY,
        "screenWidth": visible.width, "screenHeight": visible.height,
      ]
      if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
        try? data.write(to: identityURL, options: .atomic)
      }
      NSLog("Native UI fixture identity %@", metadata.description)
    }
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showWindow()
    return true
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main enum NativeUIFixtureApp {
  @MainActor static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = FixtureDelegate()
    application.delegate = delegate
    // NSApplication.delegate is weak; the explicit lifetime also owns the main fixture window.
    withExtendedLifetime(delegate) { application.run() }
  }
}

private struct FixtureRoot: View {
  @Bindable var model: Dashboard
  let world: FixtureWorld
  @State private var ready = false
  @State private var panel = DetailWindowPresenter()
  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text(ready ? "Synthetic fixture ready" : "Preparing synthetic fixture")
          .accessibilityIdentifier(ready ? "harness.ready" : "harness.preparing")
          .accessibilityLabel(ready ? "Synthetic fixture ready" : "Preparing synthetic fixture")
          .accessibilityValue(ready ? "ready" : "preparing")
        HStack(spacing: 10) {
        Button("Project review") {
          Task {
            model.request.mode = .projects
            await model.refresh()
            let key = FixtureWorld.projectPath
            model.selection = .group(key)
            if let plan = model.projectStopPlan(for: key) {
              panel.show(title: "Synthetic project review",
                         content: ProjectStopView(model: model, plan: plan), onClose: {})
            }
          }
        }.accessibilityIdentifier("harness.project")
        Button("Session operations") {
          panel.show(title: "Synthetic session operations",
                     content: OperationsView(model: model), onClose: {})
        }.accessibilityIdentifier("harness.operations")
        Button(model.paused ? "Resume" : "Pause") {
          model.paused.toggle()
        }.accessibilityIdentifier("harness.pause")
        Button(model.scanError == nil ? "Fail scan" : "Scan failed") {
          Task { await world.setScanFailure(true); await model.refresh() }
        }.accessibilityIdentifier("harness.failScan")
        Spacer(minLength: 0)
        }
      }.font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
      Divider()
      DashboardView(model: model)
    }
    .task {
      await model.refresh()
      if let first = model.presentation.rows.first(where: { $0.id.pid == 900001 }) {
        model.selection = .process(first.id)
      }
      // Ready means the real Dashboard has a populated, selected helper snapshot.
      ready = model.selectedRow?.id.pid == 900001 && model.scanError == nil
        && !model.preparing && model.snapshot?.rows.count == 3
    }
  }
}
