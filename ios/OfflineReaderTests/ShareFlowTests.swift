import ReaderCore
import XCTest

@testable import OfflineReader

/// The share sheet's decisions and wording, plus its automatic-save safety cases.
@MainActor final class ShareFlowTests: XCTestCase {
  private let one = URL(string: "https://example.com/one")!
  private let two = URL(string: "https://example.com/two")!

  func testSavesAutomaticallyOnlyWithOneLinkAndAUsableSession() {
    XCTAssertEqual(
      ShareFlow.start(signedIn: true, sessionUsable: true, candidates: [one]), .save(one))
    XCTAssertEqual(
      ShareFlow.start(signedIn: true, sessionUsable: true, candidates: [one, two]), .choose)
    XCTAssertEqual(
      ShareFlow.start(signedIn: false, sessionUsable: true, candidates: [one]), .signIn)
    XCTAssertEqual(
      ShareFlow.start(signedIn: true, sessionUsable: false, candidates: [one]), .signIn)
    XCTAssertEqual(
      ShareFlow.start(signedIn: true, sessionUsable: true, candidates: []), .unreadable)
    let six = (1...6).map { URL(string: "https://example.com/\($0)")! }
    XCTAssertEqual(
      ShareFlow.start(signedIn: true, sessionUsable: true, candidates: six), .unreadable)
  }

  func testStatusSeparatesSentFromQueuedAndNeverClaimsADownload() {
    let account = ShareAccount(
      owner: "synthetic-owner", generation: "g", server: URL(string: "https://example.com")!)
    func record(_ state: SharedSaveState, error: String? = nil, server: String? = nil) -> SharedSave
    {
      var item = SharedSave(id: UUID().uuidString, account: account, url: one)
      item.state = state
      item.error = error
      item.serverStatus = server
      return item
    }
    XCTAssertEqual(ShareFlow.status(for: record(.accepted, server: "queued")), ShareFlow.saved)
    XCTAssertEqual(ShareFlow.status(for: record(.accepted, server: "ready")), ShareFlow.saved)
    XCTAssertEqual(
      ShareFlow.status(for: record(.accepted, server: "already_saved")), ShareFlow.alreadySaved)
    XCTAssertEqual(
      ShareFlow.status(for: record(.accepted, server: "bookmark")), ShareFlow.notPrepared)
    XCTAssertEqual(
      ShareFlow.status(for: record(.queued, error: ShareServicesText.offline)),
      ShareFlow.savedOffline)
    XCTAssertEqual(ShareFlow.status(for: record(.queued)), ShareFlow.savedOffline)
    XCTAssertEqual(
      ShareFlow.status(for: record(.queued, error: "Server busy")), ShareFlow.keptOnDevice)
    XCTAssertEqual(ShareFlow.status(for: record(.authenticationRequired)), ShareFlow.signIn)
    let rejected = ShareFlow.status(for: record(.rejected, error: "Unsupported page"))
    XCTAssertEqual(rejected.text, "Couldn't save")
    XCTAssertEqual(rejected.detail, "Unsupported page")
    XCTAssertTrue(rejected.canRetry)
    XCTAssertFalse(rejected.dismisses)
    XCTAssertTrue(ShareFlow.status(for: nil).canRetry)
    XCTAssertEqual(ShareFlow.status(for: ShareError.changedAccount), ShareFlow.signIn)
    XCTAssertEqual(ShareFlow.status(for: ShareError.authenticationRequired), ShareFlow.signIn)
    XCTAssertTrue(ShareFlow.status(for: URLError(.timedOut)).canRetry)
    for status in [
      ShareFlow.saving, ShareFlow.saved, ShareFlow.alreadySaved, ShareFlow.savedOffline,
      ShareFlow.keptOnDevice, ShareFlow.notPrepared, ShareFlow.signIn, ShareFlow.failed(),
    ] {
      let words = status.announcement.lowercased()
      XCTAssertFalse(words.contains("download"), status.text)
      XCTAssertFalse(words.contains("readable"), status.text)
      XCTAssertFalse(words.contains("https://"), status.text)
    }
  }

  func testOnlySuccessfulSavesCloseTheSheetAndVoiceOverGetsLonger() throws {
    XCTAssertEqual(ShareFlow.dismissDelay(for: ShareFlow.saved, voiceOver: false), 1.0)
    let offline = try XCTUnwrap(
      ShareFlow.dismissDelay(for: ShareFlow.savedOffline, voiceOver: false))
    XCTAssertGreaterThan(offline, 1.0)
    let spoken = try XCTUnwrap(ShareFlow.dismissDelay(for: ShareFlow.saved, voiceOver: true))
    XCTAssertGreaterThan(spoken, 1.0)
    for status in [ShareFlow.saving, ShareFlow.notPrepared, ShareFlow.signIn, ShareFlow.failed()] {
      XCTAssertNil(ShareFlow.dismissDelay(for: status, voiceOver: false), status.text)
    }
  }

