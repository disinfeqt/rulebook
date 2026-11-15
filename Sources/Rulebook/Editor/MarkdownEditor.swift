import AppKit
import SwiftUI

/// Lets other views select text in, or focus, the current editor.
@MainActor
final class EditorController {
    weak var textView: NSTextView?

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    func reveal(_ needle: String, beep: Bool = true) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let candidates = [needle, needle.trimmingCharacters(in: .whitespacesAndNewlines),
                          needle.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""]
        for c in candidates where !c.isEmpty {
            var r = ns.range(of: c)
            if r.location == NSNotFound { r = ns.range(of: c, options: [.caseInsensitive, .diacriticInsensitive]) }
            if r.location != NSNotFound { select(r); return }
        }
        if beep { NSSound.beep() }
    }

    func reveal(line: Int) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        var location = 0, current = 1
        while current < line, location < ns.length {
            let r = ns.lineRange(for: NSRange(location: location, length: 0))
            location = r.location + r.length
            current += 1
        }
        select(ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0)))
    }

    private func select(_ r: NSRange) {
        guard let tv = textView else { return }
        tv.setSelectedRange(r)
        tv.scrollRangeToVisible(r)
        tv.showFindIndicator(for: r)
        focus()
    }
}

/// One text view serves every file: building a new one for each was a quarter of what switching files cost.
/// Each file keeps its own undo history, and starts at its top.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    /// Which file the text is. When it changes, the view is showing another file, not an edit to this one.
    let docID: String
    let baseDir: URL
    /// A SKILL.md: it opens with frontmatter, and an `@path` in it is plain text, not an import.
    var isSkill = false
    let controller: EditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = RulesTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.textContainerInset = NSSize(width: 26, height: 22)
        tv.font = MarkdownHighlighter.font
        tv.typingAttributes = MarkdownHighlighter.baseAttributes
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.insertionPointColor = .controlAccentColor
        tv.string = text
        MarkdownHighlighter.highlight(tv.textStorage!, baseDir: baseDir, isSkill: isSkill)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        context.coordinator.textView = tv
        controller.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent.docID
        coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if previous != docID {
            // Another file. Its text goes in without an undo step: undoing must never bring back the last file.
            coordinator.leave(previous, with: tv.string)
            coordinator.isApplyingExternalChange = true
            tv.breakUndoCoalescing()
            tv.string = text
            MarkdownHighlighter.highlight(tv.textStorage!, baseDir: baseDir, isSkill: isSkill)
            coordinator.isApplyingExternalChange = false
            coordinator.enter(docID, with: text)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.scrollToBeginningOfDocument(nil)
            tv.needsDisplay = true
            return
        }
        guard tv.string != text else { return }
        // External change (revert, a fix, a Claude revision): replace through the text system so it's undoable.
        coordinator.isApplyingExternalChange = true
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        if tv.shouldChangeText(in: full, replacementString: text) {
            tv.textStorage?.replaceCharacters(in: full, with: text)
            tv.didChangeText()
        }
        MarkdownHighlighter.highlight(tv.textStorage!, baseDir: baseDir, isSkill: isSkill)
        coordinator.isApplyingExternalChange = false
        tv.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?
        var isApplyingExternalChange = false
        /// An undo history per file, and the text each one's steps apply to.
        private var undo: [String: UndoManager] = [:]
        private var left: [String: String] = [:]

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? {
            if let manager = undo[parent.docID] { return manager }
            let manager = UndoManager()
            undo[parent.docID] = manager
            return manager
        }

        func leave(_ docID: String, with text: String) { left[docID] = text }

        /// A file's undo steps only fit the text they were made on. If it comes back different, because it was
        /// saved over, reverted or changed on disk, they're dropped.
        func enter(_ docID: String, with text: String) {
            if left[docID] != text { undo[docID]?.removeAllActions() }
            left[docID] = nil
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView, !isApplyingExternalChange else { return }
            MarkdownHighlighter.highlight(tv.textStorage!, baseDir: parent.baseDir, isSkill: parent.isSkill)
            parent.text = tv.string
        }
    }
}

/// The editor's text view, with each line's number in the margin, since audits point to lines by number.
/// The numbers sit in an indent every paragraph has, not in a ruler, so the text keeps its margin on the right.
/// A long line that wraps is numbered once, and the lines the selection is on are numbered a shade darker.
final class RulesTextView: NSTextView {
    /// How far the text moves right to make room for the numbers.
    static let gutter: CGFloat = 14
    private static let numberFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private var scrollObserver: NSObjectProtocol?

