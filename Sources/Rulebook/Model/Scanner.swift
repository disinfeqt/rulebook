import Foundation

enum Scanner {
    static let skipDirs: Set<String> = [
        "node_modules", "dist", "build", "out", "coverage", "vendor", "Pods", "Carthage",
        "DerivedData", "target", "venv", "__pycache__", "bower_components", "tmp",
    ]
    static let fileNames: Set<String> = ["claude.md", "agents.md", "claude.local.md"]
    static let maxDepth = 8

    struct Collected {
        var files: [InstructionFile] = []
        var gitRoots: Set<String> = []
        /// The `.claude/skills` and `.agents/skills` folders inside the projects.
        var skillLocations: [SkillScan.Location] = []
        var dirs = 0
    }

    // MARK: Walk

    static func collect(root: URL) -> Collected {
        var c = Collected()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        let homeClaude = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude").standardizedFileURL.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                     options: [.skipsPackageDescendants],
                                     errorHandler: { _, _ in true }) else { return c }
        while let url = en.nextObject() as? URL {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            let parentName = url.deletingLastPathComponent().lastPathComponent

            if name == ".git" {
                c.gitRoots.insert(url.deletingLastPathComponent().standardizedFileURL.path)
                if isDir { en.skipDescendants() }
                continue
            }
            if isDir {
                c.dirs += 1
                // Skills sit one level further in than the walk goes. The home folder's own are the global ones.
                if let skillHome = name == ".claude" ? SkillHome.claude : (name == ".agents" ? .agents : nil) {
                    let base = url.deletingLastPathComponent().standardizedFileURL
                    let skills = url.appendingPathComponent("skills", isDirectory: true)
                    if base.path != home, fm.fileExists(atPath: skills.path) {
                        c.skillLocations.append(.init(skillsDir: skills, home: skillHome, base: base, isGlobal: false))
                    }
                }
                let hiddenSkip = name.hasPrefix(".") && name != ".claude"
                // Inside .claude only the top level matters (skills, worktrees, agents… are not instructions).
                if skipDirs.contains(name) || hiddenSkip || parentName == ".claude"
                    || en.level >= maxDepth || url.standardizedFileURL.path == homeClaude {
                    en.skipDescendants()
                }
                continue
            }
            let lower = name.lowercased()
            guard fileNames.contains(lower) else { continue }
            let inDot = parentName == ".claude"
            if inDot && lower == "claude.local.md" { continue }
            c.files.append(makeFile(url: url, lower: lower, inDot: inDot, isSymlink: values?.isSymbolicLink ?? false))
        }
        return c
    }

    static func makeFile(url: URL, lower: String, inDot: Bool, isSymlink: Bool) -> InstructionFile {
        let kind: FileKind = lower == "claude.md" ? .claude : (lower == "agents.md" ? .agents : .claudeLocal)
        let resolved = url.resolvingSymlinksInPath()
        let modified = (try? resolved.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return InstructionFile(url: url.standardizedFileURL, resolvedURL: resolved, kind: kind,
                               inDotClaude: inDot, isSymlink: isSymlink,
                               content: readText(resolved) ?? "", modified: modified)
    }

    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    static func globalFiles() -> [InstructionFile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [(String, String)] = [(".claude/CLAUDE.md", "claude.md"), (".codex/AGENTS.md", "agents.md")]
        return candidates.compactMap { rel, lower in
            let url = home.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
            return makeFile(url: url, lower: lower, inDot: false, isSymlink: isLink)
        }
    }

    // MARK: Paths

    static func relative(_ url: URL, to base: URL) -> String? {
        let p = url.standardizedFileURL.path, b = base.standardizedFileURL.path
        if p == b { return "" }
        guard p.hasPrefix(b + "/") else { return nil }
        return String(p.dropFirst(b.count + 1))
    }

    static func projectRoot(for dir: URL, root: URL, gitRoots: Set<String>) -> URL {
        let rootPath = root.path
        var cur = dir.standardizedFileURL
        while cur.path == rootPath || cur.path.hasPrefix(rootPath + "/") {
            // The scan root itself only counts as a project for files directly inside it.
            if gitRoots.contains(cur.path) && (cur.path != rootPath || dir.path == rootPath) { return cur }
            if cur.path == rootPath { break }
            cur = cur.deletingLastPathComponent()
        }
        guard let rel = relative(dir, to: root), !rel.isEmpty,
              let first = rel.split(separator: "/").first else { return root }
        return root.appendingPathComponent(String(first), isDirectory: true)
    }

    /// A CLAUDE.md-family file in a parent folder makes Claude Code skip AGENTS.md here.
    static func ancestorClaude(above dir: URL) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var cur = dir.standardizedFileURL.deletingLastPathComponent()
        while cur.path != "/" && !cur.path.isEmpty {
            for name in ["CLAUDE.md", "CLAUDE.local.md", ".claude/CLAUDE.md"] {
                if cur.path == home && name == ".claude/CLAUDE.md" { continue } // user-level, doesn't count
                if fm.fileExists(atPath: cur.appendingPathComponent(name).path) {
                    return ((cur.appendingPathComponent(name).path) as NSString).abbreviatingWithTildeInPath
                }
            }
            cur = cur.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: Scan

    static func scan(root rawRoot: URL, includeGlobal: Bool) -> ScanResult {
        let start = Date()
        let root = rawRoot.standardizedFileURL
        let collected = collect(root: root)
        var docs: [String: Doc] = [:]
        var projects: [Project] = []

        let byLocation = Dictionary(grouping: collected.files) { $0.locationDir.standardizedFileURL.path }
        var locationsByProject: [String: [String]] = [:]
        for loc in byLocation.keys {
            let p = projectRoot(for: URL(fileURLWithPath: loc, isDirectory: true), root: root, gitRoots: collected.gitRoots)
            locationsByProject[p.path, default: []].append(loc)
        }

        for (projectPath, locations) in locationsByProject {
            let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
            let name = projectPath == root.path ? root.lastPathComponent : (relative(projectURL, to: root) ?? projectURL.lastPathComponent)
            var ids: [String] = []
            var rootStatus: PairStatus?
            let ordered = locations.sorted {
                let a = $0.split(separator: "/").count, b = $1.split(separator: "/").count
                return a == b ? $0.localizedStandardCompare($1) == .orderedAscending : a < b
            }
            for loc in ordered {
                let locURL = URL(fileURLWithPath: loc, isDirectory: true)
                let rel = relative(locURL, to: projectURL) ?? ""
                let built = analyzeLocation(byLocation[loc] ?? [], dir: locURL, rel: rel,
                                            projectID: projectPath, projectName: name)
                for d in built { docs[d.id] = d; ids.append(d.id) }
                if rel.isEmpty, rootStatus == nil { rootStatus = built.first?.status }
            }
            guard !ids.isEmpty else { continue }
            projects.append(Project(id: projectPath, name: name, root: projectURL, docIDs: ids,
                                    status: rootStatus ?? docs[ids[0]]?.status, isGlobal: false))
        }
        projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var fileCount = collected.files.count
        if includeGlobal {
            var ids: [String] = []
            for f in globalFiles() {
                let isClaude = f.kind == .claude
                let readers = Readers(
                    claude: Access(reads: isClaude, note: isClaude ? L("In every project") : L("Claude Code reads %@ instead", "~/.claude/CLAUDE.md")),
                    others: Access(reads: !isClaude, note: isClaude ? L("Codex reads %@ instead", "~/.codex/AGENTS.md") : L("In every project")))
                let d = Doc(id: f.id, projectID: "global", projectName: L("Global"), locationDir: f.containingDir,
                            relativeDir: "", primary: f, mirrors: [], linkedFrom: [], role: .global,
                            status: .global, siblingID: nil, readers: readers, staticIssues: [])
                docs[d.id] = d
                ids.append(d.id)
                fileCount += 1
            }
            if !ids.isEmpty {
                projects.insert(Project(id: "global", name: L("Global"), root: FileManager.default.homeDirectoryForCurrentUser,
                                        docIDs: ids, status: .global, isGlobal: true), at: 0)
            }
        }

        let groups = blockGroups(docs)
        for (id, issues) in driftIssues(groups) { docs[id]?.staticIssues += issues }
        let repeated = RepeatedRules.find(in: Array(docs.values))

        // Skills are documents too, so they open, save and compare like the files above. They stay out of
        // `projects`, which is the instruction files.
        let skills = SkillScan.analyze(collected.skillLocations + (includeGlobal ? SkillScan.globalLocations() : []),
                                       root: root, gitRoots: collected.gitRoots)
        for d in skills.docs { docs[d.id] = d }

        // Content issues for the saved text, so the sidebar can flag files without opening them.
        for (id, d) in docs {
            let sibling = d.siblingID.flatMap { docs[$0]?.primary.content }
            let insights = ContentInsights.compute(text: d.primary.content, doc: d, siblingText: sibling)
            docs[id]?.savedIssues = (d.staticIssues + insights.issues).sorted { $0.severity > $1.severity }
            docs[id]?.savedStats = insights.stats
        }
        let entries = skills.entries.map { entry in
            var entry = entry
            entry.needsAttention = entry.docID.flatMap { docs[$0] }?.needsAttention ?? ((entry.issue?.severity ?? .info) >= .warning)
            return entry
        }

        let covered = Set(projects.map(\.id))
        let missing = collected.gitRoots
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { $0.deletingLastPathComponent().path == root.path && !covered.contains($0.path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        return ScanResult(root: root, date: Date(), projects: projects, docs: docs, fileCount: fileCount,
                          foldersVisited: collected.dirs, missing: missing,
                          blockGroups: groups, repeatedRules: repeated, skills: entries,
                          duration: Date().timeIntervalSince(start))
    }

    static func blockGroups(_ docs: [String: Doc]) -> [ManagedBlockGroup] {
        var byName: [String: [String: (docIDs: [String], paths: [String], body: String)]] = [:]
        for d in docs.values.sorted(by: { $0.id < $1.id }) {
            for f in d.allFiles {
                for b in MarkdownScan.managedBlocks(in: f.content) {
                    let key = b.normalizedBody
                    var entry = byName[b.name, default: [:]][key] ?? ([], [], b.body)
                    if !entry.docIDs.contains(d.id) { entry.docIDs.append(d.id) }
                    entry.paths.append(f.id)
                    byName[b.name, default: [:]][key] = entry
                }
            }
        }
        return byName.map { name, variants in
            ManagedBlockGroup(name: name, variants: variants.values
                .sorted { $0.paths.count > $1.paths.count }
                .map { .init(body: $0.body, docIDs: $0.docIDs, paths: $0.paths) })
        }
        .sorted { $0.total > $1.total }
    }

    /// A tool writes the same block into every project, so a copy that differs from most others is probably stale.
    static func driftIssues(_ groups: [ManagedBlockGroup]) -> [String: [Issue]] {
        var result: [String: [Issue]] = [:]
        for group in groups where group.variants.count > 1 {
            let files = group.variants.reduce(0) { $0 + $1.docIDs.count }
            let largest = group.variants.map(\.docIDs.count).max() ?? 0
            let hasMajority = group.variants.filter { $0.docIDs.count == largest }.count == 1
            for variant in group.variants where !(hasMajority && variant.docIDs.count == largest) {
                let others = files - variant.docIDs.count
                let issue = Issue(
                    id: "block-drift-\(group.name)", severity: .info,
                    title: L("%@ differs from other projects", group.name),
                    detail: LN(others, "%d other file has a different version of this tool-written block, so this copy may be out of date.",
                               "%d other files have a different version of this tool-written block, so this copy may be out of date."),
                    reveal: group.name)
                for id in variant.docIDs { result[id, default: []].append(issue) }
            }
        }
        return result
    }

    // MARK: Relationship analysis

    static func analyzeLocation(_ files: [InstructionFile], dir: URL, rel: String,
                                projectID: String, projectName: String) -> [Doc] {
        func rootFirst(_ a: InstructionFile, _ b: InstructionFile) -> Bool { !a.inDotClaude && b.inDotClaude }
        let claudes = files.filter { $0.kind == .claude }.sorted(by: rootFirst)
        let agents = files.filter { $0.kind == .agents }.sorted(by: rootFirst)
        let local = files.first { $0.kind == .claudeLocal }
        var docs: [Doc] = []

        func make(_ primary: InstructionFile, mirrors: [InstructionFile] = [], linked: [LinkInfo] = [],
                  role: DocRole, status: PairStatus, sibling: InstructionFile? = nil,
                  claude: Access, others: Access, issues: [Issue] = []) -> Doc {
            Doc(id: primary.id, projectID: projectID, projectName: projectName, locationDir: dir,
                relativeDir: rel, primary: primary, mirrors: mirrors, linkedFrom: linked, role: role,
                status: status, siblingID: sibling?.id, readers: Readers(claude: claude, others: others),
                staticIssues: issues)
        }

        if let C = claudes.first, let A = agents.first {
            let c = C.displayName, a = A.displayName
            if C.isSymlink && C.resolvedURL.path == A.resolvedURL.path {
                docs.append(make(A, linked: [LinkInfo(file: C, viaSymlink: true)], role: .unified, status: .linkedSymlink,
                                 claude: Access(reads: true, note: L("Claude Code reads it through the %@ symlink", c)),
                                 others: Access(reads: true, note: "")))
            } else if A.isSymlink && A.resolvedURL.path == C.resolvedURL.path {
                docs.append(make(C, linked: [LinkInfo(file: A, viaSymlink: true)], role: .unified, status: .linkedSymlink,
                                 claude: Access(reads: true, note: ""),
                                 others: Access(reads: true, note: L("Other agents read it through the %@ symlink", a))))
            } else {
                let imports = MarkdownScan.imports(in: C.content, baseDir: C.containingDir)
                let toA = imports.filter { $0.exists && $0.resolved.resolvingSymlinksInPath().path == A.resolvedURL.path }
                if !toA.isEmpty && MarkdownScan.isOnlyImports(C.content, removing: toA) {
                    docs.append(make(A, linked: [LinkInfo(file: C, viaSymlink: false)], role: .unified, status: .linkedImport,
                                     claude: Access(reads: true, note: L("Claude Code reads it through %@ in %@", toA[0].raw, c)),
                                     others: Access(reads: true, note: "")))
                } else if !toA.isEmpty {
                    docs.append(make(A, role: .sharedBase, status: .layered, sibling: C,
                                     claude: Access(reads: true, note: L("Claude Code reads it through the import in %@", c)),
                                     others: Access(reads: true, note: "")))
                    docs.append(make(C, role: .claudeExtension, status: .layered, sibling: A,
                                     claude: Access(reads: true, note: L("Claude Code reads it together with the %@ it imports", a)),
                                     others: Access(reads: false, note: L("Other agents read %@ only", a))))
                } else if MarkdownScan.normalized(C.content) == MarkdownScan.normalized(A.content) {
                    let issue = Issue(
                        id: "duplicate", severity: .warning,
                        title: L("Two copies of the same instructions"),
                        detail: L("%1$@ is a full copy of %2$@. Rulebook saves both, but any other editor will let them drift. Replace %1$@ with an `@%2$@` import to keep one source.", c, a),
                        fixes: [.replaceWithImport(claude: C.url)])
                    docs.append(make(A, mirrors: [C], role: .mirrored, status: .duplicated,
                                     claude: Access(reads: true, note: L("Claude Code reads the %@ copy", c)),
                                     others: Access(reads: true, note: L("Other agents read the %@ copy", a)),
                                     issues: [issue]))
                } else {
                    let cmp = LineDiff.compare(A.content, C.content)
                    let pct = Int((cmp.similarity * 100).rounded())
                    let issue = Issue(
                        id: "diverged", severity: .warning,
                        title: L("Claude Code and other agents get different rules"),
                        detail: L("%1$@ doesn't import %2$@, so Claude Code reads only %1$@ and other agents read only %2$@. Lines only in %2$@: %3$d. Lines only in %1$@: %4$d.", c, a, cmp.onlyLeft, cmp.onlyRight),
                        fixes: [.compare, .reconcile])
                    docs.append(make(A, role: .diverged, status: .diverged(similarity: pct), sibling: C,
                                     claude: Access(reads: false, note: L("Claude Code skips it, because %@ exists and doesn't import it", c)),
                                     others: Access(reads: true, note: ""), issues: [issue]))
                    docs.append(make(C, role: .diverged, status: .diverged(similarity: pct), sibling: A,
                                     claude: Access(reads: true, note: ""),
                                     others: Access(reads: false, note: L("Other agents read %@ instead", a)), issues: [issue]))
                }
            }
        } else if let C = claudes.first {
            let imports = MarkdownScan.imports(in: C.content, baseDir: C.containingDir)
            let broken = imports.contains { !$0.exists && ($0.path as NSString).lastPathComponent.lowercased() == "agents.md" }
            if broken {
                docs.append(make(C, role: .claudeOnly, status: .brokenImport,
                                 claude: Access(reads: true, note: L("The AGENTS.md it imports is missing")),
                                 others: Access(reads: false, note: "")))
            } else {
                var issues: [Issue] = []
                if !C.inDotClaude {
                    issues.append(Issue(
                        id: "claude-only", severity: .info, title: L("Only Claude Code reads this"),
                        detail: L("Codex, Cursor and other AGENTS.md tools won't see these rules. To share them, move them to AGENTS.md and keep %@ as an `@AGENTS.md` import.", C.displayName),
                        fixes: [.shareWithAgents(claude: C.url)]))
                }
                docs.append(make(C, role: .claudeOnly, status: .claudeOnly,
                                 claude: Access(reads: true, note: ""),
                                 others: Access(reads: false, note: L("Other agents look for AGENTS.md")), issues: issues))
            }
        } else if let A = agents.first {
            if let blocker = local.map({ $0.displayName }) ?? ancestorClaude(above: dir) {
                let issue = Issue(
                    id: "agents-ignored", severity: .warning, title: L("Claude Code skips this file"),
                    detail: L("Claude Code reads AGENTS.md only when there's no CLAUDE.md or CLAUDE.local.md in this folder or above it, and %@ exists. Add a CLAUDE.md that imports AGENTS.md.", blocker),
                    fixes: [.createClaudeImport(dir: dir)])
                docs.append(make(A, role: .agentsOnly, status: .agentsIgnored,
                                 claude: Access(reads: false, note: L("Claude Code skips it, because %@ takes precedence", blocker)),
                                 others: Access(reads: true, note: ""), issues: [issue]))
            } else {
                docs.append(make(A, role: .agentsOnly, status: .agentsOnly,
                                 claude: Access(reads: true, note: L("Claude Code reads AGENTS.md when there's no CLAUDE.md")),
                                 others: Access(reads: true, note: "")))
            }
        }

        let baseStatus = docs.first?.status
        for extra in claudes.dropFirst() {
            docs.append(make(extra, role: .extra, status: baseStatus ?? .claudeOnly,
                             claude: Access(reads: true, note: L("Claude Code reads it alongside %@", claudes[0].displayName)),
                             others: Access(reads: false, note: L("Other agents read %@ only", "AGENTS.md"))))
        }
        for extra in agents.dropFirst() {
            let claudeReads = baseStatus == .agentsOnly
            docs.append(make(extra, role: .extra, status: baseStatus ?? .agentsOnly,
                             claude: Access(reads: claudeReads, note: claudeReads ? L("Claude Code reads it alongside %@", "AGENTS.md") : L("Claude Code skips it while a CLAUDE.md exists")),
                             others: Access(reads: false, note: L("Other agents read the AGENTS.md at the folder root"))))
        }
        if let local {
            docs.append(make(local, role: .local, status: .localOnly,
                             claude: Access(reads: true, note: L("Personal notes, read after CLAUDE.md")),
                             others: Access(reads: false, note: "")))
        }
        return docs
    }
}

/// Analysis that depends on the current text, recomputed live while editing.
struct ContentInsights {
    let stats: TextStats
    let imports: [ImportRef]
    let blocks: [ManagedBlock]
    let issues: [Issue]

    static func compute(text: String, doc: Doc, siblingText: String?) -> ContentInsights {
        if let skill = doc.skill {
            // A SKILL.md has no imports: agents read `@path` in it as plain text.
            let stats = MarkdownScan.stats(text)
            return ContentInsights(stats: stats, imports: [], blocks: [],
                                   issues: SkillScan.issues(text: text, stats: stats, doc: doc, skill: skill))
        }
        let imports = MarkdownScan.imports(in: text, baseDir: doc.primary.containingDir)
        let blocks = MarkdownScan.managedBlocks(in: text)
        let stats = MarkdownScan.stats(text)
        let claudeReads = doc.readers.claude.reads
        var issues: [Issue] = []

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(Issue(id: "empty", severity: .info, title: L("Empty file"),
                                detail: L("Agents load nothing from it. Add instructions or delete it.")))
        }
        if stats.lines > 200 {
            issues.append(Issue(
                id: "long", severity: .warning, title: L("Long file (%d lines)", stats.lines),
                detail: L("Instruction files work best under 200 lines. Longer ones cost context in every session, and agents follow them less reliably.")))
        }
        for imp in imports where !imp.exists {
            let looksLikePath = imp.path.contains(".") || imp.path.contains("/")
            let target = (imp.path as NSString).lastPathComponent.lowercased()
            let isInstructionFile = target == "agents.md" || target == "claude.md"
            issues.append(Issue(
                id: "import-\(imp.range.location)",
                severity: looksLikePath && claudeReads ? .warning : .info,
                title: L("Import not found: %@", imp.raw),
                detail: isInstructionFile
                    ? L("There's no `%@` here, so this import loads nothing. Create the file, or remove the import.", imp.path)
                    : claudeReads
                    ? L("Claude Code tries to load `%@` relative to this file and finds nothing. If you meant it as plain text, wrap it in backticks.", imp.path)
                    : L("`%@` doesn't exist. Wrap it in backticks if it's meant as plain text.", imp.path),
                fixes: isInstructionFile ? [] : [.wrapInBackticks(imp.raw)], reveal: imp.raw))
        }
        if doc.primary.kind == .agents, doc.readers.others.reads, imports.contains(where: \.exists) {
            issues.append(Issue(
                id: "agents-imports", severity: .info, title: L("Only Claude Code expands imports"),
                detail: L("Codex and most AGENTS.md tools read `@path` as plain text. Only Claude Code loads the imported files."),
                reveal: imports.first(where: \.exists)?.raw))
        }
        if doc.role != .mirrored, let title = MarkdownScan.fileTitle(in: text),
           title.name.lowercased() != doc.primary.name.lowercased() {
            let proper = doc.primary.kind == .agents ? "AGENTS.md" : "CLAUDE.md"
            issues.append(Issue(
                id: "title", severity: .info, title: L("Titled “%@”", title.name),
                detail: L("The file is %@, but its heading names the other file. It was probably copied.", doc.primary.name),
                fixes: [.retitle(proper)], reveal: title.name))
        }
        if doc.role == .claudeExtension, let sibling = siblingText {
            let theirs = Set(MarkdownScan.managedBlocks(in: sibling).map { $0.name.lowercased() })
            let dupes = blocks.filter { theirs.contains($0.name.lowercased()) }.map(\.name)
            if !dupes.isEmpty {
                issues.append(Issue(
                    id: "dupe-blocks", severity: .warning,
                    title: L("Loaded twice: %@", dupes.joined(separator: ", ")),
                    detail: L("AGENTS.md already contains the same tool-written block, and this file imports AGENTS.md, so Claude Code reads it twice."),
                    fixes: [.removeBlocks(dupes)], reveal: "<!-- \(dupes[0])"))
            }
            let shared = MarkdownScan.sharedLineCount(text, sibling)
            if shared >= 2 {
                issues.append(Issue(
                    id: "dupe-lines", severity: .info, title: LN(shared, "%d line repeats AGENTS.md", "%d lines repeat AGENTS.md"),
                    detail: L("Claude Code already gets them through the import. Removing them here saves context and leaves one place to edit.")))
            }
        }
        return ContentInsights(stats: stats, imports: imports, blocks: blocks, issues: issues)
    }
}
