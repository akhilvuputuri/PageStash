import ReaderCore
import SwiftUI

/// How the open article relates to articles already finished. AI-written, owner-gated by the server.
/// Opening it shows a saved context only; generating is always an explicit tap because it costs money.
struct ReadingContextSheet: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.themeTokens) private var tokens
  let item: ReadingItem
  @State private var context: ReadingContext?
  @State private var loading = true
  @State private var generating = false
  @State private var failure: String?

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
              "Summarizes this article against the articles you've marked Done, so you can see what it builds on and what you've already read."
            )
          } footer: {
            Text(
              "The article's text and the titles of your finished articles are sent to an AI provider."
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
                Text(context == nil ? "Generate Summary" : "Regenerate")
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
      context = await state.savedReadingContext(item)
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
    if !notes.isEmpty {
      Section(title) {
        ForEach(notes) { note in
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
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    } catch {
      failure =
        (error as? URLError) != nil
        ? "Generating needs an internet connection."
        : error.localizedDescription
    }
  }
}
