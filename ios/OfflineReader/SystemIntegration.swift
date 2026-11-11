import AppIntents
import CoreSpotlight
import ReaderCore
import UIKit
import WidgetKit

/// Spotlight, the Continue Reading widget and Home Screen quick action, kept in step with the library.
@MainActor enum SystemIntegration {
  static let spotlightDomain = "library"
  static let continueAction = "continue-reading"
  static let lastOpenedKey = "lastOpenedItem"
  private static let signatureKey = "spotlightSignature"
  /// Bumped by `clear()`, so an index request that started before sign-out never re-adds the library.
  private static var generation = 0
  private static var shortcutID: String?

  /// The article to resume: the last one opened if it is still unfinished in the Library,
  /// otherwise the most recently saved partly read article.
  static func continueItem(_ items: [ReadingItem]) -> ReadingItem? {
    let unfinished = items.filter {
      $0.hasPreparedContent && !$0.archived && !$0.isTrashed && $0.progress < 1
    }
    if let id = UserDefaults.standard.string(forKey: lastOpenedKey),
      let item = unfinished.first(where: { $0.id == id })
    {
      return item
    }
    return unfinished.first { $0.progress > 0 }
  }
  static func didOpen(_ id: String) {
    UserDefaults.standard.set(id, forKey: lastOpenedKey)
    ArticleDonation.opened(id)
  }

  static func update(items: [ReadingItem], position: (ReadingItem) -> Double) {
    let next = continueItem(items)
    let article = next.map {
      ContinueReading.Article(
        id: $0.id, title: $0.title, source: ArticleRow.source($0), progress: position($0))
    }
    if ContinueReading.load()?.article != article {
      ContinueReading(article: article, updated: Date()).save()
      WidgetCenter.shared.reloadTimelines(ofKind: ContinueReading.widgetKind)
    }
    // Reloads are frequent (every download); only touch the quick action when it changes.
    let shortcut = next.map { "\($0.id)\u{1}\($0.title)" }
    if shortcut != shortcutID {
      shortcutID = shortcut
      UIApplication.shared.shortcutItems =
        next.map {
        [
          UIApplicationShortcutItem(
            type: continueAction, localizedTitle: "Continue Reading", localizedSubtitle: $0.title,
            icon: UIApplicationShortcutIcon(systemImageName: "book"),
            userInfo: ["id": $0.id as NSString])
        ]
        } ?? []
    }
    index(items)
  }
  /// Saved articles appear in Spotlight by title, source, author and, once downloaded, the opening
  /// of their text, which Apple Intelligence also uses to find an article from a vague description
  /// and answer questions about it. Only what is on this device is indexed, and nothing leaves it.
  private static func index(_ items: [ReadingItem]) {
    // Trashed items leave Spotlight until they are restored.
    let visible = items.filter { $0.hasPreparedContent && !$0.isTrashed }
    let words = AppState.shared.wordCounts
    let stable = stableSignature(visible, words: words)
    let defaults = UserDefaults.standard
    guard stable != defaults.string(forKey: signatureKey) else { return }
    // Read only when something changed: one clipped query over the local search index.
    let excerpts = (try? AppState.shared.store?.searchExcerpts(characters: excerptLength)) ?? [:]
    let searchable = visible.map { item in
      let entity = ArticleEntity(item)
      let searchable = CSSearchableItem(
        uniqueIdentifier: item.id, domainIdentifier: spotlightDomain,
        attributeSet: entity.spotlightAttributes(excerpt: excerpts[item.id]))
      // Lets Siri and Apple Intelligence resolve the Spotlight result to the article entity.
      if #available(iOS 18, *) { searchable.associateAppEntity(entity) }
      return searchable
    }
    let started = generation
    Task { @MainActor in
      let index = CSSearchableIndex.default()
      try? await index.deleteSearchableItems(withDomainIdentifiers: [spotlightDomain])
      guard started == generation else { return }
      // A failed write leaves the signature alone, so the next reload tries again.
      guard (try? await index.indexSearchableItems(searchable)) != nil, started == generation
      else { return }
      defaults.set(stable, forKey: signatureKey)
    }
  }
  /// Enough of an article's opening for semantic search and questions, without indexing it whole.
  private static let excerptLength = 4000
  /// A launch-independent digest of what Spotlight shows, so a cold launch doesn't re-index.
  /// Word counts stand in for the text: they appear when an article downloads and change with it.
  private static func stableSignature(_ items: [ReadingItem], words: [String: Int]) -> String {
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    // The version re-indexes existing installs once when what is indexed changes (2: entities;
    // 3: author, publisher, link and text).
    for byte in "v3".utf8 { value = (value ^ UInt64(byte)) &* 0x100_0000_01b3 }
    for item in items {
      let fields = [
        item.id, item.title, item.archived ? "1" : "0", item.siteName ?? "", item.author ?? "",
        item.sourceUrl ?? "", String(item.contentVersion), String(words[item.id] ?? 0),
      ]
      for byte in fields.joined(separator: "\u{1}").utf8 + [0] {
        value = (value ^ UInt64(byte)) &* 0x100_0000_01b3
      }
    }
    return String(value, radix: 16)
  }
  /// Signing out removes everything the system holds about the library.
  static func clear() {
    generation += 1
    shortcutID = nil
    UserDefaults.standard.removeObject(forKey: signatureKey)
    CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [spotlightDomain])
    ContinueReading(article: nil, updated: Date()).save()
    WidgetCenter.shared.reloadTimelines(ofKind: ContinueReading.widgetKind)
    UIApplication.shared.shortcutItems = []
    UserDefaults.standard.removeObject(forKey: lastOpenedKey)
    ArticleDonation.clear()
  }
  @discardableResult static func handle(_ shortcut: UIApplicationShortcutItem) -> Bool {
    guard shortcut.type == continueAction, let id = shortcut.userInfo?["id"] as? String else {
      return false
    }
    AppState.shared.open(id)
    return true
  }
}

