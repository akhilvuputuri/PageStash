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
  private static var indexedSignature: Int?

  /// The article to resume: the last one opened if it is still unfinished in the Library,
  /// otherwise the most recently saved partly read article.
  static func continueItem(_ items: [ReadingItem]) -> ReadingItem? {
    let unfinished = items.filter { $0.hasPreparedContent && !$0.archived && $0.progress < 1 }
    if let id = UserDefaults.standard.string(forKey: lastOpenedKey),
      let item = unfinished.first(where: { $0.id == id })
    {
      return item
    }
    return unfinished.first { $0.progress > 0 }
  }
  static func didOpen(_ id: String) { UserDefaults.standard.set(id, forKey: lastOpenedKey) }

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
    UIApplication.shared.shortcutItems =
      next.map {
        [
          UIApplicationShortcutItem(
            type: continueAction, localizedTitle: "Continue Reading", localizedSubtitle: $0.title,
            icon: UIApplicationShortcutIcon(systemImageName: "book"),
            userInfo: ["id": $0.id as NSString])
        ]
      } ?? []
    index(items)
  }
  /// Saved articles appear in Spotlight by title, source and author. Only what is on this device
  /// is indexed, and nothing leaves it.
  private static func index(_ items: [ReadingItem]) {
    let visible = items.filter(\.hasPreparedContent)
    var hasher = Hasher()
    for item in visible {
      hasher.combine(item.id)
      hasher.combine(item.title)
      hasher.combine(item.archived)
      hasher.combine(item.siteName)
    }
    let signature = hasher.finalize()
    guard signature != indexedSignature else { return }
    indexedSignature = signature
    let searchable = visible.map { item in
      let attributes = CSSearchableItemAttributeSet(contentType: .text)
      attributes.title = item.title
      attributes.contentDescription = [
        ArticleRow.source(item), item.author, item.archived ? "Archived" : nil,
      ].compactMap { $0 }.joined(separator: " · ")
      return CSSearchableItem(
        uniqueIdentifier: item.id, domainIdentifier: spotlightDomain, attributeSet: attributes)
    }
    let index = CSSearchableIndex.default()
    index.deleteSearchableItems(withDomainIdentifiers: [spotlightDomain]) { _ in
      index.indexSearchableItems(searchable)
    }
  }
  /// Signing out removes everything the system holds about the library.
  static func clear() {
    indexedSignature = nil
    CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [spotlightDomain])
    ContinueReading(article: nil, updated: Date()).save()
    WidgetCenter.shared.reloadTimelines(ofKind: ContinueReading.widgetKind)
    UIApplication.shared.shortcutItems = []
    UserDefaults.standard.removeObject(forKey: lastOpenedKey)
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
    AppState.shared.open(item.id)
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
    try await AppState.shared.save(url.absoluteString, key: UUID().uuidString)
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
  }
}
