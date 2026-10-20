import AppKit
import QuartzCore

/// An inline image block drawn over its (hidden) Markdown line: rounded
/// corners, a soft shadow, and glass resize handles on hover.
final class ImageBlockView: NSView {
    weak var textView: TypeTextView?
    private(set) var spec: ImageSpec?
    private(set) var sourceRange = NSRange(location: 0, length: 0)

    private let imageLayer = CALayer()
    private let ringLayer = CALayer()
    private let edgeHandle = ImageBlockView.makeHandle()
    private let cornerHandle = ImageBlockView.makeHandle()
    private let sizeBadge = ImageBlockView.makeBadge()
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { updateChrome() } }
    var isSelected = false { didSet { if isSelected != oldValue { updateChrome() } } }

    private enum Drag { case none, edge, corner }
    private var drag: Drag = .none
    private var dragStart: NSPoint = .zero
    private var startWidth: CGFloat = 0
    private var aspect: CGFloat = 1
    private static let radius: CGFloat = 12

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        imageLayer.cornerRadius = Self.radius
        imageLayer.cornerCurve = .continuous
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.borderWidth = 0.5
        layer?.addSublayer(imageLayer)

        ringLayer.cornerRadius = Self.radius + 3
        ringLayer.cornerCurve = .continuous
        ringLayer.borderWidth = 3
        ringLayer.isHidden = true
        layer?.addSublayer(ringLayer)

        for v in [edgeHandle, cornerHandle, sizeBadge] {
            v.isHidden = true
            addSubview(v)
        }
        toolTip = nil
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(image: NSImage?, spec: ImageSpec, range: NSRange) {
        self.spec = spec
        sourceRange = range
        if let image, imageLayer.contents as? NSImage !== image {
            imageLayer.contents = image
            aspect = image.size.width > 0 ? image.size.height / image.size.width : 1
        }
        toolTip = spec.alt.isEmpty ? nil : spec.alt
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        ringLayer.frame = bounds.insetBy(dx: -4, dy: -4)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        CATransaction.commit()
        let hw: CGFloat = 8, hh = min(56, bounds.height * 0.35)
        edgeHandle.frame = NSRect(x: bounds.maxX - hw - 6, y: bounds.midY - hh / 2, width: hw, height: hh)
        cornerHandle.frame = NSRect(x: bounds.maxX - 22, y: bounds.maxY - 22, width: 16, height: 16)
        sizeBadge.frame = NSRect(x: bounds.minX + 10, y: bounds.minY + 10, width: 96, height: 24)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateChrome()
    }

    private func updateChrome() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            imageLayer.borderColor = NSColor.separatorColor.cgColor
            ringLayer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        }
        ringLayer.isHidden = !isSelected
        let showHandles = (hovering || isSelected) && drag == .none || drag != .none
        edgeHandle.isHidden = !showHandles
        cornerHandle.isHidden = !showHandles
        sizeBadge.isHidden = drag == .none
    }

    // MARK: Hover & cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func resetCursorRects() {
        addCursorRect(edgeHandle.frame.insetBy(dx: -6, dy: -6), cursor: .frameResize(position: .right, directions: .all))
        addCursorRect(cornerHandle.frame.insetBy(dx: -4, dy: -4), cursor: .frameResize(position: .bottomRight, directions: .all))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if cornerHandle.frame.insetBy(dx: -6, dy: -6).contains(p) { drag = .corner }
        else if edgeHandle.frame.insetBy(dx: -8, dy: -8).contains(p) { drag = .edge }
        else { drag = .none }

        if drag == .none {
            if event.clickCount == 2, let spec, let url = textView?.resolveImageURL(spec.path) {
                NSWorkspace.shared.open(url)
                return
            }
            textView?.selectImage(self)
            return
        }
        dragStart = event.locationInWindow
        startWidth = bounds.width
        updateChrome()
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != .none, let tv = textView else { return }
        let rtl = tv.baseWritingDirection == .rightToLeft
        var dx = event.locationInWindow.x - dragStart.x
        if rtl { dx = -dx }
        if drag == .corner {
            // Corner drags follow whichever axis moved more, preserving aspect.
            let dy = -(event.locationInWindow.y - dragStart.y)
            if abs(dy / max(aspect, 0.01)) > abs(dx) { dx = dy / max(aspect, 0.01) }
        }
        let width = min(max(80, startWidth + dx), tv.columnWidth).rounded()
        let newSize = NSSize(width: width, height: (width * aspect).rounded())
        var f = frame
        if rtl { f.origin.x = f.maxX - newSize.width }
        f.size = newSize
        frame = f
        (sizeBadge.contentView as? NSTextField)?.stringValue = "\(Int(newSize.width)) × \(Int(newSize.height))"
        updateChrome()
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != .none else { return }
        drag = .none
        updateChrome()
        if abs(bounds.width - startWidth) >= 1, let spec { textView?.commitImageWidth(Int(bounds.width), spec: spec, range: sourceRange) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let spec, let tv = textView else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Actual Size") { tv.commitImageWidth(nil, spec: spec, range: self.sourceRange) })
        menu.addItem(ClosureMenuItem(title: "Fit Width") { tv.commitImageWidth(Int(tv.columnWidth), spec: spec, range: self.sourceRange) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Copy Image") {
            if let img = self.imageLayer.contents as? NSImage {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([img])
            }
        })
        if let url = tv.resolveImageURL(spec.path) {
            menu.addItem(ClosureMenuItem(title: "Open in Preview") { NSWorkspace.shared.open(url) })
            menu.addItem(ClosureMenuItem(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Delete Image") { tv.deleteImage(range: self.sourceRange) })
        return menu
    }

    // MARK: Chrome factories

    private static func makeHandle() -> NSGlassEffectView {
        let v = NSGlassEffectView()
        v.cornerRadius = 8
        v.tintColor = NSColor.white.withAlphaComponent(0.25)
        return v
    }

    private static func makeBadge() -> NSGlassEffectView {
        let v = NSGlassEffectView()
        v.cornerRadius = 12
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.textColor = .labelColor
        v.contentView = label
        return v
    }
}
