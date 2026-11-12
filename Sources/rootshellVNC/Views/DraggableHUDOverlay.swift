//
//  DraggableHUDOverlay.swift
//  rootshellVNC
//
//  Hosts the floating HUD menu over the remote desktop and mirrors the app's
//  collapsed-keyboard-toolbar button interaction: tap activates the control,
//  while direct movement lets a native pan recognizer cancel the tap and drag.
//

import CoreGraphics

/// Insets applied before computing the centers a floating HUD may occupy.
/// Kept UIKit-independent so resize and keyboard-transition geometry can be
/// covered by the package's macOS-hosted unit tests.
struct HUDLayoutInsets: Equatable, Sendable {
    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat

    /// A uniform margin plus the safe area on the edges the HUD keeps clear of.
    /// `safeArea` is physical (`leading` is the left edge), like the geometry.
    init(
        margin: CGFloat,
        safeArea: HUDLayoutInsets = .zero,
        honoring edges: HUDSafeAreaEdges = .all
    ) {
        top = margin + (edges.contains(.top) ? max(0, safeArea.top) : 0)
        leading = margin + (edges.contains(.left) ? max(0, safeArea.leading) : 0)
        bottom = margin + (edges.contains(.bottom) ? max(0, safeArea.bottom) : 0)
        trailing = margin + (edges.contains(.right) ? max(0, safeArea.trailing) : 0)
    }

    init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    static let zero = HUDLayoutInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
}

/// Physical edges whose safe area the HUD stays out of.
struct HUDSafeAreaEdges: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let top = HUDSafeAreaEdges(rawValue: 1 << 0)
    static let left = HUDSafeAreaEdges(rawValue: 1 << 1)
    static let bottom = HUDSafeAreaEdges(rawValue: 1 << 2)
    static let right = HUDSafeAreaEdges(rawValue: 1 << 3)
    static let all: HUDSafeAreaEdges = [.top, .left, .bottom, .right]
}

/// Pure layout helpers for the draggable HUD.
struct HUDDockGeometry {
    static func allowedCenterRect(
        in bounds: CGRect,
        contentSize: CGSize,
        insets: HUDLayoutInsets
    ) -> CGRect {
        let contentMinX = bounds.minX + insets.leading
        let contentMaxX = bounds.maxX - insets.trailing
        let contentMinY = bounds.minY + insets.top
        let contentMaxY = bounds.maxY - insets.bottom

        let proposedMinX = contentMinX + contentSize.width / 2
        let proposedMaxX = contentMaxX - contentSize.width / 2
        let proposedMinY = contentMinY + contentSize.height / 2
        let proposedMaxY = contentMaxY - contentSize.height / 2

        let minX: CGFloat
        let maxX: CGFloat
        if proposedMinX <= proposedMaxX {
            minX = proposedMinX
            maxX = proposedMaxX
        } else {
            minX = (contentMinX + contentMaxX) / 2
            maxX = minX
        }

        let minY: CGFloat
        let maxY: CGFloat
        if proposedMinY <= proposedMaxY {
            minY = proposedMinY
            maxY = proposedMaxY
        } else {
            minY = (contentMinY + contentMaxY) / 2
            maxY = minY
        }

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY)
    }
}

/// A stable edge-relative HUD position. Storing a normalized vertical
/// location instead of an absolute center means a docked control follows
/// keyboard, rotation, split, and full-screen size changes.
struct HUDDockPosition: Equatable, Sendable {
    enum Side: Equatable, Sendable {
        case leading
        case trailing
    }

    var side: Side
    var verticalFraction: CGFloat

    static let bottomTrailing = HUDDockPosition(
        side: .trailing,
        verticalFraction: 1)

    init(side: Side, verticalFraction: CGFloat) {
        self.side = side
        self.verticalFraction = Self.clampedUnit(verticalFraction)
    }

    func center(in allowedCenterRect: CGRect) -> CGPoint {
        CGPoint(
            x: side == .leading
                ? allowedCenterRect.minX
                : allowedCenterRect.maxX,
            y: allowedCenterRect.minY
                + allowedCenterRect.height * verticalFraction)
    }

