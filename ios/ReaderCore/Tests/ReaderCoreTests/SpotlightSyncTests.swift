import XCTest

@testable import ReaderCore

final class SpotlightSyncTests: XCTestCase {
  func item(_ id: String, title: String = "Synthetic", trashed: Bool = false) -> ReadingItem {
    ReadingItem(
      id: id, title: title, trashedAt: trashed ? "2026-11-01T00:00:00Z" : nil, assets: [])
  }
  func signatures(_ items: [ReadingItem], words: [String: Int] = [:]) -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: SpotlightSync.visible(items).map {
        ($0.id, SpotlightSync.signature($0, words: words[$0.id]))
      })
  }

  func testPlanTouchesOnlyNewChangedAndRemovedArticles() {
    let before = signatures([item("a"), item("b"), item("c")])
    let after = signatures(
      [item("a"), item("b", title: "Renamed"), item("c", trashed: true), item("d")],
      words: ["a": 0])
    let plan = SpotlightSync.plan(after, indexed: before)
    XCTAssertEqual(Set(plan.upsert.keys), ["b", "d"])
    XCTAssertEqual(plan.remove, ["c"])
    XCTAssertTrue(SpotlightSync.plan(after, indexed: after).isEmpty)
  }

  func testADownloadChangesTheSignatureThroughItsWordCount() {
    let a = item("a")
    XCTAssertNotEqual(
      SpotlightSync.signature(a, words: nil), SpotlightSync.signature(a, words: 120))
  }

  func testAFailedWriteKeepsArticlesRecordedSoTheyAreRetriedOrRemoved() {
    let plan = SpotlightSync.Plan(upsert: ["a": "s1"], remove: ["gone"])
    let failed = SpotlightSync.record(
      plan, onto: ["gone": "old"], upserted: false, removed: false)
    XCTAssertEqual(failed, ["a": "", "gone": "old"])
    // Still visible: retried. Trashed later: removed, with its text.
    XCTAssertEqual(SpotlightSync.plan(["a": "s1"], indexed: failed).upsert, ["a": "s1"])
    XCTAssertEqual(SpotlightSync.plan([:], indexed: failed).remove, ["a", "gone"])
    XCTAssertEqual(
      SpotlightSync.record(plan, onto: ["gone": "old"], upserted: true, removed: true), ["a": "s1"])
  }

  func testGateRunsOneAtATimeAndOnceMoreForRequestsMeanwhile() {
    var gate = SpotlightSync.Gate()
    XCTAssertTrue(gate.request())
    XCTAssertFalse(gate.request())
    XCTAssertFalse(gate.request())
    XCTAssertTrue(gate.finish(), "requests during a run get one more run")
    XCTAssertFalse(gate.finish())
    XCTAssertFalse(gate.running)
    XCTAssertTrue(gate.request())
    XCTAssertFalse(gate.request())
    gate.reset()
    XCTAssertFalse(gate.finish(), "sign-out drops the queued run")
    XCTAssertTrue(gate.request())
  }
}
