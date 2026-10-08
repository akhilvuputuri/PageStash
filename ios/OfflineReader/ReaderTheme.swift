import SwiftUI

// Apply at each presentation root: sheets own their native appearance.
struct ReaderTheme: ViewModifier {
  @AppStorage("appearance") private var appearance = "light"
  static let sepiaPage = Color(red: 246 / 255, green: 240 / 255, blue: 228 / 255)
  static let sepiaRow = Color(red: 255 / 255, green: 250 / 255, blue: 240 / 255)
  static let sepiaInk = Color(red: 61 / 255, green: 53 / 255, blue: 43 / 255)
  static let sepiaLink = Color(red: 134 / 255, green: 81 / 255, blue: 45 / 255)
  private var interfaceStyle: UIUserInterfaceStyle {
    switch appearance {
    case "dark": return .dark
    case "system": return .unspecified
    default: return .light
    }
  }
  func body(content: Content) -> some View {
    content
      .background(PresentationAppearance(style: interfaceStyle).frame(width: 0, height: 0))
      .tint(appearance == "sepia" ? Self.sepiaLink : Color(red: 0.78, green: 0.30, blue: 0.15))
      .foregroundColor(appearance == "sepia" ? Self.sepiaInk : nil)
      .toolbarBackground(
        appearance == "sepia" ? Self.sepiaPage : Color(.systemBackground), for: .navigationBar)
  }
}
struct ReaderFormBackground: ViewModifier {
  @AppStorage("appearance") private var appearance = "light"
  func body(content: Content) -> some View {
    content
      .scrollContentBackground(appearance == "sepia" ? .hidden : .visible)
      .background(appearance == "sepia" ? ReaderTheme.sepiaPage : Color(.systemGroupedBackground))
  }
}
struct ReaderRowBackground: ViewModifier {
  @AppStorage("appearance") private var appearance = "light"
  func body(content: Content) -> some View {
    content.listRowBackground(appearance == "sepia" ? ReaderTheme.sepiaRow : nil)
  }
}
extension View {
  func readerTheme() -> some View { modifier(ReaderTheme()) }
  func readerFormBackground() -> some View { modifier(ReaderFormBackground()) }
  func readerRowBackground() -> some View { modifier(ReaderRowBackground()) }
}

// Set the presentation's native style explicitly. SwiftUI can retain a previous
// sheet preference when preferredColorScheme changes back to nil (System).
private struct PresentationAppearance: UIViewRepresentable {
  let style: UIUserInterfaceStyle
  func makeUIView(context: Context) -> AppearanceView { AppearanceView() }
  func updateUIView(_ view: AppearanceView, context: Context) { view.style = style }
  final class AppearanceView: UIView {
    var style: UIUserInterfaceStyle = .light { didSet { applyStyle() } }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      applyStyle()
    }
    private func applyStyle() {
      guard window != nil else { return }
      var responder: UIResponder? = self
      while let current = responder, !(current is UIViewController) { responder = current.next }
      guard var controller = responder as? UIViewController else { return }
      while let parent = controller.parent { controller = parent }
      if controller.overrideUserInterfaceStyle != style {
        controller.overrideUserInterfaceStyle = style
      }
    }
  }
}
