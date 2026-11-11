import ReaderCore
import SwiftUI

/// How the open article relates to articles already finished, its key points, and questions about
/// it. Where Apple Intelligence is available it all runs on this iPhone for any account, with
/// nothing sent anywhere; notes are usually written ahead (see `LocalAI`) and opening the sheet
/// writes one if not. Otherwise entitled accounts get the server's note, which opening never
/// generates; Generate Now and Regenerate are explicit.
struct ReadingContextSheet: View {
  @EnvironmentObject var state: AppState
  @ObservedObject private var ai = AppState.shared.localAI
  @Environment(\.dismiss) private var dismiss
  @Environment(\.themeTokens) private var tokens
  let item: ReadingItem
  @State private var context: ReadingContext?
  @State private var loading = true
  @State private var generating = false
  @State private var failure: String?
  @State private var generatedHere = false
  @State private var question = ""
  @State private var answer: String?
  @State private var answerFailure: String?
  @State private var asking: Task<Void, Never>?
  @FocusState private var questionFocused: Bool

  private var current: ReadingItem { state.items.first { $0.id == item.id } ?? item }
  private var onDevice: Bool { ai.isAvailable }
  private var job: LocalAI.Job? { ai.job?.itemID == item.id ? ai.job : nil }
  private var busy: Bool { generating || job != nil }
  private var readable: Bool { (try? state.store?.readerURL(item.id)) != nil }

