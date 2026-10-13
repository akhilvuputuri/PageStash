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
  }
}
