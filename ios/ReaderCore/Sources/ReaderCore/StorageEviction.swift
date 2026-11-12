import Foundation

/// Which downloads to remove when new articles need space under the storage limit. Pure, so it can
/// be tested without files or the network.
///
/// Articles in Trash give up their files first (longest in Trash first), then archived or finished
/// articles, oldest saved first. The article open in the reader, anything still downloading,
/// anything being downloaded in the same pass, articles the reader downloaded by hand
/// (`LocalStore.pinDownload`) and articles behind a visible Undo are never chosen. Removing files
/// this way doesn't pause the article's automatic download (see `LocalStore.evictDownload`), so an
/// article moved back to the Library unfinished downloads again.
public enum StorageEviction {
  /// Whether an article's download may be removed to make room: in Trash, archived or finished,
  /// and not deleted.
  public static func isEvictable(_ item: ReadingItem) -> Bool {
    !item.deleted && (item.isTrashed || item.archived || item.progress >= 1)
  }
  /// Evictable articles with files on this device, in removal order: Trash first (by time moved
  /// to Trash), then oldest saved first; ties by ID, so the order is stable. `sizes` gives each
  /// article's bytes on disk; `protected` lists articles to keep.
  public static func candidates(
    _ items: [ReadingItem], sizes: [String: Int64], protected: Set<String> = []
  ) -> [ReadingItem] {
    items.filter {
      isEvictable($0) && !protected.contains($0.id) && (sizes[$0.id] ?? 0) > 0
    }.sorted { a, b in
      if a.isTrashed != b.isTrashed { return a.isTrashed }
      if a.isTrashed, a.trashedAt != b.trashedAt { return (a.trashedAt ?? "") < (b.trashedAt ?? "") }
      if a.capturedAt != b.capturedAt { return a.capturedAt < b.capturedAt }
      return a.id < b.id
    }
  }
  /// One file a pending download needs: its article and size in bytes.
  public struct Need: Equatable, Sendable {
    public let itemID: String
    public let size: Int64
    public init(itemID: String, size: Int64) {
      self.itemID = itemID
      self.size = size
    }
  }
  /// The downloads to remove so that files in `wanted` fit, in the order they will be queued.
  ///
  /// It replays the queue: each file that fits in the space left takes it; a file that doesn't
  /// fit takes just enough candidates, in removal order, to fit, and only if the remaining
  /// candidates can free that much. A file that can't fit even then is skipped without removing
  /// anything, so removal happens only when it lets a file be queued. `reserved` is the space
  /// already used or promised to transfers in flight. Articles in `wanted` and `protected` are
  /// never removed.
  public static func plan(
    _ items: [ReadingItem], sizes: [String: Int64], reserved: Int64, limit: Int64,
    wanted: [Need], protected: Set<String> = []
  ) -> [String] {
    var pool = candidates(
      items, sizes: sizes, protected: protected.union(wanted.map(\.itemID))
    ).map { (id: $0.id, size: sizes[$0.id] ?? 0) }
    var poolTotal = pool.reduce(Int64(0)) { $0 + $1.size }
    var free = limit - reserved
    var chosen: [String] = []
    for need in wanted where need.size > 0 {
      if need.size <= free {
        free -= need.size
        continue
      }
      guard free + poolTotal >= need.size else { continue }
      while free < need.size, !pool.isEmpty {
        let next = pool.removeFirst()
        chosen.append(next.id)
        free += next.size
        poolTotal -= next.size
      }
      free -= need.size
    }
    return chosen
  }
}
