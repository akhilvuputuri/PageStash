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
