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
  func testWordCountsAreCapturedOnInstallAndClearedOnDelete() throws {
    let html = Data("<h1>Title</h1><p>One two three four five.</p><p>Six seven</p>".utf8)
    let content = asset(html)
    let item = ReadingItem(id: UUID().uuidString, title: "Counted", assets: [content])
    let waiting = ReadingItem(id: UUID().uuidString, title: "Not downloaded", assets: [])
    let store = try LocalStore(root: root)
    try store.apply(LibraryPage(items: [item, waiting], cursor: 1))
    XCTAssertTrue(try store.wordCounts().isEmpty, "Undownloaded articles have no length yet")
    try install(html, asset: content, item: item, store: store)
    let counts = try store.wordCounts()
    XCTAssertGreaterThanOrEqual(counts[item.id] ?? 0, 7)
    XCTAssertNil(counts[waiting.id])
    try store.edit(item.id, ItemPatch(deleted: true))
    XCTAssertNil(try store.wordCounts()[item.id])
  }
  func testSiteNameIsOptionalOnTheWire() throws {
    let json = Data(
      #"{"id":"a","title":"T","kind":"article","status":"ready","sources":[],"captured_at":"","content_version":1,"progress":0,"collections":[],"archived":false,"deleted":false,"revision":1,"assets":[]}"#
        .utf8)
    XCTAssertNil(try Wire.decoder().decode(ReadingItem.self, from: json).siteName)
    let named = Data(
      String(decoding: json, as: UTF8.self).replacingOccurrences(
        of: #""kind""#, with: #""site_name":"Example Daily","kind""#
      ).utf8)
    XCTAssertEqual(try Wire.decoder().decode(ReadingItem.self, from: named).siteName, "Example Daily")
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
  func testSameSizeCorruptionCannotReplaceReadableContent() throws {
    let original = Data("<p>Original</p>".utf8)
    let replacement = Data("<p>Replaced</p>".utf8)
    let corrupt = Data("<p>Corrupt!</p>".utf8)
    XCTAssertEqual(replacement.count, corrupt.count)
    let id = UUID().uuidString
    let firstAsset = asset(original)
    let nextAsset = asset(replacement)
    let first = ReadingItem(id: id, title: "Original", assets: [firstAsset])
    let next = ReadingItem(id: id, title: "Replacement", contentVersion: 2, assets: [nextAsset])
    let store = try LocalStore(root: root)
    try store.apply(LibraryPage(items: [first], cursor: 1))
    try install(original, asset: firstAsset, item: first, store: store)
    try store.apply(LibraryPage(items: [next], cursor: 2))
    XCTAssertThrowsError(try install(corrupt, asset: nextAsset, item: next, store: store))
    XCTAssertEqual(try Data(contentsOf: store.readerURL(id)!), original)
    XCTAssertFalse(store.hasAsset(next, nextAsset))
    try install(replacement, asset: nextAsset, item: next, store: store)
    XCTAssertEqual(try Data(contentsOf: store.readerURL(id)!), replacement)
  }

  func testLateOlderVersionDownloadCannotReplaceNewVersion() throws {
    let olderBytes = Data("<p>Older</p>".utf8)
    let newerBytes = Data("<p>Current</p>".utf8)
    let olderAsset = asset(olderBytes)
    let newerAsset = asset(newerBytes)
    let id = UUID().uuidString
    let older = ReadingItem(id: id, title: "Older", assets: [olderAsset])
    let newer = ReadingItem(id: id, title: "Current", contentVersion: 2, assets: [newerAsset])
    let store = try LocalStore(root: root)
    try store.apply(LibraryPage(items: [older], cursor: 1))
    try store.apply(LibraryPage(items: [newer], cursor: 2))
    try install(newerBytes, asset: newerAsset, item: newer, store: store)
    XCTAssertThrowsError(try install(olderBytes, asset: olderAsset, item: older, store: store))
    XCTAssertEqual(try store.installedVersion(id), 2)
    XCTAssertEqual(try Data(contentsOf: store.readerURL(id)!), newerBytes)
  }

  func testRejectedSyncPageDoesNotAdvanceCursorOrPartiallyChangeLibrary() throws {
    let id = UUID().uuidString
    let first = ReadingItem(id: id, title: "Original", assets: [])
    let changed = ReadingItem(id: id, title: "Changed", revision: 2, assets: [])
    let invalid = ReadingItem(id: "invalid-id", title: "Invalid", assets: [])
    let store = try LocalStore(root: root)
    try store.apply(LibraryPage(items: [first], cursor: 1))
    try store.edit(id, ItemPatch(progress: 0.6, collections: ["Research"]))
    XCTAssertThrowsError(try store.apply(LibraryPage(items: [changed, invalid], cursor: 3)))
    XCTAssertEqual(store.cursor, 1)
    XCTAssertEqual(try store.item(id)?.title, "Original")
    XCTAssertEqual(try store.item(id)?.progress, 0.6)
    XCTAssertEqual(try store.pendingEdits().count, 1)
    XCTAssertTrue(try store.search("Original").contains(id))
    XCTAssertFalse(try store.search("Changed").contains(id))
    try store.apply(LibraryPage(items: [changed], cursor: 3))
    XCTAssertEqual(store.cursor, 3)
    XCTAssertEqual(try store.item(id)?.collections, ["Research"])
  }

  func testOfflineEditsAndDownloadPauseSurviveRestartAndRefresh() throws {
    let item = ReadingItem(id: UUID().uuidString, title: "Reading", assets: [])
    var store: LocalStore? = try LocalStore(root: root)
    try store!.apply(LibraryPage(items: [item], cursor: 1))
    try store!.edit(item.id, ItemPatch(progress: 0.7, archived: true, collections: ["Later"]))
    try store!.removeDownload(item.id)
    store = nil
    let reopened = try LocalStore(root: root)
    XCTAssertTrue(reopened.isPaused(item.id))
    XCTAssertEqual(try reopened.pendingEdits().count, 1)
    try reopened.apply(LibraryPage(items: [item], cursor: 2))
    let restored = try XCTUnwrap(reopened.item(item.id))
    XCTAssertEqual(restored.progress, 0.7)
    XCTAssertTrue(restored.archived)
    XCTAssertEqual(restored.collections, ["Later"])
    XCTAssertTrue(reopened.isPaused(item.id))
  }
  func testFinishAndUndoSurviveRestartAndRetainPositionAndFiles() throws {
    let bytes = Data("<p>Keep reading this cached article</p>".utf8)
    let content = asset(bytes)
    let item = ReadingItem(id: UUID().uuidString, title: "Keep", assets: [content])
    var store: LocalStore? = try LocalStore(root: root)
    try store!.apply(LibraryPage(items: [item], cursor: 1))
    try install(bytes, asset: content, item: item, store: store!)
    try store!.recordReadingPosition(item.id, 0.42)
    let undo = try XCTUnwrap(store!.finishReading(item.id))
    XCTAssertEqual(try store!.item(item.id)?.progress, 1)
    XCTAssertTrue(try XCTUnwrap(store!.item(item.id)).archived)
    XCTAssertEqual(try store!.readingPosition(item.id), 0.42)
    store = nil
    let reopened = try LocalStore(root: root)
    XCTAssertEqual(try reopened.readingUndo(), undo)
    XCTAssertEqual(reopened.offlineState(try XCTUnwrap(reopened.item(item.id))), .ready)
    XCTAssertEqual(try Data(contentsOf: reopened.readerURL(item.id)!), bytes)
    XCTAssertTrue(try reopened.undoReading(undo.id))
    XCTAssertEqual(try reopened.item(item.id)?.progress, 0.42)
    XCTAssertFalse(try XCTUnwrap(reopened.item(item.id)).archived)
    XCTAssertEqual(try reopened.readingPosition(item.id), 0.42)
    XCTAssertNil(try reopened.readingUndo())
  }
  func testUndoPreservesNewCollectionsAndSurvivesAnOlderAcknowledgement() throws {
    let item = ReadingItem(id: UUID().uuidString, title: "Reading", assets: [])
    let store = try LocalStore(root: root)
    try store.apply(LibraryPage(items: [item], cursor: 1))
    try store.recordReadingPosition(item.id, 0.6)
    let undo = try XCTUnwrap(store.finishReading(item.id))
    let sent = try XCTUnwrap(store.pendingEdits().first)
    try store.edit(item.id, ItemPatch(collections: ["Research"]))
    XCTAssertTrue(try store.undoReading(undo.id))
    try store.acknowledge(sent)
    XCTAssertEqual(try store.pendingEdits().count, 1)
    let remote = ItemPatch(progress: 1, archived: true).applying(to: item)
    try store.apply(LibraryPage(items: [remote], cursor: 2))
    let restored = try XCTUnwrap(store.item(item.id))
    XCTAssertEqual(restored.progress, 0.6)
    XCTAssertFalse(restored.archived)
    XCTAssertEqual(restored.collections, ["Research"])
    XCTAssertEqual(try store.readingPosition(item.id), 0.6)
  }
  func testUndoStillWorksAfterItsFinishPatchWasSynced() throws {
    let item = ReadingItem(id: UUID().uuidString, title: "Reading", progress: 0.7, assets: [])
    let store = try LocalStore(root: root)
    try store.apply(LibraryPage(items: [item], cursor: 1))
    let undo = try XCTUnwrap(store.finishReading(item.id))
    try store.acknowledge(XCTUnwrap(store.pendingEdits().first))
    try store.apply(
      LibraryPage(items: [ItemPatch(progress: 1, archived: true).applying(to: item)], cursor: 2))
    XCTAssertTrue(try store.undoReading(undo.id))
    XCTAssertEqual(try store.item(item.id)?.progress, 0.7)
    XCTAssertEqual(try store.readingPosition(item.id), 0.7)
    XCTAssertEqual(try store.pendingEdits().count, 1)
  }
  func testNewerArchiveOrReadEditsAndDeletionInvalidateUndo() throws {
    for patch in [ItemPatch(archived: false), ItemPatch(progress: 0.8), ItemPatch(deleted: true)] {
      let item = ReadingItem(id: UUID().uuidString, title: "Reading", assets: [])
      let store = try LocalStore(root: root.appendingPathComponent(UUID().uuidString))
      try store.apply(LibraryPage(items: [item], cursor: 1))
      let undo = try XCTUnwrap(store.finishReading(item.id))
      try store.edit(item.id, patch)
      XCTAssertFalse(try store.undoReading(undo.id))
      XCTAssertNil(try store.readingUndo())
    }
  }
  func testRemoteArchiveChangeInvalidatesUndoWithoutResurrectingItem() throws {
    let item = ReadingItem(id: UUID().uuidString, title: "Reading", assets: [])
    let store = try LocalStore(root: root)
    try store.apply(LibraryPage(items: [item], cursor: 1))
    let undo = try XCTUnwrap(store.finishReading(item.id))
    try store.acknowledge(XCTUnwrap(store.pendingEdits().first))
    try store.apply(
      LibraryPage(items: [ItemPatch(progress: 1, archived: false).applying(to: item)], cursor: 2))
    XCTAssertFalse(try store.undoReading(undo.id))
    XCTAssertFalse(try XCTUnwrap(store.item(item.id)).archived)
  }
  func testBottomScrollDoesNotArchiveAndRevisitPreservesReadMarker() throws {
    let item = ReadingItem(id: UUID().uuidString, title: "Reading", assets: [])
    let store = try LocalStore(root: root)
    try store.apply(LibraryPage(items: [item], cursor: 1))
    try store.recordReadingPosition(item.id, 1)
    XCTAssertFalse(try XCTUnwrap(store.item(item.id)).archived)
    XCTAssertNil(try store.readingUndo())
    try store.recordReadingPosition(item.id, 0.3)
    XCTAssertEqual(try store.item(item.id)?.progress, 1)
    XCTAssertEqual(try store.readingPosition(item.id), 0.3)
  }
  func testOnlyLatestFinishCanBeUndoneAndDismissIsPersistent() throws {
    let first = ReadingItem(id: UUID().uuidString, title: "First", assets: [])
    let second = ReadingItem(id: UUID().uuidString, title: "Second", assets: [])
    let store = try LocalStore(root: root)
    try store.apply(LibraryPage(items: [first, second], cursor: 1))
    let old = try XCTUnwrap(store.finishReading(first.id))
    let latest = try XCTUnwrap(store.finishReading(second.id))
    XCTAssertFalse(try store.undoReading(old.id))
    XCTAssertEqual(try store.readingUndo(), latest)
    try store.dismissReadingUndo()
    XCTAssertNil(try LocalStore(root: root).readingUndo())
    XCTAssertFalse(try store.undoReading(latest.id))
  }
  func testRepeatedDoneDoesNotReplaceUndoOrAnotherItemsAction() throws {
    let first = ReadingItem(id: UUID().uuidString, title: "First", progress: 0.4, assets: [])
    let second = ReadingItem(id: UUID().uuidString, title: "Second", assets: [])
    let store = try LocalStore(root: root)
    try store.apply(LibraryPage(items: [first, second], cursor: 1))
    let initial = try XCTUnwrap(store.finishReading(first.id))
    XCTAssertEqual(try store.finishReading(first.id), initial)
    let newer = try XCTUnwrap(store.finishReading(second.id))
    XCTAssertNil(try store.finishReading(first.id))
    XCTAssertEqual(try store.readingUndo(), newer)
    XCTAssertTrue(try store.undoReading(newer.id))
    XCTAssertTrue(try XCTUnwrap(store.item(first.id)).archived)
  }

}