/// Handles the Home Screen quick action when the app is already running.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
  func windowScene(
    _ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    MainActor.assumeIsolated { completionHandler(SystemIntegration.handle(shortcutItem)) }
  }
}

struct ContinueReadingIntent: AppIntent {
  static let title: LocalizedStringResource = "Continue Reading"
  static let description = IntentDescription("Opens the article you were reading.")
  static let openAppWhenRun = true
  @MainActor func perform() async throws -> some IntentResult {
    guard let item = SystemIntegration.continueItem(AppState.shared.items) else {
      throw IntentError.nothingInProgress
    }
    ArticleDonation.open(item.id)
    return .result()
  }
}
struct SaveLinkIntent: AppIntent {
  static let title: LocalizedStringResource = "Save Link"
  static let description = IntentDescription(
    "Saves a web article to your library so it can be read offline.")
  @Parameter(title: "Link") var url: URL
  @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      throw IntentError.unsupportedLink
    }
    guard AppState.shared.session != nil else { throw IntentError.signedOut }
    // Report the save itself; the follow-up sync can fail or run late without undoing it.
    try await AppState.shared.submit(url.absoluteString, key: UUID().uuidString)
    // Saving submits the link; the server prepares it and the app downloads it afterwards.
    return .result(dialog: "Submitted. It appears in your library once it is prepared.")
  }
}
enum IntentError: Error, CustomLocalizedStringResourceConvertible {
  case nothingInProgress, unsupportedLink, signedOut
  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .nothingInProgress: return "There is no article in progress."
    case .unsupportedLink: return "Only web links (http or https) can be saved."
    case .signedOut: return "Open the app and sign in first."
    }
  }
}
struct ReaderShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ContinueReadingIntent(),
      phrases: ["Continue reading in \(.applicationName)", "Resume \(.applicationName)"],
      shortTitle: "Continue Reading", systemImageName: "book")
    AppShortcut(
      intent: SaveLinkIntent(), phrases: ["Save a link to \(.applicationName)"],
      shortTitle: "Save Link", systemImageName: "plus")
    // Article intents live in ArticleIntents.swift.
    AppShortcut(
      intent: WhatToReadNextIntent(),
      phrases: [
        "What should I read next in \(.applicationName)", "What's next in \(.applicationName)",
      ], shortTitle: "What to Read Next", systemImageName: "text.book.closed")
    AppShortcut(
      intent: OpenArticleIntent(),
      phrases: ["Open an article in \(.applicationName)", "Find an article in \(.applicationName)"],
      shortTitle: "Open Article", systemImageName: "doc.text")
    AppShortcut(
      intent: GetReadingContextIntent(),
      phrases: [
        "Get Reading Context in \(.applicationName)",
        "What does this build on in \(.applicationName)",
      ], shortTitle: "Reading Context", systemImageName: "sparkles")
    AppShortcut(
      intent: MarkDoneReadingIntent(),
      phrases: ["Mark done reading in \(.applicationName)", "I'm done reading in \(.applicationName)"],
      shortTitle: "Done Reading", systemImageName: "checkmark.circle")
  }
}
