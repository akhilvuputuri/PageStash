import BackgroundTasks
import Foundation
import UIKit

/// Bounded local diagnostics. Never include URLs, credentials, item IDs or raw error messages.
final class BackgroundDiagnostics: @unchecked Sendable {
  static let shared = BackgroundDiagnostics()
  private let defaults: UserDefaults
  private let lock = NSLock()
  private let key = "backgroundDiagnostics"
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  func launch(probeActive: Bool) {
    lock.lock()
    var report = defaults.dictionary(forKey: key) ?? [:]
    if report["backgroundOutcome"] as? String == "running" {
      report["backgroundOutcome"] = "previous_run_incomplete"
    }
    report["diagnosticProbeActive"] = probeActive
    defaults.set(report, forKey: key)
    lock.unlock()
    record("launch")
  }
  func record(_ event: String, fields: [String: Any] = [:]) {
    lock.lock()
    defer { lock.unlock() }
    var report = defaults.dictionary(forKey: key) ?? [:]
    for (name, value) in fields { report[name] = value }
    var events = report["events"] as? [[String: Any]] ?? []
    events.append(["event": event, "at": Date().timeIntervalSince1970])
    report["events"] = Array(events.suffix(40))
    defaults.set(report, forKey: key)
  }
  func begin() -> String {
    let run = UUID().uuidString
    record(
      "background_started",
      fields: [
        "run": run, "backgroundStartedAt": Date().timeIntervalSince1970,
        "backgroundOutcome": "running", "backgroundFinishedAt": 0,
      ])
    return run
  }
  func finish(_ run: String, outcome: String) {
    lock.lock()
    defer { lock.unlock() }
    var report = defaults.dictionary(forKey: key) ?? [:]
    guard report["run"] as? String == run,
      report["backgroundOutcome"] as? String == "running"
    else { return }
    report["backgroundOutcome"] = outcome
    report["backgroundFinishedAt"] = Date().timeIntervalSince1970
    defaults.set(report, forKey: key)
  }
  func clear() {
    lock.lock()
    defer { lock.unlock() }
    defaults.removeObject(forKey: key)
  }
  static func errorCode(_ error: Error) -> String {
    if error is CancellationError { return "cancelled" }
    if let error = error as? APIError, let status = error.status { return "http_\(status)" }
    let error = error as NSError
    if error.domain == NSURLErrorDomain { return "network_\(error.code)" }
    return "other_error"
  }
  @MainActor static func snapshot() {
    shared.record(
      "environment",
      fields: [
        "refreshPermission": UIApplication.shared.backgroundRefreshStatus.rawValue,
        "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
        "applicationState": UIApplication.shared.applicationState.rawValue,
      ])
    BGTaskScheduler.shared.getPendingTaskRequests { requests in
      let refresh = requests.first { $0.identifier == AppDelegate.refreshID }
      shared.record(
        "pending_requests",
        fields: [
          "pendingRefresh": refresh != nil,
          "pendingEarliestAt": refresh?.earliestBeginDate?.timeIntervalSince1970 ?? 0,
          "pendingCheckedAt": Date().timeIntervalSince1970,
        ])
    }
  }
}
