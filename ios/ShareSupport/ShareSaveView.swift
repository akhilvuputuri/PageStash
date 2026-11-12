import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class ShareSaveModel: ObservableObject {
  @Published var candidates: [URL] = []
  @Published var selected: URL?
  @Published var loading = true
  @Published var busy = false
  /// The page title, when the share supplies one.
  @Published var title: String?
  /// Sign-in, unreadable-share and choose-a-link prompts, shown while nothing is being saved.
  @Published var notice: String? {
    didSet { if notice != oldValue { announce(notice) } }
  }
  /// The one status line for the save, from "Saving…" to its result.
  @Published var status: ShareStatus? {
    didSet { if status != oldValue { announce(status?.announcement) } }
  }
  @Published var record: SharedSave?
  /// What the sheet decided to do after reading the share.
  private(set) var start: ShareStart?
  private let credentialSource: () -> ShareCredentials?
  private let storeSource: () throws -> SharedSaveStore
  private let submit: ((URL, String) async throws -> SaveResponse)?
  private let grace: Duration
  /// - Parameter grace: how long an automatic save waits, showing "Saving…", before it queues the
  ///   link. Cancel during this time leaves nothing behind.
  init(
    snapshot: @escaping () -> ShareCredentials? = ShareVault.load,
    store: @escaping () throws -> SharedSaveStore = ShareContainer.store,
    submit: ((URL, String) async throws -> SaveResponse)? = nil,
    grace: Duration = .milliseconds(600)
  ) {
    credentialSource = snapshot
    storeSource = store
    self.submit = submit
    self.grace = grace
  }
  // One operation key per share: the automatic save and every Retry reuse it, so the server
  // can't create a duplicate.
  private let requestID = UUID().uuidString
  private var store: SharedSaveStore?
  private var credentials: ShareCredentials?
  private var providers: [NSItemProvider] = []
  var canRetry: Bool { !busy && credentials != nil && status?.canRetry == true }
  var canChoose: Bool { !loading && !busy && credentials != nil && record == nil }

  /// Reads the share, then saves at once when it holds exactly one link and the session is usable.
  func run(_ items: [NSExtensionItem]) async {
    await load(items)
    guard case .save = start else { return }
    status = ShareFlow.saving
    // Cancel cancels this task. Both run on the main actor, so a cancelled sheet never queues.
    do { try await Task.sleep(for: grace) } catch { return }
    guard !Task.isCancelled else { return }
    await save()
  }
  /// Saves a link picked from several shared links.
  func choose(_ url: URL) async {
    guard canChoose, candidates.contains(url) else { return }
    selected = url
    notice = nil
    await save()
  }
  func load(_ items: [NSExtensionItem]) async {
    defer { loading = false }
    credentials = credentialSource()
    guard let credentials else {
      decide(.signIn)
      return
    }
    do {
      let store = try storeSource()
      self.store = store
      // The queue refuses a session the app has replaced or signed out.
      guard (try? store.records(credentials.account)) != nil else {
        decide(.signIn)
        return
      }
      providers = items.flatMap { $0.attachments ?? [] }
      guard providers.count <= 12 else { throw ShareError.invalidURL }
      var urls: [String] = []
      var texts: [String] = []
      for provider in providers {
        try Task.checkCancellation()
        if provider.canLoadObject(ofClass: NSURL.self) {
          let raw = try await loadURL(provider)
          urls.append(raw ?? "")
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
          let item = try await load(provider, type: UTType.url.identifier)
          if let url = item as? URL {
            urls.append(url.absoluteString)
          } else if let string = item as? String {
            urls.append(string)
          } else if let data = item as? Data, data.count <= 8192 {
            urls.append(String(data: data, encoding: .utf8) ?? "")
          } else {
            urls.append("")
          }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
          let item = try await load(provider, type: UTType.plainText.identifier)
          if let string = item as? String {
            texts.append(string)
          } else if let data = item as? Data, data.count <= 8192,
            let text = String(data: data, encoding: .utf8)
          {
            texts.append(text)
          }
        }
      }
      candidates = SharedLink.candidates(urls: urls, texts: texts)
      // Text that came with a link may be the page title; text without one was the link itself.
      let titles = items.flatMap { [$0.attributedTitle?.string, $0.attributedContentText?.string] }
      title = ShareFlow.title(from: titles + (urls.isEmpty ? [] : texts))
      decide(ShareFlow.start(signedIn: true, sessionUsable: true, candidates: candidates))
    } catch ShareError.unavailable {
      notice = ShareError.unavailable.localizedDescription
    } catch ShareError.invalidURL {
      decide(.unreadable)
    } catch {
      candidates = []
      notice = ShareFlow.unreadableItemsNotice
    }
  }
  private func decide(_ decision: ShareStart) {
    start = decision
    switch decision {
    case .signIn: notice = ShareFlow.signInNotice
    case .unreadable:
      candidates = []
      notice = ShareFlow.unreadableNotice
    case .choose: notice = ShareFlow.chooseNotice
    case .save(let url): selected = url
    }
  }
  private func loadURL(_ provider: NSItemProvider) async throws -> String? {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadObject(ofClass: NSURL.self) { value, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: (value as? NSURL)?.absoluteString)
        }
      }
    }
  }
  private func load(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding? {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: item)
        }
      }
    }
  }
  /// Queues the selected link on this device, then sends it. Also the Retry action.
  func save() async {
    guard let store, let credentials, let selected, !busy else { return }
    busy = true
    defer { busy = false }
    status = ShareFlow.saving
    do {
      if record == nil {
        record = try store.enqueue(selected, id: requestID, account: credentials.account)
      } else if record?.state == .rejected {
        // Retry resends the same operation key.
        try store.retry(requestID, account: credentials.account)
      }
      try await ShareServices.deliver(
        store, credentials: credentials, id: requestID, snapshot: credentialSource, submit: submit)
      record = try store.records(credentials.account).first { $0.id == requestID }
      status = ShareFlow.status(for: record)
    } catch { status = ShareFlow.status(for: error) }
  }
  private func announce(_ text: String?) {
    guard let text, !text.isEmpty else { return }
    AccessibilityNotification.Announcement(text).post()
  }
}
struct ShareSaveView: View {
  @ObservedObject var model: ShareSaveModel
  let finish: () -> Void
  var body: some View {
    NavigationStack {
      ShareSaveForm(model: model, finish: finish)
    }.readerTheme()
  }
}
private struct ShareSaveForm: View {
  @ObservedObject var model: ShareSaveModel
  let finish: () -> Void
  @Environment(\.themeTokens) private var tokens
  var body: some View {
    Form {
      if model.loading {
        Section { ProgressView("Reading link…") }
      } else if model.candidates.count > 1 {
        Section("Choose a Link") {
          ForEach(model.candidates, id: \.self) { url in
            Button {
              Task { await model.choose(url) }
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(ShareFlow.host(url)).foregroundStyle(.primary)
                  Text(url.absoluteString).font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(2)
                }
                Spacer(minLength: 8)
                if model.selected == url {
                  Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
              }
            }
            .disabled(!model.canChoose)
            .accessibilityAddTraits(model.selected == url ? .isSelected : [])
          }
        }
      } else if let url = model.selected {
        Section {
          VStack(alignment: .leading, spacing: 4) {
            if let title = model.title {
              Text(title).font(.headline).lineLimit(3)
            }
            Text(ShareFlow.host(url))
              .font(model.title == nil ? .headline : .subheadline)
              .foregroundStyle(model.title == nil ? .primary : .secondary)
          }
          .padding(.vertical, 2)
          .accessibilityElement(children: .combine)
        }
      }
      if let status = model.status {
        Section {
          statusRow(status)
          if status.canRetry {
            Button("Retry") { Task { await model.save() } }.disabled(!model.canRetry)
          }
        }
      } else if let notice = model.notice {
        Section { Text(notice) }
      }
    }
    .readerFormBackground()
    .navigationTitle("Save to PageStash").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        // Before the link is queued, Cancel leaves nothing behind. Once it is queued, closing the
        // sheet keeps it, so the button says Done.
        Button(model.record == nil ? "Cancel" : "Done", action: finish)
      }
    }
    .task(id: model.status) {
      guard let status = model.status,
        let delay = ShareFlow.dismissDelay(
          for: status, voiceOver: UIAccessibility.isVoiceOverRunning)
      else { return }
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      finish()
    }
  }
  private func statusRow(_ status: ShareStatus) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        if status.tone == .progress {
          ProgressView().accessibilityHidden(true)
        } else {
          Image(systemName: status.symbol).imageScale(.large)
            .foregroundStyle(color(status.tone)).accessibilityHidden(true)
        }
        Text(status.text).font(.body.weight(.semibold))
      }
      if let detail = status.detail {
        Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }
  private func color(_ tone: ShareStatus.Tone) -> Color {
    switch tone {
    case .progress, .success: return tokens.accent.color
    case .pending: return tokens.secondaryInk.color
    case .problem: return tokens.warning.color
    }
  }
}