    static func docked(
        at center: CGPoint,
        in allowedCenterRect: CGRect
    ) -> HUDDockPosition {
        let side: Side = center.x < allowedCenterRect.midX
            ? .leading
            : .trailing
        let verticalFraction: CGFloat
        if allowedCenterRect.height > 0 {
            verticalFraction = (center.y - allowedCenterRect.minY)
                / allowedCenterRect.height
        } else {
            verticalFraction = 0.5
        }
        return HUDDockPosition(
            side: side,
            verticalFraction: verticalFraction)
    }

    static func clamp(
        _ center: CGPoint,
        to allowedCenterRect: CGRect
    ) -> CGPoint {
        CGPoint(
            x: min(max(center.x, allowedCenterRect.minX), allowedCenterRect.maxX),
            y: min(max(center.y, allowedCenterRect.minY), allowedCenterRect.maxY))
    }

    private static func clampedUnit(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit

/// SwiftUI Menu installs private tap/context-menu recognizers inside the
/// hosting view. This pan gets the same direct-drag behavior as a UIButton:
/// it stays possible during a tap, but once movement recognizes it cannot be
/// preempted and cancels the Menu interaction.
public class HUDDragPanGestureRecognizer: UIPanGestureRecognizer {
    public override func canPrevent(
        _ preventedGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    public override func canBePrevented(
        by preventingGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}

/// Drags the HUD it sits in. `VNCHUDInteractiveContent` adds one to itself and
/// filters its touches through the recognizer's delegate.
public final class VNCHUDDragGestureRecognizer: HUDDragPanGestureRecognizer {
    public init() {
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(drag))
        minimumNumberOfTouches = 1
        maximumNumberOfTouches = 1
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = true
    }

    @objc private func drag() {
        var ancestor = view?.superview
        while let current = ancestor {
            if let overlay = current as? DraggableHUDOverlayHostView {
                overlay.handlePan(self)
                return
            }
            ancestor = current.superview
        }
    }
}

/// Wraps `content` in a UIKit host that fills the available area, anchors the
/// HUD at the bottom-trailing corner, and lets a direct pan move it.
/// Touches outside the HUD fall through to the remote desktop below.
struct DraggableHUDOverlay<Content: View>: UIViewRepresentable {
    var inset: CGFloat = 12
    /// Edges whose safe area the HUD keeps clear of.
    var safeAreaEdges: Edge.Set = .all
    /// Set to pin the HUD along the bottom instead of letting it float: the
    /// height of its bottom row, which is what the screen is kept clear of.
    var pinnedRowHeight: CGFloat?
    /// Height at the bottom that a pinned HUD occupies; 0 while it floats.
    var onReserveChange: ((CGFloat) -> Void)?
    @ViewBuilder var content: () -> Content

    func makeUIView(context: Context) -> DraggableHUDOverlayHostView {
        let view = DraggableHUDOverlayHostView()
        view.inset = inset
        view.safeAreaEdges = safeAreaEdges
        view.pinnedRowHeight = pinnedRowHeight
        view.onReserveChange = onReserveChange

        let host = UIHostingController(rootView: Self.sized(content(), in: view))
        host.view.backgroundColor = .clear
        // The overlay places the HUD itself. Left on, the button's own host
        // insets its content for a keyboard or safe area it happens to sit
        // in, which resizes and displaces the button.
        host.safeAreaRegions = []
        // Self-size to the SwiftUI content instead of the proposed bounds.
        host.sizingOptions = .intrinsicContentSize
        context.coordinator.host = host

        view.hostController = host
        view.hostedView = host.view
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = true
        view.attachPan()
        return view
    }

    func updateUIView(_ uiView: DraggableHUDOverlayHostView, context: Context) {
        // Keep the hosted SwiftUI view in sync. The HUD's position lives on
        // the UIView and is untouched by content updates.
        context.coordinator.host?.rootView = Self.sized(content(), in: uiView)
        uiView.inset = inset
        uiView.safeAreaEdges = safeAreaEdges
        uiView.pinnedRowHeight = pinnedRowHeight
        uiView.onReserveChange = onReserveChange
        uiView.setNeedsLayout()
    }

    static func dismantleUIView(
        _ uiView: DraggableHUDOverlayHostView,
        coordinator: Coordinator
    ) {
        coordinator.host?.willMove(toParent: nil)
        coordinator.host?.view.removeFromSuperview()
        coordinator.host?.removeFromParent()
        coordinator.host = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The HUD keeps its ideal size whatever frame it currently has, and asks
    /// to be placed again when that size changes (an accessory opening).
    private static func sized(
        _ content: Content,
        in view: DraggableHUDOverlayHostView
    ) -> AnyView {
        AnyView(
            content
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak view] _ in
                    view?.setNeedsLayout()
                })
    }

    // Erased to UIHostingController<AnyView> (not <Content>) and given an
    // explicit deinit: the swift-frontend optimizer crashes in EarlyPerfInliner
    // while inlining the synthesized deinit of a coordinator holding a generic
    // UIHostingController<Content> at -O (swiftlang/swift#89851, #90150).
    // Release-only; Debug (-Onone) is unaffected.
    final class Coordinator {
        var host: UIHostingController<AnyView>?

        deinit {
            host = nil
        }
    }
}

// Host content that tracks its own touches is not a drag handle.
extension DraggableHUDOverlayHostView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        var view = touch.view
        while let current = view, current !== self {
            if current is VNCHUDInteractiveContent { return false }
            view = current.superview
        }
        return true
    }
}

