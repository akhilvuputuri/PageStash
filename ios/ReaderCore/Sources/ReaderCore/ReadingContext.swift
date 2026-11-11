import Foundation

/// An AI-written note relating one article to articles the reader has finished. Written either on
/// this iPhone by Apple's on-device model (any account) or by the server for entitled accounts and
/// synced. The optional fields exist only on notes written on the device; server notes omit them.
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
  /// The `model` label of notes written by Apple's on-device model.
  public static let onDeviceModel = "apple-on-device"
  /// The `model` label of notes written by Apple's Private Cloud Compute model, at the reader's
  /// request, for long articles. Still an app-written note (`isLocal`), stored only on this device.
  public static let privateCloudModel = "apple-private-cloud"
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
  /// The article's main points, independent of reading history. Device notes only.
  public let keyPoints: [String]?
  /// How many articles were marked Done when it was written, so a device note knows when it's
  /// stale. The prompt may list fewer (`historyCount`) because the local context window is small.
  public let historyTotal: Int?
  /// A long article was summarized from evenly spaced sections rather than all of its text.
  public let excerpted: Bool?
  /// Set when Apple's Private Cloud Compute was tried first and the note was then written on this
  /// iPhone, with why (`limitReached`, `offline` or `failed`). The cloud request may have gone
  /// out, so the note must not claim nothing was sent. Device notes only; optional, so older notes
  /// and server notes still decode.
  public let cloudFallback: String?
  public init(
    itemId: String, contentVersion: Int, generatedAt: String, model: String, historyCount: Int,
    stale: Bool = false, summary: String, buildsOn: [Note] = [], covered: [Note] = [],
    newIdeas: [String] = [], keyPoints: [String]? = nil, historyTotal: Int? = nil,
    excerpted: Bool? = nil, cloudFallback: String? = nil
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
    self.keyPoints = keyPoints
    self.historyTotal = historyTotal
    self.excerpted = excerpted
    self.cloudFallback = cloudFallback
  }
  /// Written by the app with an Apple model provider (on this iPhone or, for long articles when
  /// allowed, Apple's Private Cloud Compute) rather than synced from the server.
  public var isLocal: Bool { model.hasPrefix("apple-") }
  /// Written by Apple's Private Cloud Compute model rather than on this iPhone.
  public var isPrivateCloud: Bool { model == Self.privateCloudModel }
  /// A device note goes stale when the number of finished articles changes. Server notes carry the
  /// server's own judgement in `stale`.
  public func stale(finishedCount: Int) -> Bool {
    guard isLocal else { return stale }
    return stale || (historyTotal.map { $0 != finishedCount } ?? false)
  }
  public func with(stale: Bool) -> ReadingContext {
    ReadingContext(
      itemId: itemId, contentVersion: contentVersion, generatedAt: generatedAt, model: model,
      historyCount: historyCount, stale: stale, summary: summary, buildsOn: buildsOn,
      covered: covered, newIdeas: newIdeas, keyPoints: keyPoints, historyTotal: historyTotal,
      excerpted: excerpted, cloudFallback: cloudFallback)
  }
  public func with(cloudFallback: String?) -> ReadingContext {
    ReadingContext(
      itemId: itemId, contentVersion: contentVersion, generatedAt: generatedAt, model: model,
      historyCount: historyCount, stale: stale, summary: summary, buildsOn: buildsOn,
      covered: covered, newIdeas: newIdeas, keyPoints: keyPoints, historyTotal: historyTotal,
      excerpted: excerpted, cloudFallback: cloudFallback)
  }
  /// The `cloudFallback` code for a Private Cloud Compute failure.
  public static func cloudFallbackCode(_ error: LocalModelError) -> String {
    switch error {
    case .limitReached: return "limitReached"
    case .offline: return "offline"
    default: return "failed"
    }
  }
  /// Why a note meant for the private cloud was written on this iPhone, in words.
  public var cloudFallbackNotice: String? {
    switch cloudFallback {
    case nil: return nil
    case "limitReached"?:
      return
        "Today's Apple Private Cloud Compute limit was used up, so this was written on your iPhone, in parts."
    case "offline"?:
      return
        "Apple's Private Cloud Compute couldn't be reached, so this was written on your iPhone, in parts."
    default:
      return
        "Apple's Private Cloud Compute couldn't write this, so it was written on your iPhone, in parts."
    }
  }
  /// Whether a stored note should stay when a server copy arrives (by sync or refresh). On-device
  /// notes are primary: one for the same content is never replaced by a server note, whatever its
  /// time, because the device can regenerate it for free. Otherwise the newer note wins. An
  /// explicit generation on the phone always saves.
  public static func keepsStored(_ stored: ReadingContext, over server: ReadingContext) -> Bool {
    guard stored.contentVersion == server.contentVersion else { return false }
    return stored.isLocal || stored.generatedAt > server.generatedAt
  }
}
