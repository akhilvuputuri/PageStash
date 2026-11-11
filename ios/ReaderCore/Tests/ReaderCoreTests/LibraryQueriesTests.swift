import XCTest

@testable import ReaderCore

final class LibraryQueriesTests: XCTestCase {
  func item(
    _ id: String, title: String? = nil, captured: String, progress: Double = 0,
    archived: Bool = false, trashed: Bool = false, status: String = "ready"
  ) -> ReadingItem {
    ReadingItem(
      id: id, title: title ?? "Synthetic \(id)", status: status, capturedAt: captured,
      contentVersion: status == "ready" ? 1 : 0, progress: progress, archived: archived,
      trashedAt: trashed ? "2026-11-01T00:00:00Z" : nil, assets: [])
  }

  func testUpNextPrefersDownloadedThenUnstartedThenNewest() {
    let items = [
      item("old-local", captured: "2026-10-01T00:00:00Z"),
      item("new-remote", captured: "2026-11-05T00:00:00Z"),
      item("new-local", captured: "2026-11-04T00:00:00Z"),
      item("started-local", captured: "2026-11-06T00:00:00Z", progress: 0.3),
      item("done", captured: "2026-11-07T00:00:00Z", progress: 1),
      item("archived", captured: "2026-11-07T00:00:00Z", archived: true),
      item("trashed", captured: "2026-11-07T00:00:00Z", trashed: true),
      item("queued", captured: "2026-11-08T00:00:00Z", status: "queued"),
    ]
    let local: Set = ["old-local", "new-local", "started-local", "done", "archived", "trashed"]
    let ranked = LibraryQueries.upNext(
      items, downloaded: { local.contains($0.id) }, position: { $0.progress })
    XCTAssertEqual(ranked.map(\.id), ["new-local", "old-local", "started-local", "new-remote"])
    let skippingOpen = LibraryQueries.upNext(
      items, excluding: "new-local", downloaded: { local.contains($0.id) },
      position: { $0.progress })
    XCTAssertEqual(skippingOpen.first?.id, "old-local")
    XCTAssertTrue(
      LibraryQueries.upNext([], downloaded: { _ in true }, position: { _ in 0 }).isEmpty)
  }

  func testUpNextUsesTheDevicePositionNotOnlyTheSyncedMarker() {
    let items = [
      item("a", captured: "2026-11-02T00:00:00Z"), item("b", captured: "2026-11-01T00:00:00Z"),
    ]
    let ranked = LibraryQueries.upNext(
      items, downloaded: { _ in true }, position: { $0.id == "a" ? 0.2 : 0 })
    XCTAssertEqual(ranked.map(\.id), ["b", "a"])
  }

  func testSearchMatchesTitleWordsFirstThenBodyMatches() {
    let items = [
      item("t1", title: "The Café Économique", captured: "2026-11-03T00:00:00Z"),
      item("t2", title: "Notes on cafe culture", captured: "2026-11-02T00:00:00Z"),
      item("b1", title: "Unrelated title", captured: "2026-11-04T00:00:00Z"),
      item("gone", title: "Cafe in Trash", captured: "2026-11-05T00:00:00Z", trashed: true),
      item("old", title: "An archived cafe", captured: "2026-10-01T00:00:00Z", archived: true),
    ]
    XCTAssertEqual(
      LibraryQueries.search("cafe", in: items, bodyMatches: ["b1", "t1", "gone"]).map(\.id),
      ["t1", "t2", "old", "b1"])
    XCTAssertEqual(LibraryQueries.search("café économique", in: items).map(\.id), ["t1"])
    XCTAssertEqual(LibraryQueries.search("cafe, culture!", in: items).map(\.id), ["t2"])
    XCTAssertTrue(LibraryQueries.search("  ", in: items, bodyMatches: ["b1"]).isEmpty)
  }

  func testExcerptDecodesCollapsesAndCutsAtAWord() {
    XCTAssertEqual(
      LibraryQueries.excerpt("  It&#39;s  &quot;slow&quot;\n\n reading &lt;3 ", characters: 100),
      "It's \"slow\" reading <3")
    XCTAssertEqual(
      LibraryQueries.excerpt("one two three four", characters: 9), "one two…")
    XCTAssertEqual(LibraryQueries.excerpt("unbroken", characters: 4), "unbr…")
    XCTAssertNil(LibraryQueries.excerpt(" \n&nbsp; ", characters: 10))
    XCTAssertNil(LibraryQueries.excerpt("text", characters: 0))
  }

  func testSpokenTextIsLabelledAndCompact() {
    let context = ReadingContext(
      itemId: "a", contentVersion: 1, generatedAt: "2026-11-01T00:00:00Z", model: "m",
      historyCount: 3, stale: true, summary: "  It argues for slower reading ",
      buildsOn: [.init(itemId: "b", title: "B", note: "n"), .init(itemId: "c", title: "C", note: "n")],
      covered: [.init(itemId: "d", title: "D", note: "n")], newIdeas: ["One.", "Two"])
    XCTAssertEqual(
      context.spokenText(title: "A"),
      "AI-generated Reading Context for “A”: It argues for slower reading. It builds on “B” and “C”. You've already read about parts of it in “D”. New here: One; Two. Your finished articles changed since it was written."
    )
    let bare = ReadingContext(
      itemId: "a", contentVersion: 1, generatedAt: "", model: "m", historyCount: 0,
      summary: "Short!")
    XCTAssertEqual(bare.spokenText(title: "A"), "AI-generated Reading Context for “A”: Short!")
    XCTAssertEqual(ReadingContext.list(["A", "B", "C"]), "“A”, “B” and “C”")
  }
}
