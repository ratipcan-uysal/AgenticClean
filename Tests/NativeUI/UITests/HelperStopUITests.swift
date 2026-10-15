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
