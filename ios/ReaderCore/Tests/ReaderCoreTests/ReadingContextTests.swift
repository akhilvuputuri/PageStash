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

  func testFeatureFlagIsRemembered() throws {
    var store: LocalStore? = try LocalStore(root: root)
    XCTAssertFalse(store!.readingContextEnabled)
    store!.readingContextEnabled = true
    store = nil
    XCTAssertTrue(try LocalStore(root: root).readingContextEnabled)
  }
}
