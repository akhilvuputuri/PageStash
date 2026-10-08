import XCTest

@testable import ReaderCore

final class ImportVisibilityTests: XCTestCase {
  func testSubmissionHistorySurvivesSyncAndRestartWithoutEnteringLibrary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalStore(root: root)
    let submissions = ["queued", "processing", "bookmark"].map {
      ReadingItem(
        id: UUID().uuidString, title: "Submission", status: $0, contentVersion: 0, assets: [])
    }
    try store.apply(LibraryPage(items: submissions, cursor: 4))
    let reopened = try LocalStore(root: root)
    XCTAssertEqual(try reopened.items().count, 3)
    XCTAssertTrue(try reopened.items().filter(\.hasPreparedContent).isEmpty)
    XCTAssertEqual(try reopened.items().filter(\.needsImportReview).count, 3)
    XCTAssertEqual(reopened.cursor, 4)
  }
  func testRecoveryPromotesTheSameSubmissionAndKeepsReadableImageWarning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalStore(root: root)
    let id = UUID().uuidString
    let failed = ReadingItem(
      id: id, title: "Submission", status: "bookmark", contentVersion: 0, assets: [])
    try store.apply(LibraryPage(items: [failed], cursor: 1))
    let bytes = Data("<p>Readable article text. [Image unavailable: Source photo]</p>".utf8)
    let asset = Asset(
      id: UUID().uuidString, role: "content", mime: "text/html", size: bytes.count,
      sha256: digest(bytes), filename: "article.html",
      url: URL(string: "https://example.com/content")!)
    let ready = ReadingItem(
      id: id, title: "Readable", error: "1 source images unavailable.", revision: 2, assets: [asset]
    )
    try store.apply(LibraryPage(items: [ready], cursor: 2))
    let temporary = root.appendingPathComponent("download.html")
    try bytes.write(to: temporary)
    try store.accept(temporary, itemID: id, version: 1, asset: asset)
    let reopened = try LocalStore(root: root)
    XCTAssertEqual(try reopened.items().count, 1)
    XCTAssertEqual(try reopened.items().filter(\.hasPreparedContent).count, 1)
    XCTAssertTrue(try reopened.items().filter(\.needsImportReview).isEmpty)
    XCTAssertEqual(reopened.offlineState(ready), .textOnly)
    let readable = try XCTUnwrap(reopened.readerURL(id))
    XCTAssertTrue(try String(contentsOf: readable, encoding: .utf8).contains("Image unavailable"))
  }
  func testFailedRefreshAndDeviceTransferCannotDestroyEarlierReadableCopy() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalStore(root: root)
    let id = UUID().uuidString
    let bytes = Data("<p>Earlier readable article</p>".utf8)
    let asset = Asset(
      id: UUID().uuidString, role: "content", mime: "text/html", size: bytes.count,
      sha256: digest(bytes), filename: "article.html",
      url: URL(string: "https://example.com/content")!)
    let ready = ReadingItem(id: id, title: "Readable", assets: [asset])
    try store.apply(LibraryPage(items: [ready], cursor: 1))
    let temporary = root.appendingPathComponent("download.html")
    try bytes.write(to: temporary)
    try store.accept(temporary, itemID: id, version: 1, asset: asset)
    let failed = ReadingItem(
      id: id, title: "Earlier readable copy", status: "bookmark", error: "Refresh failed",
      contentVersion: 1, revision: 2, assets: [asset])
    try store.apply(LibraryPage(items: [failed], cursor: 2))
    try Data("bad transfer".utf8).write(to: temporary)
    XCTAssertThrowsError(try store.accept(temporary, itemID: id, version: 1, asset: asset))
    let retained = try XCTUnwrap(store.item(id))
    XCTAssertTrue(retained.hasPreparedContent)
    XCTAssertTrue(retained.needsImportReview)
    let readable = try XCTUnwrap(store.readerURL(id))
    XCTAssertEqual(try Data(contentsOf: readable), bytes)
  }
}
