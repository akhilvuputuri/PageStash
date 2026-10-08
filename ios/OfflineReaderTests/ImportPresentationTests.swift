import SwiftUI
import XCTest

@testable import OfflineReader

@MainActor final class ImportPresentationTests: XCTestCase {
  func capture(_ window: UIWindow, name: String) {
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  func testLibraryAndImportReviewPresentation() async throws {
    let state = AppState.shared
    XCTAssertEqual(state.items.filter { $0.hasPreparedContent && !$0.archived }.count, 2)
    XCTAssertEqual(state.items.filter(\.needsImportReview).count, 2)
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: "appearance")
    defaults.set("light", forKey: "appearance")
    defer { defaults.set(previous, forKey: "appearance") }
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let root = UIHostingController(rootView: RootView().environmentObject(state))
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    window.rootViewController = root
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }
    try await Task.sleep(nanoseconds: 500_000_000)
    capture(window, name: "Synthetic library excludes failed and pending imports")
    let imports = UIHostingController(rootView: ImportsView().environmentObject(state))
    root.present(imports, animated: false)
    try await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertNotNil(imports.view.window)
    capture(window, name: "Synthetic imports with failure explanation and Retry")
    root.dismiss(animated: false)
  }
}
