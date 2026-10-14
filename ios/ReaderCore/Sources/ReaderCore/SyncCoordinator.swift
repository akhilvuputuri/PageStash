import Foundation

/// Shares an active sync, then performs a full manifest refresh if an
/// incremental sync cannot satisfy a concurrent explicit download retry.
@MainActor public final class SyncCoordinator {
  private struct Run {
    let id: UUID
    let fullManifest: Bool
    let task: Task<Void, Error>
  }
  private var current: Run?
  public init() {}

  public func run(
    fullManifest: Bool,
    operation: @escaping @MainActor (Bool) async throws -> Void
  ) async throws {
    if let active = current {
      try await active.task.value
      if fullManifest && !active.fullManifest {
        try await run(fullManifest: true, operation: operation)
      }
      return
    }
    let id = UUID()
    let task = Task { @MainActor in
      // Clear before completing the task, so waiters never join a finished run.
      // A cancelled older login must not clear a newer login's active run.
      defer { if self.current?.id == id { self.current = nil } }
      try Task.checkCancellation()
      try await operation(fullManifest)
    }
    current = Run(id: id, fullManifest: fullManifest, task: task)
    try await task.value
  }

  public func cancel() {
    current?.task.cancel()
    current = nil
  }
}

extension SyncCoordinator {
  public enum RejectedEdit: Equatable, Sendable {
    /// The item no longer exists on the server (for example, purged from Trash): drop the edit.
    case discard
    /// The server refused this edit (for example, an older server without a new field): keep it
    /// for a later sync, but still pull the library.
    case keepForLater
    /// No response or a server error: stop and retry the whole sync later.
    case retryWholeSync
  }
  /// The backend's message when an edited item no longer exists.
  public static let missingItemMessage = "Item not found."
  /// Only the backend's own "item not found" discards an edit; any other 404 (a proxy or a wrong
  /// base path) keeps it, so a misconfiguration can't silently drop every pending edit.
  nonisolated public static func disposition(
    ofRejectedEdit status: Int?, message: String? = nil
  ) -> RejectedEdit {
    guard let status else { return .retryWholeSync }
    if status == 404 { return message == missingItemMessage ? .discard : .keepForLater }
    if (400..<500).contains(status) && status != 401 && status != 408 && status != 429 {
      return .keepForLater
    }
    return .retryWholeSync
  }
}
