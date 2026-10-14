import XCTest

@testable import ReaderCore

@MainActor private final class Signal {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    opened = true
    let pending = waiters
    waiters.removeAll()
    pending.forEach { $0.resume() }
  }
}

final class SyncCoordinatorTests: XCTestCase {
  @MainActor func testConcurrentManualRetriesReceiveOneFullManifestAfterIncrementalSync()
    async throws
  {
    let coordinator = SyncCoordinator()
    let began = Signal()
    let release = Signal()
    let retryOneEntered = Signal()
    let retryTwoEntered = Signal()
    let fullBegan = Signal()
    let fullRelease = Signal()
    var runs: [Bool] = []
    let incremental = Task { @MainActor in
      try await coordinator.run(fullManifest: false) { full in
        runs.append(full)
        began.open()
        await release.wait()
      }
    }
    await began.wait()
    let fullOperation: @MainActor (Bool) async throws -> Void = { full in
      runs.append(full)
      fullBegan.open()
      await fullRelease.wait()
    }
    let retryOne = Task { @MainActor in
      retryOneEntered.open()
      try await coordinator.run(fullManifest: true, operation: fullOperation)
    }
    let retryTwo = Task { @MainActor in
      retryTwoEntered.open()
      try await coordinator.run(fullManifest: true, operation: fullOperation)
    }
    await retryOneEntered.wait()
    await retryTwoEntered.wait()
    XCTAssertEqual(runs, [false])
    release.open()
    await fullBegan.wait()
    XCTAssertEqual(runs, [false, true])
    fullRelease.open()
    try await incremental.value
    try await retryOne.value
    try await retryTwo.value
    XCTAssertEqual(runs, [false, true])
  }

  @MainActor func testIncrementalRefreshSharesAnActiveFullRefresh() async throws {
    let coordinator = SyncCoordinator()
    let began = Signal()
    let release = Signal()
    let joined = Signal()
    var count = 0
    let full = Task { @MainActor in
      try await coordinator.run(fullManifest: true) { _ in
        count += 1
        began.open()
        await release.wait()
      }
    }
    await began.wait()
    let incremental = Task { @MainActor in
      joined.open()
      try await coordinator.run(fullManifest: false) { _ in count += 1 }
    }
    await joined.wait()
    release.open()
    try await full.value
    try await incremental.value
    XCTAssertEqual(count, 1)
  }

  @MainActor func testOldCancelledRunCannotClearANewLoginRun() async throws {
    let coordinator = SyncCoordinator()
    let oldBegan = Signal()
    let oldRelease = Signal()
    let newBegan = Signal()
    let newRelease = Signal()
    let joined = Signal()
    let old = Task { @MainActor in
      try await coordinator.run(fullManifest: false) { _ in
        oldBegan.open()
        await oldRelease.wait()
        try Task.checkCancellation()
      }
    }
    await oldBegan.wait()
    coordinator.cancel()
    var newRunCount = 0
    let newer = Task { @MainActor in
      try await coordinator.run(fullManifest: true) { _ in
        newRunCount += 1
        newBegan.open()
        await newRelease.wait()
      }
    }
    await newBegan.wait()
    oldRelease.open()
    do {
      try await old.value
      XCTFail("Old login's sync must remain cancelled")
    } catch { XCTAssertTrue(error is CancellationError) }
    let following = Task { @MainActor in
      joined.open()
      try await coordinator.run(fullManifest: false) { _ in newRunCount += 1 }
    }
    await joined.wait()
    newRelease.open()
    try await newer.value
    try await following.value
    XCTAssertEqual(newRunCount, 1)
  }

  @MainActor func testFailureClearsRunAndPermitsRetry() async throws {
    enum Expected: Error { case offline }
    let coordinator = SyncCoordinator()
    do {
      try await coordinator.run(fullManifest: false) { _ in throw Expected.offline }
      XCTFail("Expected offline error")
    } catch { XCTAssertTrue(error is Expected) }
    var retried = false
    try await coordinator.run(fullManifest: true) { full in retried = full }
    XCTAssertTrue(retried)
  }
  func testRejectedEditsNeverBlockTheLibraryForever() {
    XCTAssertEqual(SyncCoordinator.disposition(ofRejectedEdit: 404), .discard)
    XCTAssertEqual(SyncCoordinator.disposition(ofRejectedEdit: 400), .keepForLater)
    XCTAssertEqual(SyncCoordinator.disposition(ofRejectedEdit: 409), .keepForLater)
    for status in [nil, 401, 408, 429, 500, 503] as [Int?] {
      XCTAssertEqual(
        SyncCoordinator.disposition(ofRejectedEdit: status), .retryWholeSync, "\(String(describing: status))")
    }
  }
}