  func testTitleIgnoresLinksAndCollapsesWhitespace() {
    XCTAssertEqual(ShareFlow.title(from: [nil, "  A  page\n title "]), "A page title")
    XCTAssertEqual(ShareFlow.title(from: ["https://example.com/one", "Title"]), "Title")
    XCTAssertEqual(ShareFlow.title(from: ["Read https://example.com/one"]), nil)
    XCTAssertNil(ShareFlow.title(from: ["", String(repeating: "x", count: 301)]))
    XCTAssertEqual(ShareFlow.host(URL(string: "https://www.example.com/a")!), "example.com")
  }

  func testCancelDuringGraceQueuesNothing() async throws {
    let (store, credentials, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    var requests = 0
    let model = ShareSaveModel(
      snapshot: { credentials }, store: { store },
      submit: { _, _ in
        requests += 1
        return SaveResponse(submissionId: "s", status: "queued", duplicate: false)
      }, grace: .seconds(30))
    let task = Task { await model.run([item(one)]) }
    for _ in 0..<200 where model.status != ShareFlow.saving {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(model.status, ShareFlow.saving)
    XCTAssertNil(model.record)
    task.cancel()
    await task.value
    XCTAssertEqual(requests, 0)
    XCTAssertTrue(try store.records(credentials.account).isEmpty)
  }

  func testNoSessionOrAReplacedSessionAsksToOpenTheApp() async throws {
    let (store, credentials, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    var requests = 0
    let submit: (URL, String) async throws -> SaveResponse = { _, _ in
      requests += 1
      return SaveResponse(submissionId: "s", status: "queued", duplicate: false)
    }
    let signedOut = ShareSaveModel(
      snapshot: { nil }, store: { store }, submit: submit, grace: .zero)
    await signedOut.run([item(one)])
    XCTAssertEqual(signedOut.start, .signIn)
    XCTAssertEqual(signedOut.notice, ShareFlow.signInNotice)
    // The app rotated the session: the extension's copy no longer matches the queue.
    let stale = ShareCredentials(
      session: credentials.session,
      account: ShareAccount(
        owner: credentials.account.owner, generation: "old", server: credentials.account.server))
    let replaced = ShareSaveModel(
      snapshot: { stale }, store: { store }, submit: submit, grace: .zero)
    await replaced.run([item(one)])
    XCTAssertEqual(replaced.start, .signIn)
    XCTAssertNil(replaced.status)
    XCTAssertEqual(requests, 0)
    XCTAssertTrue(try store.records(credentials.account).isEmpty)
  }

  func testRetryAfterRejectionResendsTheSameKey() async throws {
    let (store, credentials, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    var keys: [String] = []
    var reject = true
    let model = ShareSaveModel(
      snapshot: { credentials }, store: { store },
      submit: { _, key in
        keys.append(key)
        if reject { throw APIError(message: "Synthetic rejection", status: 422) }
        return SaveResponse(submissionId: "s", status: "queued", duplicate: true)
      }, grace: .zero)
    await model.run([item(one)])
    XCTAssertEqual(model.status?.text, "Couldn't save")
    XCTAssertEqual(model.status?.detail, "Synthetic rejection")
    XCTAssertTrue(model.canRetry)
    reject = false
    await model.save()
    XCTAssertEqual(keys.count, 2)
    XCTAssertEqual(keys[0], keys[1])
    XCTAssertEqual(model.status, ShareFlow.saved)
    XCTAssertEqual(try store.records(credentials.account).count, 1)
  }

  func testLogoutDuringSubmissionAsksToSignInAgain() async throws {
    let (store, credentials, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    var signedIn = true
    let model = ShareSaveModel(
      snapshot: { signedIn ? credentials : nil }, store: { store },
      submit: { _, _ in
        try store.deactivate()
        signedIn = false
        return SaveResponse(submissionId: "stale", status: "queued", duplicate: false)
      }, grace: .zero)
    await model.run([item(one)])
    XCTAssertEqual(model.status, ShareFlow.signIn)
    XCTAssertFalse(model.canRetry)
  }

  private func item(_ url: URL) -> NSExtensionItem {
    let input = NSExtensionItem()
    input.attachments = [NSItemProvider(object: url as NSURL)]
    return input
  }
  private func fixture() throws -> (SharedSaveStore, ShareCredentials, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try SharedSaveStore(root: directory)
    let account = ShareAccount(
      owner: "synthetic-owner", generation: "current", server: URL(string: "https://example.com")!)
    try store.activate(account)
    let credentials = ShareCredentials(
      session: Session(token: "synthetic", ownerId: account.owner), account: account)
    return (store, credentials, directory)
  }
}
