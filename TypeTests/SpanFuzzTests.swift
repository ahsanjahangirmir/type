import XCTest
import AppKit
@testable import TypeApp

/// A small seeded generator, so failures reproduce.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var x = state
        x ^= x >> 33; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33
        return x
    }
}

@MainActor
func markerProblems(_ e: LiveEditor) -> String? {
    let s = e.tv.textStorage!
    let ns = e.text as NSString
    var escaped = Set<Int>()
    var location = 0
    while location < ns.length {
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        let text = ns.substring(with: line) as NSString
        for b in MarkdownEscapes.scan(text).escapes { escaped.insert(line.location + b + 1) }
        location = NSMaxRange(line)
    }
    for i in 0..<ns.length {
        let c = ns.character(at: i)
        guard "*_~=`".utf16.contains(c), !escaped.contains(i) else { continue }
        if s.attribute(.typeHidden, at: i, effectiveRange: nil) != nil { continue }
        if s.attribute(.typeGlyph, at: i, effectiveRange: nil) != nil || s.attribute(.typeCode, at: i, effectiveRange: nil) != nil { continue }
        return "visible marker \(Character(UnicodeScalar(c)!)) at \(i) in \(e.text.debugDescription)"
    }
    return nil
}

@MainActor
final class AdjacentPendingFormatTests: XCTestCase {
    private let formats: [(name: String, wrap: (String) -> String, toggle: (EditorController) -> Void)] = [
        ("bold", { "**\($0)**" }, { $0.bold() }),
        ("italic", { "*\($0)*" }, { $0.italic() }),
        ("strike", { "~~\($0)~~" }, { $0.strikethrough() }),
        ("highlight", { "==\($0)==" }, { $0.highlight() }),
        ("code", { "`\($0)`" }, { $0.inlineCode() }),
    ]

    func testPendingFormatNextToEverySpan() {
        for base in formats {
            for pending in formats {
                for after in [false, true] {
                    let span = base.wrap("x")
                    let e = LiveEditor(span)
                    defer { e.close() }
                    e.caret(at: after ? 0 : (span as NSString).length)
                    pending.toggle(e.controller)
                    e.type("y z")
                    let label = "\(base.name) + pending \(pending.name), typed \(after ? "before" : "after"): \(e.text.debugDescription)"
                    XCTAssertNil(markerProblems(e), label)
                    XCTAssertEqual(e.visible, after ? "y zx" : "xy z", label)
                }
            }
        }
    }
}

@MainActor
final class SpanFuzzTests: XCTestCase {
    private let seeds = [
        "**a ==b== c**", "==a **b** c==", "*a **b** c*", "***ab*** cd", "~~a ==b== c~~", "`a` **b** ==c==",
        "**a**==b==*c*", "- **a ==b==**\n- *c*", "> ~~a~~ **b**", "x **a *b* c** y", "==**a**== ~~*b*~~",
    ]
    private let alphabet = Array("ab c.*_=~`\\#-1>[|") + ["\n"]

    func testRandomKeystrokesNeverExposeMarkers() {
        var rng = SeededRNG(state: UInt64(ProcessInfo.processInfo.environment["FUZZ_SEED"] ?? "") ?? 20260512)
        for seed in seeds {
            var e = LiveEditor(seed)
            defer { e.close() }
            var history: [String] = []
            for step in 0..<190 {
                let len = (e.text as NSString).length
                let pos = Int.random(in: 0...len, using: &rng)
                e.caret(at: pos)
                let action = Int.random(in: 0..<10, using: &rng)
                let before = e.text
                let caretBefore = e.tv.selectedRange().location
                switch action {
                case 0: e.tv.deleteBackward(nil)
                case 1: e.tv.deleteForward(nil)
                case 2: e.type("\n")
                case 3: e.type(" ")
                default: e.type(String(alphabet.randomElement(using: &rng)!))
                }
                history.append("\(pos):\(action)")
                if let problem = markerProblems(e) {
                    XCTFail("seed \(seed.debugDescription) step \(step): \(problem)\n(before \(before.debugDescription) caret \(caretBefore) action \(action) -> \(e.text.debugDescription) caret \(e.tv.selectedRange().location))")
                    break
                }
                if (e.text as NSString).length > 200 || e.text.isEmpty {
                    e.close()
                    e = LiveEditor(seed)
                }
            }
        }
    }
}
