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
    for doc in docs {
      for term in Set(doc) where terms.contains(term) { frequency[term, default: 0] += 1 }
    }
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

  /// The answer so far and where it is being written.
  public struct Partial: Equatable, Sendable {
    public let text: String
    public let location: ModelLocation
  }

  /// Passage budget in estimated tokens: a fraction of the window left after the instructions,
  /// the question, the answer and any reasoning.
  public static func passageBudget(_ model: any LocalLanguageModel, fraction: Double) -> Int {
    let usable = model.contextTokens - model.reservedTokens - answerTokens - 300
    return max(200, Int(Double(usable) * fraction))
  }
  static let answerTokens = 300

  /// Streams the answer so far, clipped. Retries once with fewer passages if the window overflows.
  /// With `privateCloud` (only passed when the reader allowed it) a long article's question is
  /// answered there from many more passages; if that fails before any text arrives, the device
  /// answers instead.
  public static func answer(
    _ question: String, articleText: String, model: any LocalLanguageModel,
    privateCloud: (any LocalLanguageModel)? = nil
  ) -> AsyncThrowingStream<Partial, Error> {
    let question = String(
      question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuestionCharacters))
    let all = passages(articleText)
    var models: [any LocalLanguageModel] = [model]
    if let cloud = privateCloud,
      PrivateCloudPolicy.prefersCloudForQuestions(articleText, onDevice: model, cloud: cloud)
    {
      models.insert(cloud, at: 0)
    }
    return AsyncThrowingStream { continuation in
      let task = Task {
        guard !question.isEmpty, !all.isEmpty else {
          continuation.finish(throwing: LocalModelError.emptyAnswer)
          return
        }
        var lastError: Error = LocalModelError.contextTooLong
        for (index, model) in models.enumerated() {
          let isLast = index == models.count - 1
          var produced = false
          do {
            try await stream(question, all, model: model) {
              produced = true
              continuation.yield(Partial(text: clip($0), location: model.location))
            }
            continuation.finish()
            return
          } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
            return
          } catch  where !produced && !isLast {
            // The private cloud failed before answering: the device answers instead.
            lastError = error
            continue
          } catch {
            lastError = error
            break
          }
        }
        continuation.finish(throwing: lastError)
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func stream(
    _ question: String, _ all: [String], model: any LocalLanguageModel,
    yield: (String) -> Void
  ) async throws {
    for fraction in [0.5, 0.3] {
      let chosen = relevant(
        all, question: question, budgetTokens: passageBudget(model, fraction: fraction))
      var produced = false
      do {
        for try await partial in model.stream(
          instructions: LocalPrompts.answerInstructions,
          prompt: LocalPrompts.answerPrompt(question: question, passages: chosen),
          maxResponseTokens: answerTokens + model.reservedTokens)
        {
          produced = true
          yield(partial)
        }
        if !produced { throw LocalModelError.emptyAnswer }
        return
      } catch LocalModelError.contextTooLong where !produced {
        continue
      }
    }
    throw LocalModelError.contextTooLong
  }

  /// Plain text, trimmed and length-limited; rendered with `Text`, never as markup.
  public static func clip(_ answer: String) -> String {
    String(answer.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxAnswerCharacters))
  }
}
