import AppKit
import SwiftUI

enum Theme {
    static let text = dynamic(light: rgb(29, 29, 31), dark: rgb(245, 245, 247))
    static let secondary = dynamic(light: rgb(110, 110, 115), dark: rgb(161, 161, 168))
    static let tertiary = dynamic(light: rgb(161, 161, 166), dark: rgb(107, 107, 114))
    static let accent = dynamic(light: rgb(10, 124, 255), dark: rgb(46, 139, 255))
    static let ok = dynamic(light: rgb(40, 167, 69), dark: rgb(50, 215, 75))
    static let danger = dynamic(light: rgb(229, 72, 77), dark: rgb(255, 99, 105))
    static let field = dynamic(light: .white, dark: NSColor.black.withAlphaComponent(0.28))
    static let chip = dynamic(light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.07))
    static let separator = dynamic(light: NSColor.black.withAlphaComponent(0.09), dark: NSColor.white.withAlphaComponent(0.08))

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }))
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }
}

struct WindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar = nil
        }
    }
}
