import CryptoKit
import Foundation

public struct Asset: Codable, Hashable, Sendable {
  public let id: String
  public let role: String
  public let mime: String
  public let size: Int
  public let sha256: String
  public let filename: String
  public let url: URL
  public init(
    id: String, role: String, mime: String, size: Int, sha256: String, filename: String, url: URL
  ) {
    self.id = id
    self.role = role
    self.mime = mime
    self.size = size
    self.sha256 = sha256
    self.filename = filename
    self.url = url
  }
  public var safeFilename: Bool {
    UUID(uuidString: id) != nil
      && ((role == "content" && filename == "article.html")
        || (role == "image" && filename == "\(id).webp"))
      && size > 0 && size <= 30_000_000
  }
}
public struct ReadingItem: Codable, Identifiable, Sendable {
  public let id: String
  public var title: String
  public let kind: String
  public var status: String
  public var error: String?
  public let sourceUrl: String?
  public let author: String?
  /// The publisher's name when the server captured one (`og:site_name`); older servers omit it.
  public let siteName: String?
  public let sources: [String]
  public let capturedAt: String
  public let contentVersion: Int
  public var progress: Double
  public var collections: [String]
  public var archived: Bool
  public var deleted: Bool
  /// When the item was moved to Trash (ISO 8601), or nil. Trashed items stay restorable and their
  /// downloads stay on the device until they are deleted permanently or purged after 30 days.
  public var trashedAt: String?
  public var isTrashed: Bool { trashedAt != nil }
  public let revision: Int64
  public let assets: [Asset]
  /// The server's saved reading context, sent with the item for entitled owners. The local store
  /// moves it into its own table on sync, so stored items don't carry it. A note this build can't
  /// decode is dropped rather than failing the whole library page.
  public var syncedContext: ReadingContext? {
    get { readingContext?.value }
    set { readingContext = newValue.map { Lenient(value: $0) } }
  }
  /// Stored under the wire name `reading_context`.
  var readingContext: Lenient<ReadingContext>?
  public var hasPreparedContent: Bool {
    status == "ready"
      || (contentVersion > 0 && assets.contains { $0.role == "content" && $0.safeFilename })
  }
  public var needsImportReview: Bool { status != "ready" && !isTrashed }
  public init(
    id: String, title: String, kind: String = "article", status: String = "ready",
    error: String? = nil, sourceUrl: String? = nil, author: String? = nil,
    siteName: String? = nil, sources: [String] = [],
    capturedAt: String = "", contentVersion: Int = 1, progress: Double = 0,
    collections: [String] = [], archived: Bool = false, deleted: Bool = false,
    trashedAt: String? = nil, revision: Int64 = 1, readingContext: ReadingContext? = nil,
    assets: [Asset]
  ) {
    self.id = id
    self.title = title
    self.kind = kind
    self.status = status
    self.error = error
    self.sourceUrl = sourceUrl
    self.author = author
    self.siteName = siteName
    self.sources = sources
    self.capturedAt = capturedAt
    self.contentVersion = contentVersion
    self.progress = progress
    self.collections = collections
    self.archived = archived
    self.deleted = deleted
    self.trashedAt = trashedAt
    self.revision = revision
    self.readingContext = readingContext.map { Lenient(value: $0) }
    self.assets = assets
  }
}
/// Decodes a value when it can and is nil otherwise, so an optional extra never breaks its container.
struct Lenient<Value: Codable & Sendable>: Codable, Sendable {
  var value: Value?
  init(value: Value?) { self.value = value }
  init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}
public struct LibraryPage: Codable, Sendable {
  public let items: [ReadingItem]
  public let cursor: Int64
  public let hasMore: Bool
  public init(items: [ReadingItem], cursor: Int64, hasMore: Bool = false) {
    self.items = items
    self.cursor = cursor
    self.hasMore = hasMore
  }
}
public struct ItemPatch: Codable, Sendable {
  public var progress: Double?
  public var archived: Bool?
  public var collections: [String]?
  public var deleted: Bool?
  /// Moves the item to Trash (true) or restores it (false).
  public var trashed: Bool?
  public init(
    progress: Double? = nil, archived: Bool? = nil, collections: [String]? = nil,
    deleted: Bool? = nil, trashed: Bool? = nil
  ) {
    self.progress = progress
    self.archived = archived
    self.collections = collections
    self.deleted = deleted
    self.trashed = trashed
  }
  public func applying(to item: ReadingItem) -> ReadingItem {
    var copy = item
    if let v = progress { copy.progress = v }
    if let v = archived { copy.archived = v }
    if let v = collections { copy.collections = v }
    if let v = deleted { copy.deleted = v }
    if let v = trashed {
      // Keep the first trash time, as the server does.
      copy.trashedAt = v ? (item.trashedAt ?? ISO8601DateFormatter().string(from: Date())) : nil
    }
    return copy
  }
  public mutating func merge(_ newer: ItemPatch) {
    if let v = newer.progress { progress = v }
    if let v = newer.archived { archived = v }
    if let v = newer.collections { collections = v }
    if let v = newer.deleted { deleted = v }
    if let v = newer.trashed { trashed = v }
  }
}
public struct PendingEdit: Sendable {
  public let itemID: String
  public let revision: String
  public let patch: ItemPatch
}
public struct ReadingUndo: Codable, Equatable, Sendable {
  public let id: String
  public let itemId: String
  public let previousProgress: Double
  public let previousArchived: Bool
}
public enum ReadingScrollPosition {
  public static func offset(
    progress: Double, contentHeight: Double, viewportHeight: Double, headerHeight: Double
  ) -> Double {
    let range = max(0, contentHeight - viewportHeight)
    let header = min(range, max(0, headerHeight))
    let value = min(1, max(0, progress.isFinite ? progress : 0))
    return value == 0 ? 0 : header + (range - header) * value
  }
  public static func progress(
    offset: Double, contentHeight: Double, viewportHeight: Double, headerHeight: Double
  ) -> Double {
    let range = max(0, contentHeight - viewportHeight)
    let header = min(range, max(0, headerHeight))
    guard range > header else { return 0 }
    return min(1, max(0, (offset - header) / (range - header)))
  }
}
public enum OfflineState: String, Sendable {
  case notDownloaded = "Not downloaded"
  case downloading = "Downloading"
  case textOnly = "Text available · images incomplete"
  case ready = "Available offline"
}
public enum ReaderError: Error, LocalizedError {
  case database(String)
  case invalidAsset, integrity, missingItem
  public var errorDescription: String? {
    switch self {
    case .database(let message): return message
    case .invalidAsset: return "Invalid download manifest."
    case .integrity: return "Download verification failed. Retry the download."
    case .missingItem: return "Article is unavailable."
    }
  }
}
public enum Wire {
  public static func decoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
  }
  public static func encoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.keyEncodingStrategy = .convertToSnakeCase
    return e
  }
}
public func digest(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
