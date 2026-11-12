//
//  HUDBar.swift
//  rootshellVNC
//
//  The floating HUD: the controls menu button, plus optional host-supplied
//  content that shares its glass.
//

#if canImport(UIKit)
import SwiftUI
import UIKit

/// UIKit content inside the HUD that tracks its own touches. The HUD's own
/// drag leaves it alone; it adds a `VNCHUDDragGestureRecognizer` wherever its
/// touches may move the HUD.
@MainActor
public protocol VNCHUDInteractiveContent: UIView {}

/// Size of one HUD button, so a host's own buttons and the menu button match.
public struct VNCHUDButtonStyle: Equatable, Sendable {
    public var size: CGSize
    public var symbolPointSize: CGFloat

    public init(size: CGSize, symbolPointSize: CGFloat) {
        self.size = size
        self.symbolPointSize = symbolPointSize
    }

    /// The HUD's own look when no host restyles it.
    public static let standard = VNCHUDButtonStyle(
        size: CGSize(width: 46, height: 46), symbolPointSize: 17)
}

/// Host content for the HUD: `behind` spans the bar, bottom-aligned, with the
/// buttons over its trailing end and takes the width it may use; `beside`
/// joins the menu button and takes the style to match.
struct HUDAccessory {
    /// Pinned along the bottom, with the fitted screen kept clear of it.
    var docksToBottom: Bool
    var buttonStyle: (CGFloat) -> VNCHUDButtonStyle
    var behind: (CGFloat) -> AnyView
    var beside: (VNCHUDButtonStyle) -> AnyView
}

/// Lays host content out with the menu button inside one glass shape.
/// Without any the menu button keeps its own round chrome.
struct HUDBar<MenuButton: View>: View {
    let accessory: HUDAccessory?
    /// Width of the area the HUD may occupy, margins and safe area removed.
    let availableWidth: CGFloat
    @ViewBuilder var menuButton: () -> MenuButton

    var body: some View {
        if let accessory {
            let style = accessory.buttonStyle(availableWidth)
            ZStack(alignment: .bottomTrailing) {
                accessory.behind(availableWidth)
                HStack(alignment: .bottom, spacing: 0) {
                    accessory.beside(style)
                    menuButton()
                }
            }
            .environment(\.vncHUDButtonStyle, style)
            .modifier(HUDBarChromeModifier(cornerRadius: style.size.height / 2))
        } else {
            menuButton()
        }
    }

    /// A docked bar sits closer to the edges than a floating one.
    static func margin(for accessory: HUDAccessory?) -> CGFloat {
        accessory?.docksToBottom == true ? 6 : 12
    }

    static func availableWidth(
        containerWidth: CGFloat,
        safeArea: EdgeInsets,
        safeAreaEdges: Edge.Set,
        margin: CGFloat
    ) -> CGFloat {
        var width = containerWidth - margin * 2
        if safeAreaEdges.contains(.leading) { width -= safeArea.leading }
        if safeAreaEdges.contains(.trailing) { width -= safeArea.trailing }
        return max(0, width)
    }
}

private struct VNCHUDButtonStyleKey: EnvironmentKey {
    static let defaultValue: VNCHUDButtonStyle? = nil
}

extension EnvironmentValues {
    /// Set inside a HUD bar that hosts an accessory; nil for the lone round button.
    var vncHUDButtonStyle: VNCHUDButtonStyle? {
        get { self[VNCHUDButtonStyleKey.self] }
        set { self[VNCHUDButtonStyleKey.self] = newValue }
    }
}

/// The menu button's glyph, sized by the host's button style inside a bar.
struct HUDMenuButtonLabel: View {
    @Environment(\.vncHUDButtonStyle) private var barStyle

    var body: some View {
        let style = barStyle ?? .standard
        Image(systemName: "line.3.horizontal")
            .font(barStyle == nil
                ? .body.weight(.bold)
                : .system(size: style.symbolPointSize, weight: .medium))
            .frame(width: style.size.width, height: style.size.height)
            .contentShape(Rectangle())
            .modifier(HUDButtonChromeModifier(isEnabled: barStyle == nil))
    }
}

/// Glass for the whole bar. A bar one button tall reads as a capsule.
struct HUDBarChromeModifier: ViewModifier {
    let cornerRadius: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        #if os(visionOS)
        content.background(.ultraThinMaterial, in: shape)
        #else
        if #available(iOS 26.0, macCatalyst 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
        #endif
    }
}
#endif