/// Non-generic host so the pan handler can be an `@objc` selector target
/// (a generic UIView cannot expose `@objc` members to the Obj-C runtime).
@MainActor
final class DraggableHUDOverlayHostView: UIView {
    weak var hostController: UIViewController?
    weak var hostedView: UIView?
    var inset: CGFloat = 12
    var safeAreaEdges: Edge.Set = .all
    var pinnedRowHeight: CGFloat?
    var onReserveChange: ((CGFloat) -> Void)?
    private var reportedReserve: CGFloat = 0

    /// Edge-relative state, rather than an absolute center, prevents a HUD
    /// clamped above the software keyboard from staying in the middle after
    /// the keyboard disappears.
    private var dockPosition = HUDDockPosition.bottomTrailing
    private var isDragging = false

    // MARK: VC containment

    /// Adopt the hosting controller as a proper child VC once we're in a
    /// window. Required for the hosted Menu to present its popup when this
    /// overlay is nested inside a UIKit container.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil,
              let controller = hostController, controller.parent == nil,
              let parent = nearestViewController() else { return }
        parent.addChild(controller)
        controller.didMove(toParent: parent)
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self.next
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }

    // MARK: Dragging

    func attachPan() {
        guard let bar = hostedView else { return }
        let pan = HUDDragPanGestureRecognizer(
            target: self,
            action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = true
        pan.delegate = self
        bar.addGestureRecognizer(pan)
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        // A pinned HUD stays put.
        guard pinnedRowHeight == nil, let bar = hostedView else { return }
        let translation = gesture.translation(in: self)
        let nextCenter = HUDDockPosition.clamp(
            CGPoint(
                x: bar.center.x + translation.x,
                y: bar.center.y + translation.y),
            to: allowedCenterRect(for: bar.bounds.size))

        switch gesture.state {
        case .began:
            isDragging = true
            bar.layer.removeAllAnimations()
            bar.center = nextCenter
            gesture.setTranslation(.zero, in: self)
            #if !os(visionOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        case .changed:
            guard isDragging else { return }
            bar.center = nextCenter
            gesture.setTranslation(.zero, in: self)
        case .ended, .cancelled:
            guard isDragging else { return }
            isDragging = false
            bar.center = nextCenter
            let allowedRect = allowedCenterRect(for: bar.bounds.size)
            dockPosition = HUDDockPosition.docked(
                at: bar.center,
                in: allowedRect)
            let targetCenter = dockPosition.center(in: allowedRect)
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                usingSpringWithDamping: 0.82,
                initialSpringVelocity: 0.25,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                bar.center = targetCenter
            }
        default:
            break
        }
    }

    private func allowedCenterRect(for size: CGSize) -> CGRect {
        // UIKit's safe area is where these bounds really reach under system
        // regions, and never includes the keyboard. A host-managed pane
        // already ends above the keyboard and toolbar, so its bounds are the
        // whole answer there.
        let safeArea = safeAreaInsets
        return HUDDockGeometry.allowedCenterRect(
            in: bounds,
            contentSize: size,
            insets: HUDLayoutInsets(
                margin: inset,
                safeArea: HUDLayoutInsets(
                    top: safeArea.top,
                    leading: safeArea.left,
                    bottom: safeArea.bottom,
                    trailing: safeArea.right),
                honoring: physicalSafeAreaEdges))
    }

    private var physicalSafeAreaEdges: HUDSafeAreaEdges {
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var edges: HUDSafeAreaEdges = []
        if safeAreaEdges.contains(.top) { edges.insert(.top) }
        if safeAreaEdges.contains(.bottom) { edges.insert(.bottom) }
        if safeAreaEdges.contains(.leading) { edges.insert(rightToLeft ? .right : .left) }
        if safeAreaEdges.contains(.trailing) { edges.insert(rightToLeft ? .left : .right) }
        return edges
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    private func preserveDragCenter(
        _ center: CGPoint,
        size: CGSize
    ) -> CGPoint {
        HUDDockPosition.clamp(
            center,
            to: allowedCenterRect(for: size))
    }

    private func layoutDockedBar(_ bar: UIView, size: CGSize) {
        if let pinnedRowHeight {
            isDragging = false
            let allowed = allowedCenterRect(for: size)
            bar.bounds = CGRect(origin: .zero, size: size)
            bar.center = CGPoint(x: allowed.midX, y: allowed.maxY)
            // Only the bottom row: rows that open above it float over the screen.
            reportReserve(bounds.maxY - bar.frame.maxY + pinnedRowHeight + 6)
            return
        }
        reportReserve(0)
        if isDragging {
            let center = bar.center
            bar.bounds = CGRect(origin: .zero, size: size)
            bar.center = preserveDragCenter(center, size: size)
        } else {
            bar.bounds = CGRect(origin: .zero, size: size)
            bar.center = dockPosition.center(
                in: allowedCenterRect(for: size))
        }
    }

    /// Deferred: this runs during layout, and the receiver changes view state.
    private func reportReserve(_ reserve: CGFloat) {
        guard abs(reserve - reportedReserve) > 0.5 else { return }
        reportedReserve = reserve
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onReserveChange?(self.reportedReserve)
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        if pinnedRowHeight == nil { reportReserve(0) }
        guard let bar = hostedView, bounds.width > 0, bounds.height > 0 else { return }

        // Ask the hosting controller for the SwiftUI content's ideal size
        // directly. This forces layout of the content synchronously, so the
        // FIRST measurement is already correct, unlike systemLayoutSizeFitting
        // which returns a near-full-bounds size before SwiftUI has computed
        // the content and makes the HUD flash at the wrong size/position.
        var size: CGSize
        if let host = hostController as? UIHostingController<AnyView> {
            size = host.sizeThatFits(in: UIView.layoutFittingCompressedSize)
        } else {
            size = bar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        }
        size.width = min(size.width, max(0, bounds.width - inset * 2))
        size.height = min(size.height, max(0, bounds.height - inset * 2))

        // Ignore degenerate measurements taken before SwiftUI computes the
        // content's ideal size; anchoring to them strands the HUD off-screen.
        guard size.width > 10, size.height > 10 else { return }

        layoutDockedBar(bar, size: size)
    }

    /// Only intercept touches that land on the HUD; everything else passes
    /// through to the remote desktop underneath.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let bar = hostedView, bar.frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}
#endif
