#if DEBUG
import AppKit

/// Debug-only: `Type.app/Contents/MacOS/Type -TypeSnapshot /path/out.png file.md`
/// renders the key window to a PNG after launch (useful for headless UI checks).
private func findTextView(_ v: NSView?) -> TypeTextView? {
    guard let v else { return nil }
    if let tv = v as? TypeTextView { return tv }
    for sub in v.subviews { if let tv = findTextView(sub) { return tv } }
    return nil
}

enum DebugSnapshot {
    private static var activity: NSObjectProtocol?
    static func scheduleIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-TypeSnapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        // Off-screen (other Space) windows would otherwise let App Nap stall the timers below.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Debug snapshot")
        if let j = args.firstIndex(of: "-TypePasteTest"), j + 1 < args.count {
            let image = URL(fileURLWithPath: args[j + 1])
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.8) { DispatchQueue.main.async {
                guard let tv = NSApp.windows.lazy.compactMap({ findTextView($0.contentView) }).first else { NSLog("TypePaste: no text view"); return }
                let pb = NSPasteboard(name: .init("TypeDebugPaste"))
                pb.clearContents()
                pb.writeObjects([image as NSURL])
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                if let saved = tv.imagePasteHandler?(pb) { tv.insertImages(saved) ; NSLog("TypePaste: inserted \(saved.map(\.markdownPath))") }
            } }
        }
        DispatchQueue.main.async { waitForTextView(attempt: 0) { capture(path) } }
    }

    private static func waitForTextView(attempt: Int, then: @escaping () -> Void) {
        let found = NSApp.windows.contains { findTextView($0.contentView) != nil }
        if (found && attempt >= 6) || attempt > 30 { then(); return }
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.5)
            DispatchQueue.main.async { waitForTextView(attempt: attempt + 1, then: then) }
        }
    }

    private static func capture(_ path: String) {
        do {
            NSLog("TypeSnapshot windows: \(NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) id=\($0.identifier?.rawValue ?? "-")" })")
            guard let window = NSApp.windows.first(where: { $0.isVisible && findTextView($0.contentView) != nil }) ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            func walk(_ v: NSView, _ depth: Int) {
                if let tv = v as? NSTextView, let sv = tv.enclosingScrollView,
                   let r2 = sv.bitmapImageRepForCachingDisplay(in: sv.bounds) {
                    let vr = tv.bounds
                    if let r3 = tv.bitmapImageRepForCachingDisplay(in: vr) {
                        tv.cacheDisplay(in: vr, to: r3)
                        try? r3.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-text.png")))
                    }
                    if let s = tv.textStorage, s.length > 0 {
                        NSLog("TypeSnapshot attrs0=\(s.attributes(at: 0, effectiveRange: nil)) temp=\(tv.layoutManager?.temporaryAttributes(atCharacterIndex: 0, effectiveRange: nil) ?? [:]) glyphs=\(tv.layoutManager?.numberOfGlyphs ?? -1) wantsLayer=\(tv.wantsLayer) layer=\(String(describing: tv.layer))")
                    }
                    sv.cacheDisplay(in: sv.bounds, to: r2)
                    try? r2.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-editor.png")))
                }
                if let tv = v as? NSTextView, let lm = tv.layoutManager, ProcessInfo.processInfo.arguments.contains("-TypeDumpLines") {
                    var dump = ""
                    var g = 0
                    while g < lm.numberOfGlyphs {
                        var r = NSRange()
                        let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &r)
                        let cr = lm.characterRange(forGlyphRange: r, actualGlyphRange: nil)
                        let text = (tv.string as NSString).substring(with: cr).replacingOccurrences(of: "\n", with: "⏎")
                        dump += "y=\(Int(frag.minY)) h=\(Int(frag.height)) \(text.prefix(40))\n"
                        g = NSMaxRange(r)
                    }
                    for sub in tv.subviews where sub is ImageBlockView { dump += "imageView frame=\(sub.frame)\n" }
                    try? dump.write(toFile: path.replacingOccurrences(of: ".png", with: "-lines.txt"), atomically: true, encoding: .utf8)
                }
                if let tv = v as? NSTextView {
                    NSLog("TypeSnapshot textView frame=\(tv.frame) visible=\(tv.visibleRect) inset=\(tv.textContainerInset) len=\(tv.string.count) super=\(String(describing: tv.superview?.frame)) scroll=\(String(describing: tv.enclosingScrollView?.frame)) hidden=\(tv.isHiddenOrHasHiddenAncestor) alpha=\(tv.enclosingScrollView?.alphaValue ?? -1)")
                }
                v.subviews.forEach { walk($0, depth + 1) }
            }
            walk(view, 0)
            for top in NSApp.mainMenu?.items ?? [] {
                let items = top.submenu?.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "—" : ($0.title + ($0.submenu.map { "[" + $0.items.map(\.title).joined(separator: ",") + "]" } ?? "")) } ?? []
                NSLog("TypeMenu \(top.title): \(items.joined(separator: " | "))")
            }
            NSLog("TypeSnapshot toolbar visible=\(window.toolbar?.isVisible ?? false) items=\(window.toolbar?.items.count ?? -1)")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
