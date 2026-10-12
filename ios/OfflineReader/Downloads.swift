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
  func enqueue(items: [ReadingItem], manual: Set<String> = []) async {
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
    let limit = Int64(
      UserDefaults.standard.integer(forKey: "storageLimit") == 0
        ? 512_000_000 : UserDefaults.standard.integer(forKey: "storageLimit"))
    var reserved =
      currentStore.diskUsage
      + tasks.reduce(Int64(0)) { sum, task in
        guard let description = task.taskDescription, let data = description.data(using: .utf8),
          let transfer = try? JSONDecoder().decode(Transfer.self, from: data),
          transfer.generation == currentGeneration
        else { return sum }
        return sum + Int64(transfer.asset.size)
      }
    for item in items
    where !item.deleted && item.status == "ready"
      && ((!item.archived && item.progress < 1 && !currentStore.isPaused(item.id))
        || manual.contains(item.id))
    {
      for asset in item.assets.sorted(by: { $0.role == "content" && $1.role != "content" })
      where asset.safeFilename && !currentStore.hasAsset(item, asset) {
        guard
          !existing.contains("\(currentGeneration):\(item.id):\(item.contentVersion):\(asset.id)"),
          reserved + Int64(asset.size) <= limit
        else { continue }
        // Only fetch capabilities issued by the configured backend; no arbitrary manifest hosts.
        guard
          let configured = URL(string: UserDefaults.standard.string(forKey: "backendURL") ?? ""),
          asset.url.host == configured.host, asset.url.port == configured.port,
          asset.url.scheme == configured.scheme
        else { continue }
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
    DispatchQueue.main.async { self.completion?() }
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
