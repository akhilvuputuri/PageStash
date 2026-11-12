import ReaderCore
import SwiftUI
import XCTest

@testable import OfflineReader

final class ThemeTokensTests: XCTestCase {
  /// WCAG 2.x relative luminance contrast for `#rrggbb` colours.
  func contrast(_ first: String, _ second: String) -> Double {
    func luminance(_ hex: String) -> Double {
      let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
      let channels = [value >> 16 & 0xff, value >> 8 & 0xff, value & 0xff].map {
        let c = Double($0) / 255
        return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
    let (a, b) = (luminance(first), luminance(second))
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }
  func testEveryInkMeetsAAOnItsPageAndSurface() {
    for theme in [ThemeTokens.light, .sepia, .dark] {
      let backgrounds = [theme.page] + (theme.surface.map { [$0] } ?? [])
      let inks = [
        ("ink", theme.ink), ("secondary", theme.secondaryInk), ("link", theme.link),
        ("accent", theme.accent), ("warning", theme.warning),
      ]
      for background in backgrounds {
        for (name, ink) in inks {
          for (variant, hex) in [("normal", ink.normal), ("increased", ink.contrast)] {
            XCTAssertGreaterThanOrEqual(
              contrast(hex, background), 4.5,
              "\(theme.name) \(name) (\(variant)) on \(background)")
          }
          XCTAssertGreaterThanOrEqual(
            contrast(ink.contrast, background), contrast(ink.normal, background),
            "\(theme.name) \(name): Increase Contrast must not lower contrast")
        }
      }
    }
  }
  func testThemeResolutionKeepsReaderPages() {
    // The article HTML tests depend on these exact page colours.
    XCTAssertEqual(ThemeTokens.resolve("sepia", .dark).page, "#f6f0e4")
    XCTAssertEqual(ThemeTokens.resolve("light", .light).page, "#ffffff")
    XCTAssertEqual(ThemeTokens.resolve("system", .dark).page, "#111111")
    XCTAssertEqual(ThemeTokens.resolve("dark", .dark).name, "dark")
  }
  func testRowSourceIsQuietAndReadable() {
    func item(_ url: String?, kind: String = "article") -> ReadingItem {
      ReadingItem(id: "1", title: "Synthetic", kind: kind, sourceUrl: url, assets: [])
    }
    XCTAssertEqual(ArticleRow.source(item("https://www.Example.com/a")), "example.com")
    XCTAssertEqual(ArticleRow.source(item("https://news.example.org/a")), "news.example.org")
    XCTAssertEqual(ArticleRow.source(item(nil, kind: "brief")), "Agent brief")
    XCTAssertNil(ArticleRow.source(item(nil)))
    let named = ReadingItem(
      id: "2", title: "Synthetic", sourceUrl: "https://www.example.com/a", siteName: " Example Daily ",
      assets: [])
    XCTAssertEqual(ArticleRow.source(named), "Example Daily")
  }
  func testReadingTimeRoundsAndShowsTimeLeft() {
    XCTAssertNil(ArticleRow.readingTime(words: nil, position: 0))
    XCTAssertNil(ArticleRow.readingTime(words: 0, position: 0))
    XCTAssertEqual(ArticleRow.readingTime(words: 40, position: 0), "1 min")
    XCTAssertEqual(ArticleRow.readingTime(words: 2300, position: 0), "10 min")
    XCTAssertEqual(ArticleRow.readingTime(words: 2300, position: 0.35), "7 min left")
    XCTAssertEqual(ArticleRow.readingTime(words: 2300, position: 0.99), "1 min left")
    XCTAssertEqual(ArticleRow.readingTime(words: 2300, position: 1), "10 min")
  }
  func testReaderTimeLeftMatchesTheRowAndEnds() {
    XCTAssertNil(ArticleRow.timeLeft(words: nil, position: 0.5))
    XCTAssertEqual(ArticleRow.timeLeft(words: 2300, position: 0), "10 min left")
    XCTAssertEqual(
      ArticleRow.timeLeft(words: 2300, position: 0.35),
      ArticleRow.readingTime(words: 2300, position: 0.35))
    XCTAssertEqual(ArticleRow.timeLeft(words: 2300, position: 0.99), "1 min left")
    XCTAssertEqual(ArticleRow.timeLeft(words: 2300, position: 1), "End of article")
    XCTAssertEqual(ArticleRow.timeLeft(words: 2300, position: .nan), "10 min left")
  }
  @MainActor func testReadingProgressPublishesWholePercentSteps() {
    let progress = ReadingProgress(0.2)
    progress.update(0.205)
    XCTAssertEqual(progress.fraction, 0.2)
    progress.update(0.25)
    XCTAssertEqual(progress.fraction, 0.25)
    progress.update(1.4)
    XCTAssertEqual(progress.fraction, 1)
    progress.update(-1)
    XCTAssertEqual(progress.fraction, 0)
  }
  func testPasteTakesTheFirstLinkInReadingOrder() {
    XCTAssertEqual(
      SaveView.firstLink(in: "see https://z.example/b then https://a.example/a")?.absoluteString,
      "https://z.example/b")
    XCTAssertEqual(
      SaveView.firstLink(in: "mailto:x@example.com https://example.com/x?utm_source=s")?
        .absoluteString, "https://example.com/x")
    XCTAssertNil(SaveView.firstLink(in: "no link here"))
  }
  func testSearchScopesCoverLibraryArchiveAndAll() {
    XCTAssertTrue(LibrarySearchScope.library.includes(archived: false))
    XCTAssertFalse(LibrarySearchScope.library.includes(archived: true))
    XCTAssertTrue(LibrarySearchScope.archive.includes(archived: true))
    XCTAssertFalse(LibrarySearchScope.archive.includes(archived: false))
    XCTAssertTrue(LibrarySearchScope.all.includes(archived: true))
    XCTAssertTrue(LibrarySearchScope.all.includes(archived: false))
  }
  func testOnlyTheShownFinishLinkFinishesReading() {
    let finish = ArticleWebView.finishAction
    XCTAssertTrue(ArticleWebView.isFinishAction(finish, finishShown: true))
    XCTAssertFalse(ArticleWebView.isFinishAction(finish, finishShown: false))
    for other in ["offline-reader-action:x:finish", "offline-reader-action:finish?again"] {
      XCTAssertFalse(ArticleWebView.isFinishAction(URL(string: other)!, finishShown: true), other)
    }
  }
}
