import ReaderCore
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import OfflineReader

@MainActor final class ShareSaveTests: XCTestCase {
  func testOfflineSubmissionAndRetryUseOnePersistedOperationKey() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SharedSaveStore(root: directory)
    let session = Session(token: "synthetic-test-credential", ownerId: "synthetic-owner")
    let account = ShareAccount(
      owner: session.ownerId, generation: "synthetic-generation",
      server: URL(string: "https://example.com")!)
    let credentials = ShareCredentials(session: session, account: account)
    try store.activate(account)
    let input = NSExtensionItem()
    input.attachments = [
      NSItemProvider(object: URL(string: "https://example.com/article")! as NSURL)
    ]
    var requests: [String] = []
    var offline = true
    let model = ShareSaveModel(
      snapshot: { credentials }, store: { store },
      submit: { url, key in
        XCTAssertEqual(url.absoluteString, "https://example.com/article")
        requests.append(key)
        if offline { throw URLError(.notConnectedToInternet) }
        return SaveResponse(
          submissionId: "synthetic-submission", status: "queued", duplicate: false)
      })
    await model.load([input])
    XCTAssertEqual(model.selected?.host, "example.com")
    XCTAssertTrue(model.canSave)
    await model.save()
    XCTAssertEqual(model.record?.state, .queued)
    XCTAssertTrue(model.message?.contains("Queued on this device") == true)
    let reopened = try SharedSaveStore(root: directory)
    XCTAssertEqual(try reopened.records(account).count, 1)
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    window.rootViewController = UIHostingController(
      rootView: ShareSaveView(model: model, finish: {}))
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    attach(window, name: "Synthetic browser share queued offline")
    offline = false
    await model.save()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[0], requests[1])
    XCTAssertEqual(model.record?.state, .accepted)
    XCTAssertTrue(model.message?.contains("does not mean downloaded") == true)
    try await Task.sleep(nanoseconds: 300_000_000)
    attach(window, name: "Synthetic browser share submitted for preparation")
  }
  private func attach(_ window: UIWindow, name: String) {
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testAmbiguousWebURLsRequireExplicitSelection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let account = ShareAccount(
      owner: "synthetic-owner", generation: "first", server: URL(string: "https://example.com")!)
    let credentials = ShareCredentials(
      session: Session(token: "synthetic", ownerId: account.owner), account: account)
    let store = try SharedSaveStore(root: directory)
    try store.activate(account)
    let input = NSExtensionItem()
    input.attachments = [
      NSItemProvider(object: URL(string: "https://example.com/one")! as NSURL),
      NSItemProvider(object: URL(string: "https://example.com/two")! as NSURL),
    ]
    let model = ShareSaveModel(snapshot: { credentials }, store: { store })
    await model.load([input])
    XCTAssertEqual(model.candidates.count, 2)
    XCTAssertNil(model.selected)
    XCTAssertFalse(model.canSave)
    XCTAssertTrue(try store.records(account).isEmpty)
  }
  func testCredentialRevocationStopsQueueAndStaleCompletionCannotCrossLogout() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let account = ShareAccount(
      owner: "synthetic-owner", generation: "first", server: URL(string: "https://example.com")!)
    let credentials = ShareCredentials(
      session: Session(token: "synthetic", ownerId: account.owner), account: account)
    let store = try SharedSaveStore(root: directory)
    try store.activate(account)
    let id = UUID().uuidString
    try store.enqueue(URL(string: "https://example.com/article")!, id: id, account: account)
    try await ShareServices.deliver(
      store, credentials: credentials, snapshot: { credentials },
      submit: { _, _ in throw APIError(message: "Session revoked", status: 401) })
    XCTAssertEqual(try store.records(account).first?.state, .authenticationRequired)
    XCTAssertThrowsError(try store.claim(account))
    let next = ShareAccount(owner: account.owner, generation: "next", server: account.server)
    try store.activate(next)
    try store.retry(id, account: next)
    let nextCredentials = ShareCredentials(session: credentials.session, account: next)
    try await ShareServices.deliver(
      store, credentials: nextCredentials, snapshot: { nextCredentials },
      submit: { _, _ in
        try store.deactivate()
        return SaveResponse(submissionId: "stale", status: "ready", duplicate: false)
      })
    XCTAssertThrowsError(try store.records(next))
  }
  func testLegacySessionDecodePreservesCacheAndRejectsRedirectingDestinations() throws {
    let value = try JSONDecoder().decode(
      Session.self,
      from: Data(
        "{\"token\":\"synthetic\",\"ownerId\":\"synthetic-owner\",\"generation\":\"old-cache\"}"
          .utf8))
    XCTAssertNil(value.storageId)
    XCTAssertEqual(value.generation, "old-cache")
    for raw in [
      "http://example.com", "https://user:password@example.com",
      "https://example.com?token=synthetic", "https://example.com#part",
    ] { XCTAssertThrowsError(try ShareContainer.server(raw)) }
  }
}
