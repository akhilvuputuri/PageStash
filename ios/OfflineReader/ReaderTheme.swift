import SwiftUI

// Apply at each presentation root: sheets own their color-scheme preference.
struct ReaderTheme: ViewModifier {
  @AppStorage("appearance") private var appearance = "light"
  static let sepiaPage = Color(red: 246 / 255, green: 240 / 255, blue: 228 / 255)
  static let sepiaRow = Color(red: 255 / 255, green: 250 / 255, blue: 240 / 255)
  static let sepiaInk = Color(red: 61 / 255, green: 53 / 255, blue: 43 / 255)
  static let sepiaLink = Color(red: 134 / 255, green: 81 / 255, blue: 45 / 255)
  static func scheme(_ appearance: String) -> ColorScheme? {
    switch appearance {
    case "dark": return .dark
    case "system": return nil
    default: return .light
    }
  }
  func body(content: Content) -> some View {
    content
      .preferredColorScheme(Self.scheme(appearance))
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
