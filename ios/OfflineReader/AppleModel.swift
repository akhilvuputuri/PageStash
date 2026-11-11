import Foundation
import ReaderCore

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// Chooses the model providers for this device. Everything FoundationModels-specific lives in
/// this file, gated three ways so every supported toolchain and system works:
/// - `#if canImport(FoundationModels)`: CI's Xcode 16.4 (iOS 18 SDK) has no such framework.
/// - `#if compiler(>=6.4)`: symbols that exist only in the iOS 27 SDK (Xcode 27, Swift 6.4), such
///   as Private Cloud Compute, `contextSize`, `tokenCount` and `LanguageModelError`, so the file
///   also compiles with Xcode 26.x.
/// - `@available` / `#available`: iOS 26 for the on-device model, 26.4 for token counts, 27 for
///   Private Cloud Compute and the new errors. The app still runs on iOS 17; the framework is
///   weak-linked, so iOS 17 and 18 report `requiresNewerSystem`.
enum LocalModels {
  static func current() -> any LocalLanguageModel {
    #if canImport(FoundationModels)
      if #available(iOS 26.0, macOS 26.0, *) { return AppleOnDeviceModel() }
    #endif
    return UnavailableModel()
  }

  /// Apple's Private Cloud Compute model, when this build carries Apple's managed entitlement and
  /// the system has the API (iOS 27). Nil otherwise. Whether the reader allowed it is the
  /// caller's check (`PrivateCloudPolicy.settingKey`); availability and quota are checked per use.
  static func privateCloud() async -> (any LocalLanguageModel)? {
    #if canImport(FoundationModels)
      #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, *) { return await ApplePrivateCloudModel.make() }
      #endif
    #endif
    return nil
  }

  /// Why Private Cloud Compute can or can't be used, for Settings. Never constructs the model
  /// without the entitlement.
  static func privateCloudStatus() async -> LocalModelAvailability {
    #if canImport(FoundationModels)
      #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, *) {
          guard AppEntitlements.privateCloudCompute else { return .notEntitled }
          return await ApplePrivateCloudModel.make()?.availability ?? .notEntitled
        }
      #endif
    #endif
    return .requiresNewerSystem
  }
}

/// Entitlements of this build, read from its own code signature (iOS has no public API for this).
enum AppEntitlements {
  /// Apple's managed Private Cloud Compute entitlement. Without it the framework refuses the model
  /// (reported as an error at construction), so PageStash never constructs it then.
  static let privateCloudCompute: Bool = {
    guard let url = Bundle.main.executableURL,
      let data = try? Data(contentsOf: url, options: .alwaysMapped)
    else { return false }
    return CodeSignature.hasEntitlement(CodeSignature.privateCloudComputeEntitlement, machO: data)
  }()
}

