import ReaderCore
import SwiftUI
import XCTest

@testable import OfflineReader

@MainActor final class SystemIntegrationTests: XCTestCase {
  func item(_ id: String, progress: Double = 0, archived: Bool = false) -> ReadingItem {
    ReadingItem(
      id: id, title: "Synthetic \(id)", sourceUrl: "https://example.com/\(id)", progress: progress,
      archived: archived,
      assets: [
        Asset(
          id: "a-\(id)", role: "content", mime: "text/html", size: 1, sha256: "x",
          filename: "article.html", url: URL(string: "https://example.com/c")!)
      ])
  }
  func testDeepLinksRoundTripAndRejectOtherURLs() {
    let link = ContinueReading.link("4f1c-item")
    XCTAssertEqual(link.absoluteString, "offlinereader://item/4f1c-item")
    XCTAssertEqual(ContinueReading.itemID(from: link), "4f1c-item")
    for other in [
      "https://example.com/item/x", "offlinereader://item/", "offlinereader://item/a/b",
      "offlinereader://other/x",
    ] {
      XCTAssertNil(ContinueReading.itemID(from: URL(string: other)!), other)
    }
  }
  func testContinueReadingPrefersTheLastOpenedUnfinishedArticle() {
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: SystemIntegration.lastOpenedKey)
    defer { defaults.set(previous, forKey: SystemIntegration.lastOpenedKey) }
    let items = [
      item("new"), item("partly", progress: 0.4), item("opened", progress: 0.1),
      item("done", progress: 1), item("archived", progress: 0.5, archived: true),
    ]
    defaults.removeObject(forKey: SystemIntegration.lastOpenedKey)
    XCTAssertEqual(SystemIntegration.continueItem(items)?.id, "partly")
    SystemIntegration.didOpen("opened")
    XCTAssertEqual(SystemIntegration.continueItem(items)?.id, "opened")
    SystemIntegration.didOpen("archived")
    XCTAssertEqual(
      SystemIntegration.continueItem(items)?.id, "partly", "Archived articles are not resumed")
    XCTAssertNil(SystemIntegration.continueItem([item("done", progress: 1)]))
    var trashed = item("trashed", progress: 0.6)
    trashed.trashedAt = "2026-10-15T00:00:00Z"
    SystemIntegration.didOpen("trashed")
    XCTAssertEqual(
      SystemIntegration.continueItem(items + [trashed])?.id, "partly",
      "Trashed articles are never resumed")
  }
  func testSnapshotRoundTripsThroughTheAppGroup() throws {
    let snapshot = ContinueReading(
      article: .init(id: "x", title: "Synthetic", source: "example.com", progress: 0.3),
      updated: Date(timeIntervalSince1970: 1_000))
    snapshot.save()
    XCTAssertEqual(ContinueReading.load(), snapshot)
    ContinueReading(article: nil, updated: Date()).save()
    XCTAssertNil(ContinueReading.load()?.article)
  }
}
