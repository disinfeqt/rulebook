import CryptoKit
import Foundation

/// A folder agents look in for skills. Which one a skill sits in decides who loads it.
enum SkillHome: String, Hashable, Sendable, CaseIterable {
    /// `.agents/skills`, read by Codex and most other agents.
    case agents
    /// `.claude/skills`, read by Claude Code.
    case claude
    /// `~/.codex/skills`, Codex's own folder. Only in the home folder.
    case codex

    var folder: String { ".\(rawValue)/skills" }
}

/// A file of a skill other than its SKILL.md.
struct SkillFile: Hashable, Sendable, Identifiable {
    /// Relative to the skill's folder.
    let path: String
    let size: Int
    var id: String { path }
}

/// What a `Doc` carries when it is the SKILL.md of a skill.
struct SkillInfo: Hashable, Sendable {
    /// The folder's name, which is what agents call the skill.
    let name: String
    /// The folder as found. It may be a link.
    let dir: URL
    let home: SkillHome
    /// Every folder agents reach this skill through: its own, its copies' and its links'.
    let homes: [SkillHome]
    let isGlobal: Bool
    /// Downloaded from the claude.ai account, which replaces changes made here.
    let isSynced: Bool
    /// Folders with the same SKILL.md, saved together with this one.
    let copies: [URL]
    /// Links that point at this folder.
    let links: [URL]
    /// Whether the copies match in every file, not only in SKILL.md.
    let copiesIdentical: Bool
    let files: [SkillFile]
    /// Where `npx skills` installed it from, such as "vercel-labs/agent-skills". Nil for a skill it doesn't manage.
    var source: String? = nil
}

/// A row of the Skills list: a skill, or something in a skills folder that isn't one.
struct SkillEntry: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let projectID: String
    let projectName: String
    let dir: URL
    /// Nil for a link that points nowhere and for an empty folder.
    let docID: String?
    /// What's wrong with an entry that has no SKILL.md to open.
    var issue: Issue? = nil
}

/// The YAML block at the top of a SKILL.md, read as far as Rulebook needs it: plain `key: value` pairs.
struct Frontmatter: Hashable, Sendable {
    var fields: [String: String] = [:]
    /// The block with both `---` lines, in UTF-16 units.
    var range = NSRange(location: 0, length: 0)
    /// False when the closing `---` is missing.
    var closed = false
    /// Where the value of `name` is written.
    var nameRange: NSRange?

