import Foundation

struct ImportRef: Hashable, Identifiable, Sendable {
    /// The import as written, including the leading `@`.
    let raw: String
    /// The path Claude Code would load (escapes removed).
    let path: String
    let resolved: URL
    let exists: Bool
    let range: NSRange
    let line: Int
    var id: String { "\(range.location):\(raw)" }
}

struct ManagedBlock: Hashable, Identifiable, Sendable {
    let name: String
    let range: NSRange
    let body: String
    let line: Int
    var id: String { "\(name)@\(range.location)" }
    var normalizedBody: String { MarkdownScan.normalized(body) }
}

struct TextStats: Hashable, Sendable {
    let lines: Int
    let words: Int
    let characters: Int
    let tokens: Int
}

enum MarkdownScan {
    static let fenceRegex = try! NSRegularExpression(
        pattern: "^[ \\t]{0,3}(`{3,}|~{3,})[^\\n]*$[\\s\\S]*?(?:^[ \\t]{0,3}\\1[ \\t]*$|\\z)",
        options: [.anchorsMatchLines])
    static let inlineCodeRegex = try! NSRegularExpression(pattern: "``[^\\n]+?``|`[^`\\n]+`")
    static let importRegex = try! NSRegularExpression(pattern: "(?<![^\\s])@((?:\\\\ |[^\\s])+)")
    static let commentRegex = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->")
    static let blockDashRegex = try! NSRegularExpression(
        pattern: "<!--\\s*([A-Za-z0-9_.:-]+?)[-_](?:start|begin)\\s*-->([\\s\\S]*?)<!--\\s*\\1[-_]end\\s*-->",
        options: [.caseInsensitive])
    static let blockBeginRegex = try! NSRegularExpression(
        pattern: "<!--\\s*BEGIN[:\\s]\\s*([A-Za-z0-9_.:/-]+)\\s*-->([\\s\\S]*?)<!--\\s*END[:\\s]\\s*\\1\\s*-->",
        options: [.caseInsensitive])
    static let titleRegex = try! NSRegularExpression(
        pattern: "\\A\\s*#[ \\t]+((?:CLAUDE|AGENTS)\\.md)[ \\t]*$",
        options: [.anchorsMatchLines, .caseInsensitive])

    // MARK: Code

