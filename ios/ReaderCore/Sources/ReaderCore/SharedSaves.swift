import CSQLite
import Foundation

public struct ShareAccount: Codable, Hashable, Sendable {
  public let owner: String
  public let generation: String
  public let server: URL
  public init(owner: String, generation: String, server: URL) {
    self.owner = owner
    self.generation = generation
    self.server = server
  }
  public func sameDestination(as other: ShareAccount) -> Bool {
    owner == other.owner && server == other.server
  }
}
public enum SharedSaveState: String, Codable, Sendable {
  case queued, sending, authenticationRequired, rejected, accepted
}
public struct SharedSave: Codable, Identifiable, Sendable {
  public let id: String
  public var account: ShareAccount
  public let url: URL
  public var state: SharedSaveState = .queued
  public var error: String?
  public var submissionId: String?
  public var serverStatus: String?
  public var claim: String?
  public var leaseUntil: Double = 0
  public init(id: String, account: ShareAccount, url: URL) {
    self.id = id
    self.account = account
    self.url = url
  }
}
public enum ShareError: Error, LocalizedError {
  case invalidURL, unavailable, changedAccount, authenticationRequired
  public var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "Share a valid HTTP(S) webpage link without credentials or nonstandard ports."
    case .unavailable: return "Browser sharing isn't configured for this build."
    case .changedAccount:
      return "The sign-in or destination changed. Share again with the current account."
    case .authenticationRequired:
      return "Sign in again in PageStash before sending shared links."
    }
  }
}
public enum SharedLink {
  public static func validate(_ raw: String) throws -> URL {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.utf16.count <= 2048, value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      var parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
      parts.port == nil || [80, 443].contains(parts.port!)
    else { throw ShareError.invalidURL }
    parts.scheme = scheme
    parts.fragment = nil
    parts.queryItems = parts.queryItems?.filter {
      !$0.name.lowercased().hasPrefix("utm_") && !["fbclid", "gclid"].contains($0.name)
    }
    if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
    guard let url = parts.url, url.absoluteString.utf16.count <= 2048 else {
      throw ShareError.invalidURL
    }
    return url
  }
  public static func candidates(urls: [String], texts: [String]) -> [URL] {
    // Strong URL representations take precedence over accompanying titles/text.
    let strong = Set(urls.compactMap { try? validate($0) })
    if !urls.isEmpty { return strong.sorted { $0.absoluteString < $1.absoluteString } }
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return [] }
    let found = texts.filter { $0.utf16.count <= 8192 }.flatMap { text in
      detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
        match.url.flatMap { try? validate($0.absoluteString) }
      }
    }
    return Array(Set(found)).sorted { $0.absoluteString < $1.absoluteString }
  }
}

