import AppIntents
import CoreSpotlight
import ReaderCore
import SwiftUI

// Saved articles for Siri, Shortcuts, Spotlight and Apple Intelligence. Everything here reads the
// signed-in library on this device (or the synthetic preview store); nothing new leaves it.
//
// Later SDKs: the iOS 27 App Schemas for the new Siri and on-screen View Annotations are not in the
// iOS 26.2 SDK this builds with. When they are, `ArticleEntity` and these intents are what they
// would describe, and `ArticleActivity` is where the open article would be annotated instead.
// The iOS 18 Assistant Schemas were considered and not adopted: the `books` domain models
// purchased books (series, genre, purchase date) and `reader` models paged documents (rotate,
// insert pages), neither of which fits a saved web article.

/// A saved article. Its identifier is the library item ID, which is also the Spotlight item's
/// unique identifier, so Siri, Spotlight and the app all name the same article the same way.
struct ArticleEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Article"
  static let defaultQuery = ArticleQuery()
  let id: String
  @Property(title: "Title") var title: String
  @Property(title: "Source") var source: String?
  @Property(title: "Author") var author: String?
  @Property(title: "Link") var link: URL?
  @Property(title: "Done Reading") var isFinished: Bool
  /// Source, author and Archived, as Spotlight shows them under the title.
  let details: String

  init(_ item: ReadingItem) {
    id = item.id
    details = [ArticleRow.source(item), item.author, item.archived ? "Archived" : nil]
      .compactMap { $0 }.joined(separator: " · ")
    title = item.title
    source = ArticleRow.source(item)
    author = item.author
    link = item.sourceUrl.flatMap(URL.init(string:))
    isFinished = item.progress >= 1 && item.archived
  }
  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(title)", subtitle: details.isEmpty ? nil : "\(details)",
      image: .init(systemName: "doc.text"))
  }
}

/// Lets Spotlight and Apple Intelligence treat the indexed article as this entity. iOS 18 and later;
/// on iOS 17 articles are still indexed, just without the association.
@available(iOS 18, *)
extension ArticleEntity: IndexedEntity {
  var attributeSet: CSSearchableItemAttributeSet {
    let attributes = CSSearchableItemAttributeSet(contentType: .text)
    attributes.title = title
    attributes.contentDescription = details
    return attributes
  }
}

struct ArticleQuery: EntityStringQuery {
  @MainActor func entities(for identifiers: [String]) async throws -> [ArticleEntity] {
    let items = LibraryQueries.openable(AppState.shared.items)
    return identifiers.compactMap { id in items.first { $0.id == id }.map(ArticleEntity.init) }
  }
  /// Titles first, then articles whose downloaded text matches, from the on-device search index.
  @MainActor func entities(matching string: String) async throws -> [ArticleEntity] {
    let body = (try? AppState.shared.store?.search(string)) ?? []
    return LibraryQueries.search(string, in: AppState.shared.items, bodyMatches: body)
      .prefix(20).map(ArticleEntity.init)
  }
  /// What to read next, then the rest of the library newest first, so a picker shows something.
  @MainActor func suggestedEntities() async throws -> [ArticleEntity] {
    let next = ArticleLibrary.upNext()
    let rest = LibraryQueries.openable(AppState.shared.items).filter { item in
      !next.contains { $0.id == item.id }
    }
    return (next + rest).prefix(20).map(ArticleEntity.init)
  }
}

/// The library as intents see it, read from the app's state on the main actor.
@MainActor enum ArticleLibrary {
  /// The article open in the full-screen reader, which "this article" refers to.
  static var openArticleID: String? { AppState.shared.readerRoute?.id }
  static func item(_ id: String) throws -> ReadingItem {
    guard AppState.shared.session != nil else { throw IntentError.signedOut }
    guard let item = LibraryQueries.openable(AppState.shared.items).first(where: { $0.id == id })
    else { throw ArticleIntentError.notFound }
    return item
  }
  static func upNext() -> [ReadingItem] {
    let store = AppState.shared.store
    return LibraryQueries.upNext(
      AppState.shared.items, excluding: openArticleID,
      downloaded: { (try? store?.readerURL($0.id)) != nil },
      position: { (try? store?.readingPosition($0.id)) ?? $0.progress })
  }
  static func readingTime(_ item: ReadingItem) -> String? {
    ArticleRow.readingTime(words: AppState.shared.wordCounts[item.id], position: 0)
  }
}

struct OpenArticleIntent: OpenIntent {
  static let title: LocalizedStringResource = "Open Article"
  static let description = IntentDescription("Opens a saved article in the reader.")
  static let openAppWhenRun = true
  @Parameter(title: "Article", requestValueDialog: "Which article?") var target: ArticleEntity
  static var parameterSummary: some ParameterSummary { Summary("Open \(\.$target)") }
  @MainActor func perform() async throws -> some IntentResult {
    // Same route as rows, links, Spotlight and the quick action.
    AppState.shared.open(try ArticleLibrary.item(target.id).id)
    return .result()
  }
}

struct WhatToReadNextIntent: AppIntent {
  static let title: LocalizedStringResource = "What to Read Next"
  static let description = IntentDescription(
    "Suggests an unread article from your Library: one already on this device if there is one, then one you haven't started, newest first."
  )
  @MainActor func perform() async throws
    -> some IntentResult & ReturnsValue<ArticleEntity> & ProvidesDialog & ShowsSnippetView
  {
    guard AppState.shared.session != nil else { throw IntentError.signedOut }
    guard let item = ArticleLibrary.upNext().first else { throw ArticleIntentError.nothingToRead }
    let entity = ArticleEntity(item)
    let time = ArticleLibrary.readingTime(item)
    let spoken = ["Next up: “\(item.title)”", entity.source.map { "from \($0)" }, time]
      .compactMap { $0 }.joined(separator: ", ")
    return .result(
      value: entity, dialog: IntentDialog(full: "\(spoken).", supporting: "Next up"),
      view: ArticleSnippet(entity: entity, readingTime: time))
  }
}

