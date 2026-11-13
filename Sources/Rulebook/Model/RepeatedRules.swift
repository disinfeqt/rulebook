import Foundation

/// A rule that appears, in the same or similar words, in the instruction files of more than one project.
/// One that belongs everywhere could live in a global file instead.
struct RepeatedRule: Identifiable, Hashable, Sendable {
    struct Occurrence: Identifiable, Hashable, Sendable {
        let docID: String
        let projectID: String
        let project: String
        let file: String
        let line: Int
        /// The line as written, without its list marker.
        let text: String
        var id: String { "\(docID)#\(line)" }
    }

    /// The wording used most often.
    let text: String
    let occurrences: [Occurrence]
    /// How many different ways it's worded.
    let wordings: Int

    var id: String { occurrences.first?.id ?? text }
    var projectCount: Int { Set(occurrences.map(\.projectID)).count }
}

enum RepeatedRules {
    /// Lines that share at least this share of their words count as the same rule.
    static let similarity = 0.5

    /// Finds the rules in more than one project. It reads every line of prose and every list item,
    /// and skips headings, imports, code blocks and blocks written by tools, which are checked separately.
    static func find(in docs: [Doc]) -> [RepeatedRule] {
        struct Line { let occurrence: RepeatedRule.Occurrence; let key: String }
        var lines: [Line] = []
        for doc in docs.sorted(by: { $0.id < $1.id }) {
            for (line, text) in rules(in: doc.primary.content) {
                let key = normalized(text)
                guard key.split(separator: " ").count >= 2 else { continue }
                lines.append(Line(occurrence: .init(docID: doc.id, projectID: doc.projectID, project: doc.projectName,
                                                    file: doc.title, line: line, text: text), key: key))
            }
        }

        // Lines worded the same way are one key. Keys whose words mostly match are joined into one rule.
        let keys = Array(Set(lines.map(\.key))).sorted()
        let index = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        let words = keys.map(significantWords)
        var parent = Array(keys.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        var postings: [String: [Int]] = [:]
        for (i, set) in words.enumerated() where set.count >= 3 {
            for word in set { postings[word, default: []].append(i) }
        }
        for (i, set) in words.enumerated() where set.count >= 3 {
            var shared: [Int: Int] = [:]
            for word in set { for j in postings[word] ?? [] where j > i { shared[j, default: 0] += 1 } }
            for (j, count) in shared {
                let union = set.count + words[j].count - count
                if Double(count) / Double(union) >= similarity { parent[root(j)] = root(i) }
            }
        }

        var groups: [Int: [Line]] = [:]
        for line in lines { groups[root(index[line.key]!), default: []].append(line) }
        return groups.values.compactMap { group -> RepeatedRule? in
            let occurrences = group.map(\.occurrence)
            guard Set(occurrences.map(\.projectID)).count > 1 else { return nil }
            var counts: [String: Int] = [:]
            for line in group { counts[line.key, default: 0] += 1 }
            let common = counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }!.key
            let text = group.first { $0.key == common }!.occurrence.text
            return RepeatedRule(text: text, occurrences: occurrences.sorted { ($0.project, $0.file, $0.line) < ($1.project, $1.file, $1.line) },
                                wordings: counts.count)
        }
        .sorted { ($1.projectCount, $1.occurrences.count, $0.text) < ($0.projectCount, $0.occurrences.count, $1.text) }
    }

