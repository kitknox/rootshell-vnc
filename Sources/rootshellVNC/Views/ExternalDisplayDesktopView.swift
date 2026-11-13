import SwiftUI
import RFBRendering
#if canImport(UIKit)
import UIKit

/// Presents a session's remote desktop on an external screen.
///
/// Hosts put this in the window of a non-interactive external-display scene
/// and set ``VNCSession/externalDisplayViewSize`` to that screen's size. The
/// device's ``RemoteDesktopView`` then hands over the picture and stays on as
/// a trackpad, so this view only draws: the desktop, aspect-fit to the
/// screen, and the local pointer at the last position sent to the server.
public struct ExternalDisplayDesktopView: View {
    @Bindable var session: VNCSession
    private let brightnessGain: Double
    /// The user's pointer size, in the device's terms (17 = the Mac's own
    /// size). Scales the server's pointer shapes and sizes the fallback arrow
    /// used before the server describes its own pointer.
    private let cursorHeight: CGFloat

    public init(
        session: VNCSession,
        brightnessGain: Double = 1.0,
        cursorHeight: CGFloat = 17
    ) {
        self.session = session
        self.brightnessGain = brightnessGain
        self.cursorHeight = cursorHeight
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.black

                if session.isHighPerformanceMode {
                    AdaptiveDisplayView(
                        primaryRenderer: session.videoBandRenderer,
                        secondaryRenderer: session.secondaryVideoBandRenderer,
                        displayRegions: session.presentedVideoDisplayRegions,
                        brightnessGain: brightnessGain)
                } else {
                    StandardFramebufferContent(
                        session: session,
                        showsWaitingCard: false,
                        brightnessGain: brightnessGain)
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height)
                }

                pointer(in: geometry.size)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func pointer(in viewSize: CGSize) -> some View {
        let framebufferSize = session.presentedFramebufferSize
        if session.connectionState.isConnected,
           session.activeCursorRendering == .client,
           session.remoteCursorPresence != .hidden,
           framebufferSize.width > 0, framebufferSize.height > 0 {
            let fit = min(
                viewSize.width / framebufferSize.width,
                viewSize.height / framebufferSize.height)
            let origin = CGPoint(
                x: (viewSize.width - framebufferSize.width * fit) / 2,
                y: (viewSize.height - framebufferSize.height * fit) / 2)
            let framebufferOrigin = session.presentedFramebufferRegion?.origin ?? .zero
            let remotePoint = session.lastPointerLocation ?? CGPoint(
                x: framebufferOrigin.x + framebufferSize.width / 2,
                y: framebufferOrigin.y + framebufferSize.height / 2)
            let location = CGPoint(
                x: origin.x + (remotePoint.x - framebufferOrigin.x) * fit,
                y: origin.y + (remotePoint.y - framebufferOrigin.y) * fit)

            let scale = pointerScale(fit: fit, screenHeight: viewSize.height)
            if let cursor = session.remoteCursor {
                Image(decorative: cursor.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(
                        width: CGFloat(cursor.width) * scale,
                        height: CGFloat(cursor.height) * scale)
                    .offset(
                        x: location.x - CGFloat(cursor.hotspotX) * scale,
                        y: location.y - CGFloat(cursor.hotspotY) * scale)
                    .allowsHitTesting(false)
            } else {
                // Before the server describes its pointer: the local arrow,
                // drawn as tall as the macOS arrow would be at this scale.
                let shape = TrackpadCursorArtwork.Shape.arrow
                let arrowScale = TrackpadCursorStyle.defaultCursorHeight * scale
                    / shape.visibleHeight
                if let arrow = fallbackArrow(pointHeight: shape.canvasSize.height * arrowScale) {
                    Image(decorative: arrow, scale: 1)
                        .resizable()
                        .frame(
                            width: shape.canvasSize.width * arrowScale,
                            height: shape.canvasSize.height * arrowScale)
                        .offset(
                            x: location.x - shape.hotspot.x * arrowScale,
                            y: location.y - shape.hotspot.y * arrowScale)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Screen points per server cursor-image pixel.
    ///
    /// Server shapes are 1x: one image pixel per remote desktop point, as the
    /// device's trackpad cursor assumes. A Match Client desktop is HiDPI, so a
    /// desktop point spans `presentedBackingScale` framebuffer pixels; scaling
    /// by the picture's fit alone would draw the pointer at half size.
    ///
    /// That proportional size can still be small on a large monitor, which is
    /// viewed from further away than the device, so the arrow is held to at
    /// least 1/40 of the screen height (27 pt on a 1080-line screen, 54 pt on a
    /// 1x 4K one). The floor uses the macOS arrow's height as its reference, so
    /// every shape keeps its size relative to the arrow. The user's cursor size
    /// applies on top, as on the device.
    private func pointerScale(fit: CGFloat, screenHeight: CGFloat) -> CGFloat {
        let proportional = fit * session.presentedBackingScale
        let floor = screenHeight / Self.minimumPointerHeightFraction
            / TrackpadCursorStyle.defaultCursorHeight
        return max(proportional, floor)
            * TrackpadCursorStyle.bitmapScale(cursorHeight: cursorHeight)
    }

    private static let minimumPointerHeightFraction: CGFloat = 40

    private func fallbackArrow(pointHeight: CGFloat) -> CGImage? {
        // External screens are commonly 1x; render at 2x so a scaled screen
        // stays sharp without a per-scale cache.
        TrackpadCursorArtwork.image(
            for: .arrow,
            pixelHeight: (pointHeight * 2).rounded(.up))
    }
}

#endif

/// Shown on the device while an external screen presents the desktop.
struct ExternalDisplayHandoffPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 44, weight: .light))
            Text(String(localized: "Showing on External Display", bundle: .module))
                .font(.headline)
            Text(String(
                localized: "Use this screen as a trackpad.",
                bundle: .module))
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .allowsHitTesting(false)
    }
}
