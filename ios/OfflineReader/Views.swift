import BackgroundTasks
import CoreSpotlight
import ReaderCore
import SwiftUI

struct RootView: View {
  @EnvironmentObject var state: AppState
  var body: some View {
    Group { if state.session == nil { LoginView() } else { LibraryView() } }.appTheme()
      .onOpenURL { url in
        if let id = ContinueReading.itemID(from: url) { state.open(id) }
      }
      .onContinueUserActivity(CSSearchableItemActionType) { activity in
        if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
          state.open(id)
        }
      }
  }
}
struct LoginView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.themeTokens) private var tokens
  @State private var base = ""
  @State private var email = ""
  @State private var password = ""
  @State private var busy = false
  @State private var showAdvanced = false
  @ScaledMetric(relativeTo: .largeTitle) private var headlineSize = 38
  @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 56
  private var brandMark: some View {
    Image("BrandMark").resizable().scaledToFit().frame(width: iconSize, height: iconSize)
      .accessibilityHidden(true)
  }
  private var brandName: some View {
    Text("PageStash").font(.title2.weight(.semibold)).fixedSize()
  }
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          // Side by side when it fits; stacked at the largest text sizes so the name never breaks.
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { brandMark; brandName }
            VStack(alignment: .leading, spacing: 8) { brandMark; brandName }
          }
          .padding(.top, 50).accessibilityElement(children: .combine)
          .accessibilityAddTraits(.isHeader)
          Text("A quieter place\nto read.").font(
            .system(size: headlineSize, weight: .medium, design: .serif))
          Text("Save articles and reading briefs. Take them offline.")
            .foregroundStyle(tokens.secondaryInk.color)
          VStack(spacing: 12) {
            TextField("Email", text: $email).textContentType(.username).keyboardType(.emailAddress)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Password", text: $password).textContentType(.password)
          }.textFieldStyle(.roundedBorder)
          // The server address is a setup detail; it opens automatically when none is stored.
          DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            TextField("Backend URL", text: $base).textContentType(.URL).keyboardType(.URL)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
              .textFieldStyle(.roundedBorder).padding(.top, 8)
          }
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
            tokens.secondaryInk.color)
        }.padding(28)
      }.onAppear {
        base = state.backendURL
        showAdvanced = base.isEmpty
      }
    }
  }
}
struct LibraryView: View {
  @EnvironmentObject var state: AppState
  @Namespace private var transition
  @State private var showSave = false
  @State private var showSettings = false
  @State private var showImports = false
  @State private var showArchive = false
  private var pendingImports: Int {
    state.items.filter(\.needsImportReview).count + state.sharedSaves.count
  }
  var body: some View {
    NavigationStack {
      LibraryList(archived: false, showImports: $showImports, transition: transition)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              showSave = true
            } label: {
              Image(systemName: "plus")
            }.accessibilityLabel("Save article")
          }
          // Saving and the options menu are unrelated, so they get separate glass groups on iOS 26.
          #if compiler(>=6.2)
            if #available(iOS 26.0, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
          #endif
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              if pendingImports > 0 {
                Button {
                  showImports = true
                } label: {
                  Label("Imports (\(pendingImports))", systemImage: "tray")
                }
              }
              Button {
                showArchive = true
              } label: {
                Label("Archive", systemImage: "archivebox")
              }
              Button {
                showSettings = true
              } label: {
                Label("Settings", systemImage: "gearshape")
              }
            } label: {
              Image(systemName: "ellipsis")
            }.accessibilityLabel("Library options")
          }
        }
        // A pushed Archive gets the standard Back button.
        .navigationDestination(isPresented: $showArchive) {
          LibraryList(archived: true, showImports: $showImports, transition: transition)
        }
        .sheet(isPresented: $showSave) { SaveView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showImports) { ImportsView() }
        .onChange(of: state.openRequest) { _, request in
          guard let request else { return }
          state.openRequest = nil
          let sheetOpen = showSave || showSettings || showImports
          showSave = false
          showSettings = false
          showImports = false
          if sheetOpen {
            // Present once the sheet has finished dismissing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { state.readerRoute = request }
          } else {
            state.readerRoute = request
          }
        }
        // The reader is its own presentation, so its reading theme never restyles the Library.
        .fullScreenCover(item: $state.readerRoute) { route in
          NavigationStack { ReaderScreen(itemID: route.id) }
            .readerTheme()
            .readerZoomTransition(id: route.id, in: transition)
        }
    }
  }
}
struct LibraryList: View {
  @EnvironmentObject var state: AppState
  @Environment(\.themeTokens) private var tokens
  let archived: Bool
  @Binding var showImports: Bool
  let transition: Namespace.ID
  @State private var query = ""
  @State private var collection = "All"
  @State private var pendingDelete: ReadingItem?
  @State private var collectionTarget: ReadingItem?
  @State private var collectionName = ""
  @State private var archiveCommits = 0
  @State private var retrying = false
  @Environment(\.undoManager) private var undoManager
  private var imports: [ReadingItem] { state.items.filter(\.needsImportReview) }
  private var importSummary: String {
    let failed = imports.filter { $0.status == "bookmark" }.count
    let waiting = imports.count - failed
    return [
      waiting > 0 ? "\(waiting) preparing" : nil, failed > 0 ? "\(failed) couldn't prepare" : nil,
      !state.sharedSaves.isEmpty ? "\(state.sharedSaves.count) shared links to review" : nil,
    ]
    .compactMap { $0 }.joined(separator: " · ")
  }
  private var collections: [String] {
    Array(
      Set(
        state.items.filter { $0.hasPreparedContent && $0.archived == archived }.flatMap(
          \.collections))
    ).sorted()
  }
  private var filtered: [ReadingItem] {
    let matches = query.isEmpty ? nil : (try? state.store?.search(query))
    return state.items.filter {
      $0.hasPreparedContent && $0.archived == archived
        && (collection == "All" || $0.collections.contains(collection))
        && (query.isEmpty || matches?.contains($0.id) == true)
    }
  }
  private func toggleArchive(_ item: ReadingItem) {
    let archived = !item.archived
    state.edit(item, ItemPatch(archived: archived))
    archiveCommits += 1
    // Shake to undo, named after the action.
    undoManager?.registerUndo(withTarget: state) { state in
      if let current = state.items.first(where: { $0.id == item.id }) {
        state.edit(current, ItemPatch(archived: !archived))
      }
    }
    undoManager?.setActionName(archived ? "Archive" : "Move to Library")
  }
  @ViewBuilder private func archiveButton(_ item: ReadingItem) -> some View {
    Button {
      toggleArchive(item)
    } label: {
      Label(
        item.archived ? "Move to Library" : "Archive",
        systemImage: item.archived ? "tray.and.arrow.up" : "archivebox")
    }
  }
  var body: some View {
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
        ).listRowSeparator(.hidden).listRowBackground(tokens.nativePage)
      }
      ForEach(filtered) { item in
        Button {
          state.open(item.id)
        } label: {
          HStack(alignment: .center, spacing: 12) {
            ArticleRow(item: item)
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold))
              .foregroundStyle(.tertiary).accessibilityHidden(true)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .readerZoomSource(id: item.id, in: transition)
        .listRowBackground(tokens.nativePage)
        .listRowSeparator(.hidden).listRowInsets(
          EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        )
        // Archive is safe and reversible, so it takes the full swipe. Delete never does.
        .swipeActions(edge: .leading) { archiveButton(item).tint(.gray) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          // Not `.destructive`: that role removes the row before the confirmation can be cancelled.
          Button {
            pendingDelete = item
          } label: {
            Label("Delete", systemImage: "trash")
          }.tint(.red)
        }
        .contextMenu {
          archiveButton(item)
          Button {
            collectionName = ""
            collectionTarget = item
          } label: {
            Label("Add to Collection", systemImage: "folder.badge.plus")
          }
          if (try? state.store?.readerURL(item.id)) != nil {
            Button {
              state.removeDownload(item)
            } label: {
              Label("Remove Download", systemImage: "arrow.down.circle.dotted")
            }
          }
          Divider()
          Button(role: .destructive) {
            pendingDelete = item
          } label: {
            Label("Delete", systemImage: "trash")
          }
        }
      }
      if !archived && (!imports.isEmpty || !state.sharedSaves.isEmpty) {
        // Pending and failed imports stay one tap away without sitting above the reading list.
        Button {
          showImports = true
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "tray")
            Text(importSummary)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
          }.font(.footnote).foregroundStyle(tokens.secondaryInk.color)
        }
        .accessibilityIdentifier("Review imports")
        .listRowBackground(tokens.nativePage).listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(tokens.nativePage)
    .refreshable { try? await state.sync(forceManifest: true) }
    .navigationTitle(archived ? "Archive" : "Library")
    .searchable(text: $query, prompt: "Search \(archived ? "archive" : "library")")
    .toolbar {
      if !collections.isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Picker("Collection", selection: $collection) {
              Text("All Collections").tag("All")
              ForEach(collections, id: \.self) { Text($0).tag($0) }
            }
          } label: {
            Image(
              systemName: collection == "All"
                ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
          }
          .accessibilityLabel("Filter by collection")
          .accessibilityValue(collection == "All" ? "All collections" : collection)
        }
      }
    }
    .libraryStatusBar {
      if state.readingUndo != nil || state.message != nil {
        VStack(spacing: 8) {
          if state.readingUndo != nil {
            HStack {
              Text("Moved to Archive").font(.callout)
              Spacer()
              Button("Undo") { state.undoFinishedReading() }
                .font(.callout.weight(.semibold)).accessibilityLabel("Undo Done Reading")
              Button {
                state.dismissReadingUndo()
              } label: {
                Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
              }
              .accessibilityLabel("Dismiss undo")
            }
          }
          if let message = state.message {
            HStack {
              Text(message).font(.footnote).foregroundStyle(tokens.secondaryInk.color)
                .lineLimit(2)
              Spacer()
              if retrying {
                ProgressView().accessibilityLabel("Syncing")
              } else {
                Button("Retry") {
                  retrying = true
                  Task {
                    try? await state.sync(forceManifest: true)
                    retrying = false
                  }
                }
                .font(.footnote.weight(.semibold))
              }
            }
          }
        }
      }
    }
    .sensoryFeedback(.success, trigger: archiveCommits)
    .confirmationDialog(
      "Delete “\(pendingDelete?.title ?? "")”?",
      isPresented: Binding(
        get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      titleVisibility: .visible, presenting: pendingDelete
    ) { item in
      Button("Delete Article", role: .destructive) { state.edit(item, ItemPatch(deleted: true)) }
    } message: { _ in
      Text("This removes it from your library on every device. Archive keeps it instead.")
    }
    .alert(
      "Add to Collection",
      isPresented: Binding(
        get: { collectionTarget != nil }, set: { if !$0 { collectionTarget = nil } })
    ) {
      TextField("Collection name", text: $collectionName)
      Button("Add") {
        if let item = collectionTarget { state.addToCollection(item, name: collectionName) }
      }
      Button("Cancel", role: .cancel) {}
    }
    .onChange(of: collections) { _, names in
      if collection != "All" && !names.contains(collection) { collection = "All" }
    }
  }
}
struct ArticleRow: View {
  @EnvironmentObject var state: AppState
  @Environment(\.themeTokens) private var tokens
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .title2) private var titleSize = 23
  let item: ReadingItem
  /// A readable source: "Agent brief", the publisher's name, or the host in lower case without `www.`.
  static func source(_ item: ReadingItem) -> String? {
    if item.kind == "brief" { return "Agent brief" }
    if let name = item.siteName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
      return name
    }
    guard let host = URL(string: item.sourceUrl ?? "")?.host?.lowercased() else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
  /// About 230 words a minute; partly read articles show the time left.
  static func readingTime(words: Int?, position: Double) -> String? {
    guard let words, words > 0 else { return nil }
    let minutes = max(1, Int((Double(words) / 230).rounded()))
    guard position > 0 && position < 1 else { return "\(minutes) min" }
    return "\(max(1, Int((Double(minutes) * (1 - position)).rounded(.up)))) min left"
  }
  private var position: Double { (try? state.store?.readingPosition(item.id)) ?? item.progress }
  private var metadata: String {
    [
      Self.source(item), item.author,
      Self.readingTime(words: state.wordCounts[item.id], position: item.progress > 0 ? position : 0),
    ]
    .compactMap { $0 }.joined(separator: " · ")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(item.title).font(.system(size: titleSize, weight: .medium, design: .serif))
        .lineLimit(typeSize.isAccessibilitySize ? nil : 4)
      if !metadata.isEmpty {
        Text(metadata).font(.footnote).foregroundStyle(tokens.secondaryInk.color)
      }
      DownloadIndicator(item: item)
      if item.progress > 0 && item.progress < 1 {
        let position = position
        ProgressView(value: position).tint(tokens.secondaryInk.color)
          .accessibilityLabel("\(Int((position * 100).rounded())) percent read")
      }
    }
    .accessibilityElement(children: .combine)
  }
}
/// The one exceptional status a row may show. Prepared and verified offline is the quiet default.
struct DownloadIndicator: View {
  @EnvironmentObject var state: AppState
  @Environment(\.themeTokens) private var tokens
  @Environment(\.dynamicTypeSize) private var typeSize
  let item: ReadingItem
  private var offline: OfflineState { state.store?.offlineState(item) ?? .notDownloaded }
  private var status: (text: String, symbol: String, warning: Bool)? {
    if ["queued", "processing"].contains(item.status) { return ("Updating", "clock", false) }
    if item.status == "bookmark" {
      return ("Couldn't prepare the update", "exclamationmark.triangle", true)
    }
    switch offline {
    case .ready: return nil
    case .textOnly:
      return (item.error ?? "Text only · images incomplete", "exclamationmark.triangle", true)
    case .downloading: return ("Downloading", "arrow.down.circle", false)
    case .notDownloaded:
      return Downloads.shared.progress(itemID: item.id) == nil
        ? ("Not downloaded", "icloud.and.arrow.down", false)
        : ("Downloading", "arrow.down.circle", false)
    }
  }
  var body: some View {
    if let status {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: status.symbol)
          Text(status.text).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
        }
        .font(.footnote)
        .foregroundStyle(status.warning ? tokens.warning.color : tokens.secondaryInk.color)
        if let progress = Downloads.shared.progress(itemID: item.id), progress < 1,
          offline != .ready
        {
          ProgressView(value: progress).accessibilityLabel("Download progress")
        }
      }
    }
  }
}
extension View {
  @ViewBuilder func readerZoomSource(id: String, in namespace: Namespace.ID) -> some View {
    if #available(iOS 18.0, *) {
      matchedTransitionSource(id: id, in: namespace)
    } else {
      self
    }
  }
  @ViewBuilder func readerZoomTransition(id: String, in namespace: Namespace.ID) -> some View {
    if #available(iOS 18.0, *) {
      navigationTransition(.zoom(sourceID: id, in: namespace))
    } else {
      self
    }
  }
  /// Bottom status and Undo. On iOS 26 a safe-area bar gets the system scroll edge effect and
  /// sits above the bottom search field.
  @ViewBuilder func libraryStatusBar<Content: View>(@ViewBuilder _ content: () -> Content)
    -> some View
  {
    // The iOS 26 API needs the iOS 26 SDK (Swift 6.2); older toolchains such as CI's use the fallback.
    #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        safeAreaBar(edge: .bottom) {
          content().padding(.horizontal, 20).padding(.vertical, 4)
        }
      } else {
        safeAreaInset(edge: .bottom) {
          content().padding(.horizontal).padding(.vertical, 8).background(.regularMaterial)
        }
      }
    #else
      safeAreaInset(edge: .bottom) {
        content().padding(.horizontal).padding(.vertical, 8).background(.regularMaterial)
      }
    #endif
  }
}
/// The standard Close button on iOS 26; Done before it.
struct CloseButton: View {
  let action: () -> Void
  var body: some View {
    #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        Button(role: .close, action: action)
      } else {
        Button("Done", action: action)
      }
    #else
      Button("Done", action: action)
    #endif
  }
}
struct SaveView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.themeTokens) private var tokens
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
        }.readerRowBackground()
        Section {
          Text(
            "Only readable articles enter your Library. Preparation and failed attempts appear in Imports, with Retry when available. Readable text is kept if optional images are missing."
          ).font(.footnote).foregroundStyle(tokens.secondaryInk.color)
        }.readerRowBackground()
        if let error { Text(error).foregroundStyle(.red) }
      }.readerFormBackground().navigationTitle("Save an article").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(busy ? "Submitting…" : "Save") {
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
    }.appTheme()
  }
}
struct ReaderScreen: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.undoManager) private var undoManager
  @Environment(\.themeTokens) private var tokens
  @State private var showDisplay = false
  @State private var finished = false
  @StateObject private var scrollState = ArticleScrollState()
  let itemID: String
  @AppStorage("readerFontSize") private var fontSize = 20.0
  @AppStorage("readerPaging") private var paging = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var chromeInsets = EdgeInsets()
  @State private var collection = ""
  @State private var showCollection = false
  private var item: ReadingItem? { state.items.first { $0.id == itemID } }
  /// Measure the bars only while they show; hiding them must not re-pad the article.
  @State private var currentTopInset = 0.0
  private func measureChrome(_ insets: EdgeInsets) {
    currentTopInset = insets.top
    if !scrollState.barsHidden && insets != chromeInsets { chromeInsets = insets }
  }
  private func isReadable(_ item: ReadingItem) -> Bool {
    (try? state.store?.readerURL(item.id)) != nil
  }
  private func canFinish(_ item: ReadingItem) -> Bool { !item.archived && isReadable(item) }
  private func finish(_ item: ReadingItem) {
    scrollState.flush?()
    if state.finishReading(item.id) {
      let id = item.id
      undoManager?.registerUndo(withTarget: state) { state in
        // Only while this article's Undo is still the current one.
        if state.readingUndo?.itemId == id { state.undoFinishedReading() }
      }
      undoManager?.setActionName("Done Reading")
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      finished = true
      dismiss()
    }
  }
  var body: some View {
    Group {
      if let item {
        let offline = state.store?.offlineState(item) ?? .notDownloaded
        Group {
          if let path = try? state.store?.readerURL(item.id) {
            ArticleWebView(
              url: path,
              header: ArticleHeader(
                title: item.title, kind: item.kind, author: item.author,
                source: URL(string: item.sourceUrl ?? ""),
                status: offline == .ready ? nil : offline.rawValue,
                error: item.error, finishLabel: canFinish(item) ? "Done Reading" : nil,
                sources: item.sources.compactMap(URL.init(string:))),
              scrollState: scrollState,
              progress: (try? state.store?.readingPosition(item.id)) ?? item.progress,
              fontSize: fontSize,
              chromeInsets: chromeInsets,
              paging: paging,
              onFinish: { finish(item) }
            ) { progress in
              if !finished { try? state.store?.recordReadingPosition(item.id, progress) }
            }
            .ignoresSafeArea(edges: .vertical)
            .accessibilityAction(.magicTap) { scrollState.barsHidden = false }
            .onReceive(
              NotificationCenter.default.publisher(
                for: UIAccessibility.voiceOverStatusDidChangeNotification)
            ) { _ in scrollState.barsHidden = false }
            .onReceive(
              NotificationCenter.default.publisher(
                for: UIAccessibility.switchControlStatusDidChangeNotification)
            ) { _ in scrollState.barsHidden = false }
            .background {
              GeometryReader { proxy in
                Color.clear
                  .onAppear { measureChrome(proxy.safeAreaInsets) }
                  .onChange(of: proxy.safeAreaInsets) { _, insets in measureChrome(insets) }
              }
            }
            // With the bars hidden, the page colour keeps text from showing under the status bar.
            .overlay {
              if scrollState.barsHidden {
                VStack(spacing: 0) {
                  Color(hex: tokens.page).frame(height: currentTopInset)
                  Spacer(minLength: 0)
                }
                .ignoresSafeArea().allowsHitTesting(false)
              }
            }

          } else {
            ScrollView {
              VStack(alignment: .leading, spacing: 16) {
                ReaderMetadata(item: item)
                ContentUnavailableView(
                  item.status == "bookmark" ? "Bookmark saved" : "Download to read",
                  systemImage: "arrow.down.circle",
                  description: Text(
                    item.error
                      ?? "This article is saved on the server. Download it to read offline."))
                if item.status == "ready" {
                  Button("Download now") { Task { await state.download(item) } }.buttonStyle(
                    .borderedProminent
                  ).frame(maxWidth: .infinity)
                } else if item.status == "bookmark" {
                  Button("Retry extraction") { Task { await state.retryImport(item) } }.buttonStyle(
                    .borderedProminent
                  ).frame(maxWidth: .infinity)
                }
              }.padding()
            }
          }
        }.toolbar {
          ToolbarItem(placement: .topBarLeading) {
            CloseButton { dismiss() }
          }
          // Less frequent actions; the primary ones sit in the bottom bar near the thumb.
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Button {
                showCollection = true
              } label: {
                Label("Add to Collection", systemImage: "folder.badge.plus")
              }
              if item.status == "bookmark" {
                Button {
                  Task { await state.retryImport(item) }
                } label: {
                  Label("Retry Extraction", systemImage: "arrow.clockwise")
                }
              } else if item.status == "ready", offline != .ready {
                Button {
                  Task { await state.download(item) }
                } label: {
                  Label(
                    offline == .notDownloaded ? "Download Now" : "Retry Download",
                    systemImage: "arrow.down.circle")
                }
              }
              if isReadable(item) || offline == .downloading {
                Button(role: .destructive) {
                  state.removeDownload(item)
                } label: {
                  Label("Remove Download", systemImage: "arrow.down.circle.dotted")
                }
              }
            } label: {
              Image(systemName: "ellipsis")
            }.accessibilityLabel("Reading options")
          }
          ToolbarItem(placement: .bottomBar) {
            Button {
              showDisplay = true
            } label: {
              Image(systemName: "textformat.size")
            }.accessibilityLabel("Text and theme")
          }
          ToolbarItem(placement: .bottomBar) { Spacer() }
          ToolbarItem(placement: .bottomBar) {
            if canFinish(item) {
              Button("Done Reading") { finish(item) }.fontWeight(.semibold)
            } else {
              Button(item.archived ? "Move to Library" : "Archive") {
                state.edit(item, ItemPatch(archived: !item.archived))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
              }.fontWeight(.semibold)
            }
          }
        }.sheet(isPresented: $showDisplay) {
          ReaderDisplaySheet(fontSize: $fontSize)
        }.alert("Add to Collection", isPresented: $showCollection) {
          TextField("Collection name", text: $collection)
          Button("Add") {
            state.addToCollection(item, name: collection)
            collection = ""
          }
          Button("Cancel", role: .cancel) {}
        }
      } else {
        ContentUnavailableView("Item removed", systemImage: "book")
          .toolbar {
            ToolbarItem(placement: .topBarLeading) { CloseButton { dismiss() } }
          }
      }
    }
    .background(Color(hex: tokens.page).ignoresSafeArea())
      .toolbar(scrollState.barsHidden ? .hidden : .visible, for: .navigationBar, .bottomBar)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: scrollState.barsHidden)
      .navigationBarTitleDisplayMode(.inline).onAppear {
        finished = false
        SystemIntegration.didOpen(itemID)
      }.onDisappear {
        if !finished { scrollState.flush?() }
        finished = true
        state.reload()
        Task { try? await state.sync() }
      }
  }
}
/// Text size and theme for reading, kept on the reading screen. Changes apply live.
struct ReaderDisplaySheet: View {
  @Binding var fontSize: Double
  @AppStorage("readerPaging") private var paging = false
  @AppStorage("appearance") private var appearance = ThemeTokens.defaultAppearance
  @Environment(\.dismiss) private var dismiss
  @Environment(\.themeTokens) private var tokens
  private var percent: Int { Int((fontSize / 20 * 100).rounded()) }
  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack(spacing: 12) {
            Button {
              fontSize = max(14, fontSize - 2)
            } label: {
              Image(systemName: "textformat.size.smaller").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Smaller text").disabled(fontSize <= 14)
            Slider(value: $fontSize, in: 14...32, step: 2)
              .accessibilityLabel("Text size").accessibilityValue("\(percent) percent")
            Button {
              fontSize = min(32, fontSize + 2)
            } label: {
              Image(systemName: "textformat.size.larger").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Larger text").disabled(fontSize >= 32)
          }.buttonStyle(.borderless)
        } header: {
          Text("Text Size")
        } footer: {
          Text("\(percent)% of the reader default. Articles also follow your iPhone text size.")
            .foregroundStyle(tokens.secondaryInk.color)
        }.readerRowBackground()
        Section("Reading Theme") {
          Picker("Theme", selection: $appearance) {
            Text("Light").tag("light")
            Text("Sepia").tag("sepia")
            Text("Dark").tag("dark")
            Text("System").tag("system")
          }.pickerStyle(.segmented)
        }.readerRowBackground()
        Section {
          Toggle("Page by Page", isOn: $paging)
        } footer: {
          Text("Each swipe moves one screen, keeping the last line in view.")
            .foregroundStyle(tokens.secondaryInk.color)
        }.readerRowBackground()
      }.readerFormBackground().navigationTitle("Text and Theme")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton { dismiss() } } }
    }.readerTheme().presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
  }
}
struct ReaderMetadata: View {
  @EnvironmentObject var state: AppState
  @Environment(\.themeTokens) private var tokens
  @ScaledMetric(relativeTo: .title) private var titleSize = 28
  let item: ReadingItem
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if item.kind == "brief" {
        Text("AGENT-CREATED BRIEF").font(.caption.weight(.semibold)).tracking(1)
          .foregroundStyle(tokens.secondaryInk.color)
        Text("Written by an assistant. It may contain errors; check the sources.")
          .font(.footnote).foregroundStyle(tokens.secondaryInk.color)
        ForEach(
          item.sources.compactMap(URL.init(string:)).filter {
            ["http", "https"].contains($0.scheme ?? "")
          }.prefix(5), id: \.self
        ) { url in
          Link("Source · \(url.host ?? url.absoluteString)", destination: url).font(.footnote)
            .foregroundStyle(tokens.link.color)
        }
      }
      Text(item.title).font(.system(size: titleSize, weight: .medium, design: .serif))
        .accessibilityAddTraits(.isHeader)
      if let author = item.author {
        Text(author).font(.subheadline).foregroundStyle(tokens.secondaryInk.color)
      }
      if let source = item.sourceUrl, let url = URL(string: source),
        ["http", "https"].contains(url.scheme ?? "")
      {
        Link("View original · \(url.host ?? "source")", destination: url).font(.footnote)
          .foregroundStyle(tokens.link.color)
      }
      if let offline = state.store?.offlineState(item), offline != .ready {
        Text(offline.rawValue).font(.footnote).foregroundStyle(tokens.secondaryInk.color)
      }
    }
  }
}
struct SettingsView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) var dismiss
  @AppStorage("cellular") private var cellular = false
  @AppStorage("storageLimit") private var storageLimit = 512_000_000
  @AppStorage("appearance") private var appearance = ThemeTokens.defaultAppearance
  @Environment(\.themeTokens) private var tokens
  @State private var syncing = false
  var body: some View {
    NavigationStack {
      Form {
        Section("Reading Theme") {
          Picker("Theme", selection: $appearance) {
            Text("Light").tag("light")
            Text("Sepia").tag("sepia")
            Text("Dark").tag("dark")
            Text("System").tag("system")
          }
          Text(
            "Articles use this theme. Light uses white pages; Sepia uses warm off-white pages with softer brown text. The Library and Settings follow your iPhone's appearance. While reading, Aa also changes the theme and text size."
          )
          .font(.footnote).foregroundStyle(tokens.secondaryInk.color)
        }.readerRowBackground()
        if let message = state.sharingMessage {
          Section("Browser Sharing") { Text(message).font(.footnote) }.readerRowBackground()
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
        }.readerRowBackground()
        Section("Background Refresh") {
          Text(
            UIApplication.shared.backgroundRefreshStatus == .available
              ? "Enabled in iOS" : "Restricted in iOS settings")
          Text(
            "iOS chooses when to refresh. Keep Background App Refresh enabled. Opening the app also checks for new items."
          ).font(.footnote).foregroundStyle(tokens.secondaryInk.color)
          Text("Last sync: \(state.lastSync)")
          Button {
            syncing = true
            Task {
              try? await state.sync(forceManifest: true)
              syncing = false
            }
          } label: {
            HStack {
              Text(syncing ? "Syncing…" : "Sync now")
              if syncing {
                Spacer()
                ProgressView()
              }
            }
          }.disabled(syncing)
        }.readerRowBackground()
        Section {
          NavigationLink("Assistant connections") { ConnectionsView() }
          NavigationLink("Account") { AccountView() }
        }.readerRowBackground()
      }.readerFormBackground().navigationTitle("Settings").toolbar {
        ToolbarItem(placement: .cancellationAction) { CloseButton { dismiss() } }
      }
    }.appTheme()
  }
}
struct ConnectionsView: View {
  @EnvironmentObject var state: AppState
  @State private var connections: [Connection] = []
  @State private var label = "Telegram assistant"
  @State private var newToken: String?
  @State private var error: String?
  /// Local switch positions while a change is in flight or just failed.
  @State private var sharing: [String: Bool] = [:]
  @State private var updating: Set<String> = []
  var body: some View {
    Form {
      Section("Assistant Connections") {
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
          VStack(alignment: .leading) {
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
            Toggle(
              "Share saved-article titles",
              isOn: Binding(
                get: { sharing[connection.id] ?? connection.interests ?? false },
                set: { on in Task { await setInterests(connection, on) } })
            )
            .font(.subheadline)
            // One request at a time per connection, so taps cannot land out of order.
            .disabled(updating.contains(connection.id))
            .accessibilityLabel("Share saved-article titles with \(connection.label)")
          }
        }
        if !connections.isEmpty {
          Text(
            "Sharing lets an assistant read the titles, links, sites and save times of your saved articles to suggest similar reading. It never sees article text, briefs or reading progress."
          ).font(.footnote).foregroundStyle(.secondary)
        }
        Text("MCP endpoint: \(state.backendURL)/mcp").font(.caption).textSelection(.enabled)
      }.readerRowBackground()
      if let error { Section { Text(error).foregroundStyle(.red) }.readerRowBackground() }
    }.readerFormBackground().navigationTitle("Assistant connections").task {
      await loadConnections()
    }
  }
  private func setInterests(_ connection: Connection, _ on: Bool) async {
    guard let api = state.api, !updating.contains(connection.id) else { return }
    let previous = sharing[connection.id] ?? connection.interests ?? false
    // Show the new position at once; restore it if the server refuses.
    sharing[connection.id] = on
    updating.insert(connection.id)
    do {
      let _: OK = try await api.request(
        "/v1/connections/\(connection.id)", method: "PATCH",
        body: JSONSerialization.data(withJSONObject: ["interests": on]))
      error = nil
    } catch {
      sharing[connection.id] = previous
      self.error = error.localizedDescription
    }
    updating.remove(connection.id)
    await loadConnections()
  }
  private func loadConnections() async {
    do {
      if let api = state.api {
        let response: Connections = try await api.request("/v1/connections")
        connections = response.connections
        // Server state wins once no change is in flight.
        sharing = sharing.filter { updating.contains($0.key) }
      }
    } catch { self.error = error.localizedDescription }
  }
}
struct AccountView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var confirmDelete = false
  @State private var error: String?
  @State private var reconnect = false
  var body: some View {
    Form {
      Section("Account") {
        Button("Sign in again") { reconnect = true }
        Button("Sign out", role: .destructive) {
          Task {
            await state.logout()
            dismiss()
          }
        }
        Button("Delete account and library", role: .destructive) { confirmDelete = true }
      }.readerRowBackground()
      if let error { Section { Text(error).foregroundStyle(.red) }.readerRowBackground() }
    }.readerFormBackground().navigationTitle("Account")
      .sheet(isPresented: $reconnect) {
        LoginView().onChange(of: state.session?.generation) { _, _ in reconnect = false }
          .appTheme()
      }.confirmationDialog(
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

struct ImportsView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.themeTokens) private var tokens
  @Environment(\.dismiss) private var dismiss
  @State private var retrying: Set<String> = []
  private var imports: [ReadingItem] { state.items.filter(\.needsImportReview) }
  private func sharedStatus(_ item: SharedSave) -> String {
    switch item.state {
    case .queued: return "Queued on this device · not submitted yet"
    case .sending: return "Submitting · result not confirmed"
    case .authenticationRequired: return "Sign-in required · not sent with the current sign-in"
    case .rejected: return "Request could not be accepted"
    case .accepted:
      return item.serverStatus == "ready"
        ? "Prepared on server · download not verified"
        : item.serverStatus == "bookmark"
          ? "Preparation failed · refresh for details" : "Submitted · waiting for preparation"
    }
  }
  var body: some View {
    NavigationStack {
      List {
        if imports.isEmpty && state.sharedSaves.isEmpty {
          ContentUnavailableView(
            "No pending imports", systemImage: "checkmark.circle",
            description: Text("Prepared articles appear in Library."))
        }
        ForEach(state.sharedSaves) { item in
          VStack(alignment: .leading, spacing: 8) {
            Text(item.url.absoluteString).font(.headline).lineLimit(3)
            Text(sharedStatus(item)).font(.subheadline).foregroundStyle(tokens.secondaryInk.color)
            if let error = item.error { Text(error).font(.callout) }
            if item.state != .accepted && item.state != .sending {
              Button("Retry with current sign-in") { Task { await state.retrySharedSave(item) } }
            }
            if item.state == .authenticationRequired {
              Text(
                "Use Account → Sign in again, then Retry. The old sign-in's links are never sent automatically with a new credential."
              ).font(.caption).foregroundStyle(tokens.secondaryInk.color)
            }
          }.padding(.vertical, 8).readerRowBackground()
            .swipeActions {
              Button("Remove", role: .destructive) { state.removeSharedSave(item.id) }
            }
        }
        ForEach(imports) { item in
          VStack(alignment: .leading, spacing: 8) {
            Text(item.title).font(.headline)
            if let source = item.sourceUrl {
              Text(source).font(.caption).foregroundStyle(tokens.secondaryInk.color).lineLimit(2)
            }
            Label(
              item.status == "bookmark" ? "Couldn't prepare" : "Preparing · not saved yet",
              systemImage: item.status == "bookmark" ? "exclamationmark.triangle" : "clock"
            )
            .font(.subheadline).foregroundStyle(tokens.secondaryInk.color)
            if let error = item.error { Text(String(error.prefix(240))).font(.callout) }
            if item.hasPreparedContent {
              Text("Your earlier readable copy is still in Library.").font(.caption)
            }
            if item.status == "bookmark", item.sourceUrl != nil {
              Button(retrying.contains(item.id) ? "Retrying…" : "Retry") {
                retrying.insert(item.id)
                Task {
                  await state.retryImport(item)
                  retrying.remove(item.id)
                }
              }.disabled(retrying.contains(item.id))
            }
          }.padding(.vertical, 8).readerRowBackground()
            .swipeActions {
              Button("Remove", role: .destructive) { state.edit(item, ItemPatch(deleted: true)) }
            }
        }
      }.listStyle(.insetGrouped).readerFormBackground()
        .refreshable { try? await state.sync(forceManifest: true) }
        .navigationTitle("Imports").toolbar {
          ToolbarItem(placement: .cancellationAction) { CloseButton { dismiss() } }
        }
    }.appTheme()
  }
}
