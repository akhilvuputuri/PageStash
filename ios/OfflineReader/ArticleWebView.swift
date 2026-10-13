import ReaderCore
import SwiftUI
import WebKit

struct ArticleHeader: Equatable {
  let title: String
  let kind: String
  let author: String?
  let source: URL?
  /// Shown only for exceptional states; the normal offline-ready state is quiet.
  let status: String?
  let error: String?
  /// Label for the end-of-article finish link, or nil when finishing does not apply.
  var finishLabel: String? = nil
  var payload: String {
    var data: [String: String] = ["title": title, "kind": kind]
    if let status { data["status"] = status }
    if let finishLabel { data["finish"] = finishLabel }
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
  /// Links with this scheme come from controls the reader injects, never from article content.
  static let actionScheme = "offline-reader-action"
  static let finishAction = URL(string: "\(actionScheme):finish")!
  /// Only the exact injected link counts, and only while the reader is showing it.
  static func isFinishAction(_ url: URL, finishShown: Bool) -> Bool {
    finishShown && url.absoluteString == finishAction.absoluteString
  }
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @AppStorage("appearance") private var selectedAppearance = "light"
  let url: URL
  let header: ArticleHeader
  let scrollState: ArticleScrollState
  let progress: Double
  let fontSize: Double
  var onFinish: (() -> Void)? = nil
  let onProgress: (Double) -> Void
  private var tokens: ThemeTokens { ThemeTokens.resolve(selectedAppearance, colorScheme) }
  var appearance: String { tokens.name }
  /// The reader's size preference is relative to the system text size: it equals `fontSize`
  /// at the default size and grows with larger and accessibility sizes.
  var scaledFontSize: Double {
    UIFontMetrics(forTextStyle: .body).scaledValue(
      for: fontSize,
      compatibleWith: UITraitCollection(
        preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize)))
  }
  private var pageBackground: UIColor { UIColor(hex: tokens.page) }
  /// Everything that changes the injected presentation; a change re-applies it in place.
  struct Presentation: Equatable {
    let fontSize: Double
    let appearance: String
    let increasedContrast: Bool
    let compactHeadings: Bool
    let header: ArticleHeader
  }
  var presentation: Presentation {
    Presentation(
      fontSize: scaledFontSize, appearance: appearance, increasedContrast: contrast == .increased,
      compactHeadings: dynamicTypeSize.isAccessibilitySize, header: header)
  }
  private var styleScript: String {
    let high = contrast == .increased
    let ink = tokens.ink.hex(high)
    let secondary = tokens.secondaryInk.hex(high)
    let link = tokens.link.hex(high)
    let accent = tokens.accent.hex(high)
    let scale = scaledFontSize / max(fontSize, 1)
    // At accessibility sizes the body is already large; headings converge toward it, as native text styles do.
    let headings = dynamicTypeSize.isAccessibilitySize ? "1.3em,1.2em,1.1em" : ",,"
    return """
      (() => {
      const metadata = \(header.payload);
      const body = document.body;
      if (!body) return 0;
      const root = document.documentElement;
      [['--reader-page','\(tokens.page)'],['--reader-ink','\(ink)'],['--reader-secondary','\(secondary)'],['--reader-link','\(link)'],['--reader-accent','\(accent)'],['--reader-separator','\(tokens.separator)']].forEach(([name,value]) => root.style.setProperty(name,value));
      const headerKey = Symbol.for('OfflineReader.articleHeader');
      let header = window[headerKey];
      if (!header || !header.isConnected) {
        const heading = body.querySelector('h1,h2');
        if (heading) { const prior=document.createRange(); prior.setStart(body,0); prior.setEndBefore(heading); if (!prior.toString().trim() && heading.textContent.replace(/\\s+/g,' ').trim() === metadata.title.replace(/\\s+/g,' ').trim()) heading.remove(); }
        header = document.createElement('header'); header.id='reader-header'; body.prepend(header); window[headerKey]=header;
      }
      header.replaceChildren();
      header.style.marginBottom='24px'; header.style.paddingBottom='16px'; header.style.borderBottom='1px solid var(--reader-separator)';
      const add = (tag,text) => { const node=document.createElement(tag); node.textContent=text; header.append(node); return node; };
      const small = (node,size) => { node.style.fontSize=(size*\(scale))+'px'; node.style.color='var(--reader-secondary)'; node.style.fontFamily='-apple-system,system-ui,sans-serif'; return node; };
      if (metadata.kind === 'brief') {
        const kind=small(add('div','AGENT-CREATED BRIEF'),12); kind.style.letterSpacing='1.5px'; kind.style.fontWeight='600';
        small(add('div','Written by an assistant. It may contain errors; check the sources.'),13).style.marginTop='4px';
      }
      const title=add('h1',metadata.title); title.style.fontSize='\(max(24, scaledFontSize * (dynamicTypeSize.isAccessibilitySize ? 1.15 : 1.4)))px'; title.style.lineHeight='1.2'; title.style.margin='10px 0';
      if (metadata.author) { small(add('div',metadata.author),14).style.marginBottom='8px'; }
      if (metadata.source) {
        const source=add('a','View original · '+metadata.host); source.href=metadata.source; source.style.display='block'; source.style.fontSize=(13*\(scale))+'px'; source.style.fontFamily='-apple-system,system-ui,sans-serif'; source.style.marginBottom='8px';
      }
      if (metadata.status) { small(add('div',metadata.status),12); }
      if (metadata.error) { small(add('div',metadata.error),12).style.marginTop='8px'; }
      const footerKey = Symbol.for('OfflineReader.articleFooter');
      let footer = window[footerKey];
      if (footer && footer.isConnected) footer.remove();
      if (metadata.finish) {
        footer = document.createElement('footer'); footer.id='reader-footer'; window[footerKey]=footer;
        footer.style.margin='40px 0 24px'; footer.style.paddingTop='24px'; footer.style.borderTop='1px solid var(--reader-separator)'; footer.style.textAlign='center';
        const finish=document.createElement('a'); finish.textContent=metadata.finish; finish.href='\(Self.finishAction.absoluteString)';
        finish.setAttribute('role','button'); finish.style.display='inline-block'; finish.style.padding='12px 28px'; finish.style.minHeight='44px'; finish.style.boxSizing='border-box';
        finish.style.border='1.5px solid var(--reader-accent)'; finish.style.borderRadius='999px'; finish.style.textDecoration='none';
        finish.style.fontFamily='-apple-system,system-ui,sans-serif'; finish.style.fontWeight='600'; finish.style.fontSize=(17*\(scale))+'px';
        footer.append(finish); body.append(footer);
      }
      root.style.colorScheme='\(tokens.isDark ? "dark" : "light")';
      root.style.backgroundColor='\(tokens.page)';
      body.style.backgroundColor='\(tokens.page)';
      body.style.color='\(ink)';
      body.style.fontSize='\(scaledFontSize)px';
      body.style.fontFamily='ui-serif,Georgia,serif'; body.style.lineHeight='1.6';
      body.style.padding='18px';
      body.style.maxWidth='36em'; body.style.margin='auto'; body.style.overflowWrap='break-word';
      [['hyphens','auto'],['-webkit-hyphens','auto'],['text-wrap','pretty'],['hanging-punctuation','first']].forEach(([name,value]) => body.style.setProperty(name,value));
      if (!body.hasAttribute('dir')) body.setAttribute('dir','auto');
      const sizes='\(headings)'.split(',');
      body.querySelectorAll('h1,h2,h3').forEach(heading => {
        heading.style.lineHeight='1.2';
        if (heading.parentElement !== header) heading.style.fontSize=sizes[Number(heading.tagName[1])-1];
      });
      document.querySelectorAll('a').forEach(link => link.style.color='var(--reader-link)');
      if (footer && footer.isConnected) footer.querySelector('a').style.color='var(--reader-accent)';
      return {headerHeight: header.offsetTop + header.offsetHeight + 24, contentHeight: root.scrollHeight};
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
      context.coordinator.position = progress
      context.coordinator.restoring = true
      web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    web.backgroundColor = pageBackground
    web.scrollView.backgroundColor = web.backgroundColor
    if !web.isLoading, context.coordinator.presentation != presentation {
      context.coordinator.present(
        web,
        progress: context.coordinator.restoring
          ? context.coordinator.position : context.coordinator.currentProgress(web.scrollView))
    }
  }

  final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
    var parent: ArticleWebView
    var restoring = true
    var loaded: URL?
    var lastSaved = Date.distantPast
    /// The presentation most recently injected; `fontSize` and `appearance` describe it.
    var presentation: ArticleWebView.Presentation?
    var fontSize: Double { presentation?.fontSize ?? 0 }
    var appearance: String? { presentation?.appearance }
    var headerHeight = 0.0
    var position = 0.0
    var generation = 0
    var layoutObservation: NSKeyValueObservation?
    init(_ parent: ArticleWebView) { self.parent = parent }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      present(webView, progress: parent.progress)
    }
    func present(_ web: WKWebView, progress: Double) {
      // Carry the pending target through overlapping appearance/environment updates.
      position = progress
      restoring = true
      layoutObservation?.invalidate()
      layoutObservation = nil
      generation += 1
      let current = generation
      let expected = loaded
      presentation = parent.presentation
      web.evaluateJavaScript(parent.styleScript) { value, error in
        guard current == self.generation, expected == self.loaded else { return }
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
          guard let self, let web, self.restoring, current == self.generation,
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
        if target.scheme == ArticleWebView.actionScheme {
          if ArticleWebView.isFinishAction(target, finishShown: parent.header.finishLabel != nil) {
            parent.onFinish?()
          }
        } else if ["https", "http"].contains(target.scheme ?? "") {
          UIApplication.shared.open(target)
        }
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
