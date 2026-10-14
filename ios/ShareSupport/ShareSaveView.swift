import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class ShareSaveModel: ObservableObject {
  @Published var candidates: [URL] = []
  @Published var selected: URL?
  @Published var loading = true
  @Published var busy = false
  @Published var message: String?
  @Published var record: SharedSave?
  @Published var destination: String?
  private let credentialSource: () -> ShareCredentials?
  private let storeSource: () throws -> SharedSaveStore
  private let submit: ((URL, String) async throws -> SaveResponse)?
  init(
    snapshot: @escaping () -> ShareCredentials? = ShareVault.load,
    store: @escaping () throws -> SharedSaveStore = ShareContainer.store,
    submit: ((URL, String) async throws -> SaveResponse)? = nil
  ) {
    credentialSource = snapshot
    storeSource = store
    self.submit = submit
  }
  private let requestID = UUID().uuidString
  private var store: SharedSaveStore?
  private var credentials: ShareCredentials?
  private var providers: [NSItemProvider] = []
  var canSave: Bool {
    !loading && !busy && selected != nil && credentials != nil && record?.state != .accepted
  }
  func load(_ items: [NSExtensionItem]) async {
    do {
      credentials = credentialSource()
      guard let credentials else {
        message = "Open Offline Reader and sign in before sharing."
        loading = false
        return
      }
      destination = credentials.account.server.absoluteString
      store = try storeSource()
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
      guard !candidates.isEmpty, candidates.count <= 5 else { throw ShareError.invalidURL }
      if candidates.count == 1 {
        selected = candidates[0]
      } else {
        message = "Choose the webpage link to save."
      }
    } catch {
      message =
        error is ShareError
        ? error.localizedDescription
        : "The shared link could not be read. Try sharing the webpage URL."
    }
    loading = false
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
  func save() async {
    guard let store, let credentials, let selected, !busy else { return }
    busy = true
    defer { busy = false }
    do {
      if record == nil {
        record = try store.enqueue(selected, id: requestID, account: credentials.account)
      }
      try await ShareServices.deliver(
        store, credentials: credentials, id: requestID, snapshot: credentialSource, submit: submit)
      record = try store.records(credentials.account).first { $0.id == requestID }
      switch record?.state {
      case .accepted:
        message =
          record?.serverStatus == "already_saved"
          ? "A matching request exists. Preparation and offline availability are unverified; check the app."
          : record?.serverStatus == "bookmark"
            ? "Preparation failed. Check Imports in Offline Reader."
            : record?.serverStatus == "ready"
              ? "Prepared on the server. Open Offline Reader to download it."
              : "Submitted for preparation. This does not mean downloaded on your phone."
      case .authenticationRequired: message = ShareError.authenticationRequired.localizedDescription
      case .rejected: message = record?.error ?? "The request could not be accepted."
      default: message = "Queued on this device. Open Offline Reader when online to submit."
      }
    } catch { message = error.localizedDescription }
  }
}
struct ShareSaveView: View {
  @ObservedObject var model: ShareSaveModel
  let finish: () -> Void
  var body: some View {
    NavigationStack {
      Form {
        Section("Destination") {
          Text("Offline Reader").font(.headline)
          if let destination = model.destination {
            Text(destination).font(.caption).foregroundStyle(.secondary)
          }
        }
        if model.loading { ProgressView("Reading shared link…") }
        if model.candidates.count > 1 {
          Section("Choose One Webpage") {
            ForEach(model.candidates, id: \.self) { url in
              Button {
                model.selected = url
                model.message = nil
              } label: {
                HStack {
                  Text(url.absoluteString).lineLimit(3)
                  Spacer()
                  if model.selected == url { Image(systemName: "checkmark") }
                }
              }.disabled(model.record != nil || model.busy)
            }
          }
        } else if let url = model.selected {
          Section("Webpage") { Text(url.absoluteString).textSelection(.enabled) }
        }
        if let message = model.message { Section { Text(message) } }
        Section {
          Text(
            "Only readable prepared content enters Library. Offline availability is verified in the app. Queued links belong to this sign-in and are cleared on logout."
          ).font(.footnote).foregroundStyle(.secondary)
        }
      }.navigationTitle("Save article").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(model.record == nil ? "Cancel" : "Done", action: finish)
          }
          ToolbarItem(placement: .confirmationAction) {
            if model.record?.state != .accepted {
              Button(model.busy ? "Submitting…" : model.record == nil ? "Save" : "Retry") {
                Task { await model.save() }
              }.disabled(!model.canSave)
            }
          }
        }
    }.tint(Color(red: 0.78, green: 0.30, blue: 0.15))
  }
}
