import Foundation

/// Plain text from stored reader HTML, and the splitting and matching the local model needs. Pure,
/// so `swift test` covers it without a model.
public enum ArticleText {
  /// Readable text with paragraph breaks kept as blank lines. Head, scripts and styles are dropped;
  /// nothing runs.
  public static func plainText(html: String) -> String {
    var text = html
    for pattern in [
      "(?is)<head\\b.*?</head>", "(?is)<script\\b.*?</script>", "(?is)<style\\b.*?</style>",
      "(?is)<!--.*?-->",
    ] {
      text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }
    // Block boundaries become paragraph breaks before tags go.
    text = text.replacingOccurrences(
      of: "(?i)<br\\s*/?>|</?(p|div|h[1-6]|li|ul|ol|blockquote|pre|tr|table|section|article|figure|figcaption|header|footer)\\b[^>]*>",
      with: "\n\n", options: .regularExpression)
    text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    return normalize(text, keepParagraphs: true)
  }

  /// Decodes common entities and collapses whitespace, optionally keeping paragraph breaks.
  public static func normalize(_ text: String, keepParagraphs: Bool = false) -> String {
    let decoded = decodeEntities(text)
    let paragraphs = decoded.components(separatedBy: "\n\n").map {
      $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }.filter { !$0.isEmpty }
    return paragraphs.joined(separator: keepParagraphs ? "\n\n" : " ")
  }

  private static let named: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "—",
    "ndash": "–", "hellip": "…", "rsquo": "\u{2019}", "lsquo": "\u{2018}", "rdquo": "\u{201D}",
    "ldquo": "\u{201C}",
  ]
  static func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    var result = ""
    var rest = Substring(text)
    while let amp = rest.firstIndex(of: "&") {
      result += rest[..<amp]
      let after = rest[rest.index(after: amp)...]
      if let semi = after.prefix(10).firstIndex(of: ";") {
        let name = String(after[..<semi])
        var value: String?
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
          value = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map {
            String(Character($0))
          }
        } else if name.hasPrefix("#") {
          value = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map {
            String(Character($0))
          }
        } else {
          value = named[name.lowercased()]
        }
        if let value {
          result += value
          rest = after[after.index(after: semi)...]
          continue
        }
      }
      result += "&"
      rest = after
    }
    return result + rest
  }

  /// Splits text into pieces of at most `maxTokens` (estimated), packing whole paragraphs, then
  /// sentences, then words, so pieces end at natural boundaries.
  public static func chunks(_ text: String, maxTokens: Int) -> [String] {
    let limit = max(16, maxTokens)
    var pieces: [String] = []
    var current = ""
    func flush() {
      if !current.isEmpty { pieces.append(current) }
      current = ""
    }
    func add(_ unit: String, separator: String) {
      let candidate = current.isEmpty ? unit : current + separator + unit
      if TokenEstimate.tokens(candidate) <= limit {
        current = candidate
      } else {
        flush()
        current = unit
      }
    }
    for paragraph in text.components(separatedBy: "\n\n") where !paragraph.isEmpty {
      if TokenEstimate.tokens(paragraph) <= limit {
        add(paragraph, separator: "\n\n")
        continue
      }
      for sentence in sentences(paragraph) {
        if TokenEstimate.tokens(sentence) <= limit {
          add(sentence, separator: " ")
          continue
        }
        var remaining = sentence
        while !remaining.isEmpty {
          let head = TokenEstimate.prefix(remaining, tokens: limit)
          let piece = head.isEmpty ? String(remaining.prefix(limit)) : head
          add(piece, separator: " ")
          remaining = String(remaining.dropFirst(piece.count))
            .trimmingCharacters(in: .whitespaces)
        }
      }
    }
    flush()
    return pieces
  }

  static func sentences(_ text: String) -> [String] {
    var result: [String] = []
    text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
      if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines),
        !sentence.isEmpty
      {
        result.append(sentence)
      }
    }
    return result.isEmpty ? [text] : result
  }

  /// At most `limit` items spread evenly from first to last, keeping order, so a long article's
  /// summary samples its whole length rather than only the start.
  public static func evenlySpaced<T>(_ items: [T], limit: Int) -> [T] {
    guard items.count > limit, limit > 0 else { return items }
    if limit == 1 { return [items[0]] }
    let step = Double(items.count - 1) / Double(limit - 1)
    var picked: [Int] = []
    for i in 0..<limit {
      let index = Int((Double(i) * step).rounded())
      if picked.last != index { picked.append(index) }
    }
    return picked.map { items[$0] }
  }

  // MARK: Matching

  private static let stopWords: Set<String> = [
    "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "her", "was", "one",
    "our", "out", "has", "had", "his", "how", "its", "who", "why", "what", "when", "where",
    "which", "with", "this", "that", "these", "those", "from", "they", "them", "their", "there",
    "then", "than", "been", "have", "into", "about", "does", "did", "will", "would", "could",
    "should", "your", "more", "most", "some", "such", "only", "also", "very", "just", "over",
    "were", "being", "after", "before", "because", "while", "article", "say", "says", "said",
  ]
  /// Lowercased content words with a crude plural/verb ending stripped, for lexical matching.
  public static func keywords(_ text: String) -> [String] {
    text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap {
      word -> String? in
      let word = String(word)
      guard word.count >= 3, !stopWords.contains(word) else { return nil }
      return stem(word)
    }
  }
  static func stem(_ word: String) -> String {
    for suffix in ["ing", "ies", "es", "ed", "s"] where word.count > suffix.count + 3 {
      if word.hasSuffix(suffix) { return String(word.dropLast(suffix.count)) }
    }
    return word
  }
}
