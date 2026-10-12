import XCTest

@testable import OfflineReader

final class BackgroundDiagnosticsTests: XCTestCase {
  func testBoundedEventsAndClearingFenceOldRunCompletion() throws {
    let suite = "BackgroundDiagnosticsTest-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let diagnostics = BackgroundDiagnostics(defaults: defaults)
    let old = diagnostics.begin()
    let current = diagnostics.begin()
    diagnostics.finish(old, outcome: "expired")
    XCTAssertEqual(
      defaults.dictionary(forKey: "backgroundDiagnostics")?["backgroundOutcome"] as? String,
      "running")
    diagnostics.finish(current, outcome: "success")
    let expiring = diagnostics.begin()
    diagnostics.finish(expiring, outcome: "expired")
    diagnostics.finish(expiring, outcome: "cancelled")
    XCTAssertEqual(
      defaults.dictionary(forKey: "backgroundDiagnostics")?["backgroundOutcome"] as? String,
      "expired")
    for _ in 0..<60 { diagnostics.record("environment") }
    let report = try XCTUnwrap(defaults.dictionary(forKey: "backgroundDiagnostics"))
    XCTAssertEqual((report["events"] as? [[String: Any]])?.count, 40)
    XCTAssertEqual(report["backgroundOutcome"] as? String, "expired")
    diagnostics.clear()
    diagnostics.finish(current, outcome: "expired")
    XCTAssertNil(defaults.dictionary(forKey: "backgroundDiagnostics"))
  }
  func testErrorsContainCodesAndNeverPrivateMessages() {
    XCTAssertEqual(
      BackgroundDiagnostics.errorCode(APIError(message: "synthetic-private-message", status: 401)),
      "http_401")
    XCTAssertEqual(BackgroundDiagnostics.errorCode(URLError(.timedOut)), "network_-1001")
    XCTAssertEqual(
      BackgroundDiagnostics.errorCode(NSError(domain: "synthetic-private-domain", code: 7)),
      "other_error")
  }
  func testRelaunchDistinguishesAnUnfinishedRunFromAnActiveRun() throws {
    let suite = "BackgroundDiagnosticsTest-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let diagnostics = BackgroundDiagnostics(defaults: defaults)
    let run = diagnostics.begin()
    diagnostics.launch(probeActive: false)
    diagnostics.finish(run, outcome: "success")
    let report = try XCTUnwrap(defaults.dictionary(forKey: "backgroundDiagnostics"))
    XCTAssertEqual(report["backgroundOutcome"] as? String, "previous_run_incomplete")
    XCTAssertEqual(report["diagnosticProbeActive"] as? Bool, false)
  }
}
