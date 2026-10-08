import XCTest

@testable import ReaderCore

final class SharedSaveTests: XCTestCase {
  private func account(
    _ generation: String = "first", owner: String = "synthetic-owner",
    server: String = "https://example.com"
  ) -> ShareAccount {
    ShareAccount(owner: owner, generation: generation, server: URL(string: server)!)
  }
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
  private let link = URL(string: "https://example.com/article")!
  func testURLRepresentationsAreValidatedAndAmbiguityIsPreserved() throws {
    for input in [
      "file:///private/file", "javascript:bad()", "https://user:password@example.com",
      "https://example.com:8080", "not a url",
    ] { XCTAssertThrowsError(try SharedLink.validate(input)) }
    XCTAssertEqual(
      try SharedLink.validate("https://example.com/article?utm_source=x#title").absoluteString,
      link.absoluteString)
    XCTAssertEqual(
      SharedLink.candidates(urls: [link.absoluteString], texts: ["https://other.example/story"]),
      [link])
    XCTAssertTrue(
      SharedLink.candidates(urls: ["file:///private/file"], texts: [link.absoluteString]).isEmpty)
    XCTAssertEqual(
      SharedLink.candidates(
        urls: [], texts: ["Read https://example.com/one or https://example.com/two"]
      ).count, 2)
  }
  func testOfflineQueueAndOperationKeySurviveRestartAndUncertainResponse() throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let current = account()
    let id = UUID().uuidString
    let store = try SharedSaveStore(root: directory)
    try store.activate(current)
    try store.enqueue(link, id: id, account: current)
    let reopened = try SharedSaveStore(root: directory)
    let claimed = try XCTUnwrap(reopened.claim(current))
    try reopened.finish(claimed, state: .queued, error: "Unknown network result")
    let retry = try XCTUnwrap(store.claim(current))
    XCTAssertEqual(retry.id, id)
    try store.finish(
      retry, state: .accepted, submissionId: "synthetic-submission", serverStatus: "queued")
    XCTAssertEqual(try reopened.records(current).count, 1)
    try reopened.acknowledge(["synthetic-submission"], account: current)
    XCTAssertTrue(try store.records(current).isEmpty)
  }
  func testIndependentProcessesCannotClaimTwiceAndExpiredClaimRejectsLateAcknowledgement() throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let current = account()
    let first = try SharedSaveStore(root: directory)
    let second = try SharedSaveStore(root: directory)
    try first.activate(current)
    try first.enqueue(link, id: UUID().uuidString, account: current)
    let old = try XCTUnwrap(first.claim(current, now: Date(timeIntervalSince1970: 100)))
    XCTAssertNil(try second.claim(current, now: Date(timeIntervalSince1970: 101)))
    let fresh = try XCTUnwrap(second.claim(current, now: Date(timeIntervalSince1970: 221)))
    XCTAssertNotEqual(old.claim, fresh.claim)
    try first.finish(old, state: .accepted, submissionId: "stale", serverStatus: "ready")
    XCTAssertEqual(try second.records(current).first?.state, .sending)
    try second.finish(fresh, state: .accepted, submissionId: "fresh", serverStatus: "queued")
    XCTAssertEqual(try first.records(current).first?.submissionId, "fresh")
  }
  func testLogoutFencesStaleExtensionsAndAccountSwitchNeverRebindsOldLinks() throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SharedSaveStore(root: directory)
    let old = account()
    let id = UUID().uuidString
    try store.activate(old)
    try store.enqueue(link, id: id, account: old)
    let claimed = try XCTUnwrap(store.claim(old))
    try store.deactivate()
    XCTAssertThrowsError(try store.enqueue(link, id: id, account: old))
    let next = account("next", owner: "different-owner")
    try store.activate(next)
    try store.finish(claimed, state: .accepted, submissionId: "stale", serverStatus: "ready")
    XCTAssertTrue(try store.records(next).isEmpty)
    XCTAssertThrowsError(try store.retry(id, account: next))
  }
  func testRevokedCredentialsPauseAndReauthenticationRequiresExplicitRetry() throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SharedSaveStore(root: directory)
    let old = account()
    let id = UUID().uuidString
    try store.activate(old)
    try store.enqueue(link, id: id, account: old)
    let claimed = try XCTUnwrap(store.claim(old))
    try store.finish(claimed, state: .authenticationRequired, error: "Sign in required")
    XCTAssertThrowsError(try store.claim(old))
    let next = account("new-credential")
    try store.activate(next)
    XCTAssertNil(try store.claim(next), "New credentials must not automatically send old work")
    try store.retry(id, account: next)
    XCTAssertEqual(try store.claim(next)?.id, id)
  }
  func testChangingDestinationPurgesOtherDestinationsAndCancelledWorkCannotReturn() throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SharedSaveStore(root: directory)
    let old = account()
    let id = UUID().uuidString
    try store.activate(old)
    try store.enqueue(link, id: id, account: old)
    let next = account("next", server: "https://different.example")
    try store.activate(next)
    XCTAssertTrue(try store.records(next).isEmpty)
  }
}
