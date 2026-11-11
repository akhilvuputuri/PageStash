import Foundation

/// Which saved articles the on-device Spotlight index must add, replace or drop, so a reload
/// touches only what changed instead of re-indexing the whole library. Pure, so it is unit tested;
/// the app applies a plan with Core Spotlight and records the result.
public enum SpotlightSync {
  /// Bumped when what is indexed per article changes; existing installs then re-index once.
  public static let version = "v3"
  /// Articles Spotlight shows: prepared and not in Trash (or deleted).
  public static func visible(_ items: [ReadingItem]) -> [ReadingItem] {
    items.filter { $0.hasPreparedContent && !$0.isTrashed && !$0.deleted }
  }
  /// A launch-independent digest of what is indexed for one article. The word count stands in for
  /// the text: it appears when the article downloads and changes with its content.
  public static func signature(_ item: ReadingItem, words: Int?) -> String {
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    let fields = [
      item.title, item.archived ? "1" : "0", item.siteName ?? "", item.author ?? "",
      item.sourceUrl ?? "", item.kind, String(item.contentVersion), String(words ?? 0),
    ]
    for byte in fields.joined(separator: "\u{1}").utf8 {
      value = (value ^ UInt64(byte)) &* 0x100_0000_01b3
    }
    return String(value, radix: 16)
  }
  public struct Plan: Equatable {
    /// Visible articles that are new or changed, with their new signatures.
    public var upsert: [String: String]
    /// Articles in the index that are no longer visible.
    public var remove: Set<String>
    public var isEmpty: Bool { upsert.isEmpty && remove.isEmpty }
  }
  /// Compares what should be indexed with what was recorded as indexed.
  public static func plan(_ current: [String: String], indexed: [String: String]) -> Plan {
    Plan(
      upsert: current.filter { indexed[$0.key] != $0.value },
      remove: Set(indexed.keys).subtracting(current.keys))
  }
  /// The record to save before writing a plan (write-ahead): its articles under an empty
  /// signature, so if the app is killed while Spotlight finishes the write, a later run still knows
  /// they may be indexed and removes them (and their donations) once they leave the library.
  public static func pending(_ plan: Plan, onto indexed: [String: String]) -> [String: String] {
    record(plan, onto: indexed, upserted: false, removed: false)
  }
  /// The record after applying a plan. A failed write may have left the index part-way, so its
  /// articles stay recorded under an empty signature: still present ones are retried, and ones
  /// that disappear later are still removed.
  public static func record(
    _ plan: Plan, onto indexed: [String: String], upserted: Bool, removed: Bool
  ) -> [String: String] {
    var next = indexed
    for (id, signature) in plan.upsert { next[id] = upserted ? signature : "" }
    if removed { for id in plan.remove { next[id] = nil } }
    return next
  }
  /// One indexing run at a time. A request during a run is remembered and served by one more run,
  /// which reads the newest library, so an older run can never add back an article that a newer
  /// state removed.
  public struct Gate: Equatable {
    public private(set) var running = false
    public private(set) var pending = false
    public init() {}
    /// True when the caller should start a run now.
    public mutating func request() -> Bool {
      if running {
        pending = true
        return false
      }
      running = true
      return true
    }
    /// True when the caller should run again for a request that arrived meanwhile.
    public mutating func finish() -> Bool {
      if pending {
        pending = false
        return true
      }
      running = false
      return false
    }
    /// Sign-out: forget a queued run; a run in flight stops at its next generation check.
    public mutating func reset() { pending = false }
  }
}
