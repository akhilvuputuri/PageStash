import Foundation
import ReaderCore

/// What the share sheet does once it has read the shared items.
enum ShareStart: Equatable {
  /// No saved session, or one the queue no longer accepts: ask the reader to open PageStash.
  case signIn
  /// Nothing PageStash can save was shared.
  case unreadable
  /// Several links: wait for the reader to choose one, then save it.
  case choose
  /// Exactly one link and a usable session: save it without asking.
  case save(URL)
}

/// The one status line the share sheet shows while and after saving.
struct ShareStatus: Equatable {
  enum Tone: Equatable { case progress, success, pending, problem }
  let text: String
  /// A short second line, only for problems the reader can act on.
  var detail: String?
  let symbol: String
  let tone: Tone
  var canRetry = false
  /// Close the sheet on its own after showing this.
  var dismisses = false
  /// What VoiceOver announces.
  var announcement: String { [text, detail].compactMap { $0 }.joined(separator: ". ") }
}

enum ShareFlow {
  static let maximumCandidates = 5

  static func start(signedIn: Bool, sessionUsable: Bool, candidates: [URL]) -> ShareStart {
    guard signedIn, sessionUsable else { return .signIn }
    guard !candidates.isEmpty, candidates.count <= maximumCandidates else { return .unreadable }
    return candidates.count == 1 ? .save(candidates[0]) : .choose
  }

  // Wording. "Saved" means the server accepted the link; "Saved offline" means it is only queued
  // on this device. Neither claims the article is downloaded or readable yet.
  static let saving = ShareStatus(text: "Saving…", symbol: "arrow.up.circle", tone: .progress)
  static let saved = ShareStatus(
    text: "Saved", symbol: "checkmark.circle.fill", tone: .success, dismisses: true)
  static let alreadySaved = ShareStatus(
    text: "Already saved", symbol: "checkmark.circle.fill", tone: .success, dismisses: true)
  static let savedOffline = ShareStatus(
    text: "Saved offline, will send later", symbol: "clock.arrow.circlepath", tone: .pending,
    dismisses: true)
  static let keptOnDevice = ShareStatus(
    text: "Kept on this iPhone, will send later", symbol: "clock.arrow.circlepath",
    tone: .pending, dismisses: true)
  static let notPrepared = ShareStatus(
    text: "Saved, but it couldn't be prepared", detail: "Check Imports in PageStash.",
    symbol: "exclamationmark.triangle.fill", tone: .problem)
  static let signIn = ShareStatus(
    text: "Open PageStash and sign in again", symbol: "person.crop.circle.badge.exclamationmark",
    tone: .problem)
  static func failed(_ detail: String? = nil) -> ShareStatus {
    ShareStatus(
      text: "Couldn't save", detail: detail, symbol: "exclamationmark.circle.fill",
      tone: .problem, canRetry: true)
  }

  /// Notices shown instead of a status when nothing is being saved.
  static let signInNotice = "Open PageStash and sign in, then share this page again."
  static let unreadableNotice = "This share has no webpage link PageStash can save."
  static let unreadableItemsNotice = "Couldn't read the shared link. Try sharing the page again."
  static let chooseNotice = "Choose the link to save."

  /// The status for a save record after a delivery attempt.
  static func status(for record: SharedSave?) -> ShareStatus {
    guard let record else { return failed("Couldn't confirm the save.") }
    switch record.state {
    case .accepted:
      switch record.serverStatus {
      case "already_saved": return alreadySaved
      case "bookmark": return notPrepared
      default: return saved
      }
    case .queued, .sending:
      // Without a server reason, delivery failed on the network; PageStash sends it later.
      // A server reason (busy, timed out) also keeps the link queued on this device.
      if let reason = record.error, reason != ShareServicesText.offline { return keptOnDevice }
      return savedOffline
    case .authenticationRequired: return signIn
    case .rejected: return failed(record.error)
    }
  }

  /// The status for an error thrown while queueing or delivering.
  static func status(for error: Error) -> ShareStatus {
    switch error as? ShareError {
    case .changedAccount, .authenticationRequired: return signIn
    default: return failed()
    }
  }

  /// How long a finished status stays on screen before the sheet closes, or nil to stay open.
  static func dismissDelay(for status: ShareStatus, voiceOver: Bool) -> Double? {
    guard status.dismisses else { return nil }
    let reading = status.tone == .pending ? 1.8 : 1.0
    // Leave VoiceOver time to finish the announcement before the sheet goes away.
    return voiceOver ? reading + 2.5 : reading
  }

  /// A page title supplied with the share, if any. Links and long text are not titles.
  static func title(from values: [String?]) -> String? {
    for value in values {
      guard let value else { continue }
      let words = value.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
      let text = words.joined(separator: " ")
      guard !text.isEmpty, text.count <= 300, !text.contains("://"),
        (try? SharedLink.validate(text)) == nil
      else { continue }
      return text
    }
    return nil
  }

  /// The host shown for a link, without a leading "www.".
  static func host(_ url: URL) -> String {
    let host = url.host ?? url.absoluteString
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
}
