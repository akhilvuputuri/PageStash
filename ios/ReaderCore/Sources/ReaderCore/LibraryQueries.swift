import Foundation

/// How Siri, Shortcuts and Spotlight find articles. Pure functions over the local library, so they
/// work offline, read nothing from the network and can be tested without the app.
public enum LibraryQueries {
  /// Articles an intent may refer to: prepared and not in Trash. Archived ones stay findable, so a
  /// finished article can still be opened or asked about.
  public static func openable(_ items: [ReadingItem]) -> [ReadingItem] {
    items.filter { $0.hasPreparedContent && !$0.isTrashed && !$0.deleted }
  }
  /// Unfinished articles in the Library, ranked for reading next: ones already on this device
  /// first (they open offline), then ones not started (a partly read article is what Continue
  /// Reading is for), then the newest saved. `excluding` drops the article open in the reader.
  public static func upNext(
    _ items: [ReadingItem], excluding: String? = nil, downloaded: (ReadingItem) -> Bool,
    position: (ReadingItem) -> Double
  ) -> [ReadingItem] {
    let candidates = openable(items).filter {
      !$0.archived && $0.progress < 1 && $0.id != excluding
    }
    // Score once per item; the closures may read the store.
    let ranked = candidates.map { item in
      (item: item, local: downloaded(item), started: position(item) > 0)
    }
    return ranked.sorted { a, b in
      if a.local != b.local { return a.local }
      if a.started != b.started { return !a.started }
      if a.item.capturedAt != b.item.capturedAt { return a.item.capturedAt > b.item.capturedAt }
      return a.item.id < b.item.id
    }.map(\.item)
  }
  /// Openable articles matching a spoken or typed query: titles containing every word first
  /// (ignoring case and accents), then articles whose text matched in the local search index.
  public static func search(
    _ query: String, in items: [ReadingItem], bodyMatches: Set<String> = []
  ) -> [ReadingItem] {
    let words = query.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(
      String.init)
    guard !words.isEmpty else { return [] }
    let candidates = openable(items)
    let titled = candidates.filter { item in
      words.allSatisfy {
        item.title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      }
    }
    let titledIDs = Set(titled.map(\.id))
    return titled + candidates.filter { bodyMatches.contains($0.id) && !titledIDs.contains($0.id) }
  }
  /// Readable opening text from the search index's tag-stripped article body, for Spotlight's
  /// semantic search and questions about an article: common entities decoded, whitespace collapsed
  /// and cut at a word boundary. Nil when there is no text.
  public static func excerpt(_ body: String, characters: Int) -> String? {
    var text = body
    for (entity, value) in [
      ("&nbsp;", " "), ("&#160;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
      ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&amp;", "&"),
    ] {
      text = text.replacingOccurrences(of: entity, with: value)
    }
    text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !text.isEmpty, characters > 0 else { return nil }
    guard text.count > characters else { return text }
    let clipped = text.prefix(characters)
    let cut = clipped.lastIndex(of: " ").map { clipped[..<$0] } ?? clipped
    return String(cut) + "…"
  }
}

extension ReadingContext {
  /// The note as one paragraph for Siri to speak and Shortcuts to pass on. It says it is
  /// AI-generated, because it is, and names articles by title only, to keep it short.
  public func spokenText(title: String) -> String {
    var gist = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    if let last = gist.last, !".!?…".contains(last) { gist += "." }
    var parts = ["AI-generated Reading Context for “\(title)”: \(gist)"]
    if !buildsOn.isEmpty { parts.append("It builds on \(Self.list(buildsOn.map(\.title))).") }
    if !covered.isEmpty {
      parts.append("You've already read about parts of it in \(Self.list(covered.map(\.title))).")
    }
    let ideas = newIdeas.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .\n")) }
    if !ideas.isEmpty { parts.append("New here: \(ideas.joined(separator: "; ")).") }
    if stale { parts.append("Your finished articles changed since it was written.") }
    return parts.joined(separator: " ")
  }
  /// "A", "A and B", "A, B and C", with titles quoted.
  static func list(_ titles: [String]) -> String {
    let quoted = titles.map { "“\($0)”" }
    guard quoted.count > 1 else { return quoted.first ?? "" }
    return quoted.dropLast().joined(separator: ", ") + " and " + quoted[quoted.count - 1]
  }
}
