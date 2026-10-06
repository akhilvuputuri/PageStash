import XCTest

@testable import ReaderCore

final class LocalStoreTests: XCTestCase {
  var root: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
  private func asset(_ bytes: Data, role: String = "content") -> Asset {
    let id = UUID().uuidString.lowercased()
    return Asset(
      id: id, role: role, mime: role == "content" ? "text/html" : "image/webp", size: bytes.count,
      sha256: digest(bytes), filename: role == "content" ? "article.html" : "\(id).webp",
      url: URL(string: "https://reader.example/v1/downloads/test")!)
  }
  private func install(_ data: Data, asset: Asset, item: ReadingItem, store: LocalStore) throws {
    let temporary = root.appendingPathComponent("temporary")
    try data.write(to: temporary)
    try store.accept(temporary, itemID: item.id, version: item.contentVersion, asset: asset)
  }
  func testTextAndImagesRemainAvailableAfterRestart() throws {
    let html = Data("<p>A real offline article</p>".utf8)
    let image = Data([1, 2, 3, 4])
    let content = asset(html)
    let picture = asset(image, role: "image")
    let item = ReadingItem(id: UUID().uuidString, title: "Offline", assets: [content, picture])
    var store: LocalStore? = try LocalStore(root: root)
    try store!.apply(LibraryPage(items: [item], cursor: 1))
    XCTAssertEqual(store!.offlineState(item), .notDownloaded)
    try install(html, asset: content, item: item, store: store!)
    XCTAssertEqual(store!.offlineState(item), .textOnly)
    try install(image, asset: picture, item: item, store: store!)
    XCTAssertEqual(store!.offlineState(item), .ready)
    store = nil
    let reopened = try LocalStore(root: root)
    XCTAssertEqual(reopened.offlineState(item), .ready)
    XCTAssertNotNil(try reopened.readerURL(item.id))
    XCTAssertTrue(try reopened.search("article").contains(item.id))
  }
  func testCorruptionAndNewVersionNeverReplaceExistingReadableCopy() throws {
    let old = Data("<p>Original</p>".utf8)
    let new = Data("<p>New version</p>".utf8)
    let a = asset(old)
    let b = asset(new)
    let id = UUID().uuidString
    let first = ReadingItem(id: id, title: "First", assets: [a])
    let second = ReadingItem(id: id, title: "Second", contentVersion: 2, revision: 2, assets: [b])
    let store = try LocalStore(root: root)
    try store.apply(LibraryPage(items: [first], cursor: 1))
    try install(old, asset: a, item: first, store: store)
    try store.apply(LibraryPage(items: [second], cursor: 2))
    XCTAssertThrowsError(try install(Data("corrupted".utf8), asset: b, item: second, store: store))
    XCTAssertEqual(try String(contentsOf: store.readerURL(id)!), "<p>Original</p>")
    try install(new, asset: b, item: second, store: store)
    XCTAssertEqual(try store.installedVersion(id), 2)
  }
  func testPendingEditsSurviveRefreshAndAcknowledgementRace() throws {
    let id = UUID().uuidString
    let item = ReadingItem(id: id, title: "Reading", assets: [])
    let store = try LocalStore(root: root)
    try store.apply(LibraryPage(items: [item], cursor: 1))
    try store.edit(id, ItemPatch(progress: 0.5))
    let sent = try XCTUnwrap(store.pendingEdits().first)
    try store.edit(id, ItemPatch(progress: 0.75, collections: ["Research"]))
    try store.acknowledge(sent)
    XCTAssertEqual(try store.pendingEdits().count, 1)
    try store.apply(LibraryPage(items: [item], cursor: 2))
    XCTAssertEqual(try store.item(id)?.progress, 0.75)
    let latest = try XCTUnwrap(store.pendingEdits().first)
    try store.acknowledge(latest)
    XCTAssertTrue(try store.pendingEdits().isEmpty)
  }
  func testDeletedItemRejectsLateDownload() throws {
    let bytes = Data("article".utf8)
    let content = asset(Data("article".utf8))
    let item = ReadingItem(id: UUID().uuidString, title: "Gone", assets: [content])
    let store = try LocalStore(root: root)
    try store.apply(LibraryPage(items: [item], cursor: 1))
    try store.edit(item.id, ItemPatch(deleted: true))
    XCTAssertThrowsError(try install(bytes, asset: content, item: item, store: store))
    XCTAssertNil(try store.readerURL(item.id))
    XCTAssertTrue(try store.items().isEmpty)
  }
  func testRemoveDownloadDoesNotDeleteBookmarkAndPreventsAutomaticRedownload() throws {
    let bytes = Data("article".utf8)
    let content = asset(Data("article".utf8))
    let item = ReadingItem(id: UUID().uuidString, title: "Keep", assets: [content])
    let store = try LocalStore(root: root)
    try store.apply(LibraryPage(items: [item], cursor: 1))
    try install(bytes, asset: content, item: item, store: store)
    try store.removeDownload(item.id)
    XCTAssertEqual(try store.items().count, 1)
    XCTAssertNil(try store.readerURL(item.id))
    XCTAssertTrue(store.isPaused(item.id))
    XCTAssertThrowsError(try install(bytes, asset: content, item: item, store: store))
    try store.resumeDownload(item.id)
    XCTAssertFalse(store.isPaused(item.id))
  }
  func testUnsafeManifestFilenameRejected() throws {
    let content = Asset(
      id: UUID().uuidString, role: "image", mime: "image/webp", size: 1, sha256: "x",
      filename: "../../outside", url: URL(string: "https://reader.example")!)
    XCTAssertFalse(content.safeFilename)
  }
}
