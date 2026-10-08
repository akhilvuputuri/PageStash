import ReaderCore
import SwiftUI
import WebKit
import XCTest

@testable import OfflineReader

@MainActor final class ArticleWebViewTests: XCTestCase {
  final class Controls: ObservableObject {
    @Published var font = 20.0
    @Published var dark = false
  }
  struct Harness: View {
    @ObservedObject var controls: Controls
    let file: URL
    let header: ArticleHeader
    let state: ArticleScrollState
    var body: some View {
      ArticleWebView(
        url: file, header: header, scrollState: state, progress: 0, fontSize: controls.font,
        onProgress: { _ in }
      )
      .environment(\.colorScheme, controls.dark ? .dark : .light)
    }
  }
  func evaluate(_ web: WKWebView, _ script: String) async throws -> Any? {
    try await withCheckedThrowingContinuation { continuation in
      web.evaluateJavaScript(script) { value, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: value)
        }
      }
    }
  }
  func waitFor(_ predicate: @escaping @MainActor () async throws -> Bool) async throws {
    for _ in 0..<200 {
      if try await predicate() { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw NSError(
      domain: "ReaderUITest", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Reader did not settle before deadline"])
  }
  func findWeb(_ view: UIView) -> WKWebView? {
    if let web = view as? WKWebView { return web }
    return view.subviews.compactMap { findWeb($0) }.first
  }
  func testLongHeaderScrollAndFontThemeRestoration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("article.html")
    let title =
      "A long article title that must leave the viewport when the reader scrolls into the body"
    let paragraphs = (1...40).map {
      "<p>Paragraph \($0). Synthetic cached article content validates scrolling, text sizing and reading position without using an account.</p>"
    }.joined()
    try
      "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head><body><h1>\(title)</h1><p id='reader-header'>Synthetic publisher text with a coincidentally matching ID.</p>\(paragraphs)</body></html>"
      .write(to: file, atomically: true, encoding: .utf8)
    let defaults = UserDefaults.standard
    let previousAppearance = defaults.object(forKey: "appearance")
    defaults.set("light", forKey: "appearance")
    defer { defaults.set(previousAppearance, forKey: "appearance") }
    let controls = Controls()
    let state = ArticleScrollState()
    let header = ArticleHeader(
      title: title, kind: "article", author: "Synthetic author",
      source: URL(string: "https://example.com/article"), status: "Available offline", error: nil)
    let host = UIHostingController(
      rootView: Harness(controls: controls, file: file, header: header, state: state))
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }
    try await waitFor { self.findWeb(host.view) != nil }
    let web = try XCTUnwrap(findWeb(host.view))
    let coordinator = try XCTUnwrap(web.navigationDelegate as? ArticleWebView.Coordinator)
    try await waitFor { !web.isLoading && !coordinator.restoring && coordinator.headerHeight > 0 }
    let headingCount = try await evaluate(web, "document.querySelectorAll('h1').length") as? Int
    XCTAssertEqual(headingCount, 1)
    let headingText =
      try await evaluate(web, "document.querySelector('#reader-header h1').textContent") as? String
    XCTAssertEqual(headingText, title)
    let preservedPublisherText =
      try await evaluate(web, "document.querySelector('p#reader-header').textContent") as? String
    XCTAssertEqual(
      preservedPublisherText, "Synthetic publisher text with a coincidentally matching ID.")
    let desired = 0.45
    let offset = ReadingScrollPosition.offset(
      progress: desired, contentHeight: web.scrollView.contentSize.height,
      viewportHeight: web.scrollView.bounds.height, headerHeight: coordinator.headerHeight)
    web.scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
    state.flush?()
    XCTAssertEqual(coordinator.currentProgress(web.scrollView), desired, accuracy: 0.01)
    let headerPosition =
      try await evaluate(web, "getComputedStyle(document.getElementById('reader-header')).position")
      as? String
    XCTAssertEqual(
      headerPosition, "static", "Metadata must stay in the article's scrolling document")
    XCTAssertLessThan(
      coordinator.headerHeight - web.scrollView.contentOffset.y, 0,
      "The long title must leave WKWebView's native scroll viewport")
    for size in [30.0, 14.0, 26.0, 20.0, 30.0] {
      controls.font = size
      try await waitFor { coordinator.fontSize == size && !coordinator.restoring }
      let bodyFont = try await evaluate(web, "document.body.style.fontSize") as? String
      XCTAssertEqual(bodyFont, "\(Int(size))px")
      XCTAssertEqual(
        coordinator.currentProgress(web.scrollView), desired, accuracy: 0.02,
        "Text resizing must retain the relative body position at \(size) points")
    }
    controls.dark = true
    try await waitFor { coordinator.appearance == "dark" && !coordinator.restoring }
    let scheme = try await evaluate(web, "document.documentElement.style.colorScheme") as? String
    XCTAssertEqual(scheme, "dark")
    XCTAssertEqual(coordinator.currentProgress(web.scrollView), desired, accuracy: 0.02)
    let image = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<UIImage, Error>) in
      web.takeSnapshot(with: nil) { image, error in
        if let image {
          continuation.resume(returning: image)
        } else {
          continuation.resume(throwing: error ?? NSError(domain: "ReaderUITest", code: 2))
        }
      }
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = "Synthetic large-text reader after header scroll"
    attachment.lifetime = .keepAlways
    add(attachment)
    for (theme, dark, expected) in [
      ("sepia", true, "sepia"), ("light", false, "light"),
      ("system", true, "dark"), ("system", false, "light"),
    ] {
      defaults.set(theme, forKey: "appearance")
      controls.dark = dark
      try await waitFor { coordinator.appearance == expected && !coordinator.restoring }
      XCTAssertEqual(
        coordinator.currentProgress(web.scrollView), desired, accuracy: 0.02,
        "Changing to \(theme) must retain article position")
      let background = try await evaluate(web, "document.body.style.backgroundColor") as? String
      XCTAssertEqual(
        background,
        expected == "sepia"
          ? "rgb(246, 240, 228)" : expected == "dark" ? "rgb(17, 17, 17)" : "rgb(255, 255, 255)")
    }
  }
}