    /// Each line that states something, numbered from 1, without its list marker.
    static func rules(in text: String) -> [(line: Int, text: String)] {
        let blocks = MarkdownScan.managedBlocks(in: text).map(\.range)
        var result: [(Int, String)] = []
        var inFence = false
        var location = 0
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let start = location
            location += raw.utf16.count + 1
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence || line.isEmpty || blocks.contains(where: { NSLocationInRange(start, $0) }) { continue }
            if let rule = rule(inLine: line) { result.append((i + 1, rule)) }
        }
        return result
    }

    /// What a line says without its list marker, or nil for a heading, an import, markup or a divider.
    static func rule(inLine raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = line.first, !"#@<|".contains(first), !line.allSatisfy({ "-*_= ".contains($0) }) else { return nil }
        let stripped = line.replacingOccurrences(of: #"^(?:>\s*)?(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?"#,
                                                 with: "", options: .regularExpression)
        return stripped.isEmpty ? nil : stripped
    }

    // MARK: Moving a rule to the global files

    /// Whether a copy says nothing the rule doesn't, so it can go once the rule is global: the same wording, or
    /// as many sentences with mostly the same words and at most two of its own.
    static func isCovered(_ copy: String, by rule: String) -> Bool {
        let a = normalized(copy), b = normalized(rule)
        if a == b { return true }
        guard sentences(copy) <= sentences(rule) else { return false }
        let words = significantWords(a), ruleWords = significantWords(b)
        let union = words.union(ruleWords).count
        guard union > 0 else { return false }
        return Double(words.intersection(ruleWords).count) / Double(union) >= similarity
            && words.subtracting(ruleWords).count <= 2
    }

    /// How many sentences `text` has. A Latin stop ends one when a space follows; a Chinese one, when anything does.
    static func sentences(_ text: String) -> Int {
        text.trimmingCharacters(in: .whitespaces).matches(of: #/[.!?]\s|[。！？](?=.)/#).count + 1
    }

    /// Whether any line of `text` states `wording` in the same words.
    static func contains(_ wording: String, in text: String) -> Bool {
        let key = normalized(wording)
        return text.split(separator: "\n").contains { rule(inLine: String($0)).map(normalized) == key }
    }

    /// `text` with `rule` added as the last item of a list at its end, or as a new list after a blank line.
    static func appending(_ rule: String, to text: String) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "- \(rule)\n" }
        let body = text.hasSuffix("\n") ? text : text + "\n"
        let last = body.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let inList = last.range(of: #"^(?:[-*+]|\d+[.)])\s"#, options: .regularExpression) != nil && !body.hasSuffix("\n\n")
        return body + (inList ? "" : "\n") + "- \(rule)\n"
    }

    /// `text` without the line holding `copy`: the line it was found on if that still says it, or else the first
    /// line that does. Nil when no line says it any more.
    static func removing(_ copy: RepeatedRule.Occurrence, from text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        let says = { (i: Int) in rule(inLine: lines[i]) == copy.text }
        guard let index = lines.indices.contains(copy.line - 1) && says(copy.line - 1)
                ? copy.line - 1 : lines.indices.first(where: says) else { return nil }
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }

    /// The wording with case, emphasis, quotes and closing punctuation set aside.
    static func normalized(_ text: String) -> String {
        var s = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        while let last = s.last, ".;:!,。；：！，".contains(last) { s.removeLast() }
        return s
    }

    /// The words that carry the meaning: Latin words without common ones like "the" and "use", and pairs
    /// of Han characters, since Chinese isn't written with spaces.
    static func significantWords(_ key: String) -> Set<String> {
        var words = Set<String>()
        for match in key.matches(of: #/[a-z0-9][a-z0-9./+_-]*/#) {
            let word = String(match.output).trimmingCharacters(in: CharacterSet(charactersIn: "./-_+"))
            if word.count > 1, !stopWords.contains(word) { words.insert(word) }
        }
        for match in key.matches(of: #/\p{Han}+/#) {
            let run = Array(match.output)
            if run.count == 1 { words.insert(String(run)) }
            for i in 0..<max(0, run.count - 1) { words.insert(String(run[i...i + 1])) }
        }
        return words
    }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "by", "from", "as", "at", "is", "are",
        "be", "it", "its", "this", "that", "these", "those", "you", "your", "we", "our", "use", "using", "do", "don't",
        "dont", "not", "no", "never", "always", "only", "any", "all", "when", "if", "than", "then", "so", "should",
        "must", "can", "will", "instead", "into", "over", "per",
    ]
}
