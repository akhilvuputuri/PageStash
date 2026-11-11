import AppIntents
import ReaderCore
import XCTest

@testable import OfflineReader

@MainActor final class ArticleIntentsTests: XCTestCase {
  func testEntityMirrorsTheSpotlightItem() {
    let item = ReadingItem(
      id: "4f1c-item", title: "Synthetic title", sourceUrl: "https://www.example.com/a",
      author: "A. Writer", progress: 1, archived: true, assets: [])
    let entity = ArticleEntity(item)
    XCTAssertEqual(entity.id, item.id)
    XCTAssertEqual(entity.title, "Synthetic title")
    XCTAssertEqual(entity.source, "example.com")
    XCTAssertEqual(entity.author, "A. Writer")
    XCTAssertEqual(entity.link, URL(string: "https://www.example.com/a"))
    XCTAssertTrue(entity.isFinished)
    XCTAssertEqual(entity.details, "example.com · A. Writer · Archived")
    if #available(iOS 18, *) {
      XCTAssertEqual(entity.attributeSet.title, "Synthetic title")
      XCTAssertEqual(entity.attributeSet.contentDescription, entity.details)
    }
  }

  func testUnfinishedBriefWithoutLinkHasNoDetailsBeyondItsKind() {
    let item = ReadingItem(
      id: "b", title: "Brief", kind: "brief", progress: 1, archived: false, assets: [])
    let entity = ArticleEntity(item)
    XCTAssertFalse(entity.isFinished)
    XCTAssertNil(entity.link)
    XCTAssertEqual(entity.details, "Agent brief")
  }

  func testOpenArticleActivityNamesTheEntityAndStaysOnDevice() {
    let activity = NSUserActivity(activityType: ArticleActivity.type)
    ArticleActivity.describe(activity, id: "4f1c-item", title: "Synthetic title")
    XCTAssertEqual(activity.title, "Synthetic title")
    XCTAssertFalse(activity.isEligibleForHandoff)
    XCTAssertFalse(activity.isEligibleForSearch)
    XCTAssertFalse(activity.isEligibleForPrediction)
    if #available(iOS 18.2, *) {
      XCTAssertEqual(
        activity.appEntityIdentifier,
        EntityIdentifier(for: ArticleEntity.self, identifier: "4f1c-item"))
    }
  }
}
