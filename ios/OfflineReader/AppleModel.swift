import Foundation
import ReaderCore

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// Chooses the local model provider for this device. Everything FoundationModels-specific lives in
/// this file, behind `canImport` (CI's Xcode 16.4 SDK has no such framework) and `@available`
/// (the app still runs on iOS 17). A larger provider, such as Apple's Private Cloud Compute model
/// in a later SDK, would be another `LocalLanguageModel` chosen here; callers don't change.
enum LocalModels {
  static func current() -> any LocalLanguageModel {
    #if canImport(FoundationModels)
      if #available(iOS 26.0, macOS 26.0, *) { return AppleOnDeviceModel() }
    #endif
    return UnavailableModel()
  }
}

/// Stands in on iOS 17–18 and in builds without the FoundationModels SDK.
struct UnavailableModel: LocalLanguageModel {
  let label = ReadingContext.onDeviceModel
  let contextTokens = 0
  var availability: LocalModelAvailability { .requiresNewerSystem }
  func respond(instructions: String, prompt: String, maxResponseTokens: Int) async throws -> String {
    throw LocalModelError.unavailable(.requiresNewerSystem)
  }
  func stream(instructions: String, prompt: String, maxResponseTokens: Int)
    -> AsyncThrowingStream<String, Error>
  {
    AsyncThrowingStream { $0.finish(throwing: LocalModelError.unavailable(.requiresNewerSystem)) }
  }
}

#if canImport(FoundationModels)
  /// Apple's on-device foundation model. Free, private and offline: nothing leaves the device.
  /// The window (input and answer together) is 4,096 tokens per Apple's documentation; this SDK
  /// has no API to read it or count tokens, so budgets use `TokenEstimate` and overflow retries.
  @available(iOS 26.0, macOS 26.0, *)
  struct AppleOnDeviceModel: LocalLanguageModel {
    let label = ReadingContext.onDeviceModel
    let contextTokens = 4096
    /// Summarizing and answering about articles is content transformation, which Apple's
    /// permissive guardrails are for; default guardrails refuse many ordinary news topics.
    private var model: SystemLanguageModel {
      SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }
    var availability: LocalModelAvailability {
      let model = SystemLanguageModel.default
      switch model.availability {
      case .available:
        return model.supportsLocale() ? .available : .unsupportedLanguage
      case .unavailable(.deviceNotEligible): return .deviceNotEligible
      case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
      case .unavailable(.modelNotReady): return .modelNotReady
      case .unavailable: return .deviceNotEligible
      }
    }
    private func options(_ maxTokens: Int) -> GenerationOptions {
      // Low temperature: faithful summaries over creative ones.
      GenerationOptions(temperature: 0.2, maximumResponseTokens: maxTokens)
    }
    func respond(instructions: String, prompt: String, maxResponseTokens: Int) async throws
      -> String
    {
      let session = LanguageModelSession(model: model, instructions: instructions)
      do {
        return try await session.respond(to: prompt, options: options(maxResponseTokens)).content
      } catch { throw Self.map(error) }
    }
    func stream(instructions: String, prompt: String, maxResponseTokens: Int)
      -> AsyncThrowingStream<String, Error>
    {
      let model = self.model
      let options = options(maxResponseTokens)
      return AsyncThrowingStream { continuation in
        let task = Task {
          do {
            let session = LanguageModelSession(model: model, instructions: instructions)
            for try await snapshot in session.streamResponse(to: prompt, options: options) {
              continuation.yield(snapshot.content)
            }
            continuation.finish()
          } catch { continuation.finish(throwing: Self.map(error)) }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
    static func map(_ error: Error) -> Error {
      if error is CancellationError { return error }
      guard let error = error as? LanguageModelSession.GenerationError else {
        return LocalModelError.failed
      }
      switch error {
      case .exceededContextWindowSize: return LocalModelError.contextTooLong
      case .guardrailViolation: return LocalModelError.guardrail
      case .unsupportedLanguageOrLocale: return LocalModelError.unsupportedLanguage
      case .assetsUnavailable: return LocalModelError.unavailable(.modelNotReady)
      case .rateLimited, .concurrentRequests: return LocalModelError.busy
      case .refusal: return LocalModelError.refused
      default: return LocalModelError.failed
      }
    }
  }
#endif
