import Foundation

/// "Ask about this article": the article is split into short passages, the ones that best match
/// the question are picked by simple lexical scoring, and the model answers only from them.
/// Nothing is stored and no earlier question is remembered, so every answer fits the window.
public enum ArticleQuestion {
  public static let maxQuestionCharacters = 300
  public static let maxAnswerCharacters = 1500
  static let passageTokens = 160

  /// Short passages at paragraph or sentence boundaries.
  public static func passages(_ text: String) -> [String] {
    ArticleText.chunks(text, maxTokens: passageTokens)
  }

  /// The best-matching passages within `budgetTokens`, in article order. A BM25-style score:
  /// rarer question words count for more and long passages don't win just by length. When nothing
  /// matches (for example "What is this about?"), the opening passages are used.
  public static func relevant(_ passages: [String], question: String, budgetTokens: Int)
    -> [String]
  {
    let terms = Set(ArticleText.keywords(question))
    let docs = passages.map { ArticleText.keywords($0) }
    var frequency: [String: Int] = [:]
    for doc in docs { for term in Set(doc) where terms.contains(term) { frequency[term, default: 0] += 1 } }
    let average = max(1, Double(docs.reduce(0) { $0 + $1.count }) / Double(max(1, docs.count)))
    let n = Double(docs.count)
    let scores = docs.map { doc -> Double in
      var counts: [String: Int] = [:]
      for word in doc where terms.contains(word) { counts[word, default: 0] += 1 }
      return counts.reduce(0) { total, entry in
        let df = Double(frequency[entry.key] ?? 0)
        let idf = log(1 + (n - df + 0.5) / (df + 0.5))
        let tf = Double(entry.value)
        return total + idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * Double(doc.count) / average))
      }
    }
    let ranked = scores.enumerated().filter { $0.element > 0 }.sorted { $0.element > $1.element }
      .map(\.offset)
    let order = ranked.isEmpty ? Array(passages.indices) : ranked
    var chosen: [Int] = []
    var used = 0
    for index in order {
      let cost = TokenEstimate.tokens(passages[index]) + 4
      if used + cost > budgetTokens { if chosen.isEmpty { continue } else { break } }
      chosen.append(index)
      used += cost
    }
    return chosen.sorted().map { passages[$0] }
  }

  /// Streams the answer so far, clipped. Retries once with fewer passages if the window overflows.
  public static func answer(
    _ question: String, articleText: String, model: any LocalLanguageModel
  ) -> AsyncThrowingStream<String, Error> {
    let question = String(
      question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuestionCharacters))
    let all = passages(articleText)
    return AsyncThrowingStream { continuation in
      let task = Task {
        guard !question.isEmpty, !all.isEmpty else {
          continuation.finish(throwing: LocalModelError.emptyAnswer)
          return
        }
        for fraction in [0.5, 0.3] {
          let budget = Int(Double(model.contextTokens) * fraction)
          let chosen = relevant(all, question: question, budgetTokens: budget)
          var produced = false
          do {
            for try await partial in model.stream(
              instructions: LocalPrompts.answerInstructions,
              prompt: LocalPrompts.answerPrompt(question: question, passages: chosen),
              maxResponseTokens: 300)
            {
              produced = true
              continuation.yield(clip(partial))
            }
            if !produced { throw LocalModelError.emptyAnswer }
            continuation.finish()
            return
          } catch LocalModelError.contextTooLong where !produced {
            continue
          } catch {
            continuation.finish(throwing: error)
            return
          }
        }
        continuation.finish(throwing: LocalModelError.contextTooLong)
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Plain text, trimmed and length-limited; rendered with `Text`, never as markup.
  public static func clip(_ answer: String) -> String {
    String(answer.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxAnswerCharacters))
  }
}
