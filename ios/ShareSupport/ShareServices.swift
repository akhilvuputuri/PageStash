import Foundation
import ReaderCore
import Security

struct ShareCredentials: Codable, Sendable, CustomStringConvertible {
  let session: Session
  let account: ShareAccount
  var description: String { "Reader sharing credentials (redacted)" }
}
enum ShareContainer {
  static var identifier: String {
    Bundle.main.object(forInfoDictionaryKey: "ReaderAppGroup") as? String
      ?? "group.com.akhilvuputuri.offlinereader"
  }
  static func store() throws -> SharedSaveStore {
    guard
      let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    else { throw ShareError.unavailable }
    return try SharedSaveStore(root: root.appendingPathComponent("SharedSaves", isDirectory: true))
  }
  static func server(_ raw: String) throws -> URL {
    guard let parts = URLComponents(string: raw), parts.scheme == "https",
      parts.host?.isEmpty == false,
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
      parts.port == nil || parts.port == 443, let url = parts.url
    else {
      throw APIError(
        message: "Use an HTTPS Reader destination without credentials, query or fragment.")
    }
    return url
  }
}
enum ShareVault {
  private static var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "OfflineReader.shared-session",
      kSecAttrAccount as String: "current",
      kSecAttrAccessGroup as String: ShareContainer.identifier,
    ]
  }
  static func load() -> ShareCredentials? {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return try? JSONDecoder().decode(ShareCredentials.self, from: data)
  }
  static func save(_ credentials: ShareCredentials) throws {
    let bytes = try JSONEncoder().encode(credentials)
    let attributes: [String: Any] = [
      kSecValueData as String: bytes,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updated == errSecItemNotFound {
      var item = query
      for (key, value) in attributes { item[key] = value }
      guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
        throw ShareError.unavailable
      }
    } else if updated != errSecSuccess {
      throw ShareError.unavailable
    }
  }
  static func clear() { SecItemDelete(query as CFDictionary) }
}
@MainActor enum ShareServices {
  static func activate(_ session: Session, server: String) throws -> SharedSaveStore {
    let url = try ShareContainer.server(server)
    // A credential rotation changes the sharing generation independently of its cache directory.
    let account = ShareAccount(
      owner: session.ownerId, generation: digest(Data(session.token.utf8)), server: url)
    let store = try ShareContainer.store()
    try store.activate(account)
    try ShareVault.save(ShareCredentials(session: session, account: account))
    return store
  }
  static func deactivate() {
    try? ShareContainer.store().deactivate()
    ShareVault.clear()
  }
  static func deliver(
    _ store: SharedSaveStore, credentials: ShareCredentials, id: String? = nil,
    snapshot: () -> ShareCredentials? = ShareVault.load,
    submit: ((URL, String) async throws -> SaveResponse)? = nil
  ) async throws {
    guard snapshot()?.account == credentials.account else { throw ShareError.changedAccount }
    guard let claimed = try store.claim(credentials.account, id: id) else { return }
    do {
      guard snapshot()?.account == credentials.account else {
        throw ShareError.changedAccount
      }
      let response: SaveResponse
      if let submit {
        response = try await submit(claimed.url, claimed.id)
      } else {
        response = try await API(base: credentials.account.server, token: credentials.session.token)
          .save(url: claimed.url.absoluteString, key: claimed.id, timeout: 8)
      }
      guard snapshot()?.account == credentials.account else { throw ShareError.changedAccount }
      try store.finish(
        claimed, state: .accepted, submissionId: response.submissionId,
        serverStatus: response.status)
    } catch let error as APIError {
      let state: SharedSaveState
      if [401, 403].contains(error.status ?? 0) {
        state = .authenticationRequired
      } else if let status = error.status, (300..<500).contains(status),
        ![408, 429].contains(status)
      {
        state = .rejected
      } else {
        state = .queued
      }
      try store.finish(claimed, state: state, error: error.message)
    } catch is ShareError {
      try store.finish(
        claimed, state: .authenticationRequired,
        error: ShareError.changedAccount.localizedDescription)
    } catch {
      // Timeout can follow a committed write. Keep the same operation key for retry.
      try store.finish(
        claimed, state: .queued,
        error: "Queued on this device. Open Offline Reader when online to submit.")
    }
  }
}
