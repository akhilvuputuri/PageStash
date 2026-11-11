import Foundation

/// Where a provider runs, so notes and answers can say truthfully where they were produced.
public enum ModelLocation: String, Equatable, Sendable {
  /// On this iPhone: works offline and nothing leaves the device.
  case onDevice
  /// Apple's Private Cloud Compute: needs a connection, and the prompt (article text and the
  /// finished-article list) is sent to Apple's servers, processed there and not retained.
  case privateCloud
}

/// The seam between PageStash's AI features and whichever model runs them. Callers (the reading
/// context pipeline and article questions) depend only on this. The app supplies Apple's
/// on-device model and, on iOS 27 with the entitlement, Apple's Private Cloud Compute model
/// (FoundationModels, in `AppleModel.swift`); tests supply fakes.
public protocol LocalLanguageModel: Sendable {
  /// Stored as a note's `model`, so its source is clear. Apple providers start with "apple-".
  var label: String { get }
  var location: ModelLocation { get }
  /// The provider's context window in tokens, shared by instructions, prompt and answer. Budgets
  /// scale from it, so a larger provider gets larger chunks and fewer steps automatically.
  var contextTokens: Int { get }
  /// Tokens the provider may spend besides the visible answer (reasoning), which also count
  /// against the window. Every budget sets them aside.
  var reservedTokens: Int { get }
  var availability: LocalModelAvailability { get }
  /// The model's own token count for `text` when its SDK can count (on-device, iOS 26.4 or
  /// later). Nil otherwise, and budgets then rely on `TokenEstimate` alone.
  func tokenCount(_ text: String) async -> Int?
  /// One self-contained exchange with a fresh session, so earlier calls never fill the window.
  /// Throws `LocalModelError` (or `CancellationError`).
  func respond(instructions: String, prompt: String, maxResponseTokens: Int) async throws -> String
  /// Like `respond`, but yields the answer so far as it grows (each element is the whole answer
  /// to date, not a delta).
  func stream(instructions: String, prompt: String, maxResponseTokens: Int)
    -> AsyncThrowingStream<String, Error>
}

extension LocalLanguageModel {
  public var location: ModelLocation { .onDevice }
  public var reservedTokens: Int { 0 }
  public func tokenCount(_ text: String) async -> Int? { nil }
}

/// Whether this device can run the local model now, and if not, why, in words a reader can act on.
public enum LocalModelAvailability: Equatable, Sendable {
  case available
  /// This iPhone can't run Apple Intelligence.
  case deviceNotEligible
  /// The device supports it but Apple Intelligence is turned off in Settings.
  case appleIntelligenceOff
  /// Apple Intelligence is on but its model is still downloading or preparing.
  case modelNotReady
  /// The device's language isn't one the model supports.
  case unsupportedLanguage
  /// iOS older than 26, or an app built without the FoundationModels SDK.
  case requiresNewerSystem
  /// Private Cloud Compute only: this build of the app doesn't carry Apple's managed
  /// Private Cloud Compute entitlement, so it can't use it.
  case notEntitled
  /// Private Cloud Compute only: today's per-person limit is used up.
  case limitReached

  /// The device could run the model, now or once the reader acts (turns it on, waits, changes
  /// language), so the feature is worth showing.
  public var deviceSupportsModel: Bool {
    switch self {
    case .available, .appleIntelligenceOff, .modelNotReady, .unsupportedLanguage: return true
    case .deviceNotEligible, .requiresNewerSystem, .notEntitled, .limitReached: return false
    }
  }
  public var message: String {
    switch self {
    case .available: return "Apple Intelligence is ready on this iPhone."
    case .deviceNotEligible: return "This iPhone can't run Apple Intelligence."
    case .appleIntelligenceOff:
      return "Turn on Apple Intelligence in Settings to write these on this iPhone."
    case .modelNotReady:
      return "Apple Intelligence is still getting ready on this iPhone. Try again later."
    case .unsupportedLanguage:
      return "Apple Intelligence doesn't support this iPhone's language yet."
    case .requiresNewerSystem: return "Writing these on this iPhone needs iOS 26 or later."
    case .notEntitled:
      return "Apple's Private Cloud Compute isn't enabled for this build of PageStash."
    case .limitReached: return "Today's Apple Private Cloud Compute limit is used up."
    }
  }
}

