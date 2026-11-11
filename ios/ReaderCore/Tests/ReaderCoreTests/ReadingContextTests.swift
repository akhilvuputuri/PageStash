import XCTest

@testable import ReaderCore

final class ReadingContextTests: XCTestCase {
  var root: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  func testDecodesTheServerShape() throws {
    let json = """
      {"item_id":"a","content_version":2,"generated_at":"2026-10-28T01:02:03.000Z",
       "model":"google/gemini-3.8-flash","history_count":7,"stale":true,"summary":"S",
       "builds_on":[{"item_id":"b","title":"Earlier","note":"How"}],"covered":[],
       "new_ideas":["One"]}
      """
    let context = try Wire.decoder().decode(ReadingContext.self, from: Data(json.utf8))
    XCTAssertEqual(context.historyCount, 7)
    XCTAssertTrue(context.stale)
    XCTAssertEqual(context.buildsOn, [.init(itemId: "b", title: "Earlier", note: "How")])
    XCTAssertEqual(context.newIdeas, ["One"])
  }

  func testSavedContextOpensOfflineOnlyForTheSameContent() throws {
    let item = ReadingItem(id: UUID().uuidString, title: "Article", contentVersion: 1, assets: [])
    var store: LocalStore? = try LocalStore(root: root)
    try store!.apply(LibraryPage(items: [item], cursor: 1))
    let context = ReadingContext(
      itemId: item.id, contentVersion: 1, generatedAt: "2026-10-28T00:00:00Z", model: "m",
      historyCount: 3, summary: "Builds on two articles.")
    try store!.saveReadingContext(context)
    store = nil
    let reopened = try LocalStore(root: root)
    XCTAssertEqual(try reopened.readingContext(item), context)
    let updated = ReadingItem(
      id: item.id, title: "Article", contentVersion: 2, revision: 2, assets: [])
    try reopened.apply(LibraryPage(items: [updated], cursor: 2))
    XCTAssertNil(try reopened.readingContext(updated), "New content needs a new context")
  }

  func testDeletingAnItemRemovesItsContext() throws {
    let item = ReadingItem(id: UUID().uuidString, title: "Deleted", assets: [])
    let store = try LocalStore(root: root)
    try store.apply(LibraryPage(items: [item], cursor: 1))
    try store.saveReadingContext(
      ReadingContext(
        itemId: item.id, contentVersion: 1, generatedAt: "", model: "m", historyCount: 0,
        summary: "S"))
    try store.edit(item.id, ItemPatch(deleted: true))
    let tombstone = ReadingItem(id: item.id, title: "Deleted", deleted: true, assets: [])
    XCTAssertNil(try store.readingContext(tombstone))
    XCTAssertThrowsError(
      try store.saveReadingContext(
        ReadingContext(
          itemId: UUID().uuidString, contentVersion: 1, generatedAt: "", model: "m",
          historyCount: 0, summary: "S")))
  }

  private func page(_ id: String, note: String) -> Data {
    Data(
      """
      {"items":[{"id":"\(id)","title":"Synced","kind":"article","status":"ready",
        "sources":[],"captured_at":"","content_version":1,"progress":0,"collections":[],
        "archived":false,"deleted":false,"revision":2,"assets":[],"reading_context":\(note)}],
       "cursor":2,"has_more":false}
      """.utf8)
  }

  func testSyncedContextIsStoredForOfflineUseAndNotKeptInTheItem() throws {
    let id = UUID().uuidString
    let note = """
      {"item_id":"\(id)","content_version":1,"generated_at":"2026-10-29T01:00:00.000Z",
       "model":"m","history_count":4,"stale":false,"summary":"From the server.",
       "builds_on":[],"covered":[],"new_ideas":[]}
      """
    let decoded = try Wire.decoder().decode(LibraryPage.self, from: page(id, note: note))
    let store = try LocalStore(root: root)
    try store.apply(decoded)
    let item = try XCTUnwrap(store.item(id))
    XCTAssertNil(item.syncedContext, "Items are stored without the note")
    XCTAssertEqual(try store.readingContext(item)?.summary, "From the server.")
    // A newer note made on this device survives an older synced copy.
    try store.saveReadingContext(
      ReadingContext(
        itemId: id, contentVersion: 1, generatedAt: "2026-10-29T02:00:00.000Z", model: "m",
        historyCount: 5, summary: "Regenerated here."))
    try store.apply(decoded)
    XCTAssertEqual(try store.readingContext(item)?.summary, "Regenerated here.")
  }

