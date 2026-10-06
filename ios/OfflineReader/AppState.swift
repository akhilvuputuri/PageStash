import BackgroundTasks
import ReaderCore
import SwiftUI

@MainActor final class AppState: ObservableObject {
  static let shared = AppState()
  @Published var session: Session?
  @Published var items: [ReadingItem] = []
  @Published var message: String?
  @Published var refreshing = false
  @Published var lastSync: String =
    UserDefaults.standard.string(forKey: "lastSync") ?? "Not yet synced"
  private(set) var store: LocalStore?
  private var syncing: Task<Void, Error>?
  var backendURL: String {
    get { UserDefaults.standard.string(forKey: "backendURL") ?? "" }
    set {
      UserDefaults.standard.set(
        newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "backendURL")
    }
  }
  var api: API? {
    guard let url = URL(string: backendURL), let session else { return nil }
    return API(base: url, token: session.token)
  }
  private init() {
    session = Vault.load()
    if let session { configure(session) }
    Downloads.shared.completion = { [weak self] in self?.reload() }
  }
  private func configure(_ session: Session) {
    do {
      var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OfflineReader/\(session.generation)")
      let store = try LocalStore(root: root)
      var protection = URLResourceValues()
      protection.isExcludedFromBackup = true
      try root.setResourceValues(protection)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: root.path)
      self.store = store
      Downloads.shared.configure(store: store, generation: session.generation)
      reload()
    } catch { message = error.localizedDescription }
  }
  func login(base: String, email: String, password: String) async {
    do {
      guard let url = URL(string: base) else { throw APIError(message: "Enter your backend URL.") }
      let session = try await API(base: url, token: nil).login(email: email, password: password)
      backendURL = base
      try Vault.save(session)
      self.session = session
      configure(session)
      scheduleRefresh()
      try await sync()
    } catch { message = error.localizedDescription }
  }
  func reload() {
    do { items = try store?.items() ?? [] } catch { message = error.localizedDescription }
    if let error = UserDefaults.standard.string(forKey: "downloadError") { message = error }
  }
  func sync(forceManifest: Bool = false) async throws {
    if let syncing { return try await syncing.value }
    guard let api, let store, let generation = session?.generation else { return }
    refreshing = true
    let task = Task { @MainActor in
      for edit in try store.pendingEdits() {
        try Task.checkCancellation()
        try await api.patch(edit.itemID, edit.patch)
        try store.acknowledge(edit)
      }
      var cursor = forceManifest ? 0 : store.cursor
      repeat {
        try Task.checkCancellation()
        let page = try await api.library(cursor: cursor)
        guard self.session?.generation == generation else { throw CancellationError() }
        try store.apply(page)
        cursor = page.cursor
        if !page.hasMore { break }
      } while true
      try Task.checkCancellation()
      guard self.session?.generation == generation else { throw CancellationError() }
      self.reload()
      await Downloads.shared.enqueue(items: self.items)
      self.lastSync = Date().formatted(date: .abbreviated, time: .shortened)
      UserDefaults.standard.set(self.lastSync, forKey: "lastSync")
    }
    syncing = task
    defer {
      syncing = nil
      refreshing = false
      scheduleRefresh()
    }
    do {
      try await task.value
      message = nil
      UserDefaults.standard.removeObject(forKey: "downloadError")
    } catch {
      message = error.localizedDescription
      throw error
    }
  }
  func save(_ url: String, key: String) async throws {
    guard let api else { return }
    let _: SaveResponse = try await api.save(url: url, key: key)
    try await sync()
  }
  func edit(_ item: ReadingItem, _ patch: ItemPatch) {
    do {
      try store?.edit(item.id, patch)
      reload()
      if patch.deleted == true { Downloads.shared.cancel(itemID: item.id) }
      Task { try? await sync() }
    } catch { message = error.localizedDescription }
  }
  func download(_ item: ReadingItem) async {
    do {
      try store?.resumeDownload(item.id)
      try await sync(forceManifest: true)
      await Downloads.shared.enqueue(items: items, manual: [item.id])
    } catch { message = error.localizedDescription }
  }
  func removeDownload(_ item: ReadingItem) {
    Downloads.shared.cancel(itemID: item.id)
    do {
      try store?.removeDownload(item.id)
      reload()
    } catch { message = error.localizedDescription }
  }
  func retryImport(_ item: ReadingItem) async {
    do {
      if let api { let _: OK = try await api.request("/v1/items/\(item.id)/retry", method: "POST") }
      try await sync()
    } catch { message = error.localizedDescription }
  }
  func logout() async {
    let oldAPI = api
    clearLocal()
    if let oldAPI { let _: OK? = try? await oldAPI.request("/v1/session", method: "DELETE") }
  }
  func deleteAccount() async throws {
    guard let api else { return }
    let _: OK = try await api.request("/v1/account", method: "DELETE")
    clearLocal()
  }
  private func clearLocal() {
    syncing?.cancel()
    BGTaskScheduler.shared.cancelAllTaskRequests()
    Downloads.shared.reset()
    Vault.clear()
    let root = store?.root
    store = nil
    session = nil
    items = []
    lastSync = "Not yet synced"
    UserDefaults.standard.removeObject(forKey: "lastSync")
    UserDefaults.standard.removeObject(forKey: "downloadError")
    if let root { try? FileManager.default.removeItem(at: root) }
  }
  func scheduleRefresh() {
    guard session != nil else { return }
    let request = BGAppRefreshTaskRequest(identifier: AppDelegate.refreshID)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
    do { try BGTaskScheduler.shared.submit(request) } catch
    { /* Foreground and manual refresh remain available. */  }
  }
  func backgroundRefresh(_ task: BGAppRefreshTask) {
    scheduleRefresh()
    let operation = Task { @MainActor in
      do {
        try await self.sync(forceManifest: true)
        task.setTaskCompleted(success: true)
      } catch { task.setTaskCompleted(success: false) }
    }
    task.expirationHandler = {
      operation.cancel()
      Task { @MainActor in self.syncing?.cancel() }
    }
  }
}
@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
  static let refreshID = "com.akhilvuputuri.offlinereader.refresh"
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { task in
      guard let task = task as? BGAppRefreshTask else { return }
      Task { @MainActor in AppState.shared.backgroundRefresh(task) }
    }
    _ = AppState.shared
    return true
  }
  func application(
    _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    _ = AppState.shared
    Downloads.shared.handleEvents(completion: completionHandler)
  }
}
@main struct OfflineReaderApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var state = AppState.shared
  @Environment(\.scenePhase) private var phase
  var body: some Scene {
    WindowGroup {
      RootView().environmentObject(state).task(id: phase) {
        guard phase == .active else { return }
        while !Task.isCancelled {
          if state.session != nil { try? await state.sync() }
          let pending = state.items.contains { ["queued", "processing"].contains($0.status) }
          do { try await Task.sleep(for: .seconds(pending ? 3 : 60)) } catch { return }
        }
      }.onChange(of: phase) { _, value in
        if value == .background {
          state.scheduleRefresh()
        }
      }
    }
  }
}