/// Why a local model call produced nothing usable. Providers map their own errors to these.
public enum LocalModelError: Error, Equatable, LocalizedError, Sendable {
  case unavailable(LocalModelAvailability)
  /// The prompt and answer didn't fit the context window, even after shrinking.
  case contextTooLong
  /// Apple's safety guardrails declined the article or the answer.
  case guardrail
  /// The article (or question) is in a language the model doesn't support.
  case unsupportedLanguage
  case refused
  /// The model is busy with another request or rate-limited.
  case busy
  /// Private Cloud Compute: the per-person daily limit is reached.
  case limitReached
  /// Private Cloud Compute: no connection, or the service is unavailable.
  case offline
  /// The answer was empty or had nothing usable in it.
  case emptyAnswer
  case failed

  public var errorDescription: String? {
    switch self {
    case .unavailable(let availability): return availability.message
    case .contextTooLong: return "This article is too long for Apple Intelligence on this iPhone."
    case .guardrail:
      return
        "Apple Intelligence declined to process this article. Its safety rules may have flagged the topic."
    case .unsupportedLanguage:
      return "Apple Intelligence doesn't support this article's language yet."
    case .refused: return "Apple Intelligence declined this request."
    case .busy: return "Apple Intelligence is busy. Try again in a moment."
    case .limitReached: return "Today's Apple Private Cloud Compute limit is used up."
    case .offline: return "Apple's Private Cloud Compute needs an internet connection."
    case .emptyAnswer: return "Apple Intelligence didn't return a usable answer. Try again."
    case .failed: return "Apple Intelligence couldn't finish. Try again."
    }
  }
}

/// Rough token counts without the model's tokenizer (iOS 26.0–26.3 have none; Private Cloud
/// Compute has none). Deliberately
/// pessimistic: about three characters per token for ASCII text (English usually averages nearer
/// four) and one token per non-ASCII character (right for CJK, generous for accented Latin), so a
/// budget computed from it should fit. An overflow is still caught and retried smaller.
public enum TokenEstimate {
  public static func tokens(_ text: String) -> Int {
    var ascii = 0
    var other = 0
    for scalar in text.unicodeScalars {
      if scalar.isASCII { ascii += 1 } else { other += 1 }
    }
    return (ascii + 2) / 3 + other
  }
  /// The longest prefix within `tokens`, cut at a word boundary when one is near.
  public static func prefix(_ text: String, tokens limit: Int) -> String {
    guard limit > 0 else { return "" }
    guard tokens(text) > limit else { return text }
    var used = 0
    var end = text.startIndex
    for index in text.unicodeScalars.indices {
      used += text.unicodeScalars[index].isASCII ? 1 : 3
      if used > limit * 3 { break }
      end = text.unicodeScalars.index(after: index)
    }
    var clipped = String(text.unicodeScalars[..<end])
    if let space = clipped.lastIndex(where: { $0.isWhitespace }),
      clipped.distance(from: space, to: clipped.endIndex) < 40
    {
      clipped = String(clipped[..<space])
    }
    return clipped
  }
}

extension TokenEstimate {
  /// Real tokens per estimated token for this text, from the model's own count of a sample when
  /// the provider can count (1 when it can't). Clamped so a bad count can't blow up a budget:
  /// below 1 the estimate was pessimistic and more text fits; above 1 it was optimistic.
  public static func ratio(
    _ text: String, model: any LocalLanguageModel, sampleCharacters: Int = 6000
  )
    async -> Double
  {
    let sample = String(text.prefix(sampleCharacters))
    let estimate = tokens(sample)
    guard estimate >= 50, let real = await model.tokenCount(sample), real > 0 else { return 1 }
    return min(1.5, max(0.4, Double(real) / Double(estimate)))
  }
}
