import BackgroundTasks
import ReaderCore
import SwiftUI

struct RootView: View {
  @EnvironmentObject var state: AppState
  @AppStorage("appearance") private var appearance = "light"
  private var preferredScheme: ColorScheme? {
    switch appearance {
    case "dark": return .dark
    case "system": return nil
    default: return .light
    }
  }
  var body: some View {
    Group { if state.session == nil { LoginView() } else { LibraryView() } }.tint(
      Color(red: 0.78, green: 0.30, blue: 0.15)
    ).preferredColorScheme(preferredScheme)
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
  @State private var archived = false
  @State private var collection = "All"
  @State private var showSave = false
  @State private var showSettings = false
  private var collections: [String] { Array(Set(state.items.flatMap(\.collections))).sorted() }
  private var filtered: [ReadingItem] {
    let matches = query.isEmpty ? nil : (try? state.store?.search(query))
    return state.items.filter {
      $0.archived == archived && (collection == "All" || $0.collections.contains(collection))
        && (query.isEmpty || matches?.contains($0.id) == true)
    }
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        HStack {
          Text(filtered.count == 1 ? "1 item" : "\(filtered.count) items")
          Spacer()
          if state.refreshing { ProgressView().accessibilityLabel("Syncing library") }
          if !collections.isEmpty {
            Menu {
              Button("All collections") { collection = "All" }
              ForEach(collections, id: \.self) { name in Button(name) { collection = name } }
            } label: {
              Label(collection, systemImage: "folder")
            }
          }
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 8)
        List {
          if filtered.isEmpty {
            ContentUnavailableView(
              query.isEmpty
                ? (archived ? "No archived reads" : "Your next good read") : "No matches",
              systemImage: archived ? "archivebox" : "book",
              description: Text(
                query.isEmpty
                  ? (archived
                    ? "Finished articles remain available here."
                    : "Save a link here or send one through your assistant.")
                  : "Try a title or words from a downloaded article.")
            ).listRowSeparator(.hidden)
          }
          ForEach(filtered) { item in
            NavigationLink {
              ReaderScreen(itemID: item.id)
            } label: {
              ArticleRow(item: item)
            }
            .listRowSeparator(.hidden).listRowInsets(
              EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
            )
            .swipeActions {
              Button(role: .destructive) {
                state.edit(item, ItemPatch(deleted: true))
              } label: {
                Label("Delete", systemImage: "trash")
              }
              Button {
                state.edit(item, ItemPatch(archived: !item.archived))
              } label: {
                Label(item.archived ? "Move to Library" : "Archive", systemImage: "archivebox")
              }.tint(.gray)
            }
          }
        }.listStyle(.plain).refreshable { try? await state.sync(forceManifest: true) }
      }.navigationTitle(archived ? "Archive" : "Library")
        .searchable(text: $query, prompt: "Search \(archived ? "archive" : "library")")
        .toolbar {
          if archived {
            ToolbarItem(placement: .topBarLeading) {
              Button {
                archived = false
                collection = "All"
                query = ""
              } label: {
                Label("Library", systemImage: "chevron.left")
              }
            }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              showSave = true
            } label: {
              Image(systemName: "plus")
            }.accessibilityLabel("Save article")
          }
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              if !archived {
                Button {
                  archived = true
                  collection = "All"
                  query = ""
                } label: {
                  Label("Archive", systemImage: "archivebox")
                }
              }
              Button {
                showSettings = true
              } label: {
                Label("Settings", systemImage: "gearshape")
              }
            } label: {
              Image(systemName: "ellipsis.circle")
            }.accessibilityLabel("Library options")
          }
        }.safeAreaInset(edge: .bottom) {
          if state.readingUndo != nil || state.message != nil {
            VStack(spacing: 8) {
              if state.readingUndo != nil {
                HStack {
                  Text("Moved to Archive").font(.callout)
                  Spacer()
                  Button("Undo") { state.undoFinishedReading() }.font(.callout.weight(.semibold))
                  Button {
                    state.dismissReadingUndo()
                  } label: {
                    Image(systemName: "xmark")
                  }
                  .accessibilityLabel("Dismiss undo")
                }
              }
              if let message = state.message {
                HStack {
                  Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                  Spacer()
                  Button("Retry") { Task { try? await state.sync(forceManifest: true) } }.font(
                    .caption)
                }
              }
            }.padding().background(.regularMaterial)
          }
        }.sheet(isPresented: $showSave) { SaveView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onChange(of: collections) { _, names in
          if collection != "All" && !names.contains(collection) { collection = "All" }
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
        )
        .font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.secondary).lineLimit(1)
        Spacer()
        if item.progress >= 1 {
          Image(systemName: "checkmark").foregroundStyle(.secondary).accessibilityLabel("Read")
        }
        DownloadIndicator(item: item)
      }
      Text(item.title).font(.system(size: 23, weight: .medium, design: .serif)).lineLimit(3)
      if let author = item.author { Text(author).font(.caption).foregroundStyle(.secondary) }
      if let progress = Downloads.shared.progress(itemID: item.id), progress < 1,
        state.store?.offlineState(item) != .ready
      {
        ProgressView(value: progress).accessibilityLabel("Downloading article")
      }
      if item.progress > 0 && item.progress < 1 {
        ProgressView(value: (try? state.store?.readingPosition(item.id)) ?? item.progress).tint(
          .secondary
        )
        .accessibilityLabel("Reading progress")
      }
    }
  }
}
struct DownloadIndicator: View {
  @EnvironmentObject var state: AppState
  let item: ReadingItem
  private var offline: OfflineState { state.store?.offlineState(item) ?? .notDownloaded }
  var body: some View {
    Group {
      if ["queued", "processing"].contains(item.status) {
        Label("Preparing", systemImage: "clock").foregroundStyle(.secondary)
      } else if item.status == "bookmark" {
        Label("Couldn't prepare", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
      } else if offline == .ready {
        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green).accessibilityLabel(
          "Available offline")
      } else if offline == .textOnly {
        Label("Text only", systemImage: "doc.badge.ellipsis").foregroundStyle(.orange)
          .accessibilityLabel("Text available, images incomplete")
      } else if offline == .downloading || Downloads.shared.progress(itemID: item.id) != nil {
        Label("Downloading", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
      } else {
        Image(systemName: "arrow.down.circle").foregroundStyle(.secondary).accessibilityLabel(
          "Not downloaded")
      }
    }.font(.caption)
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
  @Environment(\.dismiss) private var dismiss
  @State private var showTextSize = false
  @State private var finished = false
  let itemID: String
  @AppStorage("readerFontSize") private var fontSize = 20.0
  @AppStorage("appearance") private var appearance = "light"
  private var readerBackground: Color {
    appearance == "sepia"
      ? Color(red: 246 / 255, green: 240 / 255, blue: 228 / 255)
      : Color(.systemBackground)
  }
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
            ArticleWebView(
              url: path, progress: (try? state.store?.readingPosition(item.id)) ?? item.progress,
              fontSize: fontSize
            ) { progress in
              if !finished { try? state.store?.recordReadingPosition(item.id, progress) }
            }
          } else {
            ContentUnavailableView(
              item.status == "bookmark" ? "Bookmark saved" : "Download to read",
              systemImage: "arrow.down.circle",
              description: Text(
                item.error ?? "This article is saved on the server. Download it to read offline."))
            if item.status == "ready" {
              Button("Download now") { Task { await state.download(item) } }.buttonStyle(
                .borderedProminent
              ).frame(maxWidth: .infinity)
            } else if item.status == "bookmark" {
              Button("Retry extraction") { Task { await state.retryImport(item) } }.buttonStyle(
                .borderedProminent
              ).frame(maxWidth: .infinity)
            }
          }
          if let error = item.error {
            Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
          }
        }.toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Button("Text size") { showTextSize = true }
              if !item.archived, (try? state.store?.readerURL(item.id)) != nil {
                Button("Done reading") {
                  if state.finishReading(item.id) {
                    finished = true
                    dismiss()
                  }
                }
              } else {
                Button(item.archived ? "Move to Library" : "Archive") {
                  state.edit(item, ItemPatch(archived: !item.archived))
                  dismiss()
                }
              }
              Button("Add to collection") { showCollection = true }
              let offline = state.store?.offlineState(item) ?? .notDownloaded
              if item.status == "bookmark" {
                Button("Retry extraction") { Task { await state.retryImport(item) } }
              } else if item.status == "ready", offline != .ready {
                Button(offline == .notDownloaded ? "Download now" : "Retry download") {
                  Task { await state.download(item) }
                }
              }
              if (try? state.store?.readerURL(item.id)) != nil || offline == .downloading {
                Button("Remove download", role: .destructive) { state.removeDownload(item) }
              }
            } label: {
              Image(systemName: "ellipsis.circle")
            }.accessibilityLabel("Reading options")
          }
        }.sheet(isPresented: $showTextSize) {
          NavigationStack {
            Form {
              Section {
                Slider(value: $fontSize, in: 14...32, step: 2).accessibilityLabel("Text size")
                Text("Article text · \(Int(fontSize)) pt").font(
                  .system(size: fontSize, design: .serif))
              }
            }.navigationTitle("Text size")
              .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                  Button("Done") { showTextSize = false }
                }
              }
          }.presentationDetents([.medium])
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
    }.background(readerBackground.ignoresSafeArea())
      .toolbarBackground(readerBackground, for: .navigationBar)
      .navigationBarTitleDisplayMode(.inline).onAppear { finished = false }.onDisappear {
        finished = true
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
  @AppStorage("appearance") private var appearance = "light"
  var body: some View {
    NavigationStack {
      Form {
        Section("Appearance") {
          Picker("Theme", selection: $appearance) {
            Text("Light").tag("light")
            Text("Sepia").tag("sepia")
            Text("Dark").tag("dark")
            Text("System").tag("system")
          }
          Text("Light uses white pages. Sepia uses warm off-white pages with softer brown text.")
            .font(.footnote).foregroundStyle(.secondary)
        }
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
        }
        Section("Background refresh") {
          Text(
            UIApplication.shared.backgroundRefreshStatus == .available
              ? "Enabled in iOS" : "Restricted in iOS settings")
          Text(
            "iOS chooses when to refresh. Keep Background App Refresh enabled. Opening the app also checks for new items."
          ).font(.footnote).foregroundStyle(.secondary)
          Text("Last sync: \(state.lastSync)")
          Button("Sync now") { Task { try? await state.sync(forceManifest: true) } }
        }
        Section {
          NavigationLink("Assistant connections") { ConnectionsView() }
          NavigationLink("Account") { AccountView() }
        }
      }.navigationTitle("Settings").toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
  }
}
struct ConnectionsView: View {
  @EnvironmentObject var state: AppState
  @State private var connections: [Connection] = []
  @State private var label = "Telegram assistant"
  @State private var newToken: String?
  @State private var error: String?
  var body: some View {
    Form {
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
    }.navigationTitle("Assistant connections").task { await loadConnections() }
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
struct AccountView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var confirmDelete = false
  @State private var error: String?
  var body: some View {
    Form {
      Section("Account") {
        Button("Sign out", role: .destructive) {
          Task {
            await state.logout()
            dismiss()
          }
        }
        Button("Delete account and library", role: .destructive) { confirmDelete = true }
      }
      if let error { Section { Text(error).foregroundStyle(.red) } }
    }.navigationTitle("Account").confirmationDialog(
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
