import Foundation

/// Headless entry points, handy for checking the analysis without the UI.
enum CLI {
    static func run(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--audit"), i + 1 < args.count {
            audit(path: (args[i + 1] as NSString).expandingTildeInPath)
            return true
        }
        if let i = args.firstIndex(of: "--dump") {
            let given = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : nil
            guard let root = given.map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) ?? savedRoot else {
                print("No folder to scan. Pass one: Rulebook --dump <folder>")
                return true
            }
            dump(root: root)
            return true
        }
        return false
    }

    /// `--root`, or the folder chosen in the app.
    static var savedRoot: URL? {
        (LaunchOptions.root ?? UserDefaults.standard.string(forKey: "rootPath"))
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }

    /// Runs the same prompt audit the app runs, and stores the result where the app reads it.
    static func audit(path: String) {
        guard let root = savedRoot else {
            print("No folder to scan. Pass one: Rulebook --root <folder> --audit <file>")
            return
        }
        let engine = LaunchOptions.value("--agent").flatMap(Engine.init(rawValue:))
            ?? Engine.allCases.first { AgentService.locate($0) != nil } ?? .claude
        let scan = Scanner.scan(root: root, includeGlobal: !LaunchOptions.noGlobal)
        let command = LaunchOptions.value("--command").map { URL(fileURLWithPath: $0) } ?? AgentService.locate(engine)
        guard let doc = scan.docs[URL(fileURLWithPath: path).standardizedFileURL.path], let cli = command else {
            print("No document at \(path), or no \(engine.command) command")
            return
        }
        let projectRoot = URL(fileURLWithPath: doc.projectID, isDirectory: true)
        let rel = Scanner.relative(doc.primary.url, to: projectRoot) ?? doc.primary.name
        let started = Date()
        print("\(engine.command) \(AgentService.version(of: cli) ?? "?") · auditing \(rel) in \(projectRoot.path) · \(AppLanguage.active.promptName)")
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                var a = try await AgentService.audit(engine: engine, relativePath: rel, cwd: projectRoot, cli: cli,
                                                     model: LaunchOptions.value("--model") ?? "", language: .active) { step in
                    print(String(format: "  %5.1fs  %@", Date().timeIntervalSince(started), step))
                }
                a.contentHash = AppModel.hash(doc.primary.content)
                var store = AssessmentStore.load()
                store[doc.id] = a
                AssessmentStore.save(store)
                print("\n\(a.verdict) (\(a.grade), score \(a.score))\n\(a.summary)\n")
                for f in a.issues { print("  [\(f.severity)] \(f.title)") }
                print("\nRevised: \(a.revised.isEmpty ? "none" : "\(a.revised.count) chars") · \(Int(a.durationSeconds ?? 0))s")
            } catch {
                print("Failed: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
    }

    static func dump(root: URL) {
        let r = Scanner.scan(root: root, includeGlobal: !LaunchOptions.noGlobal)
        print("Scanned \(r.root.path) in \(String(format: "%.2f", r.duration))s — \(r.foldersVisited) folders, \(r.fileCount) files, \(r.docs.count) documents, \(r.projects.count) projects\n")
        for p in r.projects {
            print("■ \(p.name)  [\(p.status.map { "\($0)" } ?? "-")]")
            for id in p.docIDs {
                guard let d = r.docs[id] else { continue }
                let extra = d.mirrors.map { "+\($0.displayName)" } + d.linkedFrom.map { "←\($0.file.displayName)\($0.viaSymlink ? " (symlink)" : "")" }
                print("   \(d.title) \(extra.joined(separator: " "))  role=\(d.role)")
                print("      claude: \(d.readers.claude.reads ? "✓" : "✗") \(d.readers.claude.note)   others: \(d.readers.others.reads ? "✓" : "✗") \(d.readers.others.note)")
                for issue in d.savedIssues {
                    print("      [\(issue.severity)] \(issue.title)\(issue.fixes.isEmpty ? "" : "  fixes: \(issue.fixes)")")
                }
            }
        }
        print("\nManaged blocks:")
        for g in r.blockGroups {
            print("   \(g.name): \(g.total) copies, \(g.variants.count) variant(s) — \(g.variants.map { $0.paths.count })")
        }
        print("\nRepeated rules:")
        for rule in r.repeatedRules {
            print("   \(rule.projectCount) projects, \(rule.wordings) wording(s): \(rule.text)")
            for o in rule.occurrences { print("      \(o.project)/\(o.file):\(o.line)  \(o.text)") }
        }
        print("\nNo instructions: \(r.missing.map(\.lastPathComponent).joined(separator: ", "))")
    }
}