// SQLite transactions coordinate app and extension processes. No token is stored here.
public final class SharedSaveStore: @unchecked Sendable {
  private var db: OpaquePointer?
  private let lock = NSRecursiveLock()
  private let encoder = JSONEncoder(), decoder = JSONDecoder()
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  public init(root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: root.path)
    #endif
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var protected = root
    try protected.setResourceValues(values)
    guard sqlite3_open(root.appendingPathComponent("shared-saves.sqlite").path, &db) == SQLITE_OK
    else { throw ShareError.unavailable }
    sqlite3_busy_timeout(db, 5000)
    try execute("PRAGMA journal_mode=WAL")
    try execute("PRAGMA synchronous=FULL")
    try execute(
      "CREATE TABLE IF NOT EXISTS context(id INTEGER PRIMARY KEY CHECK(id=1),json TEXT NOT NULL,blocked INTEGER NOT NULL DEFAULT 0)"
    )
    try execute("CREATE TABLE IF NOT EXISTS shares(id TEXT PRIMARY KEY,json TEXT NOT NULL)")
  }
  deinit { sqlite3_close(db) }
  private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
    var result: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else {
      throw ShareError.unavailable
    }
    for (index, value) in values.enumerated() {
      sqlite3_bind_text(result, Int32(index + 1), value, -1, transient)
    }
    return result
  }
  private func execute(_ sql: String, _ values: [String] = []) throws {
    let s = try statement(sql, values)
    defer { sqlite3_finalize(s) }
    let code = sqlite3_step(s)
    guard code == SQLITE_DONE || code == SQLITE_ROW else { throw ShareError.unavailable }
  }
  private func rows(_ sql: String, _ values: [String] = []) throws -> [String] {
    let s = try statement(sql, values)
    defer { sqlite3_finalize(s) }
    var result: [String] = []
    while true {
      let code = sqlite3_step(s)
      if code == SQLITE_DONE { return result }
      guard code == SQLITE_ROW, let text = sqlite3_column_text(s, 0) else {
        throw ShareError.unavailable
      }
      result.append(String(cString: text))
    }
  }
  private func transaction<T>(_ body: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    try execute("BEGIN IMMEDIATE")
    do {
      let value = try body()
      try execute("COMMIT")
      return value
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }
  private func current() throws -> ShareAccount? {
    guard let json = try rows("SELECT json FROM context WHERE id=1").first else { return nil }
    return try decoder.decode(ShareAccount.self, from: Data(json.utf8))
  }
  private func check(_ account: ShareAccount) throws {
    guard try current() == account else { throw ShareError.changedAccount }
    if try rows("SELECT blocked FROM context WHERE id=1").first == "1" {
      throw ShareError.authenticationRequired
    }
  }
  private func all() throws -> [SharedSave] {
    try rows("SELECT json FROM shares ORDER BY rowid").map {
      try decoder.decode(SharedSave.self, from: Data($0.utf8))
    }
  }
  private func write(_ item: SharedSave) throws {
    try execute(
      "INSERT INTO shares(id,json) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
      [item.id, String(decoding: try encoder.encode(item), as: UTF8.self)])
  }
  public func activate(_ account: ShareAccount) throws {
    try transaction {
      if try current() == account { return }
      for var item in try all() {
        if !item.account.sameDestination(as: account) {
          try execute("DELETE FROM shares WHERE id=?", [item.id])
          continue
        }
        if item.state != .accepted {
          item.state = .authenticationRequired
          item.error = "Sign-in changed. Tap Retry to send with this account."
          item.claim = nil
          item.leaseUntil = 0
          try write(item)
        }
      }
      try execute(
        "INSERT INTO context(id,json,blocked) VALUES(1,?,0) ON CONFLICT(id) DO UPDATE SET json=excluded.json,blocked=0",
        [String(decoding: try encoder.encode(account), as: UTF8.self)])
    }
  }
  public func deactivate() throws {
    try transaction {
      try execute("DELETE FROM context")
      try execute("DELETE FROM shares")
    }
  }
  public func records(_ account: ShareAccount) throws -> [SharedSave] {
    try transaction {
      guard try current() == account else { throw ShareError.changedAccount }
      return try all().filter { $0.account.sameDestination(as: account) }
    }
  }
  @discardableResult public func enqueue(_ url: URL, id: String, account: ShareAccount) throws
    -> SharedSave
  {
    try transaction {
      try check(account)
      let normalized = try SharedLink.validate(url.absoluteString)
      if let existing = try all().first(where: { $0.id == id }) {
        guard existing.account == account && existing.url == normalized else {
          throw ShareError.changedAccount
        }
        return existing
      }
      guard UUID(uuidString: id) != nil else { throw ShareError.invalidURL }
      let item = SharedSave(id: id, account: account, url: normalized)
      try write(item)
      return item
    }
  }
  public func claim(_ account: ShareAccount, now: Date = Date(), id: String? = nil) throws
    -> SharedSave?
  {
    try transaction {
      try check(account)
      guard
        var item = try all().first(where: {
          $0.account == account && (id == nil || $0.id == id)
            && ($0.state == .queued
              || ($0.state == .sending && $0.leaseUntil < now.timeIntervalSince1970))
        })
      else { return nil }
      item.state = .sending
      item.claim = UUID().uuidString
      item.leaseUntil = now.timeIntervalSince1970 + 120
      item.error = nil
      try write(item)
      return item
    }
  }
  public func finish(
    _ claimed: SharedSave, state: SharedSaveState, error: String? = nil,
    submissionId: String? = nil, serverStatus: String? = nil
  ) throws {
    try transaction {
      guard let claim = claimed.claim, try current() == claimed.account,
        var item = try all().first(where: { $0.id == claimed.id }), item.claim == claim,
        item.state == .sending
      else { return }
      item.state = state
      item.error = error.map { String($0.prefix(240)) }
      item.submissionId = submissionId
      item.serverStatus = serverStatus
      item.claim = nil
      item.leaseUntil = 0
      try write(item)
      if state == .authenticationRequired {
        try execute("UPDATE context SET blocked=1 WHERE id=1")
        for var other in try all()
        where other.account == claimed.account && [.queued, .sending].contains(other.state) {
          other.state = .authenticationRequired
          other.error = ShareError.authenticationRequired.localizedDescription
          other.claim = nil
          try write(other)
        }
      }
    }
  }
  public func retry(_ id: String, account: ShareAccount) throws {
    try transaction {
      try check(account)
      guard
        var item = try all().first(where: { $0.id == id && $0.account.sameDestination(as: account) }
        ), item.state != .accepted, item.state != .sending
      else { throw ShareError.changedAccount }
      item.account = account
      item.state = .queued
      item.error = nil
      item.claim = nil
      item.leaseUntil = 0
      try write(item)
    }
  }
  public func remove(_ id: String, account: ShareAccount) throws {
    try transaction {
      guard try current() == account else { throw ShareError.changedAccount }
      try execute("DELETE FROM shares WHERE id=?", [id])
    }
  }
  public func acknowledge(_ ids: Set<String>, account: ShareAccount) throws {
    try transaction {
      guard try current() == account else { return }
      for item in try all()
      where item.state == .accepted && item.submissionId.map(ids.contains) == true {
        try execute("DELETE FROM shares WHERE id=?", [item.id])
      }
    }
  }
}
