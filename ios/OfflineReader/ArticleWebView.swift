import ReaderCore
import SwiftUI
import WebKit

struct ArticleHeader: Equatable {
  let title: String
  let kind: String
  let author: String?
  let source: URL?
  let status: String
  let error: String?
  var payload: String {
    var data: [String: String] = ["title": title, "kind": kind, "status": status]
    if let author { data["author"] = author }
    if let source, ["http", "https"].contains(source.scheme ?? "") {
      data["source"] = source.absoluteString
      data["host"] = source.host ?? "source"
    }
    if let error { data["error"] = error }
    return String(
      decoding: (try? JSONSerialization.data(withJSONObject: data)) ?? Data("{}".utf8),
      as: UTF8.self)
  }
}
@MainActor final class ArticleScrollState: ObservableObject {
  var flush: (() -> Void)?
}
struct ArticleWebView: UIViewRepresentable {
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage("appearance") private var selectedAppearance = "light"
  let url: URL
  let header: ArticleHeader
  let scrollState: ArticleScrollState
  let progress: Double
  let fontSize: Double
  let onProgress: (Double) -> Void
  private var appearance: String {
    selectedAppearance == "sepia" ? "sepia" : (colorScheme == .dark ? "dark" : "light")
  }
  private var pageBackground: UIColor {
    if appearance == "sepia" {
      return UIColor(red: 246 / 255, green: 240 / 255, blue: 228 / 255, alpha: 1)
    }
    return appearance == "dark" ? UIColor(white: 0.067, alpha: 1) : .white
  }
  private var styleScript: String {
    let dark = appearance == "dark"
    let sepia = appearance == "sepia"
    let background = sepia ? "#f6f0e4" : (dark ? "#111111" : "#ffffff")
    let foreground = sepia ? "#3d352b" : (dark ? "#eeeeee" : "#1c1c1e")
    let link = sepia ? "#86512d" : (dark ? "#8ab4f8" : "#4685c5")
    return """
      (() => {
      const metadata = \(header.payload);
      const body = document.body;
      if (!body) return 0;
      const headerKey = Symbol.for('OfflineReader.articleHeader');
      let header = window[headerKey];
      if (!header || !header.isConnected) {
        const heading = body.querySelector('h1,h2');
        if (heading) { const prior=document.createRange(); prior.setStart(body,0); prior.setEndBefore(heading); if (!prior.toString().trim() && heading.textContent.replace(/\\s+/g,' ').trim() === metadata.title.replace(/\\s+/g,' ').trim()) heading.remove(); }
        header = document.createElement('header'); header.id='reader-header'; body.prepend(header); window[headerKey]=header;
      }
      header.replaceChildren();
      header.style.marginBottom='24px'; header.style.paddingBottom='16px'; header.style.borderBottom='1px solid #8884';
      const add = (tag,text) => { const node=document.createElement(tag); node.textContent=text; header.append(node); return node; };
      const kind=add('div',metadata.kind === 'brief' ? 'AGENT-CREATED BRIEF' : 'SAVED ARTICLE');
      kind.style.fontSize='12px'; kind.style.letterSpacing='1.5px'; kind.style.opacity='0.65';
      const title=add('h1',metadata.title); title.style.fontSize='\(max(24,fontSize*1.4))px'; title.style.lineHeight='1.2'; title.style.margin='10px 0';
      if (metadata.author) { const author=add('div',metadata.author); author.style.fontSize='14px'; author.style.marginBottom='8px'; }
      if (metadata.source) {
        const source=add('a','View original · '+metadata.host); source.href=metadata.source; source.style.display='block'; source.style.fontSize='13px'; source.style.marginBottom='8px';
      }
      const status=add('div',metadata.status); status.style.fontSize='12px'; status.style.opacity='0.65';
      if (metadata.error) { const warning=add('div',metadata.error); warning.style.fontSize='12px'; warning.style.marginTop='8px'; warning.style.opacity='0.7'; }
      document.documentElement.style.colorScheme='\(dark ? "dark" : "light")';
      document.documentElement.style.backgroundColor='\(background)';
      if (document.body) {
        document.body.style.backgroundColor='\(background)';
        document.body.style.color='\(foreground)';
        document.body.style.fontSize='\(fontSize)px';
        document.body.style.fontFamily='Georgia,serif'; document.body.style.lineHeight='1.65';
        document.body.style.padding='18px'; document.body.style.maxWidth='720px'; document.body.style.margin='auto'; document.body.style.overflowWrap='anywhere';
      }
      document.querySelectorAll('a').forEach(link => link.style.color='\(link)');
      return {headerHeight: header.offsetTop + header.offsetHeight + 24, contentHeight: document.documentElement.scrollHeight};
      })();
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
    web.scrollView.contentInsetAdjustmentBehavior = .never
    web.isOpaque = false
    web.backgroundColor = .clear
    return web
  }
  func updateUIView(_ web: WKWebView, context: Context) {
    context.coordinator.parent = self
    scrollState.flush = { [weak web, weak coordinator = context.coordinator] in
      guard let web else { return }
      coordinator?.save(web.scrollView)
    }
    if context.coordinator.loaded != url {
      context.coordinator.loaded = url
      context.coordinator.restoring = true
      web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    web.backgroundColor = pageBackground
    web.scrollView.backgroundColor = web.backgroundColor
    if !web.isLoading,
      context.coordinator.fontSize != fontSize || context.coordinator.appearance != appearance
        || context.coordinator.header != header
    {
      context.coordinator.present(
        web,
        progress: context.coordinator.restoring
          ? progress : context.coordinator.currentProgress(web.scrollView))
    }
  }

  final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
    var parent: ArticleWebView
    var restoring = true
    var loaded: URL?
    var fontSize: Double = 20
    var appearance: String?
    var lastSaved = Date.distantPast
    var header: ArticleHeader?
    var headerHeight = 0.0
    var position = 0.0
    var presentation = 0
    var layoutObservation: NSKeyValueObservation?
    init(_ parent: ArticleWebView) { self.parent = parent }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      present(webView, progress: parent.progress)
    }
    func present(_ web: WKWebView, progress: Double) {
      restoring = true
      layoutObservation?.invalidate()
      layoutObservation = nil
      presentation += 1
      let current = presentation
      let expected = loaded
      fontSize = parent.fontSize
      appearance = parent.appearance
      header = parent.header
      web.evaluateJavaScript(parent.styleScript) { value, error in
        guard current == self.presentation, expected == self.loaded else { return }
        guard error == nil else {
          self.restoring = false
          return
        }
        guard let dimensions = value as? [String: NSNumber],
          let measuredHeader = dimensions["headerHeight"]?.doubleValue,
          let measuredContent = dimensions["contentHeight"]?.doubleValue
        else {
          self.restoring = false
          return
        }
        self.headerHeight = measuredHeader
        // WebKit's DOM layout and its native scroll content size update separately.
        // Restore only when the native viewport reflects the styled document.
        let restore: () -> Void = { [weak self, weak web] in
          guard let self, let web, self.restoring, current == self.presentation,
            expected == self.loaded
          else {
            return
          }
          let scale = web.scrollView.zoomScale
          guard web.scrollView.bounds.height > 0,
            abs(web.scrollView.contentSize.height - measuredContent * scale) < 2 * scale
          else { return }
          self.headerHeight = measuredHeader * scale
          self.layoutObservation?.invalidate()
          self.layoutObservation = nil
          let offset = ReadingScrollPosition.offset(
            progress: progress, contentHeight: web.scrollView.contentSize.height,
            viewportHeight: web.scrollView.bounds.height, headerHeight: self.headerHeight)
          web.scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
          self.position = progress
          self.lastSaved = Date()
          self.restoring = false
        }
        self.layoutObservation = web.scrollView.observe(\.contentSize, options: [.new]) { _, _ in
          // Leave the native size setter before restoring; it may clamp the old offset.
          DispatchQueue.main.async(execute: restore)
        }
        DispatchQueue.main.async(execute: restore)
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
    func save(_ scroll: UIScrollView) {
      guard !restoring else { return }
      guard scroll.contentSize.height > scroll.bounds.height else { return }
      lastSaved = Date()
      position = currentProgress(scroll)
      parent.onProgress(position)
    }
    func currentProgress(_ scroll: UIScrollView) -> Double {
      ReadingScrollPosition.progress(
        offset: scroll.contentOffset.y, contentHeight: scroll.contentSize.height,
        viewportHeight: scroll.bounds.height, headerHeight: headerHeight)
    }
  }
}
