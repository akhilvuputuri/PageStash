import AppIntents
import SwiftUI

// The new Siri in iOS 27 calls app intents that adopt an App Schema as tools, with no training
// phrases, and uses the app entities on screen to resolve "this article". Schemas need the iOS 27
// SDK, so everything that names one is compiled only by Swift 6.4 (Xcode 27) and runs only on
// iOS 27. Older compilers and systems keep the intents in ArticleIntents.swift unchanged.
//
// Of the schemas in the iOS 27 SDK, `system.searchInApp` fits and is adopted. Not adopted:
// - `system.open`: a schema intent must itself require iOS 27, and App Intents allows one
//   OpenIntent per entity type, so it can't sit beside Open Article, which Spotlight uses to
//   open article results on iOS 18 to 26. It replaces Open Article once the app requires iOS 27.
// - `browser.readingListItem`: the closest entity schema, but a schema entity must also require
//   iOS 27, so it would be a second type naming the same article beside `ArticleEntity`, which
//   every intent, the Spotlight index and the annotations below use; it also needs a link, which
//   agent briefs don't have. Apple lists the browser domain as Shortcuts-only.
// - `system.search` (iOS 18, deprecated in iOS 27): Xcode 27 accepts it beside `searchInApp`, but
//   Xcode 16.4 (CI) would need the older `@AssistantIntent(schema:)` spelling, which can't be
//   checked locally, and on iOS 27 it would be a second, deprecated search.
// - The browser, books and reader domains' intents describe a web browser, purchased books and
//   paged documents. Read next, Reading Context, Done Reading and Continue Reading match no schema.

extension View {
  /// Annotates a view with the saved article it shows, so Siri and Apple Intelligence know which
  /// article is on screen. The reader's article body is a web view, so its SwiftUI container
  /// carries the annotation. Built with the iOS 27 SDK and on iOS 18.4 and later; elsewhere the
  /// reader's user activity in ArticleIntents.swift still names the open article.
  @ViewBuilder func articleEntity(_ id: String?) -> some View {
    #if compiler(>=6.4)
      if #available(iOS 18.4, *) {
        appEntityIdentifier(id.map { EntityIdentifier(for: ArticleEntity.self, identifier: $0) })
      } else {
        self
      }
    #else
      self
    #endif
  }
}

/// A search Siri asked for, which the Library shows in its own search field.
@MainActor final class LibrarySearch: ObservableObject {
  struct Request: Equatable {
    let id = UUID()
    let term: String
    let date = Date()
    /// Like a pending open, a request the Library sees much later (after signing in) is dropped.
    var isCurrent: Bool { Date().timeIntervalSince(date) < 15 }
  }
  /// The Library closes what covers its results; the list fills its search field.
  enum Step { case uncover, fill }
  static let shared = LibrarySearch()
  @Published var request: Request?
  private var done: [Step: UUID] = [:]
  /// The current request if this step hasn't handled it yet, so a Library view recreated within
  /// the 15 seconds doesn't apply it again.
  func take(_ step: Step) -> Request? {
    guard let request, request.isCurrent, done[step] != request.id else { return nil }
    done[step] = request.id
    return request
  }
}

#if compiler(>=6.4)
  /// Search as the `system.searchInApp` schema, so the new Siri can show the Library's results for
  /// "search PageStash for …". It matches titles and downloaded text, as the search field does.
  @available(iOS 27.0, *)
  @AppIntent(schema: .system.searchInApp)
  struct SearchLibraryIntent: ShowInAppSearchResultsIntent {
    static let searchScopes: [StringSearchScope] = [.general]
    var criteria: StringSearchCriteria
    @MainActor func perform() async throws -> some IntentResult {
      guard AppState.shared.session != nil else { throw IntentError.signedOut }
      LibrarySearch.shared.request = .init(term: criteria.term)
      return .result()
    }
  }
#endif
