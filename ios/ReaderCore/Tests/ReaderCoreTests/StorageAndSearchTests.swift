import XCTest

@testable import ReaderCore

/// Prefix search, the storage-full eviction plan and source links. Synthetic data only.
final class StorageAndSearchTests: XCTestCase {
  var root: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
  private func content(_ html: String) -> (Data, Asset) {
    let bytes = Data(html.utf8)
    return (
      bytes,
      Asset(
        id: UUID().uuidString.lowercased(), role: "content", mime: "text/html", size: bytes.count,
        sha256: digest(bytes), filename: "article.html",
        url: URL(string: "https://reader.example/v1/downloads/test")!)
    )
  }
  private func install(_ data: Data, _ asset: Asset, _ item: ReadingItem, _ store: LocalStore)
    throws
  {
    let temporary = root.appendingPathComponent("temporary")
    try data.write(to: temporary)
    try store.accept(temporary, itemID: item.id, version: item.contentVersion, asset: asset)
  }

  // MARK: Search

  func testSearchExpressionPrefixesEveryWordAndQuotesSyntax() {
    XCTAssertEqual(LocalStore.searchExpression("progr"), "\"progr\"*")
    XCTAssertEqual(LocalStore.searchExpression("  offline   prog "), "\"offline\"* AND \"prog\"*")
    // Quotes are doubled inside the string; operators and asterisks stay literal text.
    XCTAssertEqual(LocalStore.searchExpression("say \"hi"), "\"say\"* AND \"\"\"hi\"*")
    XCTAssertEqual(LocalStore.searchExpression("OR"), "\"OR\"*")
    XCTAssertEqual(LocalStore.searchExpression("a*"), "\"a*\"*")
    // Punctuation-only words are dropped; nothing searchable gives nil.
    XCTAssertEqual(LocalStore.searchExpression("swift - ui"), "\"swift\"* AND \"ui\"*")
    XCTAssertNil(LocalStore.searchExpression("   "))
    XCTAssertNil(LocalStore.searchExpression("\" * - ("))
  }

  func testSearchMatchesWordPrefixesInTitleAndBody() throws {
    let store = try LocalStore(root: root)
    let (bytes, asset) = content("<p>Notes on programming offline readers</p>")
    let item = ReadingItem(id: UUID().uuidString, title: "Synthetic Garden", assets: [asset])
    let other = ReadingItem(id: UUID().uuidString, title: "Unrelated", assets: [])
    try store.apply(LibraryPage(items: [item, other], cursor: 1))
    try install(bytes, asset, item, store)
    XCTAssertEqual(try store.search("progr"), [item.id])
    XCTAssertEqual(try store.search("Gard"), [item.id])
    XCTAssertEqual(try store.search("offl progr"), [item.id])
    XCTAssertTrue(try store.search("progr zebra").isEmpty)
    // Syntax characters never throw or widen the search.
    XCTAssertTrue(try store.search("NOT \" ) * OR").isEmpty)
    XCTAssertTrue(try store.search("prog*ramming").isEmpty)
    XCTAssertTrue(try store.search("   ").isEmpty)
  }

  // MARK: Storage

  private func item(
    _ captured: String, archived: Bool = false, progress: Double = 0, deleted: Bool = false
  ) -> ReadingItem {
    ReadingItem(
      id: UUID().uuidString, title: captured, capturedAt: captured, progress: progress,
      archived: archived, deleted: deleted, assets: [])
  }

  func testEvictionTakesArchivedAndFinishedOldestFirst() {
    let unread = item("2026-01-01T00:00:00Z")
    let newerArchived = item("2026-03-01T00:00:00Z", archived: true)
    let olderArchived = item("2026-02-01T00:00:00Z", archived: true)
    let finished = item("2026-02-15T00:00:00Z", progress: 1)
    let notDownloaded = item("2025-01-01T00:00:00Z", archived: true)
    let deleted = item("2025-06-01T00:00:00Z", archived: true, deleted: true)
    let items = [unread, newerArchived, olderArchived, finished, notDownloaded, deleted]
    let sizes: [String: Int64] = [
      unread.id: 100, newerArchived.id: 100, olderArchived.id: 100, finished.id: 100,
      deleted.id: 100,
    ]
    XCTAssertEqual(
      StorageEviction.candidates(items, sizes: sizes).map(\.id),
      [olderArchived.id, finished.id, newerArchived.id])
    XCTAssertEqual(StorageEviction.plan(items, sizes: sizes, needed: 0), [])
    XCTAssertEqual(StorageEviction.plan(items, sizes: sizes, needed: 1), [olderArchived.id])
    XCTAssertEqual(
      StorageEviction.plan(items, sizes: sizes, needed: 150), [olderArchived.id, finished.id])
    // Not enough even with everything: all candidates, never the unread article.
    XCTAssertEqual(
      StorageEviction.plan(items, sizes: sizes, needed: 10_000),
      [olderArchived.id, finished.id, newerArchived.id])
    // The open article and in-flight downloads are protected.
    XCTAssertEqual(
      StorageEviction.plan(
        items, sizes: sizes, needed: 150, protected: [olderArchived.id]),
      [finished.id, newerArchived.id])
  }

  func testEvictionFreesFilesWithoutPausingButRemoveDownloadPauses() throws {
    let store = try LocalStore(root: root)
    let (bytes, asset) = content("<p>Archived synthetic article</p>")
    let (otherBytes, otherAsset) = content("<p>Another synthetic article</p>")
    let archived = ReadingItem(
      id: UUID().uuidString, title: "Archived", progress: 1, archived: true, assets: [asset])
    let kept = ReadingItem(id: UUID().uuidString, title: "Kept", assets: [otherAsset])
    try store.apply(LibraryPage(items: [archived, kept], cursor: 1))
    try install(bytes, asset, archived, store)
    try install(otherBytes, otherAsset, kept, store)
    let sizes = store.downloadSizes()
    XCTAssertEqual(sizes[archived.id], Int64(bytes.count))
    XCTAssertEqual(sizes[kept.id], Int64(otherBytes.count))

    try store.evictDownload(archived.id)
    XCTAssertNil(try store.readerURL(archived.id))
    XCTAssertEqual(store.offlineState(archived), .notDownloaded)
    XCTAssertNil(store.downloadSizes()[archived.id])
    XCTAssertFalse(store.isPaused(archived.id), "Evicted articles may download again")
    // The bookmark and its title search stay.
    XCTAssertNotNil(try store.item(archived.id))
    XCTAssertEqual(try store.search("Archiv"), [archived.id])

    try store.removeDownload(kept.id)
    XCTAssertTrue(store.isPaused(kept.id), "Remove Download still stops re-download")
  }

  // MARK: Links

  func testWebURLOnlyForHTTPSources() {
    func link(_ source: String?, kind: String = "article") -> URL? {
      ReadingItem(id: UUID().uuidString, title: "T", kind: kind, sourceUrl: source, assets: [])
        .webURL
    }
    XCTAssertEqual(link("https://example.com/a")?.absoluteString, "https://example.com/a")
    XCTAssertEqual(link(" http://example.com/b ")?.absoluteString, "http://example.com/b")
    XCTAssertNil(link(nil, kind: "brief"))
    XCTAssertNil(link(""))
    XCTAssertNil(link("javascript:alert(1)"))
    XCTAssertNil(link("file:///etc/hosts"))
    XCTAssertNil(link("https://"))
  }
}