    static func fencedRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        return fenceRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
    }

    static func inlineCodeRanges(in text: String, excluding fences: [NSRange]) -> [NSRange] {
        let ns = text as NSString
        return inlineCodeRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map(\.range)
            .filter { r in !fences.contains { NSLocationInRange(r.location, $0) } }
    }

    static func codeRanges(in text: String) -> [NSRange] {
        let fences = fencedRanges(in: text)
        return fences + inlineCodeRanges(in: text, excluding: fences)
    }

    // MARK: Imports

    static func imports(in text: String, baseDir: URL) -> [ImportRef] {
        let ns = text as NSString
        let code = codeRanges(in: text)
        var result: [ImportRef] = []
        for m in importRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if code.contains(where: { NSLocationInRange(m.range.location, $0) }) { continue }
            var pathRange = m.range(at: 1)
            var path = ns.substring(with: pathRange).replacingOccurrences(of: "\\ ", with: " ")
            var url = resolve(path, baseDir: baseDir)
            var exists = isFile(url)
            if !exists {
                // "See @AGENTS.md." — drop trailing punctuation, which is almost never part of the path.
                var trimmed = path
                while let last = trimmed.last, ".,;:!?)]}'\"".contains(last) { trimmed.removeLast() }
                if trimmed != path, !trimmed.isEmpty {
                    pathRange.length -= (path as NSString).length - (trimmed as NSString).length
                    path = trimmed
                    url = resolve(trimmed, baseDir: baseDir)
                    exists = isFile(url)
                }
            }
            guard !path.isEmpty else { continue }
            // A directory (e.g. the `@/` path alias) can't be imported; Claude Code ignores it.
            var isDir: ObjCBool = false
            if !exists, path.hasSuffix("/") || (FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue) {
                continue
            }
            let full = NSRange(location: m.range.location, length: pathRange.location + pathRange.length - m.range.location)
            let line = lineNumber(at: full.location, in: ns)
            result.append(ImportRef(raw: ns.substring(with: full), path: path, resolved: url, exists: exists, range: full, line: line))
        }
        return result
    }

    static func resolve(_ path: String, baseDir: URL) -> URL {
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
        }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return baseDir.appendingPathComponent(path).standardizedFileURL
    }

    static func isFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// True when the text holds nothing but the given imports, headings, comments and whitespace.
    static func isOnlyImports(_ text: String, removing imports: [ImportRef]) -> Bool {
        let ns = NSMutableString(string: text)
        for imp in imports.sorted(by: { $0.range.location > $1.range.location }) {
            ns.replaceCharacters(in: imp.range, with: "")
        }
        let stripped = commentRegex.stringByReplacingMatches(
            in: ns as String, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        for line in stripped.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            return false
        }
        return true
    }

    // MARK: Managed blocks

    static func managedBlocks(in text: String) -> [ManagedBlock] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var blocks: [ManagedBlock] = []
        for re in [blockDashRegex, blockBeginRegex] {
            for m in re.matches(in: text, range: all) {
                let name = ns.substring(with: m.range(at: 1))
                let body = ns.substring(with: m.range(at: 2))
                blocks.append(ManagedBlock(name: name, range: m.range, body: body, line: lineNumber(at: m.range.location, in: ns)))
            }
        }
        return blocks.sorted { $0.range.location < $1.range.location }
    }

    static func removingBlocks(_ names: [String], from text: String) -> String {
        let wanted = Set(names.map { $0.lowercased() })
        let ns = NSMutableString(string: text)
        for block in managedBlocks(in: text).reversed() where wanted.contains(block.name.lowercased()) {
            var r = block.range
            // Swallow the blank lines that follow so no gap is left behind.
            while r.location + r.length < ns.length {
                let c = ns.character(at: r.location + r.length)
                if c == 10 || c == 13 || c == 32 || c == 9 { r.length += 1 } else { break }
            }
            ns.replaceCharacters(in: r, with: "")
        }
        var result = ns as String
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result
    }

    static func stripBlocks(_ text: String) -> String {
        let ns = NSMutableString(string: text)
        for block in managedBlocks(in: text).reversed() { ns.replaceCharacters(in: block.range, with: "") }
        return ns as String
    }

    // MARK: Text helpers

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var s = String(line)
                while let last = s.last, last == " " || last == "\t" { s.removeLast() }
                return s
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stats(_ text: String) -> TextStats {
        let lines: Int
        if text.isEmpty { lines = 0 } else {
            let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
            lines = parts.last?.isEmpty == true ? parts.count - 1 : parts.count
        }
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let tokens = Int((Double(text.utf8.count) / 3.7).rounded())
        return TextStats(lines: lines, words: words, characters: text.count, tokens: tokens)
    }

    static func lineNumber(at location: Int, in ns: NSString) -> Int {
        var line = 1
        var i = 0
        let end = min(location, ns.length)
        while i < end {
            if ns.character(at: i) == 10 { line += 1 }
            i += 1
        }
        return line
    }

    /// The `# CLAUDE.md` / `# AGENTS.md` title on the first line, if any.
    static func fileTitle(in text: String) -> (name: String, range: NSRange)? {
        let ns = text as NSString
        guard let m = titleRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: m.range(at: 1)), m.range(at: 1))
    }

    static func retitled(_ text: String, to name: String) -> String {
        guard let title = fileTitle(in: text) else { return text }
        return (text as NSString).replacingCharacters(in: title.range, with: name)
    }

    static func wrappingInBackticks(_ raw: String, in text: String) -> String {
        let ns = text as NSString
        let code = codeRanges(in: text)
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: raw, options: [], range: search)
            if r.location == NSNotFound { return text }
            if !code.contains(where: { NSLocationInRange(r.location, $0) }) {
                return ns.replacingCharacters(in: r, with: "`\(raw)`")
            }
            search = NSRange(location: r.location + r.length, length: ns.length - r.location - r.length)
        }
    }

    /// Meaningful lines of `text` that also appear in `other`, ignoring managed blocks, headings and imports.
    static func sharedLineCount(_ text: String, _ other: String) -> Int {
        func lines(_ s: String) -> [String] {
            stripBlocks(s).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count >= 12 && !$0.hasPrefix("#") && !$0.hasPrefix("@") }
        }
        let theirs = Set(lines(other))
        return lines(text).filter { theirs.contains($0) }.count
    }
}
