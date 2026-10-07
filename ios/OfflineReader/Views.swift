import BackgroundTasks
import ReaderCore
import SwiftUI

struct RootView: View {
  @EnvironmentObject var state: AppState
  var body: some View {
    Group { if state.session == nil { LoginView() } else { LibraryView() } }.tint(
      Color(red: 0.78, green: 0.30, blue: 0.15))
  }
}
struct LoginView: View {
  @EnvironmentObject var state: AppState
  @State private var base = ""
  @State private var email = ""
  @State private var password = ""
  @State private var busy = false
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Image(systemName: "book.closed.fill").font(.system(size: 44)).foregroundStyle(.tint)
            .padding(.top, 50)
          Text("A quieter place\nto read.").font(.system(size: 38, weight: .medium, design: .serif))
          Text("Save articles and reading briefs. Take them offline.").foregroundStyle(.secondary)
          VStack(spacing: 12) {
            TextField("Backend URL", text: $base).textContentType(.URL).keyboardType(.URL)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Email", text: $email).textContentType(.username).keyboardType(.emailAddress)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Password", text: $password).textContentType(.password)
          }.textFieldStyle(.roundedBorder)
          Button {
            busy = true
            Task {
              await state.login(base: base, email: email, password: password)
              busy = false
            }
          } label: {
            HStack {
              Text("Sign in")
              Spacer()
              if busy { ProgressView() } else { Image(systemName: "arrow.right") }
            }.padding()
          }.buttonStyle(.borderedProminent).disabled(
            busy || base.isEmpty || email.isEmpty || password.isEmpty)
          if let message = state.message { Text(message).font(.callout).foregroundStyle(.red) }
          Text("Personal beta · Your library stays private").font(.footnote).foregroundStyle(
            .secondary)
        }.padding(28)
      }.onAppear { base = state.backendURL }
    }
  }
}
struct LibraryView: View {
  @EnvironmentObject var state: AppState
  @State private var query = ""
  @State private var filter = "Inbox"
  @State private var collection = "All"
  @State private var showSave = false
  @State private var showSettings = false
  private var filtered: [ReadingItem] {
    let matches = query.isEmpty ? nil : (try? state.store?.search(query))
    return state.items.filter { item in
      (filter == "Archived" ? item.archived : !item.archived)
        && (filter != "Offline" || (try? state.store?.readerURL(item.id)) != nil)
        && (collection == "All" || item.collections.contains(collection))
        && (query.isEmpty || matches?.contains(item.id) == true)
    }
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        HStack {
          Text("YOUR READING SPACE").font(.caption.weight(.semibold)).tracking(2)
          Spacer()
          if state.refreshing { ProgressView() }
        }.foregroundStyle(.secondary).padding(.horizontal).padding(.top, 8)
        Picker("Library", selection: $filter) {
          Text("Inbox").tag("Inbox")
          Text("Offline").tag("Offline")
          Text("Archived").tag("Archived")
        }.pickerStyle(.segmented).padding()
        HStack {
          Text("\(filtered.count) items").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Menu {
            Button("All collections") { collection = "All" }
            ForEach(Array(Set(state.items.flatMap(\.collections))).sorted(), id: \.self) { name in
              Button(name) { collection = name }
            }
          } label: {
            Label(collection, systemImage: "folder")
          }.font(.caption)
        }.padding(.horizontal)
        if filtered.isEmpty {
          ContentUnavailableView(
            query.isEmpty ? "Your next good read" : "No matches", systemImage: "book",
            description: Text(
              query.isEmpty
                ? "Save a link here or send one through your assistant."
                : "Try a title or words from a downloaded article."))
        } else {
          List(filtered) { item in
            NavigationLink {
              ReaderScreen(itemID: item.id)
            } label: {
              ArticleRow(item: item)
            }.listRowSeparator(.hidden).listRowInsets(
              EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
            ).swipeActions {
              Button(role: .destructive) {
                state.edit(item, ItemPatch(deleted: true))
              } label: {
                Label("Delete", systemImage: "trash")
              }
              Button {
                state.edit(item, ItemPatch(archived: !item.archived))
              } label: {
                Label(item.archived ? "Restore" : "Archive", systemImage: "archivebox")
              }.tint(.gray)
            }
          }.listStyle(.plain)
        }
        VStack(alignment: .leading, spacing: 4) {
          if let message = state.message { Text(message).foregroundStyle(.orange) }
          Text("Last sync: \(state.lastSync)")
        }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal).padding(.bottom, 8)
      }.navigationTitle("Offline Reader").searchable(text: $query, prompt: "Search your library")
        .refreshable { try? await state.sync(forceManifest: true) }.toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              showSettings = true
            } label: {
              Image(systemName: "gearshape")
            }.accessibilityLabel("Settings")
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              showSave = true
            } label: {
              Image(systemName: "plus")
            }.accessibilityLabel("Save article")
          }
        }.sheet(isPresented: $showSave) { SaveView() }.sheet(isPresented: $showSettings) {
          SettingsView()
        }
    }
  }
}
struct ArticleRow: View {
  @EnvironmentObject var state: AppState
  let item: ReadingItem
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text(
          item.kind == "brief"
            ? "AGENT BRIEF" : URL(string: item.sourceUrl ?? "")?.host?.uppercased() ?? "ARTICLE"
        ).font(.caption2.weight(.semibold)).tracking(1)
        Spacer()
        if item.progress >= 1 { Image(systemName: "checkmark.circle.fill") }
      }.foregroundStyle(.secondary)
      Text(item.title).font(.system(size: 23, weight: .medium, design: .serif)).lineLimit(3)
      if let author = item.author { Text(author).font(.caption).foregroundStyle(.secondary) }
      HStack(spacing: 6) {
        Image(
          systemName: state.store?.offlineState(item) == .ready
            ? "checkmark.circle" : "arrow.down.circle")
        Text(
          item.status == "ready"
            ? state.store?.offlineState(item).rawValue ?? "Not downloaded" : item.status.capitalized
        )
      }.font(.caption).foregroundStyle(
        state.store?.offlineState(item) == .ready ? Color.green : Color.secondary)
      if let progress = Downloads.shared.progress(itemID: item.id),
        state.store?.offlineState(item) != .ready
      {
        ProgressView(value: progress)
        Text(
          "Downloading · \(item.assets.filter { state.store?.hasAsset(item,$0)==true }.count)/\(item.assets.count) files saved"
        ).font(.caption).foregroundStyle(.secondary)
      }
      if item.progress > 0 && item.progress < 1 {
        ProgressView(value: item.progress).tint(.secondary)
      }
    }
  }
}
struct SaveView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) var dismiss
  @State private var url = ""
  @State private var key = UUID().uuidString
  @State private var busy = false
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        Section("Article URL") {
          TextField("https://…", text: $url).keyboardType(.URL).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        Section {
          Text(
            "Articles are prepared on the server, then downloaded to this phone. Failed extraction keeps a bookmark."
          ).font(.footnote).foregroundStyle(.secondary)
        }
        if let error { Text(error).foregroundStyle(.red) }
      }.navigationTitle("Save an article").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(busy ? "Saving…" : "Save") {
            busy = true
            Task {
              do {
                try await state.save(url, key: key)
                dismiss()
              } catch { self.error = error.localizedDescription }
              busy = false
            }
          }.disabled(busy || url.isEmpty)
        }
      }
    }
  }
}
struct ReaderScreen: View {
  @EnvironmentObject var state: AppState
  let itemID: String
  @AppStorage("readerFontSize") private var fontSize = 20.0
  @State private var collection = ""
  @State private var showCollection = false
  private var item: ReadingItem? { state.items.first { $0.id == itemID } }
  var body: some View {
    Group {
      if let item {
        VStack(alignment: .leading, spacing: 12) {
          VStack(alignment: .leading, spacing: 8) {
            Text(item.kind == "brief" ? "AGENT-CREATED BRIEF" : "SAVED ARTICLE").font(
              .caption.weight(.semibold)
            ).tracking(1).foregroundStyle(.secondary)
            Text(item.title).font(.system(size: 28, weight: .medium, design: .serif))
            if let author = item.author {
              Text(author).font(.subheadline).foregroundStyle(.secondary)
            }
            if let source = item.sourceUrl, let url = URL(string: source) {
              Link("View original · \(url.host ?? "source")", destination: url).font(.caption)
            }
            Text(state.store?.offlineState(item).rawValue ?? "Not downloaded").font(.caption)
              .foregroundStyle(.secondary)
          }.padding(.horizontal)
          if let path = try? state.store?.readerURL(item.id) {
            ArticleWebView(url: path, progress: item.progress, fontSize: fontSize) { progress in
              try? state.store?.edit(item.id, ItemPatch(progress: progress))
            }
          } else {
            ContentUnavailableView(
              item.status == "bookmark" ? "Bookmark saved" : "Download to read",
              systemImage: "arrow.down.circle",
              description: Text(
                item.error ?? "This article is saved on the server. Download it to read offline."))
            Button("Download now") { Task { await state.download(item) } }.buttonStyle(
              .borderedProminent
            ).frame(maxWidth: .infinity)
          }
          if let error = item.error {
            Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
          }
        }.toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Button("Larger text") { fontSize = min(32, fontSize + 2) }
              Button("Smaller text") { fontSize = max(14, fontSize - 2) }
              Button("Mark as read") { state.edit(item, ItemPatch(progress: 1)) }
              Button(item.archived ? "Restore to inbox" : "Archive") {
                state.edit(item, ItemPatch(archived: !item.archived))
              }
              Button("Add to collection") { showCollection = true }
              Button("Download / retry") { Task { await state.download(item) } }
              if item.status == "bookmark" {
                Button("Retry extraction") { Task { await state.retryImport(item) } }
              }
              Button("Remove download") { state.removeDownload(item) }
            } label: {
              Image(systemName: "ellipsis.circle")
            }
          }
        }.alert("Add to collection", isPresented: $showCollection) {
          TextField("Collection name", text: $collection)
          Button("Add") {
            let name = collection.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
              state.edit(
                item,
                ItemPatch(
                  collections: Array(Set(item.collections + [String(name.prefix(60))])).sorted()))
            }
          }
          Button("Cancel", role: .cancel) {}
        }
      } else {
        ContentUnavailableView("Item removed", systemImage: "book")
      }
    }.navigationBarTitleDisplayMode(.inline).onDisappear {
      state.reload()
      Task { try? await state.sync() }
    }
  }
}
struct SettingsView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) var dismiss
  @AppStorage("cellular") private var cellular = false
  @AppStorage("storageLimit") private var storageLimit = 512_000_000
  @State private var connections: [Connection] = []
  @State private var label = "Telegram assistant"
  @State private var newToken: String?
  @State private var error: String?
  @State private var confirmDelete = false
  var body: some View {
    NavigationStack {
      Form {
        Section("Downloads") {
          Toggle("Allow cellular downloads", isOn: $cellular).onChange(of: cellular) { _, _ in
            Task {
              await Downloads.shared.updateCellularPolicy()
              try? await state.sync(forceManifest: true)
            }
          }
          Picker("Storage limit", selection: $storageLimit) {
            Text("512 MB").tag(512_000_000)
            Text("1 GB").tag(1_000_000_000)
            Text("2 GB").tag(2_000_000_000)
          }
          Text(
            "Used: \(ByteCountFormatter.string(fromByteCount:state.store?.diskUsage ?? 0,countStyle:.file))"
          )
          Button("Refresh and retry pending downloads") {
            Task { try? await state.sync(forceManifest: true) }
          }
        }
        Section("Background refresh") {
          Text(
            UIApplication.shared.backgroundRefreshStatus == .available
              ? "Enabled in iOS" : "Restricted in iOS settings")
          Text(
            "iOS chooses when to refresh. Keep Background App Refresh enabled. Opening the app also checks for new items."
          ).font(.footnote).foregroundStyle(.secondary)
          Text("Last sync: \(state.lastSync)")
        }
        Section("Assistant connections") {
          TextField("Credential label", text: $label)
          Button("Create API credential") {
            Task {
              do {
                if let api = state.api {
                  let result: NewConnection = try await api.request(
                    "/v1/connections", method: "POST",
                    body: JSONSerialization.data(withJSONObject: ["label": label]))
                  newToken = result.token
                  await loadConnections()
                }
              } catch { self.error = error.localizedDescription }
            }
          }
          if let newToken {
            Text("Copy this credential now. It will not be shown again.").font(.footnote)
            Text(newToken).font(.caption.monospaced()).textSelection(.enabled)
            Button("Copy credential") { UIPasteboard.general.string = newToken }
          }
          ForEach(connections) { connection in
            HStack {
              Text(connection.label)
              Spacer()
              Button("Revoke", role: .destructive) {
                Task {
                  do {
                    guard let api = state.api else { return }
                    let _: OK = try await api.request(
                      "/v1/connections/\(connection.id)", method: "DELETE")
                    await loadConnections()
                  } catch { self.error = error.localizedDescription }
                }
              }
            }
          }
          Text("MCP endpoint: \(state.backendURL)/mcp").font(.caption).textSelection(.enabled)
        }
        if let error { Section { Text(error).foregroundStyle(.red) } }
        Section("Account") {
          Button("Sign out", role: .destructive) {
            Task {
              await state.logout()
              dismiss()
            }
          }
          Button("Delete account and library", role: .destructive) { confirmDelete = true }
        }
      }.navigationTitle("Settings").toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }.task { await loadConnections() }.confirmationDialog(
        "Permanently delete your account and all saved articles?", isPresented: $confirmDelete,
        titleVisibility: .visible
      ) {
        Button("Delete account", role: .destructive) {
          Task {
            do {
              try await state.deleteAccount()
              dismiss()
            } catch { self.error = error.localizedDescription }
          }
        }
      }
    }
  }
  private func loadConnections() async {
    do {
      if let api = state.api {
        let response: Connections = try await api.request("/v1/connections")
        connections = response.connections
      }
    } catch { self.error = error.localizedDescription }
  }
}
