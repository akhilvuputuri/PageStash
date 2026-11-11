import XCTest

@testable import ReaderCore

final class PrivateCloudTests: XCTestCase {
  private let sectioned = "SUMMARY: About volcanoes.\nKEY POINTS:\n- Magma"
  private func article(_ text: String) -> LocalArticle {
    LocalArticle(id: "item", contentVersion: 1, title: "Volcanoes", site: nil, text: text)
  }
  private let long = (1...700).map { "Sentence \($0) about magma chambers and eruptions." }
    .joined(separator: " ")
  private func device() -> FakeModel {
    FakeModel { instructions, _ in instructions.contains("one part") ? "Notes." : self.sectioned }
  }
  private func cloud(_ reply: @escaping (String, String) throws -> String) -> FakeModel {
    FakeModel(contextTokens: 32_768, location: .privateCloud, reservedTokens: 2048, reply: reply)
  }

  func testLongArticleGoesWholeToThePrivateCloudInOneCall() async throws {
    let onDevice = device()
    let remote = cloud { _, _ in self.sectioned }
    let steps = Steps()
    let outcome = try await LocalReadingContext.write(
      article: article(long), history: [], finishedTotal: 0, onDevice: onDevice,
      privateCloud: remote, progress: { steps.append($0) })
    XCTAssertEqual(remote.calls.count, 1)
    XCTAssertTrue(remote.calls[0].prompt.contains("Sentence 700"), "The whole article is sent")
    XCTAssertEqual(remote.calls[0].max, 520 + 2048, "Room for the answer and the reasoning")
    XCTAssertEqual(onDevice.calls.count, 0)
    XCTAssertEqual(outcome.context.model, "apple-private-cloud")
    XCTAssertTrue(outcome.context.isPrivateCloud)
    XCTAssertTrue(outcome.context.isLocal)
    XCTAssertNil(outcome.cloudFallback)
    XCTAssertEqual(steps.values.first?.step, .privateCloud)
  }

  func testShortArticleStaysOnTheDevice() async throws {
    let onDevice = device()
    let remote = cloud { _, _ in self.sectioned }
    let outcome = try await LocalReadingContext.write(
      article: article("Magma rises."), history: [], finishedTotal: 0, onDevice: onDevice,
      privateCloud: remote)
    XCTAssertEqual(remote.calls.count, 0)
    XCTAssertEqual(outcome.context.model, "apple-on-device")
  }

  func testUnavailableOrLimitedCloudIsNotTried() async throws {
    for availability in [LocalModelAvailability.limitReached, .modelNotReady, .notEntitled] {
      let onDevice = device()
      let remote = cloud { _, _ in self.sectioned }
      remote.availability = availability
      let outcome = try await LocalReadingContext.write(
        article: article(long), history: [], finishedTotal: 0, onDevice: onDevice,
        privateCloud: remote)
      XCTAssertEqual(remote.calls.count, 0)
      XCTAssertGreaterThan(onDevice.calls.count, 1, "Chunked on the device")
      XCTAssertEqual(outcome.context.model, "apple-on-device")
      XCTAssertNil(outcome.cloudFallback)
    }
  }

  func testCloudFailureFallsBackToTheDeviceAndSaysWhy() async throws {
    for failure in [LocalModelError.limitReached, .offline, .busy, .guardrail] {
      let onDevice = device()
      let remote = cloud { _, _ in throw failure }
      let outcome = try await LocalReadingContext.write(
        article: article(long), history: [], finishedTotal: 0, onDevice: onDevice,
        privateCloud: remote)
      XCTAssertEqual(outcome.context.model, "apple-on-device")
      XCTAssertEqual(outcome.cloudFallback, failure)
      XCTAssertGreaterThan(onDevice.calls.count, 1)
    }
  }

  func testFallbackIsSavedWithTheNoteAndOldNotesStillDecode() async throws {
    let outcome = try await LocalReadingContext.write(
      article: article(long), history: [], finishedTotal: 0, onDevice: device(),
      privateCloud: cloud { _, _ in throw LocalModelError.limitReached })
    XCTAssertEqual(outcome.context.cloudFallback, "limitReached")
    XCTAssertTrue(outcome.context.cloudFallbackNotice!.contains("limit"))
    // Survives a relaunch: encoded and decoded like the store does.
    let data = try Wire.encoder().encode(outcome.context)
    let decoded = try Wire.decoder().decode(ReadingContext.self, from: data)
    XCTAssertEqual(decoded.cloudFallback, "limitReached")
    XCTAssertEqual(decoded.with(stale: true).cloudFallback, "limitReached")
    // A note written on the device without a cloud attempt has none.
    let plain = try await LocalReadingContext.write(
      article: article(long), history: [], finishedTotal: 0, onDevice: device(), privateCloud: nil)
    XCTAssertNil(plain.context.cloudFallback)
    XCTAssertNil(plain.context.cloudFallbackNotice)
    let old = """
      {"item_id":"a","content_version":1,"generated_at":"2026-11-01T00:00:00.000Z",
       "model":"apple-on-device","history_count":0,"stale":false,"summary":"S",
       "builds_on":[],"covered":[],"new_ideas":[]}
      """
    XCTAssertNil(try Wire.decoder().decode(ReadingContext.self, from: Data(old.utf8)).cloudFallback)
  }