  func testANewerServerNoteNeverReplacesAnOnDeviceNote() throws {
    let id = UUID().uuidString
    let note = """
      {"item_id":"\(id)","content_version":1,"generated_at":"2026-11-11T09:00:00.000Z",
       "model":"m","history_count":4,"stale":false,"summary":"From the server.",
       "builds_on":[],"covered":[],"new_ideas":[]}
      """
    let decoded = try Wire.decoder().decode(LibraryPage.self, from: page(id, note: note))
    let store = try LocalStore(root: root)
    try store.apply(LibraryPage(items: [ReadingItem(id: id, title: "Synced", assets: [])], cursor: 1))
    let local = ReadingContext(
      itemId: id, contentVersion: 1, generatedAt: "2026-11-11T08:00:00.000Z",
      model: ReadingContext.onDeviceModel, historyCount: 2, summary: "Written on the phone.",
      keyPoints: ["One"], historyTotal: 2, excerpted: false)
    try store.saveReadingContext(local)
    try store.apply(decoded)
    let item = try XCTUnwrap(store.item(id))
    XCTAssertEqual(try store.readingContext(item), local, "Sync keeps the on-device note")
    let server = try XCTUnwrap(decoded.items.first?.syncedContext)
    XCTAssertEqual(try store.saveServerReadingContext(server), local, "So does a server refresh")
    // An explicit save (for example a server Regenerate) still replaces it.
    try store.saveReadingContext(server)
    XCTAssertEqual(try store.readingContext(item)?.summary, "From the server.")
    // And a server note for an older content version never lands.
    let older = ReadingContext(
      itemId: id, contentVersion: 0, generatedAt: "2026-11-12T00:00:00.000Z", model: "m",
      historyCount: 0, summary: "Old")
    XCTAssertEqual(try store.saveServerReadingContext(older)?.summary, "From the server.")
  }

  func testPrecedenceAndStalenessRules() {
    func note(_ model: String, _ at: String, version: Int = 1, total: Int? = nil) -> ReadingContext {
      ReadingContext(
        itemId: "a", contentVersion: version, generatedAt: at, model: model, historyCount: 1,
        summary: "S", historyTotal: total)
    }
    let server = note("google/x", "2026-11-11T10:00:00.000Z")
    XCTAssertTrue(ReadingContext.keepsStored(note("apple-on-device", "2026-11-01T00:00:00.000Z"), over: server))
    XCTAssertFalse(ReadingContext.keepsStored(note("google/x", "2026-11-01T00:00:00.000Z"), over: server))
    XCTAssertTrue(ReadingContext.keepsStored(note("google/x", "2026-11-12T00:00:00.000Z"), over: server))
    XCTAssertFalse(
      ReadingContext.keepsStored(note("apple-on-device", "2026-11-12T00:00:00.000Z", version: 0), over: server))
    let local = note("apple-on-device", "x", total: 3)
    XCTAssertFalse(local.stale(finishedCount: 3))
    XCTAssertTrue(local.stale(finishedCount: 4))
    XCTAssertFalse(server.stale(finishedCount: 99), "Server notes carry the server's own staleness")
    XCTAssertTrue(local.with(stale: true).stale)
  }

  func testOnDeviceFieldsRoundTripAndServerNotesOmitThem() throws {
    let local = ReadingContext(
      itemId: "a", contentVersion: 1, generatedAt: "t", model: "apple-on-device", historyCount: 1,
      summary: "S", keyPoints: ["k"], historyTotal: 4, excerpted: true)
    let data = try Wire.encoder().encode(local)
    XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"key_points\""))
    XCTAssertEqual(try Wire.decoder().decode(ReadingContext.self, from: data), local)
  }

  func testOpeningAndArticleTextComeFromTheDownload() throws {
    let store = try LocalStore(root: root)
    let html = Data("<html><head><title>x</title></head><body><p>Hello &amp; welcome.</p><p>Second.</p></body></html>".utf8)
    let asset = Asset(
      id: UUID().uuidString, role: "content", mime: "text/html", size: html.count,
      sha256: digest(html), filename: "article.html", url: URL(string: "https://example.com/a")!)
    let item = ReadingItem(id: UUID().uuidString, title: "T", assets: [asset])
    try store.apply(LibraryPage(items: [item], cursor: 1))
    XCTAssertNil(try store.articleText(item.id))
    let temporary = root.appendingPathComponent("tmp.html")
    try html.write(to: temporary)
    try store.accept(temporary, itemID: item.id, version: 1, asset: asset)
    XCTAssertEqual(try store.articleText(item.id), "Hello & welcome.\n\nSecond.")
    XCTAssertEqual(try store.openingText(item.id, characters: 9), "Hello & w")
  }

  func testAMalformedNoteDoesNotBreakTheLibraryPage() throws {
    let id = UUID().uuidString
    let decoded = try Wire.decoder().decode(
      LibraryPage.self, from: page(id, note: #"{"summary":42,"future":"shape"}"#))
    XCTAssertEqual(decoded.items.first?.id, id)
    XCTAssertNil(decoded.items.first?.syncedContext)
  }

  func testFeatureFlagIsRemembered() throws {
    var store: LocalStore? = try LocalStore(root: root)
    XCTAssertFalse(store!.readingContextEnabled)
    store!.readingContextEnabled = true
    store = nil
    XCTAssertTrue(try LocalStore(root: root).readingContextEnabled)
  }
}
