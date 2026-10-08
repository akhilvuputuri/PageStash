import SwiftUI
import XCTest

@testable import OfflineReader

@MainActor final class SettingsThemeTests: XCTestCase {
  struct Presenter: View {
    @AppStorage("appearance") private var appearance = "light"
    @State private var presented = true
    private var scheme: ColorScheme? {
      appearance == "system" ? nil : appearance == "dark" ? .dark : .light
    }
    var body: some View {
      Color.clear.preferredColorScheme(scheme)
        .sheet(isPresented: $presented) {
          SettingsView().environmentObject(AppState.shared)
        }
    }
  }
  func waitFor(_ label: String, _ predicate: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw NSError(
      domain: "SettingsThemeTest", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Timed out: \(label)"])
  }
  func findScroll(_ view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
      return scroll
    }
    return view.subviews.compactMap { findScroll($0) }.first
  }
  func snapshot(_ window: UIWindow, name: String) {
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  func testThemeChangesInPresentedSettingsWithoutRecreation() async throws {
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: "appearance")
    defaults.set("light", forKey: "appearance")
    defer { defaults.set(previous, forKey: "appearance") }
    let host = UIHostingController(rootView: Presenter())
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    window.overrideUserInterfaceStyle = .light
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }
    try await waitFor("settings presentation") { host.presentedViewController?.view.window != nil }
    let sheet = try XCTUnwrap(host.presentedViewController)
    try await waitFor("initial light") { sheet.traitCollection.userInterfaceStyle == .light }
    snapshot(window, name: "Synthetic settings light")
    try await waitFor("settings scroll layout") { self.findScroll(sheet.view) != nil }
    let scroll = try XCTUnwrap(findScroll(sheet.view))
    scroll.setContentOffset(CGPoint(x: 0, y: 30), animated: false)
    try await Task.sleep(nanoseconds: 300_000_000)
    let savedOffset = scroll.contentOffset.y
    for theme in ["dark", "sepia", "light", "system"] {
      defaults.set(theme, forKey: "appearance")
      let expected: UIUserInterfaceStyle = theme == "dark" ? .dark : .light
      try await waitFor("\(theme) appearance") {
        sheet.traitCollection.userInterfaceStyle == expected
      }
      XCTAssertTrue(
        host.presentedViewController === sheet, "Changing theme must preserve the open sheet")
      XCTAssertEqual(
        scroll.contentOffset.y, savedOffset, accuracy: 1, "Theme changes must retain form position")
      snapshot(window, name: "Synthetic settings \(theme)")
    }
    window.overrideUserInterfaceStyle = .dark
    try await waitFor("system follows device dark") {
      sheet.traitCollection.userInterfaceStyle == .dark
    }
    window.overrideUserInterfaceStyle = .light
    try await waitFor("system follows device light") {
      sheet.traitCollection.userInterfaceStyle == .light
    }
    XCTAssertTrue(host.presentedViewController === sheet)
  }
}
