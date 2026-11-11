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
  /// What is in the Spotlight index: article ID to `SpotlightSync.signature`, and its version.
  private static let indexedKey = "spotlightIndexed"
  private static let indexVersionKey = "spotlightIndexVersion"
  /// The whole-library digest earlier builds kept; removed on upgrade.
  private static let legacySignatureKey = "spotlightSignature"
  /// Bumped by `clear()`; an index run checks it after every wait, so a run that started before
  /// sign-out never re-adds the library.
  private static var generation = 0
  private static var indexGate = SpotlightSync.Gate()
  /// The newest library an index run should reflect.
  private static var indexItems: [ReadingItem] = []
  /// Spotlight's requests to rebuild, applied at the start of the next run so a run in flight
  /// can't overwrite them: everything, or these articles.
  private static var reindexAll = false
  private static var reindexIDs: Set<String> = []
  /// Held strongly: the index keeps its delegate weakly.
  private static let reindexer = SpotlightReindexer()
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
  ///
  /// Every finished download reloads the library, so indexing is incremental and serialized: one
  /// run at a time touches only new, changed and removed articles, and a request during a run gets
  /// one more run over the newest library. Runs never overlap, so an older one can't put back an
  /// article (or its text) that was trashed or deleted meanwhile.
  private static func index(_ items: [ReadingItem]) {
    indexItems = items
    let systemIndex = CSSearchableIndex.default()
    if systemIndex.indexDelegate == nil { systemIndex.indexDelegate = reindexer }
    guard indexGate.request() else { return }
    Task { @MainActor in
      repeat { await indexRun() } while indexGate.finish()
    }
  }
  private static func indexRun() async {
    // Downloads finish in bursts; let a burst settle into one run.
    try? await Task.sleep(for: .milliseconds(500))
    let started = generation
    let defaults = UserDefaults.standard
    let index = CSSearchableIndex.default()
    var indexed = defaults.dictionary(forKey: indexedKey) as? [String: String] ?? [:]
    if reindexAll { defaults.removeObject(forKey: indexVersionKey) }
    for id in reindexIDs where indexed[id] != nil { indexed[id] = "" }
    (reindexAll, reindexIDs) = (false, [])
    if defaults.string(forKey: indexVersionKey) != SpotlightSync.version {
      // Once per version (and after sign-out): replace the whole domain, then go incremental.
      let replaced: Void? = try? await index.deleteSearchableItems(
        withDomainIdentifiers: [spotlightDomain])
      guard replaced != nil, started == generation else { return }
      indexed = [:]
      defaults.set(indexed, forKey: indexedKey)
      defaults.set(SpotlightSync.version, forKey: indexVersionKey)
      defaults.removeObject(forKey: legacySignatureKey)
    }
    // Trashed and deleted items leave Spotlight until they are restored.
    let visible = SpotlightSync.visible(indexItems)
    let words = AppState.shared.wordCounts
    let current = Dictionary(
      visible.map { ($0.id, SpotlightSync.signature($0, words: words[$0.id])) },
      uniquingKeysWith: { first, _ in first })
    let plan = SpotlightSync.plan(current, indexed: indexed)
    guard !plan.isEmpty else {
      defaults.set(indexed, forKey: indexedKey)
      return
    }
    // Write-ahead: record the articles about to be written before Spotlight can have them, so a
    // kill during the write can't leave one indexed that a later run doesn't know to remove.
    defaults.set(SpotlightSync.pending(plan, onto: indexed), forKey: indexedKey)
    // An article that left the library takes its suggestions with it.
    ArticleDonation.forget(plan.remove)
    // Read and tidy only the changed articles' text, off the main actor.
    let store = AppState.shared.store
    let ids = Set(plan.upsert.keys)
    let length = excerptLength
    let excerpts = await Task.detached(priority: .utility) {
      ids.isEmpty ? [:] : ((try? store?.searchExcerpts(characters: length, ids: ids)) ?? [:])
    }.value
    guard started == generation else { return }
    let searchable = visible.filter { ids.contains($0.id) }.map { item in
      let entity = ArticleEntity(item)
      let searchable = CSSearchableItem(
        uniqueIdentifier: item.id, domainIdentifier: spotlightDomain,
        attributeSet: entity.spotlightAttributes(excerpt: excerpts[item.id]))
      // Lets Siri and Apple Intelligence resolve the Spotlight result to the article entity.
      if #available(iOS 18, *) { searchable.associateAppEntity(entity) }
      return searchable
    }
    var removed = true
    if !plan.remove.isEmpty {
      removed =
        (try? await index.deleteSearchableItems(withIdentifiers: Array(plan.remove))) != nil
      guard started == generation else { return }
    }
    var upserted = true
    if !searchable.isEmpty {
      upserted = (try? await index.indexSearchableItems(searchable)) != nil
      guard started == generation else { return }
    }
    // A failed write is retried by the next run; see `SpotlightSync.record`.
    defaults.set(
      SpotlightSync.record(plan, onto: indexed, upserted: upserted, removed: removed),
      forKey: indexedKey)
  }
  /// Enough of an article's opening for semantic search and questions, without indexing it whole.
  private static let excerptLength = 4000
  /// Spotlight lost or couldn't apply some of the app's items: rebuild them on the next run.
  static func reindex(_ ids: Set<String>?) {
    if let ids { reindexIDs.formUnion(ids) } else { reindexAll = true }
    index(indexItems)
  }
  /// Signing out removes everything the system holds about the library.
  static func clear() {
    generation += 1
    indexGate.reset()
    indexItems = []
    shortcutID = nil
    for key in [indexedKey, indexVersionKey, legacySignatureKey] {
      UserDefaults.standard.removeObject(forKey: key)
    }
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

/// Receives Spotlight's requests to rebuild the app's items while the app runs. (Requests while it
/// isn't running would need an index extension; the app re-checks its items on every reload.)
final class SpotlightReindexer: NSObject, CSSearchableIndexDelegate {
  func searchableIndex(
    _ searchableIndex: CSSearchableIndex,
    reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void
  ) {
    // The request is kept until the next run applies it, so it can be acknowledged now.
    DispatchQueue.main.async {
      MainActor.assumeIsolated { SystemIntegration.reindex(nil) }
      acknowledgementHandler()
    }
  }
  func searchableIndex(
    _ searchableIndex: CSSearchableIndex,
    reindexSearchableItemsWithIdentifiers identifiers: [String],
    acknowledgementHandler: @escaping () -> Void
  ) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated { SystemIntegration.reindex(Set(identifiers)) }
      acknowledgementHandler()
    }
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
  /// It adds to the account, so not from a locked iPhone.
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
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
