import ReaderCore
import SwiftUI

/// How the open article relates to articles already finished. AI-written, owner-gated by the server.
/// The server writes notes for articles in the background and they arrive with sync. Opening this
/// never generates; Generate Now and Regenerate are explicit.
struct ReadingContextSheet: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.themeTokens) private var tokens
  let item: ReadingItem
  @State private var context: ReadingContext?
  @State private var loading = true
  @State private var generating = false
  @State private var failure: String?
  @State private var generatedHere = false

  var body: some View {
    NavigationStack {
      List {
        if let context {
          result(context)
        } else if loading {
          Section {
            ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
          }
        } else {
          Section {
            Text(
              item.kind == "brief"
                ? "Briefs aren't summarized automatically. Generate one to compare this brief with the articles you've marked Done."
                : "Not ready yet. PageStash usually writes this in the background soon after an article is saved, comparing it with the articles you've marked Done."
            )
          } footer: {
            Text(
              "The article's text, plus the titles, sites and opening lines of your finished articles, are sent to an AI provider through OpenRouter."
            ).foregroundStyle(tokens.secondaryInk.color)
          }.readerRowBackground()
        }
        if let failure {
          Section {
            Label(failure, systemImage: "exclamationmark.triangle")
              .foregroundStyle(tokens.warning.color)
          }.readerRowBackground()
        }
        if !loading {
          Section {
            Button {
              Task { await generate() }
            } label: {
              HStack {
                Text(context == nil ? "Generate Now" : "Regenerate")
                Spacer()
                if generating { ProgressView() }
              }
            }
            .disabled(generating)
          } footer: {
            if generating {
              Text("Comparing with your finished articles…")
                .foregroundStyle(tokens.secondaryInk.color)
            }
          }.readerRowBackground()
        }
      }
      .readerFormBackground()
      .navigationTitle("Reading Context")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton { dismiss() } } }
    }
    .readerTheme()
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .task {
      // Show the device copy at once, then let the server say whether it's out of date.
      context = state.localReadingContext(item)
      loading = context == nil
      // A slow refresh must not replace a note generated in this sheet meanwhile.
      if let fresh = await state.serverReadingContext(item), !generating, !generatedHere {
        context = fresh
      }
      loading = false
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

  private func footer(_ context: ReadingContext) -> String {
    var parts = ["AI-generated and may contain mistakes."]
    let count = context.historyCount
    parts.append(
      count == 0
        ? "You hadn't finished any articles yet."
        : "Compared with \(count) finished article\(count == 1 ? "" : "s")"
          + (generatedDate(context).map { ", \($0)." } ?? "."))
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
    generating = true
    failure = nil
    defer { generating = false }
    do {
      let regenerate = context != nil
      context = try await state.generateReadingContext(item, regenerate: regenerate)
      generatedHere = true
      UINotificationFeedbackGenerator().notificationOccurred(.success)
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
