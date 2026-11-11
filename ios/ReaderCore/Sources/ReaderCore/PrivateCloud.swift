import Foundation

/// When PageStash uses Apple's Private Cloud Compute (PCC) model instead of the on-device one.
///
/// - On-device is the default, and the only path when offline, when PCC is unavailable, when this
///   build lacks Apple's PCC entitlement, when today's PCC limit is reached, on iOS 26, for short
///   articles, and for quiet pre-generation of unread articles.
/// - PCC is used only when the reader turned on "Use Apple's Private Cloud for Long Articles" in
///   Settings (off by default, because it sends the article's text and the finished-article list
///   off the iPhone, and earlier versions promised nothing was sent anywhere), PCC reports
///   available, and the article is long: one that the on-device model could only summarize in
///   parts. PCC then reads it whole in one call, and answers questions from many more passages.
/// - Any PCC failure falls back to the device, and the sheet says why.
public enum PrivateCloudPolicy {
  /// The `UserDefaults` key of the Settings switch. Absent means off.
  public static let settingKey = "privateCloudForLongArticles"

  /// Whether the on-device model would have to summarize this text in parts.
  public static func isLong(
    _ text: String, onDevice: any LocalLanguageModel, tokenRatio: Double = 1
  )
    -> Bool
  {
    let plan = LocalReadingContext.Plan(
      contextTokens: onDevice.contextTokens, reservedTokens: onDevice.reservedTokens,
      tokenRatio: tokenRatio)
    return TokenEstimate.tokens(text) > plan.directTokens
  }

  /// Whether to send this article to `cloud` (already allowed by the reader) rather than chunk it
  /// on the device.
  public static func prefersCloud(
    _ text: String, onDevice: any LocalLanguageModel, cloud: any LocalLanguageModel
  ) async -> Bool {
    guard cloud.location == .privateCloud, cloud.availability == .available else { return false }
    let ratio = await TokenEstimate.ratio(text, model: onDevice)
    return isLong(text, onDevice: onDevice, tokenRatio: ratio)
  }

  /// Whether a question about this text gets better grounding on `cloud`: the article holds more
  /// than the on-device passage budget, so the device would see only part of it.
  public static func prefersCloudForQuestions(
    _ text: String, onDevice: any LocalLanguageModel, cloud: any LocalLanguageModel
  ) -> Bool {
    guard cloud.location == .privateCloud, cloud.availability == .available else { return false }
    return TokenEstimate.tokens(text) > ArticleQuestion.passageBudget(onDevice, fraction: 0.5)
  }
}

/// Reads the entitlements embedded in a Mach-O executable's code signature, so the app can tell at
/// run time whether its own build carries a managed entitlement (iOS has no public API for this).
/// Unsigned and simulator builds have none here, which reads as not entitled.
public enum CodeSignature {
  /// The managed entitlement Apple's Private Cloud Compute model requires.
  public static let privateCloudComputeEntitlement = "com.apple.developer.private-cloud-compute"

  public static func hasEntitlement(_ key: String, machO data: Data) -> Bool {
    guard let value = entitlements(machO: data)?[key] else { return false }
    if let flag = value as? Bool { return flag }
    return true
  }

  /// The XML entitlements of the first slice that has them, or nil.
  public static func entitlements(machO data: Data) -> [String: Any]? {
    let bytes = [UInt8](data.prefix(8))
    guard bytes.count >= 8 else { return nil }
    let bigMagic = be32(data, 0)
    if bigMagic == 0xCAFE_BABE || bigMagic == 0xCAFE_BABF {
      // Universal binary: big-endian fat_arch (20 bytes) or fat_arch_64 (32 bytes) entries.
      let wide = bigMagic == 0xCAFE_BABF
      guard let count = be32(data, 4), count < 64 else { return nil }
      for index in 0..<Int(count) {
        let entry = 8 + index * (wide ? 32 : 20)
        let offset: Int?
        let size: Int?
        if wide {
          offset = be64(data, entry + 8).map(Int.init)
          size = be64(data, entry + 16).map(Int.init)
        } else {
          offset = be32(data, entry + 8).map(Int.init)
          size = be32(data, entry + 12).map(Int.init)
        }
        guard let offset, let size, offset >= 0, size > 0, offset + size <= data.count else {
          continue
        }
        let slice = data.subdata(in: data.startIndex + offset..<data.startIndex + offset + size)
        if let found = thin(slice) { return found }
      }
      return nil
    }
    return thin(data)
  }

  static func thin(_ data: Data) -> [String: Any]? {
    // MH_MAGIC_64 (0xfeedfacf) or MH_MAGIC (0xfeedface), little-endian on Apple platforms.
    guard let magic = le32(data, 0), magic == 0xFEED_FACF || magic == 0xFEED_FACE,
      let commands = le32(data, 16)
    else { return nil }
    var cursor = magic == 0xFEED_FACF ? 32 : 28
    for _ in 0..<min(Int(commands), 4096) {
      guard let command = le32(data, cursor), let size = le32(data, cursor + 4), size >= 8 else {
        return nil
      }
      if command == 0x1D,  // LC_CODE_SIGNATURE
        let offset = le32(data, cursor + 8), let length = le32(data, cursor + 12)
      {
        return superBlob(data, at: Int(offset), length: Int(length))
      }
      cursor += Int(size)
    }
    return nil
  }

  static func superBlob(_ data: Data, at start: Int, length: Int) -> [String: Any]? {
    guard start >= 0, length >= 12, start + length <= data.count,
      be32(data, start) == 0xFADE_0CC0, let count = be32(data, start + 8), count < 256
    else { return nil }
    for index in 0..<Int(count) {
      let entry = start + 12 + index * 8
      guard let type = be32(data, entry), let offset = be32(data, entry + 4) else { return nil }
      guard type == 5 else { continue }  // CSSLOT_ENTITLEMENTS
      let blob = start + Int(offset)
      guard be32(data, blob) == 0xFADE_7171, let size = be32(data, blob + 4), size > 8,
        blob + Int(size) <= start + length
      else { return nil }
      let xml = data.subdata(in: data.startIndex + blob + 8..<data.startIndex + blob + Int(size))
      return (try? PropertyListSerialization.propertyList(from: xml, format: nil))
        as? [String: Any]
    }
    return nil
  }

  private static func byte(_ data: Data, _ offset: Int) -> UInt8? {
    guard offset >= 0, offset < data.count else { return nil }
    return data[data.startIndex + offset]
  }
  private static func be32(_ data: Data, _ offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(byte(data, offset + $1)!) }
  }
  private static func le32(_ data: Data, _ offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return (0..<4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32(byte(data, offset + $1)!) }
  }
  private static func be64(_ data: Data, _ offset: Int) -> UInt64? {
    guard let high = be32(data, offset), let low = be32(data, offset + 4) else { return nil }
    return UInt64(high) << 32 | UInt64(low)
  }
}
