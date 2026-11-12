import Foundation
import ReaderCore

struct Transfer: Codable {
  let generation: String
  let itemID: String
  let version: Int
  let asset: Asset
}
final class Downloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  static let shared = Downloads()
  private let lock = NSRecursiveLock()
  private var store: LocalStore?
  private var generation: String?
  private var enqueuing = false
  private var enqueueWaiters: [CheckedContinuation<Void, Never>] = []
  private var progressByItem: [String: Double] = [:]
  /// Articles with files the latest enqueue couldn't fit under the storage limit, even after
  /// removing downloads of archived and finished articles.
  private var storageFull: Set<String> = []
  private var lastProgressNotification = Date.distantPast
  var completion: (() -> Void)?
  private(set) var backgroundCompletion: (() -> Void)?
  lazy var session: URLSession = {
    let config = URLSessionConfiguration.background(
      withIdentifier: "\(Bundle.main.bundleIdentifier ?? "offline-reader").downloads")
    config.sessionSendsLaunchEvents = true
    config.isDiscretionary = false
    config.waitsForConnectivity = true
    // Keep the session eligible; each request enforces the current user choice.
    // A session created with cellular disabled cannot be relaxed by its requests.
    config.allowsCellularAccess = true
    config.timeoutIntervalForResource = 86400
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }()
  func configure(store: LocalStore, generation: String) {
    lock.lock()
    defer { lock.unlock() }
    self.store = store
    self.generation = generation
    _ = session
  }
  func reset() {
    lock.lock()
    store = nil
    generation = nil
    progressByItem = [:]
    storageFull = []
    lock.unlock()
    session.getAllTasks { tasks in
      for task in tasks { task.cancel() }
    }
  }
  func handleEvents(completion: @escaping () -> Void) {
    lock.lock()
    backgroundCompletion = completion
    lock.unlock()
    _ = session
  }
  /// Queues the files `items` still need. Every caller passes the whole library, so the storage
  /// full set is rebuilt here. When the limit is reached, downloads of archived and finished
  /// articles are removed, oldest saved first, before new files are skipped; `protected` (the
  /// article being read) and anything still transferring keep theirs.
  func enqueue(items: [ReadingItem], manual: Set<String> = [], protected: Set<String> = []) async {
    await beginEnqueue()
    defer { endEnqueue() }
    guard !Task.isCancelled else { return }
    let tasks = await session.allTasks.filter { $0.state != .canceling && $0.state != .completed }
    let existing = Set(
      tasks.compactMap { task -> String? in
        guard let description = task.taskDescription, let data = description.data(using: .utf8),
          let transfer = try? JSONDecoder().decode(Transfer.self, from: data)
        else { return nil }
        return "\(transfer.generation):\(transfer.itemID):\(transfer.version):\(transfer.asset.id)"
      })
    let (currentStore, currentGeneration) = snapshot()
    guard let currentStore, let currentGeneration else { return }
    let limit = Self.storageLimit
    let inFlight = tasks.reduce(Int64(0)) { sum, task in
      guard let description = task.taskDescription, let data = description.data(using: .utf8),
        let transfer = try? JSONDecoder().decode(Transfer.self, from: data),
        transfer.generation == currentGeneration
      else { return sum }
      return sum + Int64(transfer.asset.size)
    }
    let configured = URL(string: UserDefaults.standard.string(forKey: "backendURL") ?? "")
    let wanted = items.filter {
      !$0.deleted && !$0.isTrashed && $0.status == "ready"
        && ((!$0.archived && $0.progress < 1 && !currentStore.isPaused($0.id))
          || manual.contains($0.id))
    }.map { item in
      (
        item: item,
        assets: item.assets.sorted(by: { $0.role == "content" && $1.role != "content" }).filter {
          asset in
          asset.safeFilename && !currentStore.hasAsset(item, asset)
            && !existing.contains(
              "\(currentGeneration):\(item.id):\(item.contentVersion):\(asset.id)")
            // Only fetch capabilities issued by the configured backend; no arbitrary manifest hosts.
            && asset.url.host == configured?.host && asset.url.port == configured?.port
            && asset.url.scheme == configured?.scheme
        }
      )
    }.filter { !$0.assets.isEmpty }
    let needed = wanted.reduce(Int64(0)) { sum, entry in
      entry.assets.reduce(sum) { $0 + Int64($1.size) }
    }
    var reserved = currentStore.diskUsage + inFlight
    if reserved + needed > limit {
      // Make room from archived and finished articles before skipping new ones.
      let busy = Set(
        tasks.compactMap { task -> String? in
          guard let description = task.taskDescription, let data = description.data(using: .utf8)
          else { return nil }
          return (try? JSONDecoder().decode(Transfer.self, from: data))?.itemID
        })
      let evict = StorageEviction.plan(
        items, sizes: currentStore.downloadSizes(), needed: reserved + needed - limit,
        protected: protected.union(busy).union(wanted.map(\.item.id)))
      for id in evict { try? currentStore.evictDownload(id) }
      if !evict.isEmpty { reserved = currentStore.diskUsage + inFlight }
    }
    var full: Set<String> = []
    for (item, assets) in wanted {
      for asset in assets {
        guard reserved + Int64(asset.size) <= limit else {
          full.insert(item.id)
          continue
        }
        reserved += Int64(asset.size)
        let transfer = Transfer(
          generation: currentGeneration, itemID: item.id, version: item.contentVersion, asset: asset
        )
        guard let data = try? JSONEncoder().encode(transfer) else { continue }
        var request = URLRequest(url: asset.url)
        request.allowsCellularAccess = UserDefaults.standard.bool(forKey: "cellular")
        let task = session.downloadTask(with: request)
        task.taskDescription = String(decoding: data, as: UTF8.self)
        task.resume()
      }
    }
    record(storageFull: full, generation: currentGeneration)
    DispatchQueue.main.async { self.completion?() }
  }
  private func record(storageFull full: Set<String>, generation current: String) {
    lock.lock()
    defer { lock.unlock() }
    if generation == current { storageFull = full }
  }
  /// The storage limit chosen in Settings (512 MB by default).
  static var storageLimit: Int64 {
    let chosen = UserDefaults.standard.integer(forKey: "storageLimit")
    return Int64(chosen == 0 ? 512_000_000 : chosen)
  }
  /// Whether the latest enqueue skipped some of this article's files for lack of space.
  func isStorageFull(itemID: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return storageFull.contains(itemID)
  }
  private func snapshot() -> (LocalStore?, String?) {
    lock.lock()
    defer { lock.unlock() }
    return (store, generation)
  }
  private func beginEnqueue() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if enqueuing {
        enqueueWaiters.append(continuation)
        lock.unlock()
      } else {
        enqueuing = true
        lock.unlock()
        continuation.resume()
      }
    }
  }
  private func endEnqueue() {
    lock.lock()
    let next = enqueueWaiters.isEmpty ? nil : enqueueWaiters.removeFirst()
    if next == nil { enqueuing = false }
    lock.unlock()
    next?.resume()
  }
  func updateCellularPolicy() async {
    let allowed = UserDefaults.standard.bool(forKey: "cellular")
    // Existing URLSession requests are immutable. Cancel and requeue them with
    // the new policy, retaining files already verified in the local store.
    for task in await session.allTasks
    where task.originalRequest?.allowsCellularAccess != allowed {
      task.cancel()
    }
  }
  func progress(itemID: String) -> Double? {
    lock.lock()
    defer { lock.unlock() }
    return progressByItem[itemID]
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard let description = downloadTask.taskDescription, let data = description.data(using: .utf8),
      let transfer = try? JSONDecoder().decode(Transfer.self, from: data),
      transfer.generation == generation
    else { return }
    progressByItem[transfer.itemID] = min(
      1, Double(totalBytesWritten) / Double(max(1, transfer.asset.size)))
    if Date().timeIntervalSince(lastProgressNotification) > 1 {
      lastProgressNotification = Date()
      DispatchQueue.main.async { self.completion?() }
    }
  }
  func cancel(itemID: String) {
    lock.lock()
    progressByItem.removeValue(forKey: itemID)
    lock.unlock()
    session.getAllTasks { tasks in
      for task in tasks {
        if let description = task.taskDescription, description.contains(itemID) { task.cancel() }
      }
    }
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard let description = downloadTask.taskDescription, let data = description.data(using: .utf8),
      let transfer = try? JSONDecoder().decode(Transfer.self, from: data),
      transfer.generation == generation, let store
    else { return }
    guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200
    else {
      UserDefaults.standard.set(
        "A download expired or failed. Refresh to retry.", forKey: "downloadError")
      DispatchQueue.main.async { self.completion?() }
      return
    }
    // Consume Apple's temporary file synchronously, before this delegate callback returns.
    do {
      try store.accept(
        location, itemID: transfer.itemID, version: transfer.version, asset: transfer.asset)
      BackgroundDiagnostics.shared.record(
        "asset_verified",
        fields: [
          "assetVerifiedAt": Date().timeIntervalSince1970,
          "lastVerifiedWasText": transfer.asset.role == "content",
        ])
    } catch { UserDefaults.standard.set("A download needs retrying.", forKey: "downloadError") }
    DispatchQueue.main.async { self.completion?() }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    defer { lock.unlock() }
    guard let description = task.taskDescription, let data = description.data(using: .utf8),
      let transfer = try? JSONDecoder().decode(Transfer.self, from: data),
      transfer.generation == generation
    else { return }
    if let error, (error as NSError).code != NSURLErrorCancelled {
      UserDefaults.standard.set(
        "A download was interrupted. Refresh to retry.", forKey: "downloadError")
      DispatchQueue.main.async { self.completion?() }
    }
  }
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    lock.lock()
    let finish = backgroundCompletion
    backgroundCompletion = nil
    lock.unlock()
    DispatchQueue.main.async { finish?() }
  }
}
extension URLSession {
  fileprivate var allTasks: [URLSessionTask] {
    get async {
      await withCheckedContinuation { continuation in
        getAllTasks { continuation.resume(returning: $0) }
      }
    }
  }
}
