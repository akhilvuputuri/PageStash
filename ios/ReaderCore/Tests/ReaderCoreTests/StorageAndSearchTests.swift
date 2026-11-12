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
    _ captured: String, archived: Bool = false, progress: Double = 0, deleted: Bool = false,
    trashedAt: String? = nil
  ) -> ReadingItem {
    ReadingItem(
      id: UUID().uuidString, title: captured, capturedAt: captured, progress: progress,
      archived: archived, deleted: deleted, trashedAt: trashedAt, assets: [])
  }
  private func need(_ item: ReadingItem, _ size: Int64) -> StorageEviction.Need {
    StorageEviction.Need(itemID: item.id, size: size)
  }

  func testCandidatesAreTrashFirstThenArchivedAndFinishedOldestFirst() {
    let unread = item("2026-01-01T00:00:00Z")
    let newerArchived = item("2026-03-01T00:00:00Z", archived: true)
    let olderArchived = item("2026-02-01T00:00:00Z", archived: true)
    let finished = item("2026-02-15T00:00:00Z", progress: 1)
    let notDownloaded = item("2025-01-01T00:00:00Z", archived: true)
    let deleted = item("2025-06-01T00:00:00Z", archived: true, deleted: true)
    let laterTrash = item("2024-01-01T00:00:00Z", trashedAt: "2026-04-02T00:00:00Z")
    let earlierTrash = item("2026-05-01T00:00:00Z", trashedAt: "2026-04-01T00:00:00Z")
    let items = [
      unread, newerArchived, olderArchived, finished, notDownloaded, deleted, laterTrash,
      earlierTrash,
    ]
    var sizes = [String: Int64]()
    for entry in items where entry.id != notDownloaded.id { sizes[entry.id] = 100 }
    XCTAssertEqual(
      StorageEviction.candidates(items, sizes: sizes).map(\.id),
      [earlierTrash.id, laterTrash.id, olderArchived.id, finished.id, newerArchived.id])
    XCTAssertEqual(
      StorageEviction.candidates(items, sizes: sizes, protected: [earlierTrash.id]).first?.id,
      laterTrash.id)
  }

  func testPlanEvictsOnlyWhatLetsFilesFit() {
    let unread = item("2026-01-01T00:00:00Z")
    let older = item("2026-02-01T00:00:00Z", archived: true)
    let newer = item("2026-03-01T00:00:00Z", progress: 1)
    let new = item("2026-04-01T00:00:00Z")
    let items = [unread, older, newer, new]
    let sizes: [String: Int64] = [unread.id: 300, older.id: 100, newer.id: 100]
    // Fits without removing anything.
    XCTAssertEqual(
      StorageEviction.plan(
        items, sizes: sizes, reserved: 500, limit: 1000, wanted: [need(new, 400)]), [])
    // Needs 50 more: the oldest candidate is enough.
    XCTAssertEqual(
      StorageEviction.plan(
        items, sizes: sizes, reserved: 500, limit: 1000, wanted: [need(new, 550)]), [older.id])
    // Needs 150 more: both.
    XCTAssertEqual(
      StorageEviction.plan(
        items, sizes: sizes, reserved: 500, limit: 1000, wanted: [need(new, 650)]),
      [older.id, newer.id])
    // Two files: the first fits as is, the second needs one removal.
    XCTAssertEqual(
      StorageEviction.plan(
        items, sizes: sizes, reserved: 500, limit: 1000,
        wanted: [need(new, 400), need(new, 150)]), [older.id])
  }

  func testPlanRemovesNothingWhenItCannotHelp() {
    // 512 limit, 500 used by unread articles, 10 archived, a new 50 file: removal can't make it
    // fit, so nothing is removed (sync after sync).
    let unread = item("2026-01-01T00:00:00Z")
    let archived = item("2026-02-01T00:00:00Z", archived: true)
    let new = item("2026-04-01T00:00:00Z")
    let sizes: [String: Int64] = [unread.id: 490, archived.id: 10]
    XCTAssertEqual(
      StorageEviction.plan(
        [unread, archived, new], sizes: sizes, reserved: 500, limit: 512,
        wanted: [need(new, 50)]), [])
    // A huge file that can't fit is skipped; a later small one that fits after removal is placed.
    XCTAssertEqual(
      StorageEviction.plan(
        [unread, archived, new], sizes: sizes, reserved: 500, limit: 512,
        wanted: [need(new, 50), need(new, 20)]), [archived.id])
  }

  func testPlanNeverRemovesWantedProtectedOrBusyArticles() {
    // Wiring Downloads relies on: articles being downloaded in the pass, the open article,
    // pinned downloads, Undo items and transfers in flight are all kept.
    let reading = item("2026-01-01T00:00:00Z", archived: true)
    let manual = item("2026-01-02T00:00:00Z", archived: true)
    let busy = item("2026-01-03T00:00:00Z", archived: true)
    let free = item("2026-01-04T00:00:00Z", archived: true)
    let new = item("2026-04-01T00:00:00Z")
    let items = [reading, manual, busy, free, new]
    let sizes: [String: Int64] = [reading.id: 100, manual.id: 100, busy.id: 100, free.id: 100]
    XCTAssertEqual(
      StorageEviction.plan(
        items, sizes: sizes, reserved: 400, limit: 400,
        wanted: [need(manual, 50), need(new, 50)], protected: [reading.id, busy.id]),
      [free.id])
    XCTAssertEqual(
      StorageEviction.plan(
        items, sizes: sizes, reserved: 400, limit: 400, wanted: [need(new, 50)],
        protected: [reading.id, manual.id, busy.id, free.id]), [])
  }

  func testPinnedDownloadsEndWithRemoveArchiveDoneOrEviction() throws {
    let store = try LocalStore(root: root)
    let a = ReadingItem(id: UUID().uuidString, title: "A", archived: true, assets: [])
    let b = ReadingItem(id: UUID().uuidString, title: "B", assets: [])
    let c = ReadingItem(id: UUID().uuidString, title: "C", assets: [])
    let d = ReadingItem(id: UUID().uuidString, title: "D", archived: true, assets: [])
    try store.apply(LibraryPage(items: [a, b, c, d], cursor: 1))
    for id in [a.id, b.id, c.id, d.id] { try store.pinDownload(id) }
    XCTAssertEqual(store.pinnedDownloads(), [a.id, b.id, c.id, d.id])
    try store.removeDownload(a.id)
    try store.finishReading(b.id)
    try store.edit(c.id, ItemPatch(archived: true))
    XCTAssertEqual(store.pinnedDownloads(), [d.id])
    try store.edit(d.id, ItemPatch(archived: false))
    XCTAssertEqual(store.pinnedDownloads(), [d.id], "Moving to the Library keeps the pin")
    try store.evictDownload(d.id)
    XCTAssertTrue(store.pinnedDownloads().isEmpty)
  }

  func testSearchExpressionCapsWords() {
    let long = (1...40).map { "w\($0)" }.joined(separator: " ")
    let expression = LocalStore.searchExpression(long) ?? ""
    XCTAssertEqual(expression.components(separatedBy: " AND ").count, LocalStore.maxSearchWords)
    XCTAssertFalse(expression.contains("w33"))
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
