import BackgroundTasks
import ReaderCore
import SwiftUI

@MainActor final class AppState: ObservableObject {
  static let shared = AppState()
  @Published var session: Session?
  @Published var items: [ReadingItem] = []
  @Published var message: String?
  @Published var refreshing = false
  @Published var readingUndo: ReadingUndo?
  @Published var sharedSaves: [SharedSave] = []
  @Published var sharingMessage: String?
  private var shareStore: SharedSaveStore?
  @Published var lastSync: String =
    UserDefaults.standard.string(forKey: "lastSync") ?? "Not yet synced"
  private(set) var store: LocalStore?
  private let syncCoordinator = SyncCoordinator()
  private var previewMode = false
  var backendURL: String {
    get {
      UserDefaults.standard.string(forKey: "backendURL")
        ?? Bundle.main.object(forInfoDictionaryKey: "ReaderBackendURL") as? String ?? ""
    }
    set {
      UserDefaults.standard.set(
        newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "backendURL")
    }
  }
  var api: API? {
    guard !previewMode else { return nil }
    guard let url = URL(string: backendURL), let session else { return nil }
    return API(base: url, token: session.token)
  }
  private init() {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--preview-library") {
        previewMode = true
        configurePreview()
        return
      }
    #endif
    session = Vault.load()
    if let session { configure(session) } else { ShareServices.deactivate() }
    Downloads.shared.completion = { [weak self] in self?.reload() }
  }
  private func configure(_ session: Session) {
    do {
      var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OfflineReader/\(session.storageId ?? session.generation)")
      let store = try LocalStore(root: root)
      var protection = URLResourceValues()
      protection.isExcludedFromBackup = true
      try root.setResourceValues(protection)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: root.path)
      self.store = store
      do {
        shareStore = try ShareServices.activate(session, server: backendURL)
        sharingMessage = nil
      } catch {
        ShareServices.deactivate()
        shareStore = nil
        sharingMessage = "Browser sharing isn't configured for this build."
      }
      Downloads.shared.configure(store: store, generation: session.generation)
      reload()
    } catch { message = error.localizedDescription }
  }
  func login(base: String, email: String, password: String) async {
    guard !previewMode else { return }
    do {
      guard let url = URL(string: base) else { throw APIError(message: "Enter your backend URL.") }
      var session = try await API(base: url, token: nil).login(email: email, password: password)
      if let previous = self.session, previous.ownerId == session.ownerId,
        let oldServer = try? ShareContainer.server(backendURL),
        let newServer = try? ShareContainer.server(base),
        oldServer == newServer
      {
        session.storageId = previous.storageId ?? previous.generation
      }
      syncCoordinator.cancel()
      Downloads.shared.reset()
      backendURL = base
      try Vault.save(session)
      self.session = session
      // The download delegate reads the configured origin from UserDefaults.
      configure(session)
      scheduleRefresh()
      try await sync()
    } catch { message = error.localizedDescription }
  }
  func reload() {
    do {
      items = try store?.items() ?? []
      readingUndo = try store?.readingUndo()
      if let shareStore = self.shareStore, let credentials = ShareVault.load() {
        sharedSaves = try shareStore.records(credentials.account)
      }
    } catch { message = error.localizedDescription }
    if let error = UserDefaults.standard.string(forKey: "downloadError") { message = error }
  }
  func sync(forceManifest: Bool = false) async throws {
    guard let api, let store, let generation = session?.generation else { return }
    do {
      try await syncCoordinator.run(fullManifest: forceManifest) { fullManifest in
        guard self.session?.generation == generation else { throw CancellationError() }
        self.refreshing = true
        let syncStarted = Date()
        BackgroundDiagnostics.shared.record(
          "sync_started",
          fields: [
            "syncStartedAt": syncStarted.timeIntervalSince1970, "fullManifest": fullManifest,
            "syncError": "none",
          ])
        defer {
          if self.session?.generation == generation {
            self.refreshing = false
            self.scheduleRefresh()
          }
        }
        self.reload()  // Local shares remain visible even when the network is unavailable.
        if let shareStore = self.shareStore, let credentials = ShareVault.load() {
          // A bounded batch also runs in the foreground/background refresh pipeline.
          for _ in 0..<5 {
            try Task.checkCancellation()
            guard self.session?.generation == generation else { throw CancellationError() }
            guard
              (try? shareStore.records(credentials.account).contains {
                $0.account == credentials.account && [.queued, .sending].contains($0.state)
              }) == true
            else { break }
            do { try await ShareServices.deliver(shareStore, credentials: credentials) } catch {
              break
            }
            if (try? shareStore.records(credentials.account).contains { $0.state == .queued })
              == true
            {
              break
            }
          }
        }
        for edit in try store.pendingEdits() {
          try Task.checkCancellation()
          try await api.patch(edit.itemID, edit.patch)
          try Task.checkCancellation()
          guard self.session?.generation == generation else { throw CancellationError() }
          try store.acknowledge(edit)
        }
        var cursor = fullManifest ? 0 : store.cursor
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
        if let shareStore = self.shareStore, let credentials = ShareVault.load() {
          try shareStore.acknowledge(Set(try store.items().map(\.id)), account: credentials.account)
        }
        self.reload()
        BackgroundDiagnostics.shared.record(
          "metadata_applied",
          fields: [
            "itemCount": self.items.count,
            "readyCount": self.items.filter { $0.status == "ready" }.count,
          ])
        await Downloads.shared.enqueue(items: self.items)
        BackgroundDiagnostics.shared.record(
          "downloads_enqueued",
          fields: [
            "syncSucceededAt": Date().timeIntervalSince1970,
            "syncSeconds": Date().timeIntervalSince(syncStarted),
          ])
        try Task.checkCancellation()
        guard self.session?.generation == generation else { throw CancellationError() }
        self.lastSync = Date().formatted(date: .abbreviated, time: .shortened)
        UserDefaults.standard.set(self.lastSync, forKey: "lastSync")
      }
      guard self.session?.generation == generation else { return }
      message = nil
      UserDefaults.standard.removeObject(forKey: "downloadError")
    } catch {
      if self.session?.generation == generation {
        BackgroundDiagnostics.shared.record(
          "sync_failed",
          fields: [
            "syncError": BackgroundDiagnostics.errorCode(error),
            "syncFailedAt": Date().timeIntervalSince1970,
          ])
        reload()
        message = error.localizedDescription
      }
      throw error
    }
  }
  func save(_ url: String, key: String) async throws {
    guard let api else { throw APIError(message: "Reconnect before submitting an article.") }
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
  func addToCollection(_ item: ReadingItem, name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    edit(
      item,
      ItemPatch(collections: Array(Set(item.collections + [String(name.prefix(60))])).sorted()))
  }
  func download(_ item: ReadingItem) async {
    do {
      try store?.resumeDownload(item.id)
      try await sync(forceManifest: true)
      await Downloads.shared.enqueue(items: items, manual: [item.id])
    } catch { message = error.localizedDescription }
  }
  func finishReading(_ id: String) -> Bool {
    do {
      guard let store else { return false }
      try store.finishReading(id)
      reload()
      Task { try? await sync() }
      return true
    } catch {
      message = error.localizedDescription
      return false
    }
  }
  func undoFinishedReading() {
    do {
      guard let undo = readingUndo, let store else { return }
      if !(try store.undoReading(undo.id)) {
        message = "This item changed. Undo is no longer available."
      }
      reload()
      Task { try? await sync() }
    } catch { message = error.localizedDescription }
  }
  func dismissReadingUndo() {
    do {
      try store?.dismissReadingUndo()
      reload()
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
  func retrySharedSave(_ item: SharedSave) async {
    do {
      guard let shareStore, let credentials = ShareVault.load() else {
        throw ShareError.authenticationRequired
      }
      try shareStore.retry(item.id, account: credentials.account)
      try await ShareServices.deliver(shareStore, credentials: credentials, id: item.id)
      try await sync()
      reload()
    } catch { message = error.localizedDescription }
  }
  func removeSharedSave(_ id: String) {
    do {
      guard let shareStore, let credentials = ShareVault.load() else { return }
      try shareStore.remove(id, account: credentials.account)
      reload()
    } catch { message = error.localizedDescription }
  }
  func logout() async {
    if previewMode {
      let root = store?.root
      session = nil
      store = nil
      items = []
      readingUndo = nil
      if let root { try? FileManager.default.removeItem(at: root) }
      return
    }
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
    syncCoordinator.cancel()
    refreshing = false
    BGTaskScheduler.shared.cancelAllTaskRequests()
    Downloads.shared.reset()
    ShareServices.deactivate()
    shareStore = nil
    sharedSaves = []
    sharingMessage = nil
    Vault.clear()
    let root = store?.root
    store = nil
    session = nil
    items = []
    readingUndo = nil
    lastSync = "Not yet synced"
    UserDefaults.standard.removeObject(forKey: "lastSync")
    UserDefaults.standard.removeObject(forKey: "downloadError")
    BackgroundDiagnostics.shared.clear()
    if let root { try? FileManager.default.removeItem(at: root) }
  }
  func scheduleRefresh() {
    guard session != nil, !previewMode else { return }
    let request = BGAppRefreshTaskRequest(identifier: AppDelegate.refreshID)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
    do {
      try BGTaskScheduler.shared.submit(request)
      BackgroundDiagnostics.shared.record(
        "schedule_accepted",
        fields: [
          "scheduleAccepted": true, "scheduledAt": Date().timeIntervalSince1970,
          "requestedEarliestAt": request.earliestBeginDate?.timeIntervalSince1970 ?? 0,
        ])
    } catch {
      BackgroundDiagnostics.shared.record(
        "schedule_failed",
        fields: [
          "scheduleAccepted": false, "scheduleErrorCode": (error as NSError).code,
        ])
    }
    BackgroundDiagnostics.snapshot()
  }
  func backgroundRefresh(_ task: BGAppRefreshTask) {
    let run = BackgroundDiagnostics.shared.begin()
    BackgroundDiagnostics.shared.record(
      "background_context",
      fields: [
        "backgroundSessionAvailable": session != nil, "backgroundCacheAvailable": store != nil,
      ])
    scheduleRefresh()
    let operation = Task { @MainActor in
      do {
        try await self.sync(forceManifest: true)
        BackgroundDiagnostics.shared.finish(run, outcome: "success")
        task.setTaskCompleted(success: true)
      } catch {
        BackgroundDiagnostics.shared.finish(run, outcome: BackgroundDiagnostics.errorCode(error))
        task.setTaskCompleted(success: false)
      }
    }
    task.expirationHandler = {
      BackgroundDiagnostics.shared.finish(run, outcome: "expired")
      operation.cancel()
      Task { @MainActor in self.syncCoordinator.cancel() }
    }
  }
  #if DEBUG
    private func configurePreview() {
      // This preview bypasses Keychain and every API call. Its store is a new synthetic directory.
      do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
          "LibraryPreview-\(UUID().uuidString)")
        let store = try LocalStore(root: root)
        func content(_ title: String) -> (Data, Asset) {
          let body = (1...24).map {
            "<p>Paragraph \($0). This is synthetic reading content for checking layout, text size and the finished-reading flow.</p>"
          }.joined()
          let bytes = Data(
            "<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head><body><h2>\(title)</h2>\(body)</body></html>"
              .utf8)
          return (
            bytes,
            Asset(
              id: UUID().uuidString, role: "content", mime: "text/html", size: bytes.count,
              sha256: digest(bytes), filename: "article.html",
              url: URL(string: "https://example.com/content")!)
          )
        }
        let previewTitle =
          ProcessInfo.processInfo.arguments.contains("--preview-long-title")
          ? "A long article title that should scroll away and leave the screen available for reading"
          : "A calmer reading library"
        let (bytes, asset) = content(previewTitle)
        let ready = ReadingItem(
          id: UUID().uuidString, title: previewTitle,
          sourceUrl: "https://example.com/reading", capturedAt: "2026-10-08T12:00:00Z",
          progress: ProcessInfo.processInfo.arguments.contains("--preview-long-title") ? 0 : 0.35,
          assets: [asset])
        let (partialBytes, partialAsset) = content("An article with images still pending")
        let imageID = UUID().uuidString
        let image = Asset(
          id: imageID, role: "image", mime: "image/webp", size: 10,
          sha256: "uninstalled-preview-image", filename: "\(imageID).webp",
          url: URL(string: "https://example.com/image")!)
        let partial = ReadingItem(
          id: UUID().uuidString, title: "An article with images still pending",
          sourceUrl: "https://example.com/images", capturedAt: "2026-10-08T11:00:00Z",
          assets: [partialAsset, image])
        let waiting = ReadingItem(
          id: UUID().uuidString, title: "A saved reading brief", kind: "brief", status: "queued",
          capturedAt: "2026-10-08T10:00:00Z", assets: [])
        let archived = ReadingItem(
          id: UUID().uuidString, title: "An earlier finished article",
          sourceUrl: "https://example.com/earlier", capturedAt: "2026-10-07T12:00:00Z", progress: 1,
          archived: true, assets: [])
        let failed = ReadingItem(
          id: UUID().uuidString, title: "An article that couldn't be prepared",
          status: "bookmark",
          error: "The source returned an access-check page instead of readable article text.",
          sourceUrl: "https://example.com/unavailable", contentVersion: 0, assets: [])
        try store.apply(LibraryPage(items: [ready, partial, waiting, archived, failed], cursor: 1))
        for (item, data, asset) in [(ready, bytes, asset), (partial, partialBytes, partialAsset)] {
          let temporary = root.appendingPathComponent("preview.html")
          try data.write(to: temporary)
          try store.accept(temporary, itemID: item.id, version: item.contentVersion, asset: asset)
          try FileManager.default.removeItem(at: temporary)
        }
        self.store = store
        self.session = Session(token: "synthetic-preview-session", ownerId: UUID().uuidString)
        reload()
      } catch { message = "Preview could not be prepared." }
    }
  #endif
}
@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
  static let refreshID = "com.akhilvuputuri.offlinereader.refresh"
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    BackgroundDiagnostics.shared.launch(
      probeActive: ProcessInfo.processInfo.arguments.contains("--reader-background-probe"))
    let registered = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.refreshID, using: nil
    ) { task in
      guard let task = task as? BGAppRefreshTask else { return }
      Task { @MainActor in AppState.shared.backgroundRefresh(task) }
    }
    BackgroundDiagnostics.shared.record("registered", fields: ["registrationAccepted": registered])
    BackgroundDiagnostics.snapshot()
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
      RootView().environmentObject(state).task(
        id: ForegroundRefreshKey(
          phase: phase, generation: state.session?.generation,
          importsPending: state.items.contains { ["queued", "processing"].contains($0.status) }
            || !state.sharedSaves.isEmpty)
      ) {
        guard phase == .active else { return }
        while !Task.isCancelled {
          if state.session != nil { try? await state.sync() }
          let pending =
            state.items.contains { ["queued", "processing"].contains($0.status) }
            || state.sharedSaves.contains { [.queued, .sending].contains($0.state) }
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

private struct ForegroundRefreshKey: Equatable {
  let phase: ScenePhase
  let generation: String?
  let importsPending: Bool
}
