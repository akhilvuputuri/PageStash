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
