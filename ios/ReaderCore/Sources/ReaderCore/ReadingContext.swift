import Foundation

/// An AI-written note relating one article to articles the reader has finished. Gated by the server.
public struct ReadingContext: Codable, Equatable, Sendable {
  public struct Note: Codable, Equatable, Sendable, Identifiable {
    public let itemId: String
    public let title: String
    public let note: String
    public var id: String { itemId }
    public init(itemId: String, title: String, note: String) {
      self.itemId = itemId
      self.title = title
      self.note = note
    }
  }
  public let itemId: String
  public let contentVersion: Int
  public let generatedAt: String
  public let model: String
  /// How many finished articles it was compared with.
  public let historyCount: Int
  /// The finished articles changed after it was generated.
  public let stale: Bool
  public let summary: String
  public let buildsOn: [Note]
  public let covered: [Note]
  public let newIdeas: [String]
  public init(
    itemId: String, contentVersion: Int, generatedAt: String, model: String, historyCount: Int,
    stale: Bool = false, summary: String, buildsOn: [Note] = [], covered: [Note] = [],
    newIdeas: [String] = []
  ) {
    self.itemId = itemId
    self.contentVersion = contentVersion
    self.generatedAt = generatedAt
    self.model = model
    self.historyCount = historyCount
    self.stale = stale
    self.summary = summary
    self.buildsOn = buildsOn
    self.covered = covered
    self.newIdeas = newIdeas
  }
}
