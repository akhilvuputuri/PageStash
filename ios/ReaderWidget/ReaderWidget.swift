import SwiftUI
import WidgetKit

struct ContinueReadingEntry: TimelineEntry {
  let date: Date
  let snapshot: ContinueReading?
}
struct ContinueReadingProvider: TimelineProvider {
  func placeholder(in context: Context) -> ContinueReadingEntry {
    ContinueReadingEntry(
      date: Date(),
      snapshot: ContinueReading(
        article: .init(
          id: "placeholder", title: "A calmer reading library", source: "example.com",
          progress: 0.4), updated: Date()))
  }
  func getSnapshot(in context: Context, completion: @escaping (ContinueReadingEntry) -> Void) {
    completion(
      context.isPreview
        ? placeholder(in: context) : ContinueReadingEntry(date: Date(), snapshot: .load()))
  }
  // The app reloads this timeline whenever the article in progress changes.
  func getTimeline(
    in context: Context, completion: @escaping (Timeline<ContinueReadingEntry>) -> Void
  ) {
    completion(
      Timeline(entries: [ContinueReadingEntry(date: Date(), snapshot: .load())], policy: .never))
  }
}
struct ContinueReadingView: View {
  @Environment(\.widgetFamily) private var family
  let entry: ContinueReadingEntry
  var body: some View {
    Group {
      if let article = entry.snapshot?.article {
        VStack(alignment: .leading, spacing: 4) {
          if family != .accessoryRectangular {
            Text("Continue Reading").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
          }
          // Titles can be private; the system redacts them on a locked device when configured.
          Text(article.title)
            .font(.system(family == .accessoryRectangular ? .headline : .title3, design: .serif))
            .lineLimit(family == .systemSmall ? 4 : 3).privacySensitive()
          if let source = article.source, family != .systemSmall {
            Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 0)
          ProgressView(value: article.progress)
            .accessibilityLabel("\(Int((article.progress * 100).rounded())) percent read")
          if family == .systemMedium, let updated = entry.snapshot?.updated {
            Text("Updated \(updated.formatted(.relative(presentation: .named)))")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
        .widgetURL(ContinueReading.link(article.id))
      } else {
        VStack(alignment: .leading, spacing: 4) {
          Text("Nothing in progress").font(.headline)
          Text("Open a saved article and it appears here.").font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .containerBackground(.fill.tertiary, for: .widget)
  }
}
struct ContinueReadingWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: ContinueReading.widgetKind, provider: ContinueReadingProvider()) {
      ContinueReadingView(entry: $0)
    }
    .configurationDisplayName("Continue Reading")
    .description("Pick up the article you were reading.")
    .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
  }
}
@main struct ReaderWidgetBundle: WidgetBundle {
  var body: some Widget { ContinueReadingWidget() }
}
