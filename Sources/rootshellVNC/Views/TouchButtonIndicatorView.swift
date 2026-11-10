#if canImport(UIKit)
import UIKit

/// A small label that floats above a touch hold and names the remote mouse
/// button it is pressing, so a hold that turned into a right or middle drag
/// is never a surprise.
@MainActor
final class TouchButtonIndicatorView: UIView {
    /// Far enough above the anchor that a fingertip does not cover it.
    private static let anchorClearance: CGFloat = 52
    private static let edgeInset: CGFloat = 8

    private let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let iconView = UIImageView(image: UIImage(systemName: "computermouse.fill"))
    private let label = UILabel()
    private(set) var isShowing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        alpha = 0
        isHidden = true

        effectView.clipsToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)

        iconView.tintColor = .label
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            textStyle: .footnote, scale: .small)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        label.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label

        let stack = UIStackView(arrangedSubviews: [iconView, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: effectView.contentView.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(title: String, near anchor: CGPoint, in container: CGRect) {
        label.text = title
        bounds.size = systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        effectView.layer.cornerRadius = bounds.height / 2
        move(near: anchor, in: container)
        guard !isShowing else { return }
        isShowing = true
        isHidden = false
        UIView.animate(withDuration: 0.12) { self.alpha = 1 }
    }

    func move(near anchor: CGPoint, in container: CGRect) {
        guard anchor.x.isFinite, anchor.y.isFinite else { return }
        let size = bounds.size
        let area = container.insetBy(dx: Self.edgeInset, dy: Self.edgeInset)
        var origin = CGPoint(
            x: anchor.x - size.width / 2,
            y: anchor.y - Self.anchorClearance - size.height / 2)
        // Flip below the anchor near the top edge rather than clip.
        if origin.y < area.minY {
            origin.y = anchor.y + Self.anchorClearance - size.height / 2
        }
        origin.x = min(max(origin.x, area.minX), max(area.minX, area.maxX - size.width))
        origin.y = min(max(origin.y, area.minY), max(area.minY, area.maxY - size.height))
        frame.origin = origin
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        UIView.animate(withDuration: 0.15) {
            self.alpha = 0
        } completion: { _ in
            if !self.isShowing { self.isHidden = true }
        }
    }
}
#endif
