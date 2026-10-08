import XCTest

@testable import ReaderCore

final class ReadingScrollPositionTests: XCTestCase {
  func testHeaderScrollDoesNotCountAsArticleProgress() {
    XCTAssertEqual(
      ReadingScrollPosition.progress(
        offset: 120, contentHeight: 1800, viewportHeight: 600, headerHeight: 240), 0)
    XCTAssertEqual(
      ReadingScrollPosition.offset(
        progress: 0, contentHeight: 1800, viewportHeight: 600, headerHeight: 240), 0)
  }
  func testSavedArticlePositionRoundTripsWithLongHeader() {
    let offset = ReadingScrollPosition.offset(
      progress: 0.4, contentHeight: 1800, viewportHeight: 600, headerHeight: 240)
    XCTAssertEqual(offset, 624, accuracy: 0.001)
    XCTAssertEqual(
      ReadingScrollPosition.progress(
        offset: offset, contentHeight: 1800, viewportHeight: 600, headerHeight: 240), 0.4,
      accuracy: 0.001)
    XCTAssertEqual(
      ReadingScrollPosition.offset(
        progress: 1, contentHeight: 1800, viewportHeight: 600, headerHeight: 240), 1200)
  }
  func testLongerTitleDoesNotMoveTheRelativeBodyPosition() {
    let short = ReadingScrollPosition.offset(
      progress: 0.4, contentHeight: 1800, viewportHeight: 600, headerHeight: 240)
    let long = ReadingScrollPosition.offset(
      progress: 0.4, contentHeight: 1980, viewportHeight: 600, headerHeight: 420)
    XCTAssertEqual(short - 240, long - 420, accuracy: 0.001)
  }
  func testFitsOnScreenAndInvalidProgressAreSafe() {
    XCTAssertEqual(
      ReadingScrollPosition.offset(
        progress: 0.8, contentHeight: 300, viewportHeight: 600, headerHeight: 200), 0)
    XCTAssertEqual(
      ReadingScrollPosition.progress(
        offset: 0, contentHeight: 300, viewportHeight: 600, headerHeight: 200), 0)
    XCTAssertEqual(
      ReadingScrollPosition.offset(
        progress: .nan, contentHeight: 1800, viewportHeight: 600, headerHeight: 240), 0)
    XCTAssertEqual(
      ReadingScrollPosition.progress(
        offset: -100, contentHeight: 1800, viewportHeight: 600, headerHeight: 240), 0)
  }
}
