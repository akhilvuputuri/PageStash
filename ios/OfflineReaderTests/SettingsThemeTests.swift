import SwiftUI
import XCTest

@testable import OfflineReader

@MainActor final class SettingsThemeTests: XCTestCase {
  struct Presenter: View {
    @State private var presented = true
    var body: some View {
      Color.clear.readerTheme()
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
    if let scroll = view as? UIScrollView, scroll.contentSize.height > 0, scroll.bounds.height > 0 {
      return scroll
    }
    return view.subviews.compactMap { findScroll($0) }.first
  }
  func findField(_ view: UIView) -> UITextField? {
    if let field = view as? UITextField { return field }
    return view.subviews.compactMap { findField($0) }.first
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
    let minimum = -scroll.adjustedContentInset.top
    let maximum =
      scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
    scroll.setContentOffset(
      CGPoint(x: 0, y: max(minimum, min(minimum + 30, maximum))), animated: false)
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
    host.dismiss(animated: false)
    defaults.set("sepia", forKey: "appearance")
    let library = UIHostingController(rootView: RootView().environmentObject(AppState.shared))
    window.rootViewController = library
    try await waitFor("synthetic library") { library.view.window != nil }
    try await Task.sleep(nanoseconds: 300_000_000)
    snapshot(window, name: "Synthetic sepia library")
    let connections = UIHostingController(
      rootView:
        NavigationStack { ConnectionsView().environmentObject(AppState.shared) }.readerTheme())
    window.rootViewController = connections
    try await waitFor("credential label field") { self.findField(connections.view) != nil }
    let field = try XCTUnwrap(findField(connections.view))
    XCTAssertTrue(field.becomeFirstResponder())
    let label = field.text
    for theme in ["dark", "light", "sepia", "system"] {
      defaults.set(theme, forKey: "appearance")
      let expected: UIUserInterfaceStyle = theme == "dark" ? .dark : .light
      try await waitFor("focused \(theme)") {
        connections.traitCollection.userInterfaceStyle == expected
      }
      try await Task.sleep(nanoseconds: 100_000_000)
      XCTAssertTrue(field.isFirstResponder, "Theme changes must retain editing focus")
      XCTAssertEqual(field.text, label, "Theme changes must retain the entered label")
    }
    field.resignFirstResponder()
  }
}