  func testLongCJKArticleNotesAllFitTheCombiningCall() async throws {
    // About a token per character: notes as long as the 700-character clip would overflow.
    let text = (1...60).map { "第\($0)段。" + String(repeating: "火山の噴火と溶岩の流れについて説明する。", count: 12) }
      .joined(separator: "\n\n")
    let onDevice = FakeModel { instructions, prompt in
      if instructions.contains("one part") { return String(repeating: "溶岩", count: 400) }
      return self.sectioned
    }
    _ = try await LocalReadingContext.generate(
      article: article(text), history: [], finishedTotal: 0, model: onDevice)
    let parts = onDevice.calls.filter { $0.instructions.contains("one part") }
    let reduce = onDevice.calls.last!
    XCTAssertGreaterThan(parts.count, 1)
    XCTAssertTrue(reduce.prompt.contains("(\(parts.count))"), "The last part's note isn't cut off")
    XCTAssertEqual(onDevice.calls.count, parts.count + 1, "No overflow retry was needed")
  }

  func testCancellationIsNotAFallback() async {
    let onDevice = device()
    let remote = cloud { _, _ in throw CancellationError() }
    do {
      _ = try await LocalReadingContext.write(
        article: article(long), history: [], finishedTotal: 0, onDevice: onDevice,
        privateCloud: remote)
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(onDevice.calls.count, 0)
  }

  func testRealTokenCountsCalibrateTheBudget() async {
    let onDevice = device()
    let uncounted = await TokenEstimate.ratio(long, model: onDevice)
    XCTAssertEqual(uncounted, 1, "No counter: the estimate")
    onDevice.counter = { TokenEstimate.tokens($0) * 3 / 4 }
    let ratio = await TokenEstimate.ratio(long, model: onDevice)
    XCTAssertEqual(ratio, 0.75, accuracy: 0.01)
    onDevice.counter = { _ in 1_000_000 }
    let clamped = await TokenEstimate.ratio(long, model: onDevice)
    XCTAssertEqual(clamped, 1.5)
    let plain = LocalReadingContext.Plan(contextTokens: 4096)
    let calibrated = LocalReadingContext.Plan(contextTokens: 4096, tokenRatio: 0.75)
    XCTAssertGreaterThan(calibrated.directTokens, plain.directTokens)
    let reasoning = LocalReadingContext.Plan(contextTokens: 32_768, reservedTokens: 2048)
    XCTAssertLessThanOrEqual(
      reasoning.historyTokens + reasoning.materialTokens + reasoning.answerTokens + 2048 + 360,
      32_768)
    XCTAssertEqual(reasoning.historyLimit, 60)
  }

  func testQuestionsAboutLongArticlesUseTheCloudThenFallBack() async throws {
    let onDevice = FakeModel { _, _ in "From the device." }
    let remote = cloud { _, prompt in
      XCTAssertTrue(prompt.contains("QUESTION"))
      return "From the cloud."
    }
    var last: ArticleQuestion.Partial?
    for try await partial in ArticleQuestion.answer(
      "What about magma?", articleText: long, model: onDevice, privateCloud: remote)
    {
      last = partial
    }
    XCTAssertEqual(last, .init(text: "From the cloud.", location: .privateCloud))
    XCTAssertGreaterThan(
      remote.calls[0].prompt.count, onDevice.contextTokens * 3,
      "Far more passages than fit on device")

    let failing = cloud { _, _ in throw LocalModelError.limitReached }
    last = nil
    for try await partial in ArticleQuestion.answer(
      "What about magma?", articleText: long, model: onDevice, privateCloud: failing)
    {
      last = partial
    }
    XCTAssertEqual(last, .init(text: "From the device.", location: .onDevice))

    // Short articles never leave the device.
    let unused = cloud { _, _ in "From the cloud." }
    for try await partial in ArticleQuestion.answer(
      "Why?", articleText: "The river floods.", model: onDevice, privateCloud: unused)
    {
      last = partial
    }
    XCTAssertEqual(unused.calls.count, 0)
    XCTAssertEqual(last?.location, .onDevice)
  }

  func testNewAvailabilityAndErrorCopy() {
    XCTAssertFalse(LocalModelAvailability.notEntitled.deviceSupportsModel)
    XCTAssertTrue(LocalModelAvailability.notEntitled.message.contains("Private Cloud Compute"))
    XCTAssertTrue(LocalModelError.limitReached.errorDescription!.contains("limit"))
    XCTAssertTrue(LocalModelError.offline.errorDescription!.contains("internet"))
  }

  // MARK: Code signature

  /// A minimal 64-bit Mach-O with one LC_CODE_SIGNATURE pointing at a SuperBlob that holds an
  /// entitlements blob.
  private func machO(entitlements xml: String?) -> Data {
    func le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    func be(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    var blobs: [UInt8] = []
    var index: [UInt8] = []
    var count: UInt32 = 1
    // A code directory placeholder (slot 0) comes first, as in real signatures.
    let directory = be(0xFADE_0C02) + be(12) + [0, 0, 0, 0]
    var slots: [(UInt32, [UInt8])] = [(0, directory)]
    if let xml {
      let payload = Array(xml.utf8)
      slots.append((5, be(0xFADE_7171) + be(UInt32(8 + payload.count)) + payload))
      count = 2
    }
    var offset = UInt32(12 + 8 * slots.count)
    for (type, blob) in slots {
      index += be(type) + be(offset)
      blobs += blob
      offset += UInt32(blob.count)
    }
    let superBlob =
      be(0xFADE_0CC0) + be(UInt32(12 + index.count + blobs.count)) + be(count) + index
      + blobs
    let headerSize = 32
    let commandSize = 16
    let dataOffset = UInt32(headerSize + commandSize + 8)
    var bytes =
      le(0xFEED_FACF) + le(0x0100_000C) + le(0) + le(2) + le(1) + le(UInt32(commandSize))
      + le(0) + le(0)
    bytes += le(0x1D) + le(UInt32(commandSize)) + le(dataOffset) + le(UInt32(superBlob.count))
    bytes += [UInt8](repeating: 0, count: 8)
    bytes += superBlob
    return Data(bytes)
  }
  private let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
    <key>com.apple.developer.private-cloud-compute</key><true/>
    <key>com.apple.security.application-groups</key><array><string>group.x</string></array>
    </dict></plist>
    """

  func testReadsEntitlementsFromTheCodeSignature() {
    let key = CodeSignature.privateCloudComputeEntitlement
    XCTAssertTrue(CodeSignature.hasEntitlement(key, machO: machO(entitlements: plist)))
    XCTAssertFalse(
      CodeSignature.hasEntitlement(
        key, machO: machO(entitlements: plist.replacingOccurrences(of: "<true/>", with: "<false/>"))
      ))
    XCTAssertFalse(
      CodeSignature.hasEntitlement("com.example.other", machO: machO(entitlements: plist)))
    XCTAssertFalse(
      CodeSignature.hasEntitlement(key, machO: machO(entitlements: nil)), "Unsigned slot")
    XCTAssertFalse(CodeSignature.hasEntitlement(key, machO: Data()))
    XCTAssertFalse(CodeSignature.hasEntitlement(key, machO: Data(repeating: 0xFF, count: 4096)))
    // The key as a string elsewhere in the binary (our own constant) is not an entitlement.
    XCTAssertFalse(CodeSignature.hasEntitlement(key, machO: Data(("\u{0}" + plist).utf8)))
    var truncated = machO(entitlements: plist)
    truncated.removeLast(40)
    XCTAssertFalse(CodeSignature.hasEntitlement(key, machO: truncated))
  }

  func testMalformedUniversalHeadersAreSkippedWithoutTrapping() {
    func be(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    func be64(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    let key = CodeSignature.privateCloudComputeEntitlement
    let slice = machO(entitlements: plist)
    // fat_arch_64 entries: an offset of 2^63 or more, then one whose offset + size overflows,
    // then a valid slice, which is still found.
    var header = be(0xCAFE_BABF) + be(3)
    header += be(0x0100_000C) + be(0) + be64(UInt64(1) << 63) + be64(16) + be(14) + be(0)
    header += be(0x0100_000C) + be(0) + be64(UInt64(Int.max) - 4) + be64(64) + be(14) + be(0)
    header += be(0x0100_000C) + be(0) + be64(256) + be64(UInt64(slice.count)) + be(14) + be(0)
    let data = Data(header + [UInt8](repeating: 0, count: 256 - header.count)) + slice
    XCTAssertTrue(CodeSignature.hasEntitlement(key, machO: data))
    // Only malformed entries: nothing, no trap.
    let bad = Data(Array(header.prefix(8 + 64)) + [UInt8](repeating: 0, count: 64))
    var badHeader = bad
    badHeader[7] = 2
    XCTAssertFalse(CodeSignature.hasEntitlement(key, machO: badHeader))
    // 32-bit entries past the end of the file.
    let short =
      be(0xCAFE_BABE) + be(1) + be(0x0100_000C) + be(0) + be(0xFFFF_FFF0) + be(0xFFFF)
      + be(14)
    XCTAssertFalse(CodeSignature.hasEntitlement(key, machO: Data(short)))
  }

  func testReadsEntitlementsFromAUniversalBinary() {
    func be(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    let slice = machO(entitlements: plist)
    let header =
      be(0xCAFE_BABE) + be(1) + be(0x0100_000C) + be(0) + be(64) + be(UInt32(slice.count)) + be(14)
    let data = Data(header + [UInt8](repeating: 0, count: 64 - header.count)) + slice
    XCTAssertTrue(
      CodeSignature.hasEntitlement(CodeSignature.privateCloudComputeEntitlement, machO: data))
  }
}
