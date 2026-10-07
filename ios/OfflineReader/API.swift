import Foundation
import ReaderCore

struct Session: Codable, Sendable {
  let token: String
  let ownerId: String
  var generation: String = UUID().uuidString
}
struct LoginResponse: Decodable {
  let token: String
  let ownerId: String
}
struct APIError: Error, LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
struct Failure: Decodable { let error: String }
struct OK: Decodable { let ok: Bool }
struct SaveResponse: Decodable {
  let submissionId: String?
  let status: String
  let duplicate: Bool
}
struct Connection: Decodable, Identifiable {
  let id: String
  let label: String
  let kind: String
  let expiresAt: String
}
struct Connections: Decodable { let connections: [Connection] }
struct NewConnection: Decodable {
  let token: String
  let id: String
  let connectionId: String
}

struct API: Sendable {
  let base: URL
  let token: String?
  func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws
    -> T
  {
    guard base.scheme == "https" || permitsLocalHTTP(base) else {
      throw APIError(message: "Use an HTTPS backend URL.")
    }
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
      throw APIError(message: "Invalid backend URL.")
    }
    let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    components.path = base.path + String(parts[0])
    components.query = parts.count > 1 ? String(parts[1]) : nil
    guard let url = components.url else { throw APIError(message: "Invalid request URL.") }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = 20
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode)
    else {
      throw APIError(
        message: (try? JSONDecoder().decode(Failure.self, from: data).error)
          ?? "The server could not complete this request.")
    }
    return try Wire.decoder().decode(T.self, from: data)
  }
  func login(email: String, password: String) async throws -> Session {
    let data = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
    let response: LoginResponse = try await request("/v1/session", method: "POST", body: data)
    return Session(token: response.token, ownerId: response.ownerId)
  }
  func library(cursor: Int64) async throws -> LibraryPage {
    try await request("/v1/library?cursor=\(cursor)")
  }
  func patch(_ id: String, _ patch: ItemPatch) async throws {
    let _: OK = try await request(
      "/v1/items/\(id)", method: "PATCH", body: Wire.encoder().encode(patch))
  }
  func save(url: String, key: String) async throws -> SaveResponse {
    try await request(
      "/v1/saves/link", method: "POST",
      body: JSONSerialization.data(withJSONObject: ["url": url, "idempotency_key": key]))
  }
}
private func permitsLocalHTTP(_ url: URL) -> Bool {
  #if DEBUG
    return url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
  #else
    return false
  #endif
}