    /// Where the text starts, and the numbers end a little before.
    private var textStart: CGFloat { textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0) + Self.gutter }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard rect.minX < textStart else { return }
        let ns = string as NSString
        let origin = textContainerOrigin
        let selection = selectedRange()
        let active = window?.firstResponder === self
        // Lines are counted from the first one drawn, so a redraw near the end of a long file doesn't count from the top.
        var counted = 0, newlines = 0

        func number(at offset: Int, baseline: CGFloat) {
            guard offset == 0 || (offset <= ns.length && ns.character(at: offset - 1) == 10) else { return }
            while counted < offset { if ns.character(at: counted) == 10 { newlines += 1 }; counted += 1 }
            let line = ns.lineRange(for: NSRange(location: offset, length: 0))
            let current = active && (NSIntersectionRange(line, selection).length > 0
                || (selection.location >= line.location && selection.location < NSMaxRange(line))
                || (selection.location == ns.length && NSMaxRange(line) == ns.length && !ns.hasSuffix("\n")))
            let label = NSAttributedString(string: String(newlines + 1), attributes: [
                .font: Self.numberFont,
                .foregroundColor: current ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
            ])
            label.draw(at: NSPoint(x: textStart - 12 - label.size().width, y: baseline - Self.numberFont.ascender))
        }

        if let layout = textLayoutManager, let content = layout.textContentManager {
            // TextKit 2 puts the space between lines above a line of text, but inside the height of an empty one,
            // so the baseline is found from the bottom of the line.
            let font = MarkdownHighlighter.font
            let height = ceil(font.ascender) + ceil(-font.descender)
            let top = CGPoint(x: 0, y: max(0, rect.minY - origin.y))
            let start = layout.textLayoutFragment(for: top)?.rangeInElement.location ?? layout.documentRange.location
            layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
                let frame = fragment.layoutFragmentFrame
                guard frame.minY + origin.y <= rect.maxY else { return false }
                let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
                guard let first = fragment.textLineFragments.first else { return true }
                number(at: offset, baseline: origin.y + frame.minY + first.typographicBounds.maxY - height + first.glyphOrigin.y)
                return true
            }
        } else if let layout = layoutManager, let container = textContainer {
            // TextKit 1, which the view falls back to if anything asks for its layout manager.
            let glyphs = layout.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
            layout.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, range, _ in
                number(at: layout.characterIndexForGlyph(at: range.location),
                       baseline: origin.y + lineRect.minY + layout.location(forGlyphAt: range.location).y)
            }
        }
    }

    /// The numbers are drawn with the background, which an edit, a scroll or a new selection doesn't always redraw.
    private func redrawNumbers() {
        let visible = visibleRect
        setNeedsDisplay(NSRect(x: 0, y: visible.minY, width: textStart, height: visible.height))
    }

    override func didChangeText() { super.didChangeText(); redrawNumbers() }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); redrawNumbers() }
    override func becomeFirstResponder() -> Bool { defer { redrawNumbers() }; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { defer { redrawNumbers() }; return super.resignFirstResponder() }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        redrawNumbers()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.redrawNumbers() }
        }
    }
}

@MainActor
enum MarkdownHighlighter {
    static let size: CGFloat = 13
    static let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    static let bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
    static let semibold = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
    static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        // Room on the left for the line numbers.
        p.firstLineHeadIndent = RulesTextView.gutter
        p.headIndent = RulesTextView.gutter
        return p
    }()
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    static let heading = try! NSRegularExpression(pattern: "^(#{1,6})[ \\t]+.*$", options: [.anchorsMatchLines])
    static let list = try! NSRegularExpression(pattern: "^[ \\t]*([-*+]|\\d+[.)])[ \\t]", options: [.anchorsMatchLines])
    static let quote = try! NSRegularExpression(pattern: "^>.*$", options: [.anchorsMatchLines])
    static let strong = try! NSRegularExpression(pattern: "\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__")
    static let link = try! NSRegularExpression(pattern: "\\[([^\\]\\n]+)\\]\\(([^)\\n]+)\\)")
    static let frontmatterKey = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_-]*:", options: [.anchorsMatchLines])

    static func highlight(_ storage: NSTextStorage, baseDir: URL, isSkill: Bool = false) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)

        func apply(_ re: NSRegularExpression, group: Int = 0, _ attrs: [NSAttributedString.Key: Any]) {
            for m in re.matches(in: text, range: full) {
                let r = m.range(at: group)
                if r.location != NSNotFound { storage.addAttributes(attrs, range: r) }
            }
        }

        for block in MarkdownScan.managedBlocks(in: text) {
            storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.08), range: block.range)
        }
        apply(heading, [.font: bold])
        apply(heading, group: 1, [.foregroundColor: NSColor.tertiaryLabelColor])
        apply(list, group: 1, [.foregroundColor: NSColor.secondaryLabelColor])
        apply(quote, [.foregroundColor: NSColor.secondaryLabelColor])
        apply(strong, [.font: bold])
        apply(link, group: 2, [.foregroundColor: NSColor.linkColor])

        let fences = MarkdownScan.fencedRanges(in: text)
        for r in fences {
            storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .font: font], range: r)
        }
        // Inline code keeps the text color, with its backticks dimmed, so a file full of commands stays readable.
        for r in MarkdownScan.inlineCodeRanges(in: text, excluding: fences) {
            let ticks = (text as NSString).substring(with: r).prefix { $0 == "`" }.count
            guard r.length >= ticks * 2 else { continue }
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: NSRange(location: r.location, length: ticks))
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                                 range: NSRange(location: r.location + r.length - ticks, length: ticks))
        }
        apply(MarkdownScan.commentRegex, [.foregroundColor: NSColor.tertiaryLabelColor])
        if isSkill, let front = SkillScan.frontmatter(in: text), front.closed {
            // The block agents read first: its keys step back, so the name and description stand out.
            for m in frontmatterKey.matches(in: text, range: front.range) {
                storage.addAttributes([.font: font, .foregroundColor: NSColor.secondaryLabelColor], range: m.range)
            }
            for edge in [NSRange(location: 0, length: 3), NSRange(location: NSMaxRange(front.range) - 4, length: 3)]
            where (text as NSString).substring(with: edge) == "---" {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: edge)
            }
        }
        for imp in isSkill ? [] : MarkdownScan.imports(in: text, baseDir: baseDir) {
            var attrs: [NSAttributedString.Key: Any] = [.font: semibold,
                                                        .foregroundColor: imp.exists ? NSColor.controlAccentColor : NSColor.systemOrange]
            if !imp.exists {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                attrs[.underlineColor] = NSColor.systemOrange
            }
            storage.addAttributes(attrs, range: imp.range)
        }
        storage.endEditing()
    }
}
