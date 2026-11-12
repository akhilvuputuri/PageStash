import Foundation

/// Which downloads to remove when new articles need space under the storage limit. Pure, so it can
/// be tested without files or the network.
///
/// Only archived or finished articles give up their files, oldest saved first. The article open in
/// the reader and anything still downloading are never chosen. Removing files this way doesn't
/// pause the article's automatic download (see `LocalStore.evictDownload`), so an article moved
/// back to the Library unfinished downloads again.
public enum StorageEviction {
  /// Whether an article's download may be removed to make room: archived or finished, and not
  /// deleted. Articles in Trash follow the same rule.
  public static func isEvictable(_ item: ReadingItem) -> Bool {
    !item.deleted && (item.archived || item.progress >= 1)
  }
  /// Evictable articles with files on this device, oldest saved first (ties by ID, so the order is
  /// stable). `sizes` gives each article's bytes on disk; `protected` lists articles to keep,
  /// such as the one being read or ones still downloading.
  public static func candidates(
    _ items: [ReadingItem], sizes: [String: Int64], protected: Set<String> = []
  ) -> [ReadingItem] {
    items.filter {
      isEvictable($0) && !protected.contains($0.id) && (sizes[$0.id] ?? 0) > 0
    }.sorted {
      $0.capturedAt != $1.capturedAt ? $0.capturedAt < $1.capturedAt : $0.id < $1.id
    }
  }
  /// The fewest candidates, taken oldest first, that free at least `needed` bytes. When even all
  /// of them aren't enough, all of them: whatever is freed lets some new downloads fit. Empty when
  /// nothing is needed.
  public static func plan(
    _ items: [ReadingItem], sizes: [String: Int64], needed: Int64, protected: Set<String> = []
  ) -> [String] {
    guard needed > 0 else { return [] }
    var freed: Int64 = 0
    var chosen: [String] = []
    for item in candidates(items, sizes: sizes, protected: protected) {
      guard freed < needed else { break }
      chosen.append(item.id)
      freed += sizes[item.id] ?? 0
    }
    return chosen
  }
}