struct GetReadingContextIntent: AppIntent {
  static let title: LocalizedStringResource = "Get Reading Context"
  static let description = IntentDescription(
    "Reads the AI-generated Reading Context saved for an article: what it builds on, what you've already read and what's new. Uses the note on this device and never asks for a new one."
  )
  @Parameter(title: "Article", description: "Leave empty for the article open in the reader.")
  var article: ArticleEntity?
  static var parameterSummary: some ParameterSummary {
    Summary("Get Reading Context for \(\.$article)")
  }
  @MainActor func perform() async throws
    -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView
  {
    guard let id = article?.id ?? ArticleLibrary.openArticleID else {
      throw $article.needsValueError("Which article?")
    }
    let item = try ArticleLibrary.item(id)
    // The server decides who has Reading Context; a saved note is not shown once it says no.
    guard AppState.shared.readingContextEnabled else {
      throw ArticleIntentError.contextUnavailable
    }
    // Only the saved note. Generating one costs a model call, so it stays an explicit tap in the app.
    guard let context = AppState.shared.localReadingContext(item) else {
      throw ArticleIntentError.noContext(item.title)
    }
    let text = context.spokenText(title: item.title)
    return .result(
      value: text, dialog: IntentDialog(full: "\(text)", supporting: "AI-generated Reading Context"),
      view: ReadingContextSnippet(title: item.title, context: context))
  }
}

struct MarkDoneReadingIntent: AppIntent {
  static let title: LocalizedStringResource = "Mark Done Reading"
  static let description = IntentDescription(
    "Marks an article as read and moves it to Archive, like Done Reading in the reader. Undo it from the Library."
  )
  @Parameter(title: "Article", description: "Leave empty for the article open in the reader.")
  var article: ArticleEntity?
  static var parameterSummary: some ParameterSummary { Summary("Mark \(\.$article) done reading") }
  @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let id = article?.id ?? ArticleLibrary.openArticleID else {
      throw $article.needsValueError("Which article?")
    }
    let item = try ArticleLibrary.item(id)
    if item.archived && item.progress >= 1 {
      return .result(dialog: "“\(item.title)” is already done.")
    }
    // The same path as the reader's Done Reading, including its one persisted Undo.
    guard AppState.shared.finishReading(item.id) else {
      throw ArticleIntentError.notFinished(AppState.shared.message)
    }
    // Like the in-app action, close the reader if it shows this article.
    if AppState.shared.readerRoute?.id == item.id { AppState.shared.readerRoute = nil }
    return .result(dialog: "Done. “\(item.title)” is in Archive. You can undo it in the Library.")
  }
}

enum ArticleIntentError: Error, CustomLocalizedStringResourceConvertible {
  case notFound, nothingToRead, contextUnavailable
  case noContext(String)
  case notFinished(String?)
  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .notFound: return "That article isn't in your library on this iPhone."
    case .nothingToRead: return "There's nothing unread in your Library."
    case .contextUnavailable: return "Reading Context isn't available for this account."
    case .noContext(let title):
      return
        "No Reading Context is saved for “\(title)” yet. Open the article and choose Reading Context."
    case .notFinished(let reason):
      return "Couldn't mark it done. \(reason ?? "Try again in the app.")"
    }
  }
}

/// Advertises the open article as the current activity, so Siri and Apple Intelligence can resolve
/// "this article" to its entity (iOS 18.2 and later). Handoff, search and prediction stay off:
/// Spotlight already indexes articles and nothing should leave this iPhone.
@MainActor enum ArticleActivity {
  static let type = "com.akhilvuputuri.offlinereader.reading"
  static func describe(_ activity: NSUserActivity, id: String, title: String?) {
    activity.title = title
    activity.isEligibleForHandoff = false
    activity.isEligibleForSearch = false
    activity.isEligibleForPrediction = false
    if #available(iOS 18.2, *) {
      activity.appEntityIdentifier = EntityIdentifier(for: ArticleEntity.self, identifier: id)
    }
  }
}

/// The suggested article, as Siri and Shortcuts show it.
struct ArticleSnippet: View {
  let entity: ArticleEntity
  let readingTime: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(entity.title).font(.headline).lineLimit(3)
      let line = [entity.details.isEmpty ? nil : entity.details, readingTime].compactMap { $0 }
      if !line.isEmpty {
        Text(line.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
  }
}

/// A short form of the saved note. It is labelled AI-generated, as it is in the app.
struct ReadingContextSnippet: View {
  let title: String
  let context: ReadingContext
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("AI-generated Reading Context", systemImage: "sparkles")
        .font(.caption).foregroundStyle(.secondary)
      Text(title).font(.headline).lineLimit(2)
      Text(context.summary).font(.subheadline).lineLimit(6)
      section("Builds on", context.buildsOn.map(\.title))
      section("Already covered", context.covered.map(\.title))
      section("New here", context.newIdeas)
      if context.stale {
        Text("Your finished articles changed since this was written.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
  }
  @ViewBuilder private func section(_ heading: String, _ lines: [String]) -> some View {
    if !lines.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        Text(heading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        ForEach(Array(lines.prefix(3).enumerated()), id: \.offset) { _, line in
          Text(line).font(.footnote).lineLimit(2)
        }
      }
    }
  }
}