  var body: some View {
    NavigationStack {
      List {
        if let context {
          result(context)
        } else if loading {
          Section {
            ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
          }
        } else if job == nil {
          Section {
            Text(emptyMessage)
          } footer: {
            Text(privacy).foregroundStyle(tokens.secondaryInk.color)
          }.readerRowBackground()
        }
        if let job { progress(job) }
        if let failure {
          Section {
            Label(failure, systemImage: "exclamationmark.triangle")
              .foregroundStyle(tokens.warning.color)
          }.readerRowBackground()
        }
        if !loading, job == nil, onDevice || state.readingContextEnabled {
          Section {
            Button {
              Task { await generate() }
            } label: {
              HStack {
                Text(context == nil ? (failure == nil ? "Generate Now" : "Try Again") : "Regenerate")
                Spacer()
                if generating { ProgressView() }
              }
              .frame(minHeight: 44)
            }
            .disabled(busy)
          } footer: {
            if generating {
              Text("Comparing with your finished articles…")
                .foregroundStyle(tokens.secondaryInk.color)
            }
          }.readerRowBackground()
        }
        if onDevice, readable { ask }
      }
      .readerFormBackground()
      .navigationTitle("Reading Context")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton { dismiss() } } }
    }
    .readerTheme()
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .onAppear { ai.hold(item.id) }
    .onDisappear {
      ai.release()
      asking?.cancel()
    }
    .onChange(of: ai.saved) { _, _ in
      if let saved = state.localReadingContext(current) { context = saved }
    }
    .task {
      // Show the device copy at once.
      ai.refreshAvailability()
      context = state.localReadingContext(current)
      failure = ai.failure(for: current)
      loading = context == nil && !onDevice && state.readingContextEnabled
      // On the device, writing is free and private, so a missing note is written now.
      if context == nil, onDevice, job == nil, failure == nil, readable {
        Task { await generate() }
      }
      // Entitled accounts: let the server say whether its note is out of date. A slow refresh must
      // not replace a note generated in this sheet meanwhile, and never replaces an on-device note.
      if state.readingContextEnabled, let fresh = await state.serverReadingContext(current),
        !busy, !generatedHere
      {
        context = fresh
      }
      loading = false
    }
  }

  private var emptyMessage: String {
    if onDevice {
      return readable
        ? "Not written yet. PageStash writes this on your iPhone, comparing the article with the ones you've marked Done."
        : "Download this article to write its reading context."
    }
    if state.readingContextEnabled {
      return item.kind == "brief"
        ? "Briefs aren't summarized automatically. Generate one to compare this brief with the articles you've marked Done."
        : "Not ready yet. PageStash usually writes this in the background soon after an article is saved, comparing it with the articles you've marked Done."
    }
    return ai.availability.message
  }

  private var privacy: String {
    onDevice || !state.readingContextEnabled
      ? "Apple Intelligence writes this on your iPhone from the article's text and the titles and openings of articles you've marked Done. Nothing is sent anywhere."
      : "The article's text, plus the titles, sites and opening lines of your finished articles, are sent to an AI provider through OpenRouter."
  }

  @ViewBuilder private func progress(_ job: LocalAI.Job) -> some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        Text(step(job.progress))
        ProgressView(value: job.progress?.fraction ?? 0)
          .accessibilityLabel("Writing reading context")
      }
      .padding(.vertical, 4)
      .accessibilityElement(children: .combine)
      Button("Cancel", role: .cancel) { ai.cancel(item.id) }.frame(minHeight: 44)
    } footer: {
      Text(
        context == nil
          ? "Writing on your iPhone. You can keep reading; it's saved when it's done."
          : "Writing a new version on your iPhone. You can keep reading.")
        .foregroundStyle(tokens.secondaryInk.color)
    }.readerRowBackground()
  }

  private func step(_ progress: LocalReadingContext.Progress?) -> String {
    switch progress?.step {
    case .reading(let part, let total)?: return "Reading part \(part) of \(total)…"
    case .relating?:
      return state.finishedCount(excluding: item.id) == 0
        ? "Writing the summary…" : "Comparing with your finished articles…"
    case nil: return "Getting ready…"
    }
  }

  @ViewBuilder private func result(_ context: ReadingContext) -> some View {
    Section {
      Text(context.summary)
    } header: {
      Text("Summary")
    } footer: {
      Text(footer(context)).foregroundStyle(tokens.secondaryInk.color)
    }.readerRowBackground()
    if let points = context.keyPoints, !points.isEmpty {
      Section("Key Points") {
        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
          Text(point)
        }
      }.readerRowBackground()
    }
    notes("Builds On", context.buildsOn)
    notes("Already Covered", context.covered)
    if !context.newIdeas.isEmpty {
      Section("New Here") {
        ForEach(Array(context.newIdeas.enumerated()), id: \.offset) { _, idea in
          Text(idea)
        }
      }.readerRowBackground()
    }
  }

  @ViewBuilder private func notes(_ title: String, _ notes: [ReadingContext.Note]) -> some View {
    // Articles deleted since the note was made drop out, with their titles and notes.
    let present = notes.filter { note in state.items.contains { $0.id == note.itemId } }
    if !present.isEmpty {
      Section(title) {
        ForEach(present) { note in
          VStack(alignment: .leading, spacing: 4) {
            Text(note.title).font(.headline)
            Text(note.note).font(.subheadline).foregroundStyle(tokens.secondaryInk.color)
          }
          .padding(.vertical, 2)
          .accessibilityElement(children: .combine)
        }
      }.readerRowBackground()
    }
  }

  private var ask: some View {
    Section {
      TextField("Ask a question about this article", text: $question)
        .submitLabel(.send)
        .focused($questionFocused)
        .onSubmit { startAsking() }
        .frame(minHeight: 44)
        .accessibilityLabel("Question about this article")
      Button {
        startAsking()
      } label: {
        HStack {
          Text(asking == nil ? "Ask" : "Answering…")
          Spacer()
          if asking != nil { ProgressView() }
        }
        .frame(minHeight: 44)
      }
      .disabled(
        question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || asking != nil || busy)
      if let answer, !answer.isEmpty {
        Text(answer)
          .textSelection(.enabled)
          .accessibilityLabel("Answer: \(answer)")
      }
      if let answerFailure {
        Label(answerFailure, systemImage: "exclamationmark.triangle")
          .foregroundStyle(tokens.warning.color)
      }
    } header: {
      Text("Ask About This Article")
    } footer: {
      Text(
        "Answers use only this article's text. They're AI-generated by Apple Intelligence on your iPhone and may be wrong. Nothing is sent anywhere."
      ).foregroundStyle(tokens.secondaryInk.color)
    }.readerRowBackground()
  }

  private func startAsking() {
    let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, asking == nil, !busy else { return }
    questionFocused = false
    answer = nil
    answerFailure = nil
    asking = Task {
      defer { asking = nil }
      do {
        for try await partial in ai.ask(text, about: current) { answer = partial }
        if let answer { UIAccessibility.post(notification: .announcement, argument: answer) }
      } catch is CancellationError {
      } catch {
        answerFailure = error.localizedDescription
      }
    }
  }

  private func footer(_ context: ReadingContext) -> String {
    var parts = ["AI-generated and may contain mistakes."]
    if context.isLocal {
      parts.append("Written on this iPhone by Apple Intelligence; nothing was sent anywhere.")
    }
    let count = context.historyCount
    parts.append(
      count == 0
        ? "You hadn't finished any articles yet."
        : "Compared with \(count) finished article\(count == 1 ? "" : "s")"
          + (generatedDate(context).map { ", \($0)." } ?? "."))
    if context.excerpted == true {
      parts.append("The article is long, so parts of it were summarized.")
    }
    if context.stale { parts.append("You've finished more since. Regenerate to include them.") }
    return parts.joined(separator: " ")
  }

  private func generatedDate(_ context: ReadingContext) -> String? {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard
      let date = parser.date(from: context.generatedAt)
        ?? ISO8601DateFormatter().date(from: context.generatedAt)
    else { return nil }
    return date.formatted(.relative(presentation: .named))
  }

  private func generate() async {
    failure = nil
    let local = onDevice
    // On-device progress shows in its own section; the spinner is for the server call.
    if !local { generating = true }
    defer { generating = false }
    do {
      let regenerate = context != nil
      context = try await state.generateReadingContext(current, regenerate: regenerate)
      generatedHere = true
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    } catch is CancellationError {
    } catch {
      switch (error as? URLError)?.code {
      case .timedOut?:
        failure = "This is taking longer than expected. Open Reading Context again in a moment."
      case .some:
        failure = "Generating needs an internet connection."
      case nil:
        failure = error.localizedDescription
      }
    }
  }
}
