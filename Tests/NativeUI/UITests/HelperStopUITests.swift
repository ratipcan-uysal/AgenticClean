import Foundation
import XCTest

/// Exercises the production SwiftUI views in an isolated synthetic application.
/// It does not require Codex/ChatGPT to be installed and never signals a real process.
@MainActor final class HelperStopUITests: XCTestCase {
  private var app: XCUIApplication!
  private var logURL: URL!
  private var applicationURL: URL!
  private var expectedBuildID = ""

  // XCTest synchronous lifecycle overrides are nonisolated. Keep UI fixture ownership
  // entirely in each @MainActor test instead of crossing that inherited boundary.
  private func prepareFixture() throws {
    continueAfterFailure = true
    logURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("cleaner-native-ui-" + UUID().uuidString + ".json")
    let configuration = Bundle(for: HelperStopUITests.self)
    guard let path = configuration.object(forInfoDictionaryKey: "CleanerNativeUIHarnessPath") as? String,
      let buildID = configuration.object(forInfoDictionaryKey: "CleanerNativeUIBuildID") as? String,
      !buildID.isEmpty else {
      XCTFail("Missing generated fixture build identity")
      throw FixtureFailure.unavailable("generated build identity")
    }
    applicationURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    expectedBuildID = buildID
    guard let product = Bundle(url: applicationURL),
      product.bundleIdentifier?.hasPrefix("local.cleaner.native-ui-harness.") == true,
      product.object(forInfoDictionaryKey: "CleanerNativeUIBuildID") as? String == buildID else {
      XCTFail("The requested app product does not match this test build")
      throw FixtureFailure.unavailable("fixture product identity")
    }
    // Pin the actual product URL. Bundle-ID lookup can select an older generated app
    // registered by LaunchServices, even while the newest source compiled successfully.
    app = XCUIApplication(url: applicationURL)
    app.launchEnvironment["CLEANER_UI_FIXTURE_LOG"] = logURL.path
    try launchFixture()
  }
  private func finishFixture() {
    if let app {
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
      app.terminate()
    }
    if let logURL {
      try? FileManager.default.removeItem(at: logURL)
      try? FileManager.default.removeItem(atPath: logURL.path + ".identity.json")
    }
  }
  private enum FixtureFailure: Error { case unavailable(String) }
  private func captureDiagnostics(_ reason: String) {
    guard let app else { return }
    let tree = XCTAttachment(string: reason + "\n\n" + app.debugDescription)
    tree.name = "Native UI hierarchy — " + reason
    tree.lifetime = .keepAlways
    add(tree)
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = "Native UI failure — " + reason
    image.lifetime = .keepAlways
    add(image)
  }
  private func requireExists(_ target: XCUIElement, _ description: String,
                             timeout: TimeInterval = 8,
                             file: StaticString = #filePath, line: UInt = #line) throws {
    guard target.waitForExistence(timeout: timeout) else {
      captureDiagnostics("Missing " + description)
      XCTFail("Missing " + description, file: file, line: line)
      throw FixtureFailure.unavailable(description)
    }
  }
  private func launchFixture() throws {
    try? FileManager.default.removeItem(atPath: logURL.path + ".identity.json")
    app.launch()
    let ready = app.staticTexts["harness.ready"]
    try requireExists(ready, "ready fixture", timeout: 10)
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@ OR value == %@",
                             "Synthetic fixture ready", "ready"), object: ready)
    guard XCTWaiter.wait(for: [expectation], timeout: 10) == .completed else {
      captureDiagnostics("Fixture ready state did not complete")
      XCTFail("Fixture ready state did not complete")
      throw FixtureFailure.unavailable("ready state")
    }
    let identity = try Data(contentsOf: URL(fileURLWithPath: logURL.path + ".identity.json"))
    let attachment = XCTAttachment(data: identity, uniformTypeIdentifier: "public.json")
    attachment.name = "Running fixture build identity and window bounds"
    attachment.lifetime = .keepAlways
    add(attachment)
    guard let metadata = try JSONSerialization.jsonObject(with: identity) as? [String: Any],
      metadata["buildID"] as? String == expectedBuildID,
      metadata["bundlePath"] as? String == applicationURL.path,
      let width = metadata["contentWidth"] as? Double,
      let height = metadata["contentHeight"] as? Double,
      width <= 1200, height <= 800 else {
      captureDiagnostics("Running fixture identity or window bounds mismatch")
      XCTFail("Running fixture must match this build and fit within 1200x800")
      throw FixtureFailure.unavailable("running build identity")
    }
  }
  private func visibleText(_ target: XCUIElement) -> String {
    [target.label, target.value as? String ?? ""].joined(separator: " ")
  }
  private func approvalContainer() throws -> XCUIElement {
    // AppKit alerts may expose an AXDialog or AXSheet depending on window presentation.
    for candidate in [app.alerts.firstMatch, app.dialogs.firstMatch, app.sheets.firstMatch]
    where candidate.exists { return candidate }
    captureDiagnostics("Missing native approval container")
    XCTFail("Missing native approval container")
    throw FixtureFailure.unavailable("approval container")
  }
  private func approvalText(_ container: XCUIElement, contains text: String) -> XCUIElement {
    container.staticTexts.containing(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
  }
  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }
  private func click(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) throws {
    let target = element(identifier)
    try requireExists(target, identifier, file: file, line: line)
    target.click()
  }
  private func fixtureCommand(_ title: String) throws {
    let menu = app.menuBars.menuBarItems["Fixture"]
    try requireExists(menu, "native Fixture menu")
    menu.click()
    let command = app.menuItems[title]
    try requireExists(command, "Fixture command: " + title)
    command.click()
  }
  private func waitForLabel(_ identifier: String, _ label: String) throws {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", label), object: element(identifier))
    guard XCTWaiter.wait(for: [expectation], timeout: 8) == .completed else {
      captureDiagnostics("Fixture state did not change: " + identifier)
      XCTFail("Expected fixture state label: " + label)
      throw FixtureFailure.unavailable(identifier)
    }
  }
  private func showProject() throws {
    try click("harness.project")
    try requireExists(app.checkBoxes["helpers.choice.900001"], "first helper checkbox")
  }
  func testLiveReadingsKeepRowsAndExpandedProjectFixedUntilExplicitResort() throws {
    defer { finishFixture() }
    try prepareFixture()
    try fixtureCommand("Show list")
    let projects = app.buttons["Projects"]
    try requireExists(projects, "Projects sidebar")
    projects.click()
    try click("group.row./synthetic/cleaner-native-ui-project")
    // The narrow CI window shows the inspector; closing it returns to the
    // still-expanded list without resetting its expansion or scroll identity.
    let close = app.buttons["Close details"]
    try requireExists(close, "Close group details")
    close.click()
    let first = element("process.row.900001")
    let second = element("process.row.900002")
    try requireExists(first, "first displayed process")
    try requireExists(second, "second displayed process")
    let firstY = first.frame.minY
    let secondY = second.frame.minY
    try fixtureCommand("Change readings")
    try requireExists(element("list.pending"), "pending new-task count")
    XCTAssertTrue(visibleText(element("list.pending")).contains("1 new"))
    XCTAssertEqual(first.frame.minY, firstY, accuracy: 1)
    XCTAssertEqual(second.frame.minY, secondY, accuracy: 1)
    XCTAssertTrue(visibleText(first).contains("4 MB"), visibleText(first))
    XCTAssertFalse(element("process.row.900004").exists)
    try fixtureCommand("Remove first task")
    let closed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Closed", "Closed"),
      object: first)
    XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 8), .completed)
    XCTAssertEqual(first.frame.minY, firstY, accuracy: 1)
    XCTAssertEqual(second.frame.minY, secondY, accuracy: 1)
    try assertNoActions()
    try click("list.resort")
    try requireExists(element("process.row.900004"), "new process after explicit re-sort")
    XCTAssertFalse(first.exists)
    XCTAssertFalse(element("list.pending").exists)
    XCTAssertLessThan(element("process.row.900004").frame.minY, second.frame.minY)
    try assertNoActions()
  }
  private var closedSimulatorID: String { "00000000-0000-0000-0000-000000000021" }
  private var activeSimulatorID: String { "00000000-0000-0000-0000-000000000022" }
  private var unknownSimulatorID: String { "00000000-0000-0000-0000-000000000023" }
  private func showSimulatorStorage() throws {
    let disk = app.buttons["Disk Space"]
    try requireExists(disk, "Disk Space sidebar")
    disk.click()
    try click("disk.simulators")
    try requireExists(app.checkBoxes["simstorage.choice." + closedSimulatorID], "closed simulator")
    try waitEnabled("simstorage.refresh")
  }
  private func waitSimulatorResult(_ fragment: String) throws {
    let result = element("simstorage.result." + closedSimulatorID)
    try requireExists(result, "simulator action result")
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment), object: result)
    guard XCTWaiter.wait(for: [expectation], timeout: 8) == .completed else {
      captureDiagnostics("Wrong simulator result: " + visibleText(result))
      XCTFail("Expected result: " + fragment)
      throw FixtureFailure.unavailable("simulator result")
    }
  }
  func testSimulatorInventoryReviewCancelAndRefreshKeepActionsExplicit() throws {
    defer { finishFixture() }
    try prepareFixture(); try showSimulatorStorage()
    let choice = app.checkBoxes["simstorage.choice." + closedSimulatorID]
    XCTAssertFalse(try checkboxState(choice))
    XCTAssertFalse(app.checkBoxes["simstorage.choice." + activeSimulatorID].isEnabled)
    XCTAssertTrue(app.checkBoxes["simstorage.choice." + unknownSimulatorID].exists)
    XCTAssertFalse(element("simstorage.reviewDelete").isEnabled)
    XCTAssertTrue(visibleText(element("simstorage.summary")).contains("1 sizes unknown"))
    choice.click()
    try click("simstorage.reviewDelete")
    try requireExists(element("simstorage.approval"), "destructive simulator review")
    XCTAssertTrue(element("simstorage.approved." + closedSimulatorID).exists)
    XCTAssertFalse(element("simstorage.approved." + activeSimulatorID).exists)
    XCTAssertFalse(element("simstorage.approved." + unknownSimulatorID).exists)
    try click("simstorage.cancel"); try assertNoActions()
    try click("simstorage.refresh"); try waitEnabled("simstorage.refresh")
    XCTAssertFalse(try checkboxState(choice))
    try assertNoActions()
  }
  func testSimulatorDeleteOnlySelectedClosedDeviceAndVerifyResult() throws {
    defer { finishFixture() }
    try prepareFixture(); try showSimulatorStorage()
    try click("simstorage.choice." + closedSimulatorID)
    try click("simstorage.reviewDelete"); try click("simstorage.confirm")
    try waitSimulatorResult("Deleted")
    XCTAssertFalse(app.checkBoxes["simstorage.choice." + closedSimulatorID].exists)
    XCTAssertTrue(app.checkBoxes["simstorage.choice." + activeSimulatorID].exists)
    XCTAssertTrue(app.checkBoxes["simstorage.choice." + unknownSimulatorID].exists)
    let calls = try JSONSerialization.jsonObject(with: Data(contentsOf: logURL)) as? [[String: String]]
    XCTAssertEqual(calls, [["kind": "simulator", "action": "delete", "udid": closedSimulatorID]])
  }
  func testSimulatorEraseRetainsDeviceAndDoesNotDeleteAnotherDevice() throws {
    defer { finishFixture() }
    try prepareFixture(); try showSimulatorStorage()
    try click("simstorage.choice." + closedSimulatorID)
    try click("simstorage.reviewErase"); try click("simstorage.confirm")
    try waitSimulatorResult("Contents erased")
    let choice = app.checkBoxes["simstorage.choice." + closedSimulatorID]
    XCTAssertTrue(choice.exists)
    XCTAssertFalse(try checkboxState(choice))
    let calls = try JSONSerialization.jsonObject(with: Data(contentsOf: logURL)) as? [[String: String]]
    XCTAssertEqual(calls, [["kind": "simulator", "action": "erase", "udid": closedSimulatorID]])
  }
  func testSimulatorBootedAfterReviewIsSkippedWithoutMutation() throws {
    defer { finishFixture() }
    try prepareFixture(); try showSimulatorStorage()
    try click("simstorage.choice." + closedSimulatorID)
    try click("simstorage.reviewDelete")
    try fixtureCommand("Boot reviewed device")
    try click("simstorage.confirm")
    try waitSimulatorResult("Skipped")
    XCTAssertTrue(app.checkBoxes["simstorage.choice." + closedSimulatorID].exists)
    XCTAssertFalse(app.checkBoxes["simstorage.choice." + closedSimulatorID].isEnabled)
    try assertNoActions()
  }
  private func checkboxState(_ checkbox: XCUIElement) throws -> Bool {
    let value = checkbox.value
    if let number = value as? NSNumber, [0, 1].contains(number.intValue) {
      return number.intValue == 1
    }
    if let string = value as? String, ["0", "1"].contains(string) {
      return string == "1"
    }
    captureDiagnostics("Unexpected checkbox value: " + String(describing: value))
    XCTFail("Checkbox value must explicitly represent 0 or 1; got " + String(describing: value))
    throw FixtureFailure.unavailable("checkbox state")
  }
  private func assertUnchecked(_ pid: Int, file: StaticString = #filePath, line: UInt = #line) throws {
    let checkbox = app.checkBoxes["helpers.choice.\(pid)"]
    try requireExists(checkbox, "helper checkbox \(pid)", file: file, line: line)
    XCTAssertFalse(try checkboxState(checkbox), file: file, line: line)
  }
  private func assertNoActions(file: StaticString = #filePath, line: UInt = #line) throws {
    let calls = try JSONSerialization.jsonObject(with: Data(contentsOf: logURL)) as? [[String: String]]
    XCTAssertEqual(calls?.count, 0, file: file, line: line)
  }
  private func waitEnabled(_ identifier: String, enabled: Bool = true) throws {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == %@", NSNumber(value: enabled)), object: element(identifier))
    guard XCTWaiter.wait(for: [expectation], timeout: 8) == .completed else {
      captureDiagnostics("Unexpected enabled state: " + identifier)
      XCTFail("Unexpected enabled state: " + identifier)
      throw FixtureFailure.unavailable(identifier)
    }
  }

  func testSingleProcessEntryOffersSeparateHelperReviewUnchecked() throws {
    defer { finishFixture() }
    try prepareFixture()
    try click("process.helperReview")
    try assertUnchecked(900001)
    XCTAssertFalse(app.checkBoxes["helpers.choice.900002"].exists,
                   "Single-process review must not silently include another helper")
    XCTAssertFalse(element("helpers.review").isEnabled)
    XCTAssertTrue(element("helpers.disabledReason").exists)
    try click("project.refresh")
    try waitEnabled("project.refresh")
    try assertUnchecked(900001)
    XCTAssertFalse(app.checkBoxes["helpers.choice.900002"].exists,
                   "Refreshing a single-helper review must preserve its original scope")
    XCTAssertFalse(element("project.stop").exists,
                   "Refreshing a single-helper review must not expose normal project stopping")
    try click("helpers.choice.900001")
    try click("helpers.review")
    try requireExists(element("helpers.confirm"), "single-helper approval")
    let approval = try approvalContainer()
    XCTAssertFalse(approvalText(approval, contains: "900002").exists)
    XCTAssertFalse(approvalText(approval, contains: "900003").exists)
    try click("helpers.cancel")
    try assertNoActions()
  }

  func testSelectionSecondApprovalCancelAndRefreshReset() throws {
    defer { finishFixture() }
    try prepareFixture()
    try showProject()
    try assertUnchecked(900001)
    try assertUnchecked(900002)
    try click("helpers.choice.900001")
    try waitEnabled("helpers.review")
    try click("helpers.review")
    try requireExists(element("helpers.confirm"), "helper approval")
    let alert = try approvalContainer()
    XCTAssertTrue(approvalText(alert, contains: "900001").exists)
    XCTAssertFalse(approvalText(alert, contains: "900002").exists)
    try click("helpers.cancel")
    try assertNoActions()
    XCTAssertTrue(try checkboxState(app.checkBoxes["helpers.choice.900001"]))
    try click("project.refresh")
    try waitEnabled("project.refresh")
    try assertUnchecked(900001)
    try assertUnchecked(900002)
    XCTAssertFalse(element("helpers.review").isEnabled)
    try assertNoActions()
  }

  func testPausedMonitoringExplainsDisabledHelperAction() throws {
    defer { finishFixture() }
    try prepareFixture()
    try showProject()
    try click("helpers.choice.900001")
    try waitEnabled("helpers.review")
    try fixtureCommand("Pause monitoring")
    try waitForLabel("harness.pause", "Resume")
    try waitEnabled("helpers.review", enabled: false)
    let reason = element("helpers.disabledReason")
    try requireExists(reason, "helper disabled reason")
    XCTAssertTrue(visibleText(reason).localizedCaseInsensitiveContains("paused"), visibleText(reason))
    try assertNoActions()
  }

  func testFailedScanExplainsDisabledHelperAction() throws {
    defer { finishFixture() }
    try prepareFixture()
    try showProject()
    try click("helpers.choice.900001")
    try waitEnabled("helpers.review")
    try fixtureCommand("Fail scan")
    try waitForLabel("harness.failScan", "Scan failed")
    try waitEnabled("helpers.review", enabled: false)
    let reason = element("helpers.disabledReason")
    try requireExists(reason, "helper disabled reason")
    XCTAssertTrue(visibleText(reason).localizedCaseInsensitiveContains("scan")
                  || visibleText(reason).localizedCaseInsensitiveContains("refresh"), visibleText(reason))
    try assertNoActions()
  }

  func testOnlySelectedHelperStopsAndSessionHistoryClearsAfterRelaunch() throws {
    defer { finishFixture() }
    try prepareFixture()
    try showProject()
    try click("helpers.choice.900001")
    try click("helpers.review")
    try click("helpers.confirm")
    try requireExists(element("project.results"), "project results", timeout: 10)
    let summary = element("project.results")
    let resultExpectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                             "1 closed", "1 closed"), object: summary)
    guard XCTWaiter.wait(for: [resultExpectation], timeout: 8) == .completed else {
      captureDiagnostics("Selected-helper result must report one closed process")
      XCTFail("Expected one closed process; got " + visibleText(summary))
      throw FixtureFailure.unavailable("one closed result")
    }
    let calls = try JSONSerialization.jsonObject(with: Data(contentsOf: logURL)) as? [[String: String]]
    XCTAssertEqual(calls, [["kind": "helper", "pid": "900001"]])
    try click("project.dismiss")
    try click("harness.operations")
    try requireExists(element("operations.title"), "session operations title")
    XCTAssertFalse(element("operations.empty").exists)
    XCTAssertTrue(element("operations.sessionNotice").exists)
    try click("operations.dismiss")
    app.terminate()
    try launchFixture()
    try click("harness.operations")
    try requireExists(element("operations.empty"), "empty operations after relaunch")
    try assertNoActions()
  }

  func testNormalProjectStopLeavesHelpersUnselectedAndUntouched() throws {
    defer { finishFixture() }
    try prepareFixture()
    try showProject()
    try assertUnchecked(900001)
    try assertUnchecked(900002)
    try click("project.stop")
    try requireExists(element("project.results"), "project results", timeout: 10)
    let calls = try JSONSerialization.jsonObject(with: Data(contentsOf: logURL)) as? [[String: String]]
    XCTAssertEqual(calls, [["kind": "project", "pid": "900003"]])
  }
}
