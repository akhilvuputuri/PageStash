import CSQLite
import Foundation

public final class LocalStore: @unchecked Sendable {
  private var db: OpaquePointer?
  private let lock = NSRecursiveLock()
  public let root: URL
  private let encoder = Wire.encoder(), decoder = Wire.decoder()
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  public init(root: URL) throws {
    self.root = root
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    guard sqlite3_open(root.appendingPathComponent("library.sqlite").path, &db) == SQLITE_OK else {
      throw ReaderError.database("Cannot open local library.")
    }
    sqlite3_busy_timeout(db, 5000)
    try execute("PRAGMA journal_mode=WAL")
    try execute(
      "CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY,json TEXT NOT NULL,installed INTEGER NOT NULL DEFAULT 0)"
    )
    try execute(
      "CREATE TABLE IF NOT EXISTS edits(id TEXT PRIMARY KEY,revision TEXT NOT NULL,json TEXT NOT NULL)"
    )
    try execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
    try execute("CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(id UNINDEXED,title,body)")
    try execute("CREATE TABLE IF NOT EXISTS lengths(id TEXT PRIMARY KEY,words INTEGER NOT NULL)")
    try execute(
      "CREATE TABLE IF NOT EXISTS verified(item TEXT,version INTEGER,asset TEXT,sha256 TEXT,size INTEGER,PRIMARY KEY(item,version,asset))"
    )
    try execute("CREATE TABLE IF NOT EXISTS contexts(item TEXT PRIMARY KEY,json TEXT NOT NULL)")
  }
  deinit { sqlite3_close(db) }
  private func synchronized<T>(_ action: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try action()
  }
  private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
    var s: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else {
      throw ReaderError.database("Local library query failed.")
    }
    for (index, value) in values.enumerated() {
      sqlite3_bind_text(s, Int32(index + 1), value, -1, transient)
    }
    return s
  }
  private func execute(_ sql: String, _ values: [String] = []) throws {
    let s = try statement(sql, values)
    defer { sqlite3_finalize(s) }
    let result = sqlite3_step(s)
    guard result == SQLITE_DONE || result == SQLITE_ROW else {
      throw ReaderError.database("Local library write failed.")
    }
  }
  private func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
    let s = try statement(sql, values)
    defer { sqlite3_finalize(s) }
    var result: [[String]] = []
    while true {
      let step = sqlite3_step(s)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else { throw ReaderError.database("Local library read failed.") }
      var row: [String] = []
      for i in 0..<sqlite3_column_count(s) {
        row.append(sqlite3_column_text(s, i).map { String(cString: $0) } ?? "")
      }
      result.append(row)
    }
    return result
  }
  public var cursor: Int64 {
    (try? synchronized {
      Int64(try rows("SELECT value FROM meta WHERE key='cursor'").first?.first ?? "0") ?? 0
    }) ?? 0
  }
  public func items() throws -> [ReadingItem] {
    try synchronized {
      try rows("SELECT json FROM items").map {
        try decoder.decode(ReadingItem.self, from: Data($0[0].utf8))
      }.filter { !$0.deleted }.sorted { $0.capturedAt > $1.capturedAt }
    }
  }
  public func item(_ id: String) throws -> ReadingItem? {
    try synchronized {
      guard let json = try rows("SELECT json FROM items WHERE id=?", [id]).first?.first else {
        return nil
      }
      return try decoder.decode(ReadingItem.self, from: Data(json.utf8))
    }
  }
  private func write(_ item: ReadingItem) throws {
    let json = String(decoding: try encoder.encode(item), as: UTF8.self)
    try execute(
      "INSERT INTO items(id,json) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
      [item.id, json])
  }
  public func apply(_ page: LibraryPage) throws {
    try synchronized {
      try execute("BEGIN IMMEDIATE")
      do {
        for var item in page.items {
          guard UUID(uuidString: item.id) != nil else { throw ReaderError.invalidAsset }
          if let edit = try rows("SELECT json FROM edits WHERE id=?", [item.id]).first?.first {
            item = try decoder.decode(ItemPatch.self, from: Data(edit.utf8)).applying(to: item)
          }
          if let context = item.readingContext {
            try storeSyncedContext(context, for: item)
            item.readingContext = nil
          }
          if let undo = try storedReadingUndo(), undo.itemId == item.id,
            item.deleted || !item.archived || item.progress != 1
          {
            try execute("DELETE FROM meta WHERE key='readingUndo'")
          }
          try write(item)
          try execute("DELETE FROM search WHERE id=?", [item.id])
          if !item.deleted {
            try execute(
              "INSERT INTO search(id,title,body) VALUES(?,?,?)",
              [item.id, item.title, try bodyForSearch(item.id)])
          }
        }
        try execute(
          "INSERT INTO meta(key,value) VALUES('cursor',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
          [String(page.cursor)])
        try execute("COMMIT")
      } catch {
        try? execute("ROLLBACK")
        throw error
      }
      // Delete files after committing tombstones. Late download callbacks check tombstones before writing.
      for item in page.items where item.deleted {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(item.id))
        try? execute("DELETE FROM lengths WHERE id=?", [item.id])
        try? execute("DELETE FROM contexts WHERE item=?", [item.id])
      }
    }
  }
  public func edit(_ id: String, _ patch: ItemPatch) throws {
    try synchronized {
      guard let current = try item(id), !current.deleted else { throw ReaderError.missingItem }
      var combined = patch
      if let json = try rows("SELECT json FROM edits WHERE id=?", [id]).first?.first {
        combined = try decoder.decode(ItemPatch.self, from: Data(json.utf8))
        combined.merge(patch)
      }
      try execute("BEGIN IMMEDIATE")
      do {
        if patch.progress != nil || patch.archived != nil || patch.deleted == true
          || patch.trashed == true,
          let undo = try storedReadingUndo(), undo.itemId == id
        {
          try execute("DELETE FROM meta WHERE key='readingUndo'")
        }
        try write(patch.applying(to: current))
        try execute(
          "INSERT INTO edits(id,revision,json) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,json=excluded.json",
          [id, UUID().uuidString, String(decoding: try encoder.encode(combined), as: UTF8.self)])
        try execute("COMMIT")
      } catch {
        try? execute("ROLLBACK")
        throw error
      }
      if patch.deleted == true {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
        try execute("DELETE FROM search WHERE id=?", [id])
        try execute("DELETE FROM lengths WHERE id=?", [id])
        try execute("DELETE FROM contexts WHERE item=?", [id])
      }
    }
  }
  /// The saved reading context for an item's current content, so it opens offline.
  public func readingContext(_ item: ReadingItem) throws -> ReadingContext? {
    try synchronized {
      guard let json = try rows("SELECT json FROM contexts WHERE item=?", [item.id]).first?.first
      else { return nil }
      let context = try decoder.decode(ReadingContext.self, from: Data(json.utf8))
      return context.contentVersion == item.contentVersion ? context : nil
    }
  }
  /// Keeps a synced note for the item's current content, unless this device has a newer one.
  private func storeSyncedContext(_ context: ReadingContext, for item: ReadingItem) throws {
    guard context.itemId == item.id, context.contentVersion == item.contentVersion, !item.deleted
    else { return }
    if let json = try rows("SELECT json FROM contexts WHERE item=?", [item.id]).first?.first,
      let local = try? decoder.decode(ReadingContext.self, from: Data(json.utf8)),
      local.contentVersion == context.contentVersion, local.generatedAt > context.generatedAt
    {
      return
    }
    try execute(
      "INSERT INTO contexts(item,json) VALUES(?,?) ON CONFLICT(item) DO UPDATE SET json=excluded.json",
      [item.id, String(decoding: try encoder.encode(context), as: UTF8.self)])
  }
  public func saveReadingContext(_ context: ReadingContext) throws {
    try synchronized {
      guard let current = try item(context.itemId), !current.deleted else {
        throw ReaderError.missingItem
      }
      try execute(
        "INSERT INTO contexts(item,json) VALUES(?,?) ON CONFLICT(item) DO UPDATE SET json=excluded.json",
        [context.itemId, String(decoding: try encoder.encode(context), as: UTF8.self)])
    }
  }
  /// Whether the server offers reading context to this account, remembered for offline use.
  public var readingContextEnabled: Bool {
    get {
      (try? synchronized {
        try rows("SELECT value FROM meta WHERE key='readingContext'").first?.first == "1"
      }) ?? false
    }
    set {
      try? synchronized {
        try execute(
          "INSERT INTO meta(key,value) VALUES('readingContext',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
          [newValue ? "1" : "0"])
      }
    }
  }
  private func storedReadingUndo() throws -> ReadingUndo? {
    guard let json = try rows("SELECT value FROM meta WHERE key='readingUndo'").first?.first else {
      return nil
    }
    return try decoder.decode(ReadingUndo.self, from: Data(json.utf8))
  }
  public func readingUndo() throws -> ReadingUndo? {
    try synchronized {
      guard let undo = try storedReadingUndo(), let current = try item(undo.itemId),
        !current.deleted, current.archived, current.progress == 1
      else { return nil }
      return undo
    }
  }
  public func dismissReadingUndo() throws {
    try synchronized { try execute("DELETE FROM meta WHERE key='readingUndo'") }
  }
  public func readingPosition(_ id: String) throws -> Double {
    try synchronized {
      if let saved = try rows("SELECT value FROM meta WHERE key=?", ["position:\(id)"]).first?
        .first,
        let value = Double(saved), value.isFinite
      {
        return min(1, max(0, value))
      }
      return try item(id)?.progress ?? 0
    }
  }
  public func recordReadingPosition(_ id: String, _ progress: Double) throws {
    try synchronized {
      guard progress.isFinite, let current = try item(id), !current.deleted else {
        throw ReaderError.missingItem
      }
      let value = min(1, max(0, progress))
      // Keep the server's established progress==1 read marker when revisiting a finished item.
      // The actual position remains device-local and survives archive, sync and app restart.
      if current.progress < 1 { try edit(id, ItemPatch(progress: value)) }
      try execute(
        "INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        ["position:\(id)", String(value)])
    }
  }
  @discardableResult public func finishReading(_ id: String) throws -> ReadingUndo? {
    try synchronized {
      guard let current = try item(id), !current.deleted else { throw ReaderError.missingItem }
      if current.archived && current.progress == 1 {
        return try readingUndo().flatMap { $0.itemId == id ? $0 : nil }
      }
      let undo = ReadingUndo(
        id: UUID().uuidString, itemId: id, previousProgress: current.progress,
        previousArchived: current.archived)
      var combined = ItemPatch(progress: 1, archived: true)
      if let json = try rows("SELECT json FROM edits WHERE id=?", [id]).first?.first {
        combined = try decoder.decode(ItemPatch.self, from: Data(json.utf8))
        combined.merge(ItemPatch(progress: 1, archived: true))
      }
      let position = try readingPosition(id)
      try execute("BEGIN IMMEDIATE")
      do {
        try write(ItemPatch(progress: 1, archived: true).applying(to: current))
        try execute(
          "INSERT INTO edits(id,revision,json) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,json=excluded.json",
          [id, UUID().uuidString, String(decoding: try encoder.encode(combined), as: UTF8.self)])
        try execute(
          "INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
          ["position:\(id)", String(position)])
        try execute(
          "INSERT INTO meta(key,value) VALUES('readingUndo',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
          [String(decoding: try encoder.encode(undo), as: UTF8.self)])
        try execute("COMMIT")
      } catch {
        try? execute("ROLLBACK")
        throw error
      }
      return undo
    }
  }
  @discardableResult public func undoReading(_ token: String) throws -> Bool {
    try synchronized {
      guard let undo = try readingUndo(), undo.id == token else { return false }
      // edit merges only completion/archive fields, preserving newer collection changes and position.
      try edit(
        undo.itemId, ItemPatch(progress: undo.previousProgress, archived: undo.previousArchived))
      return true
    }
  }
  public func pendingEdits() throws -> [PendingEdit] {
    try synchronized {
      try rows("SELECT id,revision,json FROM edits").map {
        PendingEdit(
          itemID: $0[0], revision: $0[1],
          patch: try decoder.decode(ItemPatch.self, from: Data($0[2].utf8)))
      }
    }
  }
  public func acknowledge(_ edit: PendingEdit) throws {
    try synchronized {
      try execute("DELETE FROM edits WHERE id=? AND revision=?", [edit.itemID, edit.revision])
    }
  }
  public func directory(_ id: String, version: Int) -> URL {
    root.appendingPathComponent(id).appendingPathComponent("v\(version)")
  }
  public func installedVersion(_ id: String) throws -> Int {
    try synchronized {
      Int(try rows("SELECT installed FROM items WHERE id=?", [id]).first?.first ?? "0") ?? 0
    }
  }
  public func readerURL(_ id: String) throws -> URL? {
    try synchronized {
      let version = try installedVersion(id)
      guard version > 0, let item = try item(id), !item.deleted else { return nil }
      let path = directory(id, version: version).appendingPathComponent("article.html")
      return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }
  }
  public func hasAsset(_ item: ReadingItem, _ asset: Asset) -> Bool {
    synchronized {
      guard asset.safeFilename else { return false }
      let path = directory(item.id, version: item.contentVersion).appendingPathComponent(
        asset.filename)
      guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size == asset.size
      else { return false }
      return
        (try? rows(
          "SELECT asset FROM verified WHERE item=? AND version=? AND asset=? AND sha256=? AND size=?",
          [item.id, String(item.contentVersion), asset.id, asset.sha256, String(asset.size)]
        ).isEmpty) == false
    }
  }
  public func accept(_ temporary: URL, itemID: String, version: Int, asset: Asset) throws {
    try synchronized {
      guard asset.safeFilename, let item = try item(itemID), !item.deleted, !isPaused(itemID),
        item.contentVersion == version,
        item.assets.contains(where: {
          $0.id == asset.id && $0.sha256 == asset.sha256 && $0.filename == asset.filename
            && $0.size == asset.size
        })
      else { throw ReaderError.invalidAsset }
      let values = try temporary.resourceValues(forKeys: [.fileSizeKey])
      guard values.fileSize == asset.size else { throw ReaderError.integrity }
      let bytes = try Data(contentsOf: temporary)
      guard digest(bytes) == asset.sha256 else { throw ReaderError.integrity }
      let dir = directory(itemID, version: version)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let target = dir.appendingPathComponent(asset.filename)
      try bytes.write(to: target, options: .atomic)
      try execute(
        "INSERT OR REPLACE INTO verified(item,version,asset,sha256,size) VALUES(?,?,?,?,?)",
        [itemID, String(version), asset.id, asset.sha256, String(asset.size)])
      // Text can be read even if images are still pending. Full readiness checks every manifest entry.
      if asset.role == "content" {
        try execute("UPDATE items SET installed=? WHERE id=?", [String(version), itemID])
        try execute("DELETE FROM search WHERE id=?", [itemID])
        let body = try bodyForSearch(itemID)
        try execute("INSERT INTO search(id,title,body) VALUES(?,?,?)", [itemID, item.title, body])
        try execute(
          "INSERT OR REPLACE INTO lengths(id,words) VALUES(?,?)",
          [itemID, String(Self.wordCount(body))])
      }
      if item.assets.allSatisfy({ hasAsset(item, $0) }) {
        // Keep the previous version through partial replacement, then reclaim its storage.
        let parent = root.appendingPathComponent(itemID)
        for older
          in (try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil)) ?? []
        where older.standardizedFileURL.path != dir.standardizedFileURL.path {
          try? FileManager.default.removeItem(at: older)
        }
        try execute("DELETE FROM verified WHERE item=? AND version<>?", [itemID, String(version)])
      }
    }
  }
  private func bodyForSearch(_ id: String) throws -> String {
    guard let path = try readerURL(id), let html = try? String(contentsOf: path, encoding: .utf8)
    else { return "" }
    return html.replacingOccurrences(
      of: "(?is)<head>.*?</head>", with: " ", options: .regularExpression
    )
    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
  }
  public func offlineState(_ item: ReadingItem) -> OfflineState {
    synchronized {
      let complete = item.assets.filter { hasAsset(item, $0) }
      if !item.assets.isEmpty && complete.count == item.assets.count {
        return item.error == nil ? .ready : .textOnly
      }
      if (try? readerURL(item.id)) != nil { return .textOnly }
      return complete.isEmpty ? .notDownloaded : .downloading
    }
  }
  /// Words in a downloaded article's text, for reading-time estimates. Counts are captured when
  /// content is installed; articles installed before counts existed are filled in from the search index.
  public func wordCounts() throws -> [String: Int] {
    try synchronized {
      let missing = try rows(
        "SELECT search.id,search.body FROM search LEFT JOIN lengths ON lengths.id=search.id WHERE lengths.id IS NULL AND search.body<>''"
      )
      if !missing.isEmpty {
        // One transaction for the one-time backfill after upgrading.
        try execute("BEGIN")
        do {
          for row in missing where row.count == 2 {
            try execute(
              "INSERT OR REPLACE INTO lengths(id,words) VALUES(?,?)",
              [row[0], String(Self.wordCount(row[1]))])
          }
          try execute("COMMIT")
        } catch {
          try? execute("ROLLBACK")
          throw error
        }
      }
      var counts: [String: Int] = [:]
      for row in try rows("SELECT id,words FROM lengths WHERE words>0") where row.count == 2 {
        counts[row[0]] = Int(row[1])
      }
      return counts
    }
  }
  public static func wordCount(_ text: String) -> Int {
    var count = 0
    text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) {
      _, _, _, _ in count += 1
    }
    return count
  }
  public func removeDownload(_ id: String) throws {
    try synchronized {
      try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
      try execute("UPDATE items SET installed=0 WHERE id=?", [id])
      try execute("DELETE FROM verified WHERE item=?", [id])
      try execute("DELETE FROM search WHERE id=?", [id])
      try execute("DELETE FROM lengths WHERE id=?", [id])
      if let item = try item(id) {
        try execute("INSERT INTO search(id,title,body) VALUES(?,?,'')", [id, item.title])
      }
      try execute(
        "INSERT INTO meta(key,value) VALUES(?, '1') ON CONFLICT(key) DO UPDATE SET value='1'",
        ["paused:\(id)"])
    }
  }
  public func resumeDownload(_ id: String) throws {
    try synchronized { try execute("DELETE FROM meta WHERE key=?", ["paused:\(id)"]) }
  }
  public func isPaused(_ id: String) -> Bool {
    (try? synchronized {
      !(try rows("SELECT value FROM meta WHERE key=?", ["paused:\(id)"])).isEmpty
    }) ?? false
  }
  public func search(_ query: String) throws -> Set<String> {
    try synchronized {
      let words = query.split(whereSeparator: { $0.isWhitespace }).map {
        "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\""
      }
      guard !words.isEmpty else { return [] }
      return Set(
        try rows("SELECT id FROM search WHERE search MATCH ?", [words.joined(separator: " AND ")])
          .map { $0[0] })
    }
  }
  public var diskUsage: Int64 {
    synchronized {
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.fileSizeKey])
      var total: Int64 = 0
      while let url = enumerator?.nextObject() as? URL {
        total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
      }
      return total
    }
  }
}
