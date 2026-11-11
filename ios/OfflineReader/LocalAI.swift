import Foundation
import ReaderCore

/// Runs Apple's models for reading context and article questions: the on-device model by default,
/// and Apple's Private Cloud Compute for long articles when the reader allowed it in Settings
/// (see `PrivateCloudPolicy`). Quiet pre-generation never uses the private cloud: a long article
/// waits for the reader to open Reading Context, so nothing leaves the iPhone unasked. The model
/// handles one request at a time, so there is one job: an explicit request (the sheet) takes over
/// from quiet pre-generation, which is bounded, runs one article at a time, pauses while a
/// Reading Context sheet is open or the app is in the background, and skips Low Power Mode and
/// preview mode.
/// Work happens off the main thread; this class only coordinates, so reading never waits on it.
@MainActor final class LocalAI: ObservableObject {
  struct Job: Equatable {
    let itemID: String
    var quiet: Bool
    var progress: LocalReadingContext.Progress?
  }
  enum InputError: LocalizedError {
    case notDownloaded
    var errorDescription: String? { "Download this article to write its reading context." }
  }
  /// Quiet work left a long article for the private cloud, when the reader opens it.
  struct LeftForPrivateCloud: Error {}
  let model: any LocalLanguageModel
  @Published private(set) var availability: LocalModelAvailability
  /// The note being written now, for progress in the sheet.
  @Published private(set) var job: Job?
  /// Bumped when a note is saved, so an open sheet reloads it.
  @Published private(set) var saved = 0
  /// Why quiet pre-generation failed, per item and content version, so the sheet explains rather
  /// than retrying an article the model declined.
  @Published private(set) var failures: [String: String] = [:]
  /// Why a note meant for the private cloud was written on the device, per item and version.
  @Published private(set) var cloudNotices: [String: String] = [:]
  /// Whether Apple's Private Cloud Compute can be used, for Settings.
  @Published private(set) var privateCloudStatus = LocalModelAvailability.requiresNewerSystem
  weak var state: AppState?
  /// Off in preview mode: the synthetic library is for checking layout, not running the model.
  var allowsBackground = true
  /// Articles prepared quietly in one foreground visit, beyond the one being read.
  static let foregroundBudget = 3
  private var task: Task<ReadingContext, Error>?
  private var queue: [String] = []
  private var attempted: Set<String> = []
  private var foregroundStarted = 0
  private var holds = 0
  private var foreground = false
  private var powerObserver: NSObjectProtocol?
  private var cloud: (any LocalLanguageModel)?
  private var cloudResolved = false

