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
  public let sources: [String]
  public let capturedAt: String
  public let contentVersion: Int
  public var progress: Double
  public var collections: [String]
  public var archived: Bool
  public var deleted: Bool
  public let revision: Int64
  public let assets: [Asset]
  public init(
    id: String, title: String, kind: String = "article", status: String = "ready",
    error: String? = nil, sourceUrl: String? = nil, author: String? = nil, sources: [String] = [],
    capturedAt: String = "", contentVersion: Int = 1, progress: Double = 0,
    collections: [String] = [], archived: Bool = false, deleted: Bool = false, revision: Int64 = 1,
    assets: [Asset]
  ) {
    self.id = id
    self.title = title
    self.kind = kind
    self.status = status
    self.error = error
    self.sourceUrl = sourceUrl
    self.author = author
    self.sources = sources
    self.capturedAt = capturedAt
    self.contentVersion = contentVersion
    self.progress = progress
    self.collections = collections
    self.archived = archived
    self.deleted = deleted
    self.revision = revision
    self.assets = assets
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
  public init(
    progress: Double? = nil, archived: Bool? = nil, collections: [String]? = nil,
    deleted: Bool? = nil
  ) {
    self.progress = progress
    self.archived = archived
    self.collections = collections
    self.deleted = deleted
  }
  public func applying(to item: ReadingItem) -> ReadingItem {
    var copy = item
    if let v = progress { copy.progress = v }
    if let v = archived { copy.archived = v }
    if let v = collections { copy.collections = v }
    if let v = deleted { copy.deleted = v }
    return copy
  }
  public mutating func merge(_ newer: ItemPatch) {
    if let v = newer.progress { progress = v }
    if let v = newer.archived { archived = v }
    if let v = newer.collections { collections = v }
    if let v = newer.deleted { deleted = v }
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
