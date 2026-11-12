import AppKit
import QuartzCore

/// Draws the editor's caret: a font-height bar that glides between positions
/// and blinks softly, plus the fading "ghosts" of deleted characters.
/// It sits over the text view and never takes mouse events.
final class CaretOverlay: NSView {
    private let bar = CALayer()
    private(set) var target: NSRect = .null

    /// Caret glide duration; short enough to never lag behind fast typing.
    static let glideDuration: CFTimeInterval = 0.09
    static let ghostDuration: CFTimeInterval = 0.16

    var color: NSColor = .controlAccentColor {
        didSet { updateColor() }
    }

    var isCaretVisible = false {
        didSet {
            guard isCaretVisible != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.isHidden = !isCaretVisible
            CATransaction.commit()
            if isCaretVisible { restartBlink() }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        bar.cornerRadius = 1
        bar.cornerCurve = .continuous
        bar.isHidden = true
        bar.actions = ["hidden": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(bar)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bar.backgroundColor = color.cgColor
        }
    }

    /// Moves the caret to `rect`, gliding there when `animated`.
    func move(to rect: NSRect, animated: Bool) {
        let rect = backingAlignedRect(rect, options: .alignAllEdgesNearest)
        guard rect != target else { return }
        let from = bar.presentation()?.frame ?? bar.frame
        target = rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.frame = rect
        CATransaction.commit()
        if animated, !from.isEmpty, !bar.isHidden {
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: NSPoint(x: from.midX, y: from.midY))
            move.toValue = NSValue(point: NSPoint(x: rect.midX, y: rect.midY))
            let size = CABasicAnimation(keyPath: "bounds.size")
            size.fromValue = NSValue(size: from.size)
            size.toValue = NSValue(size: rect.size)
            let group = CAAnimationGroup()
            group.animations = [move, size]
            group.duration = Self.glideDuration
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.3, 1)
            bar.add(group, forKey: "glide")
        } else {
            bar.removeAnimation(forKey: "glide")
        }
        restartBlink()
    }

    /// Solid while the caret moves; after a pause it breathes on and off.
    func restartBlink() {
        bar.removeAnimation(forKey: "blink")
        guard isCaretVisible else { return }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0, 1]
        blink.keyTimes = [0, 0.42, 0.55, 0.88, 1]
        blink.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut),
                                 CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut)]
        blink.duration = 1.1
        blink.repeatCount = .infinity
        blink.beginTime = bar.convertTime(CACurrentMediaTime(), from: nil) + 0.6
        blink.fillMode = .backwards
        bar.add(blink, forKey: "blink")
    }

    /// Fades an image of just-deleted text out where it was drawn.
    func fadeOutGhost(_ image: CGImage, frame: NSRect) {
        let ghost = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.contents = image
        ghost.contentsGravity = .resize
        ghost.frame = frame
        ghost.opacity = 0
        layer?.insertSublayer(ghost, below: bar)
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        fade.duration = Self.ghostDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ghost.add(fade, forKey: "fade")
        CATransaction.commit()
    }
}