  init(model: any LocalLanguageModel = LocalModels.current()) {
    self.model = model
    availability = model.availability
    powerObserver = NotificationCenter.default.addObserver(
      forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { self.cancelQuiet() } else { self.pump() }
      }
    }
  }

  var isAvailable: Bool { availability == .available }
  func refreshAvailability() {
    let now = model.availability
    if now != availability { availability = now }
  }
  static func key(_ item: ReadingItem) -> String { "\(item.id):\(item.contentVersion)" }
  func failure(for item: ReadingItem) -> String? { failures[Self.key(item)] }
  func cloudNotice(for item: ReadingItem) -> String? { cloudNotices[Self.key(item)] }

  // MARK: Private Cloud Compute

  /// The reader's Settings choice. Off unless turned on.
  var allowsPrivateCloud: Bool { UserDefaults.standard.bool(forKey: PrivateCloudPolicy.settingKey) }
  /// The private cloud model when the reader allowed it and this build can use it. Created once;
  /// availability and quota are checked on every use.
  func privateCloudIfAllowed() async -> (any LocalLanguageModel)? {
    guard allowsPrivateCloud else { return nil }
    if !cloudResolved {
      cloud = await LocalModels.privateCloud()
      cloudResolved = true
    }
    return cloud
  }
  func refreshPrivateCloudStatus() async {
    let status = await LocalModels.privateCloudStatus()
    if status != privateCloudStatus { privateCloudStatus = status }
  }
  static func notice(_ fallback: LocalModelError) -> String {
    switch fallback {
    case .limitReached:
      return
        "Today's Apple Private Cloud Compute limit is used up, so this was written on your iPhone, in parts."
    case .offline:
      return
        "Apple's Private Cloud Compute couldn't be reached, so this was written on your iPhone, in parts."
    default:
      return
        "Apple's Private Cloud Compute couldn't write this, so it was written on your iPhone, in parts."
    }
  }

  // MARK: Explicit

  /// Writes the note now, joining a quiet run for the same article or replacing one for another.
  func generate(_ item: ReadingItem) async throws -> ReadingContext {
    refreshAvailability()
    guard isAvailable else { throw LocalModelError.unavailable(availability) }
    failures[Self.key(item)] = nil
    cloudNotices[Self.key(item)] = nil
    if let job, let task {
      if job.itemID == item.id {
        self.job?.quiet = false
        return try await task.value
      }
      task.cancel()
      _ = await task.result
    }
    return try await run(item, quiet: false, cloud: await privateCloudIfAllowed())
  }
  func cancel(_ itemID: String) {
    guard job?.itemID == itemID else { return }
    task?.cancel()
  }
  /// Streams an answer grounded in the article. Quiet work stops first so the model is free.
  /// Long articles are answered by the private cloud when the reader allowed it.
  func ask(_ question: String, about item: ReadingItem)
    -> AsyncThrowingStream<ArticleQuestion.Partial, Error>
  {
    cancelQuiet()
    let store = state?.store
    let model = self.model
    let id = item.id
    return AsyncThrowingStream { continuation in
      let task = Task(priority: .userInitiated) {
        let cloud = await self.privateCloudIfAllowed()
        let text = await Task.detached { try? store?.articleText(id) }.value
        guard let text, !text.isEmpty else {
          continuation.finish(throwing: InputError.notDownloaded)
          return
        }
        do {
          for try await partial in ArticleQuestion.answer(
            question, articleText: text, model: model, privateCloud: cloud)
          {
            continuation.yield(partial)
          }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: Quiet pre-generation

  /// The reader opened an article: prepare its note first, unless a current one exists.
  func prepare(_ itemID: String) {
    guard let item = state?.items.first(where: { $0.id == itemID }), needsNote(item, orStale: true)
    else { return }
    queue.removeAll { $0 == itemID }
    queue.insert(itemID, at: 0)
    pump()
  }
  /// While the app is open, prepare a few of the newest unread downloaded articles that have no
  /// note at all, one at a time.
  func pregenerate() {
    guard let state, foreground, allowsBackground, job == nil else { return }
    let room = Self.foregroundBudget - foregroundStarted - queue.count
    guard room > 0 else { return }
    refreshAvailability()
    guard isAvailable, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
    // Items are newest first; lazily, so a large library isn't scanned every loop.
    let candidates = state.items.lazy.filter {
      $0.kind == "article" && $0.status == "ready" && !$0.archived && !$0.isTrashed
        && $0.progress < 1 && !self.queue.contains($0.id) && self.needsNote($0, orStale: false)
    }
    queue += candidates.prefix(room).map(\.id)
    pump()
  }
  func setForeground(_ active: Bool) {
    foreground = active
    if active {
      foregroundStarted = 0
      refreshAvailability()
      Task { await refreshPrivateCloudStatus() }
      pump()
    } else {
      queue.removeAll()
      cancelQuiet()
    }
  }
  /// A Reading Context sheet is open: quiet work for other articles waits, so questions and
  /// explicit requests get the model.
  func hold(_ itemID: String) {
    holds += 1
    if let job, job.quiet, job.itemID != itemID { task?.cancel() }
  }
  func release() {
    holds = max(0, holds - 1)
    pump()
  }
  func reset() {
    queue.removeAll()
    attempted.removeAll()
    failures.removeAll()
    cloudNotices.removeAll()
    task?.cancel()
  }

  private func needsNote(_ item: ReadingItem, orStale: Bool) -> Bool {
    guard let state, let store = state.store, item.status == "ready", !item.isTrashed,
      !attempted.contains(Self.key(item)), (try? store.readerURL(item.id)) != nil
    else { return false }
    guard let note = try? store.readingContext(item) else { return true }
    guard orStale else { return false }
    return !note.isLocal || note.stale(finishedCount: state.finishedCount(excluding: item.id))
  }
  private var canRunQuietly: Bool {
    allowsBackground && foreground && holds == 0 && job == nil && isAvailable
      && !ProcessInfo.processInfo.isLowPowerModeEnabled
      && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
  }
  private func pump() {
    refreshAvailability()
    guard canRunQuietly else { return }
    while let id = queue.first {
      queue.removeFirst()
      guard let item = state?.items.first(where: { $0.id == id }), needsNote(item, orStale: true)
      else { continue }
      attempted.insert(Self.key(item))
      foregroundStarted += 1
      Task {
        do {
          // A long article the private cloud would write waits for the reader to open it.
          let leaveLong = await privateCloudIfAllowed()?.availability == .available
          _ = try await run(item, quiet: true, cloud: nil, leaveLongArticles: leaveLong)
        } catch is CancellationError {
          // Paused; it may be tried again on a later visit.
          attempted.remove(Self.key(item))
        } catch is LeftForPrivateCloud {
        } catch {
          failures[Self.key(item)] = error.localizedDescription
        }
        // A short gap keeps the device cool and leaves room for the reader.
        try? await Task.sleep(for: .seconds(2))
        pump()
      }
      return
    }
  }
  private func cancelQuiet() {
    if let job, job.quiet { task?.cancel() }
  }

  private func run(
    _ item: ReadingItem, quiet: Bool, cloud: (any LocalLanguageModel)?,
    leaveLongArticles: Bool = false
  ) async throws -> ReadingContext {
    guard let state, let store = state.store else { throw LocalModelError.failed }
    let model = self.model
    let items = state.items
    let id = item.id
    let key = Self.key(item)
    job = Job(itemID: id, quiet: quiet)
    let task = Task(priority: quiet ? .utility : .userInitiated) { () throws -> ReadingContext in
      let inputs = try await Task.detached { try Self.inputs(item, items: items, store: store) }
        .value
      try Task.checkCancellation()
      if leaveLongArticles {
        let ratio = await TokenEstimate.ratio(inputs.article.text, model: model)
        if PrivateCloudPolicy.isLong(inputs.article.text, onDevice: model, tokenRatio: ratio) {
          throw LeftForPrivateCloud()
        }
      }
      let outcome = try await LocalReadingContext.write(
        article: inputs.article, history: inputs.history, finishedTotal: inputs.finishedTotal,
        onDevice: model, privateCloud: cloud,
        progress: { progress in
          // LocalAI lives as long as the app, so a strong reference is fine.
          Task { @MainActor in
            if self.job?.itemID == id { self.job?.progress = progress }
          }
        })
      try Task.checkCancellation()
      try store.saveReadingContext(outcome.context)
      if let fallback = outcome.cloudFallback {
        await MainActor.run { self.cloudNotices[key] = LocalAI.notice(fallback) }
      }
      return outcome.context
    }
    self.task = task
    defer {
      if self.task == task {
        self.task = nil
        job = nil
      }
    }
    let context = try await task.value
    saved += 1
    return context
  }

  nonisolated static func inputs(_ item: ReadingItem, items: [ReadingItem], store: LocalStore)
    throws -> (article: LocalArticle, history: [HistoryEntry], finishedTotal: Int)
  {
    guard let text = try store.articleText(item.id), !text.isEmpty else {
      throw InputError.notDownloaded
    }
    let finished = ReadingHistory.finished(items, excluding: item.id)
    let history = LocalReadingContext.historyEntries(finished) {
      try? store.openingText($0.id, characters: 400)
    }
    let site = item.siteName ?? item.sourceUrl.flatMap { URL(string: $0)?.host }
    return (
      LocalArticle(
        id: item.id, contentVersion: item.contentVersion, title: item.title, site: site, text: text),
      history, finished.count
    )
  }
}