    var name: String? { fields["name"].flatMap { $0.isEmpty ? nil : $0 } }
    /// What agents match a request against. Claude Code adds `when_to_use` to it.
    var description: String {
        [fields["description"], fields["when_to_use"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

enum SkillScan {
    /// The Agent Skills format's limits, and Claude Code's cut-off for a description in its listing.
    static let maxDescription = 1024, maxListedDescription = 1536, maxLines = 500, maxName = 64

    // MARK: Frontmatter

    private static let keyRegex = try! NSRegularExpression(pattern: "^([A-Za-z_][A-Za-z0-9_-]*):(?:[ \\t]+(.*?))?[ \\t]*$")

    static func frontmatter(in text: String) -> Frontmatter? {
        let ns = text as NSString
        var result = Frontmatter()
        var location = 0, first = true
        var key: String?, block: [String] = [], literal = false

        func flush() {
            guard let k = key else { return }
            if !block.isEmpty {
                let joined = block.joined(separator: literal ? "\n" : " ")
                result.fields[k] = [result.fields[k] ?? "", joined].filter { !$0.isEmpty }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            key = nil; block = []; literal = false
        }

        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(lineRange)
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if first {
                first = false
                guard trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) == "---" else { return nil }
                continue
            }
            if trimmed == "---" || trimmed == "..." {
                flush()
                result.range = NSRange(location: 0, length: NSMaxRange(lineRange))
                result.closed = true
                return result
            }
            if let m = keyRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                flush()
                let k = (line as NSString).substring(with: m.range(at: 1))
                let valueRange = m.range(at: 2)
                let raw = valueRange.location == NSNotFound ? "" : (line as NSString).substring(with: valueRange)
                key = k
                if raw.range(of: #"^[>|][+-]?\d?$"#, options: .regularExpression) != nil {
                    literal = raw.hasPrefix("|")
                    result.fields[k] = ""
                } else {
                    result.fields[k] = unquoted(raw)
                    if k == "name", valueRange.location != NSNotFound {
                        result.nameRange = NSRange(location: lineRange.location + valueRange.location, length: valueRange.length)
                    }
                }
            } else if key != nil, line.first?.isWhitespace == true || trimmed.isEmpty {
                // A value that runs on: a block scalar, or a plain one folded over several lines.
                if !trimmed.isEmpty { block.append(trimmed) }
            }
        }
        flush()
        result.range = NSRange(location: 0, length: ns.length)
        return result
    }

    private static func unquoted(_ raw: String) -> String {
        guard raw.count >= 2, let first = raw.first, raw.last == first else { return raw }
        let inner = String(raw.dropFirst().dropLast())
        if first == "\"" {
            return inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: " ")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if first == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        return raw
    }

    /// `text` with the frontmatter's `name` set to `name`.
    static func renamed(_ text: String, to name: String) -> String {
        guard let range = frontmatter(in: text)?.nameRange else { return text }
        return (text as NSString).replacingCharacters(in: range, with: name)
    }

    /// What the name and description cost in every session, where each skill is listed.
    static func listingTokens(name: String, description: String) -> Int {
        let listed = String(description.prefix(maxListedDescription))
        return Int((Double((name + ": " + listed).utf8.count) / 3.7).rounded())
    }

    // MARK: References to the skill's own files

    private static let linkRegex = try! NSRegularExpression(pattern: "\\[[^\\]\\n]*\\]\\(([^)\\s]+)(?:\\s+\"[^\"\\n]*\")?\\)")

    /// Files SKILL.md links to that the folder doesn't have. Only Markdown links count: a path in backticks is as
    /// often about the user's project as about the skill.
    static func missingFiles(in text: String, dir: URL) -> [String] {
        let ns = text as NSString
        let fences = MarkdownScan.fencedRanges(in: text)
        let fm = FileManager.default
        var candidates: [String] = []
        for m in linkRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if fences.contains(where: { NSLocationInRange(m.range.location, $0) }) { continue }
            var target = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            if let cut = target.firstIndex(where: { $0 == "#" || $0 == "?" }) { target = String(target[..<cut]) }
            // A placeholder such as "(URL)" isn't a path. A path has a folder or an extension.
            guard let first = target.first, !"/~$#{".contains(first), !target.contains(":"), !target.contains("*"),
                  !target.contains("{"), target.contains("/") || target.range(of: #"\.[A-Za-z0-9]+$"#, options: .regularExpression) != nil
            else { continue }
            candidates.append(target.removingPercentEncoding ?? target)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted && !fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    // MARK: Folders

    private static let skippedNames: Set<String> = [".DS_Store", ".git", "node_modules", "__pycache__", ".venv"]

    /// The files of a skill folder next to its SKILL.md, largest folders cut off at 300 files.
    static func files(in dir: URL) -> [SkillFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys,
                                                      options: [.producesRelativePathURLs]) else { return [] }
        var files: [SkillFile] = []
        while let url = en.nextObject() as? URL, files.count < 300 {
            if skippedNames.contains(url.lastPathComponent) { en.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, url.relativePath != "SKILL.md" else { continue }
            files.append(SkillFile(path: url.relativePath, size: values?.fileSize ?? 0))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// A hash of every file's path and content, to tell whether two folders hold the same skill throughout.
    static func signature(of dir: URL) -> String {
        var hasher = SHA256()
        var all = files(in: dir)
        all.append(SkillFile(path: "SKILL.md", size: 0))
        for file in all.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data((file.path + "\u{0}").utf8))
            // Large assets are compared by size, so a scan doesn't read megabytes on every pass.
            if file.size > 1 << 20 {
                hasher.update(data: Data("size:\(file.size)".utf8))
            } else if let data = try? Data(contentsOf: dir.appendingPathComponent(file.path)) {
                hasher.update(data: data)
            }
        }
        return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// One skill folder, or link to one, in a folder agents look in.
    struct Copy {
        let name: String
        let dir: URL
        let realDir: URL
        let home: SkillHome
        let isSymlink: Bool
        let isSynced: Bool
        /// Nil for a link that points nowhere and for a folder with nothing in it.
        let file: InstructionFile?
    }

    /// A `.claude/skills` or `.agents/skills` folder, and the folder its skills apply to.
    struct Location: Hashable {
        let skillsDir: URL
        let home: SkillHome
        let base: URL
        let isGlobal: Bool
    }

    static func globalLocations() -> [Location] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        return SkillHome.allCases.map {
            Location(skillsDir: home.appendingPathComponent($0.folder, isDirectory: true), home: $0, base: home, isGlobal: true)
        }
    }

    static func copies(in location: Location) -> [Copy] {
        var result: [Copy] = []
        for url in children(of: location.skillsDir) {
            // Claude Code keeps the skills of the claude.ai account apart, one folder per account.
            if location.isGlobal, location.home == .claude, url.lastPathComponent == "synced" {
                for account in children(of: url) {
                    for skill in children(of: account) {
                        if let copy = copy(at: skill, home: .claude, synced: true), copy.file != nil { result.append(copy) }
                    }
                }
                continue
            }
            if let copy = copy(at: url, home: location.home, synced: false) { result.append(copy) }
        }
        return result
    }

    /// The folders and links directly inside `dir`, without hidden ones such as `.git` and Codex's `.system`.
    private static func children(of dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        return items.filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func copy(at url: URL, home: SkillHome, synced: Bool) -> Copy? {
        let fm = FileManager.default
        let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
        let real = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: real.path, isDirectory: &isDir)
        func make(_ file: InstructionFile?) -> Copy {
            Copy(name: url.lastPathComponent, dir: url.standardizedFileURL, realDir: real, home: home,
                 isSymlink: isLink, isSynced: synced, file: file)
        }
        if !exists { return isLink ? make(nil) : nil }
        guard isDir.boolValue else { return nil }
        let skillFile = url.appendingPathComponent("SKILL.md")
        guard fm.fileExists(atPath: skillFile.path) else {
            // A folder with other things in it may hold something Rulebook doesn't know about. An empty one is clutter.
            let contents = (try? fm.contentsOfDirectory(atPath: real.path)) ?? []
            return contents.allSatisfy({ $0 == ".DS_Store" }) ? make(nil) : nil
        }
        let resolved = skillFile.resolvingSymlinksInPath()
        let modified = (try? resolved.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return make(InstructionFile(url: skillFile.standardizedFileURL, resolvedURL: resolved, kind: .skill, inDotClaude: false,
                                    isSymlink: isLink, content: Scanner.readText(resolved) ?? "", modified: modified))
    }

    /// What `npx skills` recorded about the skills it installed for `base`: each one's name and where it came from.
    /// It keeps `skills-lock.json` in a project and `~/.agents/.skill-lock.json` for the global ones.
    static func installed(in base: URL, isGlobal: Bool) -> [String: String] {
        let url = base.appendingPathComponent(isGlobal ? ".agents/.skill-lock.json" : "skills-lock.json")
        guard let data = try? Data(contentsOf: url),
              let lock = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skills = lock["skills"] as? [String: Any] else { return [:] }
        return skills.compactMapValues { ($0 as? [String: Any])?["source"] as? String }
    }

    // MARK: Analysis

    /// Turns the skill folders found in `locations` into documents and list entries.
    static func analyze(_ locations: [Location], root: URL, gitRoots: Set<String>) -> (docs: [Doc], entries: [SkillEntry]) {
        struct Group { var copies: [Copy]; let base: URL; let isGlobal: Bool }
        var groups: [String: Group] = [:]
        var order: [String] = []
        for location in locations {
            for copy in copies(in: location) {
                let key = [location.base.path, copy.isSynced ? "synced" : "", copy.name].joined(separator: "\u{0}")
                if groups[key] == nil {
                    groups[key] = Group(copies: [], base: location.base, isGlobal: location.isGlobal)
                    order.append(key)
                }
                groups[key]?.copies.append(copy)
            }
        }

        var docs: [Doc] = [], entries: [SkillEntry] = []
        var locks: [String: [String: String]] = [:]
        for key in order {
            guard let group = groups[key] else { continue }
            if locks[group.base.path] == nil { locks[group.base.path] = installed(in: group.base, isGlobal: group.isGlobal) }
            let source = group.copies[0].isSynced ? nil : locks[group.base.path]?[group.copies[0].name]
            var projectID = "global", projectName = L("Global"), rel = ""
            if !group.isGlobal {
                let project = Scanner.projectRoot(for: group.base, root: root, gitRoots: gitRoots)
                projectID = project.path
                projectName = project.path == root.path ? root.lastPathComponent
                    : (Scanner.relative(project, to: root) ?? project.lastPathComponent)
                rel = Scanner.relative(group.base, to: project) ?? ""
            }
            let built = analyze(group.copies, base: group.base, isGlobal: group.isGlobal, source: source,
                                projectID: projectID, projectName: projectName, rel: rel)
            docs += built.docs
            entries += built.entries
        }
        shadow(&docs)
        drift(&docs)
        entries.sort {
            let a = ($0.projectID == "global" ? 0 : 1, $0.projectName.lowercased(), $0.name.lowercased(), $0.id)
            let b = ($1.projectID == "global" ? 0 : 1, $1.projectName.lowercased(), $1.name.lowercased(), $1.id)
            return a < b
        }
        return (docs, entries)
    }

    /// One skill name in one place: the same folder reached through links is one document, folders with the same
    /// SKILL.md are one document saved together, and folders that differ are documents that point at each other.
    private static func analyze(_ copies: [Copy], base: URL, isGlobal: Bool, source: String?,
                                projectID: String, projectName: String, rel: String) -> (docs: [Doc], entries: [SkillEntry]) {
        let ranking: [SkillHome] = [.agents, .claude, .codex]
        func rank(_ c: Copy) -> Int { ranking.firstIndex(of: c.home) ?? 0 }
        func show(_ url: URL) -> String { isGlobal ? url.path.tildePath : (Scanner.relative(url, to: base) ?? url.path.tildePath) }
        func folder(_ home: SkillHome) -> String { isGlobal ? "~/" + home.folder : home.folder }
        let name = copies[0].name
        let live = copies.filter { $0.file != nil }.sorted { rank($0) < rank($1) }
        let dead = copies.filter { $0.file == nil }

        func deadIssue(_ c: Copy, alone: Bool) -> Issue {
            guard c.isSymlink else {
                return Issue(id: "skill-empty", severity: .info, title: L("Empty folder"),
                             detail: L("`%@` has no SKILL.md, so it isn't a skill.", show(c.dir)))
            }
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: c.dir.path)) ?? ""
            return Issue(id: "skill-dead-" + c.dir.path, severity: .warning,
                         title: alone ? L("Link points nowhere") : L("%@ points nowhere", show(c.dir)),
                         detail: L("`%1$@` links to `%2$@`, which doesn't exist, so agents that look there find nothing.", show(c.dir), target),
                         fixes: [.removeSkillLink(c.dir)])
        }

        guard !live.isEmpty else {
            return ([], dead.map {
                SkillEntry(id: $0.dir.path, name: name, projectID: projectID, projectName: projectName, dir: $0.dir,
                           docID: nil, issue: deadIssue($0, alone: true))
            })
        }

        // One folder on disk, with every path that reaches it.
        struct Folder { let primary: Copy; let links: [Copy] }
        var byReal: [String: [Copy]] = [:], realOrder: [String] = []
        for c in live {
            if byReal[c.realDir.path] == nil { realOrder.append(c.realDir.path) }
            byReal[c.realDir.path, default: []].append(c)
        }
        let folders: [Folder] = realOrder.map { path in
            let sorted = byReal[path]!.sorted { ($0.isSymlink ? 1 : 0, rank($0)) < ($1.isSymlink ? 1 : 0, rank($1)) }
            return Folder(primary: sorted[0], links: Array(sorted.dropFirst()))
        }
        var variants: [[Folder]] = []
        for f in folders {
            let text = MarkdownScan.normalized(f.primary.file!.content)
            if let i = variants.firstIndex(where: { MarkdownScan.normalized($0[0].primary.file!.content) == text }) {
                variants[i].append(f)
            } else {
                variants.append([f])
            }
        }

        var docs: [Doc] = []
        for (i, variant) in variants.enumerated() {
            let first = variant[0].primary
            let mirrors = variant.dropFirst().map(\.primary)
            let links = variant.flatMap(\.links)
            let all = variant.flatMap { [$0.primary] + $0.links }
            let homes = ranking.filter { home in all.contains { $0.home == home } }
            let others = variants.enumerated().filter { $0.offset != i }.flatMap { $0.element.flatMap { [$0.primary] + $0.links } }

            func access(_ wanted: [SkillHome], missing: String) -> Access {
                if let c = all.first(where: { wanted.contains($0.home) }) {
                    if c.isSynced { return Access(reads: true, note: L("Synced from your claude.ai account")) }
                    if c.home == .codex { return Access(reads: true, note: L("Only Codex, from %@", show(c.dir))) }
                    if c.isSymlink { return Access(reads: true, note: L("Through the %@ symlink", show(c.dir))) }
                    return Access(reads: true, note: mirrors.isEmpty ? L("Reads %@ directly", show(c.dir)) : L("Reads the %@ copy", show(c.dir)))
                }
                if let other = others.first(where: { wanted.contains($0.home) }) {
                    return Access(reads: false, note: L("Gets the other version, in %@", show(other.dir)))
                }
                return Access(reads: false, note: missing)
            }
            let readers = Readers(claude: access([.claude], missing: L("It only looks in %@", folder(.claude))),
                                  others: access([.agents, .codex], missing: L("They look in %@", folder(.agents))))

            var issues: [Issue] = []
            var identical = true
            let role: DocRole, status: PairStatus
            var sibling: Copy?
            if variants.count > 1 {
                let other = variants[i == 0 ? 1 : 0][0].primary
                sibling = other
                let cmp = LineDiff.compare(first.file!.content, other.file!.content)
                role = .diverged
                status = .diverged(similarity: Int((cmp.similarity * 100).rounded()))
                issues.append(Issue(
                    id: "skill-diverged", severity: .warning, title: L("Agents get different versions of this skill"),
                    detail: L("%1$@ and %2$@ are separate folders, and their SKILL.md files differ. Lines only in %1$@: %3$d. Lines only in %2$@: %4$d.",
                              show(first.dir), show(other.dir), cmp.onlyLeft, cmp.onlyRight),
                    fixes: [.compare, .useSkillVersion]))
            } else if let copy = mirrors.first {
                // By names and sizes here. The contents are compared before a copy is replaced.
                identical = Set(variant.map { files(in: $0.primary.realDir) }).count == 1
                role = .mirrored
                status = .duplicated
                issues.append(Issue(
                    id: "skill-duplicate", severity: .info, title: L("Two copies of the same skill"),
                    detail: identical
                        ? L("%1$@ and %2$@ are separate folders with the same content. Rulebook saves both, but other tools will let them drift. A link keeps one copy.", show(first.dir), show(copy.dir))
                        : L("%1$@ and %2$@ have the same SKILL.md, but their other files differ.", show(first.dir), show(copy.dir)),
                    fixes: identical ? [.linkSkillCopies] : []))
            } else if homes.count > 1 {
                role = .unified
                status = .linkedSymlink
            } else if homes == [.claude] {
                role = .claudeOnly
                status = .claudeOnly
                if !first.isSynced {
                    // A folder of its own moves to where the other agents look, as `npx skills` lays skills out.
                    // A link to somewhere else gets a second link next to it.
                    issues.append(Issue(
                        id: "skill-claude-only", severity: .info, title: L("Only Claude Code loads this skill"),
                        detail: first.isSymlink
                            ? L("Codex and other agents look in `%@`. A link there lets them use this folder too.", folder(.agents))
                            : L("Codex and other agents look in `%@`. With the folder there and a link to it here, every agent uses the same one.", folder(.agents)),
                        fixes: [first.isSymlink ? .linkSkill(into: .agents) : .moveSkillToAgents]))
                }
            } else {
                role = .agentsOnly
                status = .agentsOnly
                issues.append(Issue(
                    id: "skill-no-claude", severity: .info, title: L("Claude Code doesn't load this skill"),
                    detail: L("Claude Code only looks in `%@`. A link there lets it use this folder too.", folder(.claude)),
                    fixes: [.linkSkill(into: .claude)]))
            }
            if i == 0 { issues += dead.filter(\.isSymlink).map { deadIssue($0, alone: false) } }
            if let source {
                issues.append(Issue(
                    id: "skill-installed", severity: .info, title: L("Installed from %@", source),
                    detail: L("`npx skills` manages this skill. Updating it there replaces the folder, so changes made here don't last.")))
            }

            let info = SkillInfo(name: name, dir: first.dir, home: first.home, homes: homes, isGlobal: isGlobal,
                                 isSynced: first.isSynced, copies: mirrors.map(\.dir), links: links.map(\.dir),
                                 copiesIdentical: identical, files: files(in: first.realDir), source: source)
            docs.append(Doc(id: first.file!.id, projectID: projectID, projectName: projectName, locationDir: base,
                            relativeDir: rel, primary: first.file!, mirrors: mirrors.compactMap(\.file),
                            linkedFrom: links.compactMap { c in c.file.map { LinkInfo(file: $0, viaSymlink: true) } },
                            role: role, status: status, siblingID: sibling?.file?.id, readers: readers,
                            staticIssues: issues, skill: info))
        }
        return (docs, docs.map {
            SkillEntry(id: $0.id, name: name, projectID: projectID, projectName: projectName, dir: $0.skill!.dir, docID: $0.id)
        })
    }

    /// Claude Code runs the personal skill when a project has one with the same name.
    private static func shadow(_ docs: inout [Doc]) {
        var personal: [String: Doc] = [:]
        for d in docs {
            if let s = d.skill, s.isGlobal, !s.isSynced, d.readers.claude.reads { personal[s.name] = d }
        }
        for i in docs.indices {
            guard let s = docs[i].skill, !s.isGlobal, docs[i].readers.claude.reads, let mine = personal[s.name],
                  mine.primary.resolvedURL != docs[i].primary.resolvedURL,
                  MarkdownScan.normalized(mine.primary.content) != MarkdownScan.normalized(docs[i].primary.content) else { continue }
            let path = mine.skill!.dir.path.tildePath
            docs[i].readers.claude = Access(reads: false, note: L("Uses your personal skill instead, in %@", path))
            docs[i].staticIssues.append(Issue(
                id: "skill-shadowed", severity: .warning, title: L("Claude Code uses your personal skill instead"),
                detail: L("When a project skill and a personal one share a name, Claude Code runs the personal one. `%@` differs from this one.", path)))
        }
    }

    /// A skill copied into several projects is probably stale where it differs from most of the others.
    private static func drift(_ docs: inout [Doc]) {
        var byName: [String: [Int]] = [:]
        for (i, d) in docs.enumerated() {
            if let s = d.skill, !s.isSynced { byName[s.name, default: []].append(i) }
        }
        for indices in byName.values where Set(indices.map { docs[$0].projectID }).count > 1 {
            let versions = Dictionary(grouping: indices) { MarkdownScan.normalized(docs[$0].primary.content) }
            guard versions.count > 1 else { continue }
            let largest = versions.values.map(\.count).max() ?? 0
            let hasMajority = versions.values.filter { $0.count == largest }.count == 1
            for group in versions.values where !(hasMajority && group.count == largest) {
                let others = indices.count - group.count
                for i in group {
                    docs[i].staticIssues.append(Issue(
                        id: "skill-drift", severity: .info, title: L("Differs from this skill in other projects"),
                        detail: LN(others, "%d other place has a different version of this skill, so this copy may be out of date.",
                                   "%d other places have a different version of this skill, so this copy may be out of date.")))
                }
            }
        }
    }

    // MARK: Content issues

    static func issues(text: String, stats: TextStats, doc: Doc, skill: SkillInfo) -> [Issue] {
        var issues: [Issue] = []
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [Issue(id: "empty", severity: .warning, title: L("Empty file"),
                          detail: L("Agents list a skill by its description and load its instructions from here. This one has neither."))]
        }
        let front = frontmatter(in: text)
        if front == nil || front?.closed == false {
            issues.append(Issue(
                id: "skill-frontmatter", severity: .warning, title: front == nil ? L("No frontmatter") : L("Frontmatter isn't closed"),
                detail: L("SKILL.md starts with a block between two `---` lines that holds the skill's `name` and `description`. Without it agents can't tell when to use the skill.")))
        } else if let front {
            let description = front.description
            if description.isEmpty {
                issues.append(Issue(
                    id: "skill-description", severity: .warning, title: L("No description"),
                    detail: L("Agents decide when to use a skill from its `description`. Say what the skill does and when to use it."),
                    reveal: "---"))
            } else if description.count > maxDescription {
                issues.append(Issue(
                    id: "skill-description-long", severity: .warning, title: L("Long description (%d characters)", description.count),
                    detail: L("The Agent Skills format allows %1$d characters, and Claude Code cuts a description off at %2$d. The description is listed in every session, so put the main use first.", maxDescription, maxListedDescription),
                    reveal: "description:"))
            }
            if let name = front.name {
                if name != skill.name {
                    issues.append(Issue(
                        id: "skill-name", severity: .info, title: L("Named “%1$@” in a folder called “%2$@”", name, skill.name),
                        detail: L("The Agent Skills format expects the `name` to match the folder. Agents that follow it may list this skill under either name, or skip it."),
                        fixes: [.renameSkill(skill.name)], reveal: "name:"))
                } else if name.count > maxName || name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) == nil {
                    issues.append(Issue(
                        id: "skill-name-format", severity: .info, title: L("Unusual name"),
                        detail: L("The Agent Skills format allows lowercase letters, numbers and single hyphens in a name, up to %d characters.", maxName),
                        reveal: "name:"))
                }
            }
        }
        if stats.lines > maxLines {
            issues.append(Issue(
                id: "long", severity: .info, title: L("Long skill (%d lines)", stats.lines),
                detail: L("An agent loads all of SKILL.md when it uses the skill. Keep it under %d lines and move reference material into separate files, which are read only when needed.", maxLines)))
        }
        for path in missingFiles(in: text, dir: doc.primary.resolvedURL.deletingLastPathComponent()) {
            issues.append(Issue(
                id: "skill-file-" + path, severity: .warning, title: L("File not found: %@", path),
                detail: L("SKILL.md points at `%@`, which isn't in the skill's folder.", path), reveal: path))
        }
        return issues
    }
}
