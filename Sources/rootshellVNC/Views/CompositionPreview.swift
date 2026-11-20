//
//  CompositionPreview.swift
//  rootshellVNC
//
//  Shows the text an input method is still composing. That text stays local
//  until it is committed, so the remote screen never draws it.
//

import CoreGraphics

/// Where the preview goes: along the bottom, just above the keyboard, and
/// clear of a HUD that sits there. UIKit-independent for the unit tests.
struct CompositionPreviewSlot: Equatable, Sendable {
    var minX: CGFloat
    var maxWidth: CGFloat
    /// The preview's bottom edge.
    var maxY: CGFloat

    static let gap: CGFloat = 6
    /// Narrowest space beside the HUD worth wrapping the preview into.
    static let minimumWidthBesideHUD: CGFloat = 160

    /// `height` is the preview's own at full width. A HUD on the bottom row
    /// gets the preview beside it while there is room, otherwise above it.
    static func resolve(
        in bounds: CGRect,
        insets: HUDLayoutInsets,
        hudFrame: CGRect?,
        height: CGFloat
    ) -> CompositionPreviewSlot {
        let left = bounds.minX + insets.leading
        let right = bounds.maxX - insets.trailing
        let floor = bounds.maxY - insets.bottom
        let resting = CompositionPreviewSlot(minX: left, maxWidth: max(0, right - left), maxY: floor)
        guard let hud = hudFrame, !hud.isEmpty,
              hud.maxY + gap > floor - height,
              hud.maxX > left, hud.minX < right else { return resting }

        let before = hud.minX - gap - left
        let after = right - hud.maxX - gap
        if max(before, after) >= minimumWidthBesideHUD {
            return before >= after
                ? CompositionPreviewSlot(minX: left, maxWidth: before, maxY: floor)
                : CompositionPreviewSlot(minX: hud.maxX + gap, maxWidth: after, maxY: floor)
        }
        let lifted = hud.minY - gap
        // A HUD filling the whole height leaves nowhere above it.
        guard lifted - height >= bounds.minY + insets.top else { return resting }
        return CompositionPreviewSlot(minX: left, maxWidth: resting.maxWidth, maxY: lifted)
    }
}

#if canImport(UIKit)
import Observation
import SwiftUI
import UIKit

/// Where the HUD is, in the area it floats over. A class, so a moving HUD
/// redraws only the preview that reads it.
@MainActor
@Observable
final class HUDFrameModel {
    var frame = CGRect.zero
}

extension HUDSafeAreaEdges {
    init(_ edges: Edge.Set, rightToLeft: Bool) {
        self = []
        if edges.contains(.top) { insert(.top) }
        if edges.contains(.bottom) { insert(.bottom) }
        if edges.contains(.leading) { insert(rightToLeft ? .right : .left) }
        if edges.contains(.trailing) { insert(rightToLeft ? .left : .right) }
    }
}

/// Draws the composition over the remote screen. It takes no touches and
/// no space: with nothing being composed there is nothing here.
struct CompositionPreviewLayer: View {
    let keyboardCapture: VNCKeyboardCapture
    let hudFrame: HUDFrameModel
    /// The HUD's margin, so the preview lines up with a docked bar.
    let margin: CGFloat
    let safeArea: EdgeInsets
    let safeAreaEdges: Edge.Set

    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        if let composition = keyboardCapture.composition {
            CompositionPreviewPlacement(hudFrame: hudFrame.frame, insets: insets) {
                CompositionPreviewLabel(composition: composition)
                    .environment(\.layoutDirection, layoutDirection)
            }
            // The HUD's frame is in physical coordinates.
            .environment(\.layoutDirection, .leftToRight)
            .allowsHitTesting(false)
        }
    }

    private var insets: HUDLayoutInsets {
        let rightToLeft = layoutDirection == .rightToLeft
        return HUDLayoutInsets(
            margin: margin,
            safeArea: HUDLayoutInsets(
                top: safeArea.top,
                leading: rightToLeft ? safeArea.trailing : safeArea.leading,
                bottom: safeArea.bottom,
                trailing: rightToLeft ? safeArea.leading : safeArea.trailing),
            honoring: HUDSafeAreaEdges(safeAreaEdges, rightToLeft: rightToLeft))
    }
}

private struct CompositionPreviewPlacement: Layout {
    var hudFrame: CGRect
    var insets: HUDLayoutInsets

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let preview = subviews.first else { return }
        let area = CGRect(origin: .zero, size: bounds.size)
        let resting = CompositionPreviewSlot.resolve(in: area, insets: insets, hudFrame: nil, height: 0)
        let height = preview.sizeThatFits(ProposedViewSize(width: resting.maxWidth, height: nil)).height
        let slot = CompositionPreviewSlot.resolve(in: area, insets: insets, hudFrame: hudFrame, height: height)
        preview.place(
            at: CGPoint(x: bounds.minX + slot.minX, y: bounds.minY + slot.maxY),
            anchor: .bottomLeading,
            proposal: ProposedViewSize(width: slot.maxWidth, height: nil))
    }
}

/// The composition as a text field would show it: underlined, with the
/// input method's selection or caret.
private struct CompositionPreviewLabel: View {
    let composition: RemoteTextInputDocument.Composition

    var body: some View {
        text
            .font(.body)
            .lineLimit(3)
            // The end being typed stays in view.
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .modifier(HUDBarChromeModifier(cornerRadius: 16))
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: composition.text))
    }

    private var text: Text {
        let parts = composition.parts
        let before = Text(verbatim: parts.before).underline()
        let after = Text(verbatim: parts.after).underline()
        guard parts.selected.isEmpty else {
            var selected = AttributedString(parts.selected)
            selected.swiftUI.backgroundColor = Color.accentColor.opacity(0.35)
            return before + Text(selected).underline() + after
        }
        return before + Self.caret + after
    }

    /// A caret the height of a line of body text, set on its descender.
    private static var caret: Text {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let size = CGSize(width: 2, height: ceil(font.lineHeight))
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return Text(Image(uiImage: image).renderingMode(.template))
            .foregroundStyle(.tint)
            .baselineOffset(font.descender)
    }
}
#endif
