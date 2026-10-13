import Foundation

/// What the Continue Reading widget shows. The app writes it to the shared App Group whenever the
/// article in progress changes; the widget only reads it, so it never touches the library store.
struct ContinueReading: Codable, Equatable {
  struct Article: Codable, Equatable {
    let id: String
    let title: String
    let source: String?
    let progress: Double
  }
  let article: Article?
  let updated: Date

  static let key = "continueReading"
  static let widgetKind = "ContinueReading"
  /// Deep link that opens an article in the reader.
  static func link(_ id: String) -> URL {
    var components = URLComponents()
    components.scheme = "offlinereader"
    components.host = "item"
    components.path = "/" + id
    return components.url!
  }
  /// The article id in a link made by `link(_:)`, or nil for any other URL.
  static func itemID(from url: URL) -> String? {
    guard url.scheme == "offlinereader", url.host == "item" else { return nil }
    let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return id.isEmpty || id.contains("/") ? nil : id
  }
  private static var shared: UserDefaults? {
    (Bundle.main.object(forInfoDictionaryKey: "ReaderAppGroup") as? String).flatMap {
      UserDefaults(suiteName: $0)
    }
  }
  static func load() -> ContinueReading? {
    guard let data = shared?.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(ContinueReading.self, from: data)
  }
  func save() {
    if let data = try? JSONEncoder().encode(self) { Self.shared?.set(data, forKey: Self.key) }
  }
}
