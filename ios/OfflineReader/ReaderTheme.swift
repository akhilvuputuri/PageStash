import SwiftUI

/// One reading theme's colours. Native views and the article HTML both read these, so they match.
/// Text inks meet WCAG AA (4.5:1) on `page` and `surface`; `contrast` variants are used when
/// Increase Contrast is on. Measured ratios are recorded in docs/VALIDATION.md.
struct ThemeTokens: Equatable {
  struct Ink: Equatable {
    let normal: String
    let contrast: String
    func hex(_ increased: Bool) -> String { increased ? contrast : normal }
    var color: Color {
      Color(
        uiColor: UIColor { traits in
          UIColor(hex: traits.accessibilityContrast == .high ? contrast : normal)
        })
    }
  }
  let name: String
  /// The reading page, shared with the article HTML.
  let page: String
  /// Grouped form rows. Light and Dark keep the system's grouped surfaces.
  let surface: String?
  let ink: Ink
  let secondaryInk: Ink
  let link: Ink
  let accent: Ink
  let warning: Ink
  let separator: String
  var isDark: Bool { name == "dark" }
  /// Library, Settings and Imports keep the system background unless the theme paints its own page.
  var nativePage: Color { name == "sepia" ? Color(hex: page) : Color(.systemBackground) }

  static let light = ThemeTokens(
    name: "light", page: "#ffffff", surface: nil,
    ink: Ink(normal: "#1c1c1e", contrast: "#000000"),
    secondaryInk: Ink(normal: "#6c6c70", contrast: "#48484a"),
    link: Ink(normal: "#2a63a3", contrast: "#1d4a7d"),
    accent: Ink(normal: "#c74d26", contrast: "#9c3a1a"),
    warning: Ink(normal: "#a4561a", contrast: "#7f4214"), separator: "#3c3c4329")
  static let sepia = ThemeTokens(
    name: "sepia", page: "#f6f0e4", surface: "#fffaf0",
    ink: Ink(normal: "#3d352b", contrast: "#241f19"),
    secondaryInk: Ink(normal: "#6b5e4e", contrast: "#4f4437"),
    link: Ink(normal: "#86512d", contrast: "#683e21"),
    accent: Ink(normal: "#86512d", contrast: "#683e21"),
    warning: Ink(normal: "#a4561a", contrast: "#7f4214"), separator: "#3d352b29")
  static let dark = ThemeTokens(
    name: "dark", page: "#111111", surface: nil,
    ink: Ink(normal: "#eeeeee", contrast: "#ffffff"),
    secondaryInk: Ink(normal: "#9a9a9f", contrast: "#c7c7cc"),
    link: Ink(normal: "#8ab4f8", contrast: "#b3cefa"),
    accent: Ink(normal: "#e0763f", contrast: "#f09a6c"),
    warning: Ink(normal: "#ffb340", contrast: "#ffcc80"), separator: "#ebebf529")
  static func resolve(_ appearance: String, _ colorScheme: ColorScheme) -> ThemeTokens {
    if appearance == "sepia" { return .sepia }
    return colorScheme == .dark ? .dark : .light
  }
}
extension UIColor {
  /// `#rrggbb` or `#rrggbbaa`.
  convenience init(hex: String) {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    let value = UInt64(digits, radix: 16) ?? 0
    let rgba = digits.count == 8 ? value : value << 8 | 0xff
    self.init(
      red: CGFloat(rgba >> 24 & 0xff) / 255, green: CGFloat(rgba >> 16 & 0xff) / 255,
      blue: CGFloat(rgba >> 8 & 0xff) / 255, alpha: CGFloat(rgba & 0xff) / 255)
  }
}
extension Color {
  init(hex: String) { self.init(uiColor: UIColor(hex: hex)) }
}
private struct ThemeTokensKey: EnvironmentKey {
  static let defaultValue = ThemeTokens.light
}
extension EnvironmentValues {
  var themeTokens: ThemeTokens {
    get { self[ThemeTokensKey.self] }
    set { self[ThemeTokensKey.self] = newValue }
  }
}

// Apply at each presentation root: sheets own their native appearance.
struct ReaderTheme: ViewModifier {
  @AppStorage("appearance") private var appearance = "light"
  private var interfaceStyle: UIUserInterfaceStyle {
    switch appearance {
    case "dark": return .dark
    case "system": return .unspecified
    default: return .light
    }
  }
  func body(content: Content) -> some View {
    content
      .modifier(ThemeEnvironment(appearance: appearance))
      .background(PresentationAppearance(style: interfaceStyle).frame(width: 0, height: 0))
  }
}
/// Reads the presentation's resolved light/dark style, then publishes the matching tokens.
private struct ThemeEnvironment: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  let appearance: String
  func body(content: Content) -> some View {
    let tokens = ThemeTokens.resolve(appearance, colorScheme)
    content
      .environment(\.themeTokens, tokens)
      .tint(tokens.accent.color)
      .foregroundColor(tokens.name == "sepia" ? tokens.ink.color : nil)
  }
}
struct ReaderFormBackground: ViewModifier {
  @Environment(\.themeTokens) private var tokens
  func body(content: Content) -> some View {
    content
      .scrollContentBackground(tokens.surface == nil ? .visible : .hidden)
      .background(tokens.surface == nil ? Color(.systemGroupedBackground) : Color(hex: tokens.page))
  }
}
struct ReaderRowBackground: ViewModifier {
  @Environment(\.themeTokens) private var tokens
  func body(content: Content) -> some View {
    content.listRowBackground(tokens.surface.map { Color(hex: $0) })
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
