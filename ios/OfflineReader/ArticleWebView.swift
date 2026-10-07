import SwiftUI
import WebKit

struct ArticleWebView: UIViewRepresentable {
  @Environment(\.colorScheme) private var colorScheme
  let url: URL
  let progress: Double
  let fontSize: Double
  let onProgress: (Double) -> Void
  private var appearance: String { colorScheme == .dark ? "dark" : "light" }
  private var styleScript: String {
    let dark = colorScheme == .dark
    let background = dark ? "#111111" : "#ffffff"
    let foreground = dark ? "#eeeeee" : "#1c1c1e"
    return """
      document.documentElement.style.colorScheme='\(appearance)';
      document.documentElement.style.backgroundColor='\(background)';
      if (document.body) {
        document.body.style.backgroundColor='\(background)';
        document.body.style.color='\(foreground)';
        document.body.style.fontSize='\(fontSize)px';
      }
      """
  }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .zero, configuration: configuration)
    web.navigationDelegate = context.coordinator
    web.scrollView.delegate = context.coordinator
    web.isOpaque = false
    web.backgroundColor = .clear
    return web
  }
  func updateUIView(_ web: WKWebView, context: Context) {
    context.coordinator.parent = self
    if context.coordinator.loaded != url {
      context.coordinator.loaded = url
      context.coordinator.restoring = true
      web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    web.backgroundColor = colorScheme == .dark ? UIColor(white: 0.067, alpha: 1) : .white
    web.scrollView.backgroundColor = web.backgroundColor
    if context.coordinator.fontSize != fontSize || context.coordinator.appearance != appearance {
      context.coordinator.fontSize = fontSize
      context.coordinator.appearance = appearance
      web.evaluateJavaScript(styleScript)
    }
  }
  final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
    var parent: ArticleWebView
    var restoring = true
    var loaded: URL?
    var fontSize: Double = 20
    var appearance: String?
    var lastSaved = Date.distantPast
    init(_ parent: ArticleWebView) { self.parent = parent }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      webView.evaluateJavaScript(parent.styleScript)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        let height = max(
          0, webView.scrollView.contentSize.height - webView.scrollView.bounds.height)
        webView.scrollView.setContentOffset(
          CGPoint(x: 0, y: height * self.parent.progress), animated: false)
        self.restoring = false
      }
    }
    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard let target = action.request.url else {
        decisionHandler(.cancel)
        return
      }
      if action.navigationType == .linkActivated {
        if ["https", "http"].contains(target.scheme ?? "") { UIApplication.shared.open(target) }
        decisionHandler(.cancel)
        return
      }
      // Only the top-level article file may navigate; images are confined by CSP/read access.
      decisionHandler(
        target.standardizedFileURL == parent.url.standardizedFileURL ? .allow : .cancel)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      if Date().timeIntervalSince(lastSaved) > 2 { save(scrollView) }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { save(scrollView) }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if !decelerate { save(scrollView) }
    }
    private func save(_ scroll: UIScrollView) {
      guard !restoring else { return }
      let height = scroll.contentSize.height - scroll.bounds.height
      guard height > 0 else { return }
      lastSaved = Date()
      parent.onProgress(min(1, max(0, scroll.contentOffset.y / height)))
    }
  }
}