/// Stands in on iOS 17–18 and in builds without the FoundationModels SDK.
struct UnavailableModel: LocalLanguageModel {
  let label = ReadingContext.onDeviceModel
  let contextTokens = 0
  var availability: LocalModelAvailability { .requiresNewerSystem }
  func respond(instructions: String, prompt: String, maxResponseTokens: Int) async throws -> String
  {
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
  /// The window (input and answer together) is read from the model where the SDK has
  /// `contextSize` (4,096 before iOS 27; measured 4,096 on macOS 27.2.1), else 4,096 as Apple
  /// documents. Token counts come from the model on iOS 26.4 and later; budgets calibrate the
  /// estimate with them (see `TokenEstimate.ratio`).
  @available(iOS 26.0, macOS 26.0, *)
  struct AppleOnDeviceModel: LocalLanguageModel {
    let label = ReadingContext.onDeviceModel
    /// Summarizing and answering about articles is content transformation, which Apple's
    /// permissive guardrails are for; default guardrails refuse many ordinary news topics.
    private var model: SystemLanguageModel {
      SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }
    var contextTokens: Int {
      #if compiler(>=6.4)
        // Back-deployed: 4,096 before iOS 26.4. Reads 0 while the model is still downloading.
        let size = SystemLanguageModel.default.contextSize
        if size > 0 { return size }
      #endif
      return 4096
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
    func tokenCount(_ text: String) async -> Int? {
      #if compiler(>=6.4)
        if #available(iOS 26.4, macOS 26.4, *) { return try? await model.tokenCount(for: text) }
      #endif
      return nil
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
      } catch { throw AppleModelErrors.map(error) }
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
          } catch { continuation.finish(throwing: AppleModelErrors.map(error)) }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
  }

  /// Maps FoundationModels errors to `LocalModelError`. iOS 27 replaced
  /// `LanguageModelSession.GenerationError` with `LanguageModelError` and friends; both are mapped.
  enum AppleModelErrors {
    static func map(_ error: Error) -> Error {
      if error is CancellationError || error is LocalModelError { return error }
      #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, *), let mapped = map27(error) { return mapped }
      #endif
      if #available(iOS 26.0, macOS 26.0, *),
        let error = error as? LanguageModelSession.GenerationError
      {
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
      return LocalModelError.failed
    }

    #if compiler(>=6.4)
      @available(iOS 27.0, macOS 27.0, *)
      static func map27(_ error: Error) -> LocalModelError? {
        if let error = error as? LanguageModelError {
          switch error {
          case .contextSizeExceeded: return .contextTooLong
          case .guardrailViolation: return .guardrail
          case .unsupportedLanguageOrLocale: return .unsupportedLanguage
          case .refusal: return .refused
          // Private Cloud Compute has reported its daily limit as rate limiting too; either way
          // the caller falls back to the device.
          case .rateLimited: return .busy
          case .timeout: return .offline
          default: return .failed
          }
        }
        if let error = error as? PrivateCloudComputeLanguageModel.Error {
          switch error {
          case .quotaLimitReached: return .limitReached
          case .networkFailure: return .offline
          case .serviceUnavailable: return .unavailable(.modelNotReady)
          default: return .failed
          }
        }
        if error is SystemLanguageModel.Error { return .unavailable(.modelNotReady) }
        if error is LanguageModelSession.Error { return .busy }
        return nil
      }
    #endif
  }

  #if compiler(>=6.4)
    /// Apple's Private Cloud Compute model (iOS 27): a 32K window (read from the model), stronger
    /// reasoning, a connection required, a per-person daily limit tied to the iCloud account,
    /// and Apple's managed entitlement required. The prompt, which includes the article's text
    /// and the finished-article list, is processed on Apple's Private Cloud Compute servers.
    /// Used only for long articles when the reader allows it (`PrivateCloudPolicy`).
    @available(iOS 27.0, macOS 27.0, *)
    struct ApplePrivateCloudModel: LocalLanguageModel {
      let label = ReadingContext.privateCloudModel
      let location = ModelLocation.privateCloud
      let contextTokens: Int
      /// Light reasoning: condensing supplied text needs little, and it keeps latency and the
      /// reasoning tokens (which count against the window) low. Reasoning gets this much room
      /// beyond each answer cap.
      let reservedTokens = 2048
      private let model: PrivateCloudComputeLanguageModel

      static func make() async -> ApplePrivateCloudModel? {
        guard AppEntitlements.privateCloudCompute else { return nil }
        let model = PrivateCloudComputeLanguageModel()
        // Measured 32,768 on macOS 27.2.1; Apple documents 32K.
        let size = (try? await model.contextSize) ?? 0
        return ApplePrivateCloudModel(contextTokens: size > 0 ? size : 32_768, model: model)
      }

      var availability: LocalModelAvailability {
        if model.quotaUsage.isLimitReached { return .limitReached }
        switch model.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable: return .modelNotReady
        }
      }
      private var context: ContextOptions { ContextOptions(reasoningLevel: .light) }
      private func options(_ maxTokens: Int) -> GenerationOptions {
        GenerationOptions(temperature: 0.2, maximumResponseTokens: maxTokens)
      }
      func respond(instructions: String, prompt: String, maxResponseTokens: Int) async throws
        -> String
      {
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
          return try await session.respond(
            to: prompt, options: options(maxResponseTokens), contextOptions: context
          ).content
        } catch { throw AppleModelErrors.map(error) }
      }
      func stream(instructions: String, prompt: String, maxResponseTokens: Int)
        -> AsyncThrowingStream<String, Error>
      {
        let model = self.model
        let options = options(maxResponseTokens)
        let context = self.context
        return AsyncThrowingStream { continuation in
          let task = Task {
            do {
              let session = LanguageModelSession(model: model, instructions: instructions)
              for try await snapshot in session.streamResponse(
                to: prompt, options: options, contextOptions: context)
              {
                continuation.yield(snapshot.content)
              }
              continuation.finish()
            } catch { continuation.finish(throwing: AppleModelErrors.map(error)) }
          }
          continuation.onTermination = { _ in task.cancel() }
        }
      }
    }
  #endif
#endif
