import AppKit
import CryptoKit
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case repeatedRules
    case doc(String)
}

struct AlertInfo: Identifiable {
    struct Action: Identifiable {
        let id = UUID()
        let title: String
        var role: ButtonRole? = nil
        let run: () -> Void
    }
    let id = UUID()
    let title: String
    let message: String
    var actions: [Action]
}

struct AgentJob {
    enum Kind { case audit, reconcile }
    let kind: Kind
    var steps: [String] = []
    var error: String?
    var isQueued = false
    var isRunning = true
    var startedAt = Date()
    var task: Task<Void, Never>?
}

struct CompareRequest: Identifiable { let id = UUID(); let agentsID: String; let claudeID: String }
struct RevisionReview: Identifiable { let id = UUID(); let docID: String; let revised: String }
struct ReconcileReview: Identifiable {
    let id = UUID()
    let agentsID: String
    let claudeID: String
    let result: ReconcileResult
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    @ObservationIgnored private let defaults = UserDefaults.standard
    private enum Keys {
        static let root = "rootPath", global = "includeGlobal", engine = "engine", inspector = "showInspector"
        static let autoReaudit = "autoReaudit", concurrency = "auditConcurrency"
        static func cli(_ e: Engine) -> String { "cliPath." + e.rawValue }
        static func model(_ e: Engine) -> String { "model." + e.rawValue }
    }

    // MARK: Settings

    /// The folder whose projects are scanned. Nil until the user picks one.
    var rootPath: String? {
        didSet {
            guard rootPath != oldValue else { return }
            defaults.set(rootPath, forKey: Keys.root)
            scan = nil
            selection = .overview
            rescan()
        }
    }
    var includeGlobal: Bool { didSet { defaults.set(includeGlobal, forKey: Keys.global); rescan() } }
    /// The agent picked in Settings. Nil means the first one found on this Mac.
    var engineChoice: Engine? { didSet { defaults.set(engineChoice?.rawValue, forKey: Keys.engine); cliChecked = false } }
    /// A path typed in Settings, for a CLI that isn't where Rulebook looks.
    var cliOverrides: [Engine: String] {
        didSet {
            for e in Engine.allCases { defaults.set(cliOverrides[e], forKey: Keys.cli(e)) }
            cliChecked = false
            refreshAgents()
        }
    }
    /// Model per agent. Empty means the CLI's own default.
    var models: [Engine: String] { didSet { for e in Engine.allCases { defaults.set(models[e], forKey: Keys.model(e)) } } }
    /// Applies the next time the app opens.
    var language: AppLanguage { didSet { AppLanguage.saved = language } }
    /// Re-audit a file automatically when its content changes, in Rulebook or any other editor.
    var autoReaudit: Bool { didSet { defaults.set(autoReaudit, forKey: Keys.autoReaudit); if autoReaudit { queueChangedAudits() } } }
    var auditConcurrency: Int { didSet { defaults.set(auditConcurrency, forKey: Keys.concurrency); pumpAuditQueue() } }

    // MARK: State

    var scan: ScanResult?
    var isScanning = false
    var selection: SidebarItem? = .overview
    var searchText = ""
    var attentionOnly = false
    var showInspector: Bool { didSet { defaults.set(showInspector, forKey: Keys.inspector) } }
    var drafts: [String: String] = [:]
    var assessments: [String: Assessment] = [:]
    var jobs: [String: AgentJob] = [:]
    var auditQueue: [String] = []
    var compare: CompareRequest?
    var revisionReview: RevisionReview?
    var reconcileReview: ReconcileReview?
    var alert: AlertInfo?
    var focusEditorOnAppear = false
    /// A line for the next file that opens to scroll to.
    @ObservationIgnored var revealLineOnAppear: Int?
    /// Agent CLIs found on this Mac.
    var detected: [Engine: URL] = [:]
    /// How Claude Code audits are paid for, from `claude auth status`.
    var billing: AgentService.Billing = .unknown
    /// The language the app launched in, to tell when a change in Settings is still pending.
    let launchLanguage = AppLanguage.saved

    @ObservationIgnored private var rescanQueued = false
    @ObservationIgnored private var pendingSelection: String?
    @ObservationIgnored private var cliChecked = false

    init() {
        rootPath = LaunchOptions.root ?? defaults.string(forKey: Keys.root)
        includeGlobal = LaunchOptions.noGlobal ? false : defaults.object(forKey: Keys.global) as? Bool ?? true
        engineChoice = defaults.string(forKey: Keys.engine).flatMap(Engine.init(rawValue:))
        var paths: [Engine: String] = [:], names: [Engine: String] = [:]
        for e in Engine.allCases {
            paths[e] = defaults.string(forKey: Keys.cli(e))
            names[e] = defaults.string(forKey: Keys.model(e))
        }
        cliOverrides = paths
        models = names
        language = launchLanguage
        showInspector = defaults.object(forKey: Keys.inspector) as? Bool ?? true
        autoReaudit = defaults.object(forKey: Keys.autoReaudit) as? Bool ?? false
        auditConcurrency = max(1, defaults.object(forKey: Keys.concurrency) as? Int ?? 2)
        assessments = AssessmentStore.load()
        refreshAgents()
    }

    var rootURL: URL? {
        rootPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }

    /// The agent that runs audits and merges.
    var engine: Engine {
        get { engineChoice ?? Engine.allCases.first { detected[$0] != nil } ?? .claude }
        set { engineChoice = newValue }
    }

    var agentModel: String { (models[engine] ?? "").trimmingCharacters(in: .whitespaces) }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL
        panel.message = L("Choose the folder that holds your projects.")
        panel.prompt = L("Scan")
        if panel.runModal() == .OK, let url = panel.url { rootPath = url.path }
    }

    // MARK: Lookup

    func doc(_ id: String) -> Doc? { scan?.docs[id] }

    var currentDoc: Doc? {
        if case .doc(let id) = selection { return doc(id) }
        return nil
    }

    func text(for doc: Doc) -> String { drafts[doc.id] ?? doc.primary.content }

    func setText(_ text: String, for id: String) {
        guard let doc = doc(id) else { return }
        if text == doc.primary.content { drafts[id] = nil } else { drafts[id] = text }
    }

    func isDirty(_ id: String) -> Bool { drafts[id] != nil }

    func sibling(of doc: Doc) -> Doc? { doc.siblingID.flatMap { self.doc($0) } }

    func insights(for doc: Doc) -> ContentInsights {
        ContentInsights.compute(text: text(for: doc), doc: doc, siblingText: sibling(of: doc).map { text(for: $0) })
    }

    func issues(for doc: Doc, insights: ContentInsights) -> [Issue] {
        (doc.staticIssues + insights.issues).sorted { $0.severity > $1.severity }
    }

    var visibleProjects: [Project] {
        guard let scan else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return scan.projects.compactMap { project in
            var ids = project.docIDs
            if attentionOnly {
                ids = ids.filter { (scan.docs[$0]?.needsAttention ?? false) || isDirty($0) }
            }
            if !query.isEmpty && !project.name.lowercased().contains(query) {
                ids = ids.filter { id in
                    guard let d = scan.docs[id] else { return false }
                    return d.title.lowercased().contains(query) || text(for: d).lowercased().contains(query)
                }
            }
            guard !ids.isEmpty else { return nil }
            var copy = project
            copy.docIDs = ids
            return copy
        }
    }

    var visibleDocIDs: [String] { visibleProjects.flatMap(\.docIDs) }

    // MARK: Navigation

    func select(_ id: String, focusEditor: Bool = false) {
        focusEditorOnAppear = focusEditor
        selection = .doc(id)
    }

    /// Opens a file with its editor scrolled to `line` and the line selected.
    func open(_ id: String, line: Int) {
        revealLineOnAppear = line
        select(id, focusEditor: true)
    }

    func move(_ delta: Int) {
        let ids = visibleDocIDs
        guard !ids.isEmpty else { return }
        var index = delta > 0 ? 0 : ids.count - 1
        if case .doc(let id) = selection, let i = ids.firstIndex(of: id) {
            index = max(0, min(ids.count - 1, i + delta))
            if ids[index] == id { NSSound.beep(); return }
        }
        select(ids[index], focusEditor: true)
    }

    func nextNeedingAttention() {
        let ids = visibleDocIDs.filter { doc($0)?.needsAttention == true }
        guard !ids.isEmpty else { NSSound.beep(); return }
        var start = -1
        if case .doc(let id) = selection, let i = visibleDocIDs.firstIndex(of: id) { start = i }
        let ordered = visibleDocIDs
        let next = ids.first { (ordered.firstIndex(of: $0) ?? 0) > start } ?? ids[0]
        select(next, focusEditor: true)
    }

    // MARK: Scanning

    func rescan() {
        guard let root = rootURL else { return }
        if isScanning { rescanQueued = true; return }
        isScanning = true
        let global = includeGlobal
        Task.detached(priority: .userInitiated) {
            let result = Scanner.scan(root: root, includeGlobal: global)
            await MainActor.run { AppModel.shared.finishScan(result) }
        }
    }

    /// Synchronous rescan, used right after structural changes so nothing acts on stale data.
    func rescanNow() {
        guard let root = rootURL else { return }
        finishScan(Scanner.scan(root: root, includeGlobal: includeGlobal))
    }

    private func finishScan(_ result: ScanResult) {
        let previous = scan
        scan = result
        isScanning = false
        for (id, text) in drafts {
            if let d = result.docs[id], d.primary.content == text { drafts[id] = nil }
        }
        if let pending = pendingSelection, result.docs[pending] != nil {
            selection = .doc(pending)
            pendingSelection = nil
        } else if case .doc(let id) = selection, result.docs[id] == nil {
            // The document merged into another one (e.g. CLAUDE.md became an import). Follow it.
            let successor = result.docs.values.first { d in
                d.allFiles.contains { $0.id == id } || d.linkedFrom.contains { $0.file.id == id }
            } ?? previous?.docs[id].flatMap { old in result.docs.values.first { $0.locationDir == old.locationDir } }
            selection = successor.map { .doc($0.id) } ?? .overview
        }
        if rescanQueued {
            rescanQueued = false
            rescan()
        } else if autoReaudit {
            queueChangedAudits()
        }
    }

    // MARK: Saving

    @discardableResult
    func save(_ id: String, force: Bool = false) -> Bool {
        guard let doc = doc(id), let text = drafts[id] else { return true }
        if !force {
            let changed = doc.allFiles.filter { (Scanner.readText($0.resolvedURL) ?? "") != $0.content }
            if let first = changed.first {
                alert = AlertInfo(
                    title: L("%@ changed on disk", first.displayName),
                    message: L("Another app modified %@ after Rulebook loaded it.", first.url.path.tildePath),
                    actions: [
                        .init(title: L("Overwrite"), role: .destructive) { [weak self] in self?.save(id, force: true) },
                        .init(title: L("Discard My Edits")) { [weak self] in self?.drafts[id] = nil; self?.rescan() },
                        .init(title: L("Cancel"), role: .cancel) {},
                    ])
                return false
            }
        }
        do {
            for file in doc.allFiles { try text.write(to: file.resolvedURL, atomically: true, encoding: .utf8) }
        } catch {
            alert = AlertInfo(title: L("Couldn't save %@", doc.title), message: error.localizedDescription,
                              actions: [.init(title: L("OK"), role: .cancel) {}])
            return false
        }
        drafts[id] = nil
        if var d = scan?.docs[id] {
            d.primary.content = text
            d.mirrors = d.mirrors.map { var m = $0; m.content = text; return m }
            scan?.docs[id] = d
        }
        rescan()  // also re-audits the file when "keep audits up to date" is on
        return true
    }

    func saveCurrent() {
        if let doc = currentDoc { save(doc.id) }
    }

    func saveAll() {
        for id in drafts.keys.sorted() where !save(id) { break }
    }

    func revertCurrent() {
        if let doc = currentDoc { drafts[doc.id] = nil }
    }

    func confirmTermination() -> NSApplication.TerminateReply {
        guard !drafts.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = LN(drafts.count, "Save changes to %d file before quitting?", "Save changes to %d files before quitting?")
        alert.informativeText = L("Your edits will be lost if you don't save them.")
        alert.addButton(withTitle: L("Save All"))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Don't Save"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveAll()
            return drafts.isEmpty ? .terminateNow : .terminateCancel
        case .alertSecondButtonReturn:
            return .terminateCancel
        default:
            return .terminateNow
        }
    }

    // MARK: Files

    func reveal(_ doc: Doc) { NSWorkspace.shared.activateFileViewerSelecting([doc.primary.url]) }
    func openExternally(_ doc: Doc) { NSWorkspace.shared.open(doc.primary.resolvedURL) }

    func copyPath(_ doc: Doc) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(doc.primary.url.path, forType: .string)
    }

    private func write(_ text: String, to url: URL) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            alert = AlertInfo(title: L("Couldn't save %@", url.lastPathComponent), message: error.localizedDescription,
                              actions: [.init(title: L("OK"), role: .cancel) {}])
            return false
        }
    }

    private func confirm(_ title: String, _ message: String, action: String, perform: @escaping () -> Void) {
        alert = AlertInfo(title: title, message: message, actions: [
            .init(title: action) { perform() },
            .init(title: L("Cancel"), role: .cancel) {},
        ])
    }

    func createAgents(in projectRoot: URL) {
        let url = projectRoot.appendingPathComponent("AGENTS.md")
        confirm(L("Create AGENTS.md in %@?", projectRoot.lastPathComponent),
                L("Rulebook will add %@. Claude Code, Codex and most other agents read it.", url.path.tildePath),
                action: L("Create")) { [weak self] in
            guard let self, self.write("# \(projectRoot.lastPathComponent)\n\n", to: url) else { return }
            self.pendingSelection = url.standardizedFileURL.path
            self.focusEditorOnAppear = true
            self.rescanNow()
        }
    }

    // MARK: Fixes

    func perform(_ fix: Fix, on doc: Doc) {
        switch fix {
        case .compare:
            openCompare(doc)
        case .reconcile:
            reconcile(doc)
        case .replaceWithImport(let claudeURL):
            let name = claudeURL.lastPathComponent
            confirm(L("Replace %@ with an import?", name),
                    L("%@ will contain only “@AGENTS.md”. Claude Code then loads AGENTS.md through it, so there's one file to edit.", name),
                    action: L("Replace")) { [weak self] in
                guard let self else { return }
                if self.isDirty(doc.id) { self.save(doc.id) }
                guard self.write("@AGENTS.md\n", to: claudeURL) else { return }
                self.rescanNow()
            }
        case .shareWithAgents(let claudeURL):
            let agentsURL = claudeURL.deletingLastPathComponent().appendingPathComponent("AGENTS.md")
            let content = text(for: doc)
            confirm(L("Move these rules to AGENTS.md?"),
                    L("Rulebook will create AGENTS.md with this content and reduce %@ to “@AGENTS.md”. Claude Code keeps reading the same rules, and other agents start reading them too.", claudeURL.lastPathComponent),
                    action: L("Move")) { [weak self] in
                guard let self, self.write(content, to: agentsURL), self.write("@AGENTS.md\n", to: claudeURL) else { return }
                self.drafts[doc.id] = nil
                self.pendingSelection = agentsURL.standardizedFileURL.path
                self.rescanNow()
            }
        case .createClaudeImport(let dir):
            let url = dir.appendingPathComponent("CLAUDE.md")
            confirm(L("Create a CLAUDE.md that imports AGENTS.md?"),
                    L("Claude Code will then load AGENTS.md even with a CLAUDE.local.md or a parent CLAUDE.md present."),
                    action: L("Create")) { [weak self] in
                guard let self, self.write("@AGENTS.md\n", to: url) else { return }
                self.rescanNow()
            }
        case .removeBlocks(let names):
            setText(MarkdownScan.removingBlocks(names, from: text(for: doc)), for: doc.id)
        case .retitle(let name):
            setText(MarkdownScan.retitled(text(for: doc), to: name), for: doc.id)
        case .wrapInBackticks(let raw):
            setText(MarkdownScan.wrappingInBackticks(raw, in: text(for: doc)), for: doc.id)
        }
    }

    /// AGENTS.md and CLAUDE.md docs of a pair, in that order.
    func pair(for doc: Doc) -> (agents: Doc, claude: Doc)? {
        guard let other = sibling(of: doc) else { return nil }
        return doc.primary.kind == .agents ? (doc, other) : (other, doc)
    }

    func openCompare(_ doc: Doc) {
        guard let pair = pair(for: doc) else { return }
        compare = CompareRequest(agentsID: pair.agents.id, claudeID: pair.claude.id)
    }

    // MARK: Agent

    func resolveCLI() -> URL? {
        let override = ((cliOverrides[engine] ?? "") as NSString).expandingTildeInPath
        if !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? URL(fileURLWithPath: override) : nil
        }
        if detected[engine] == nil { detected[engine] = AgentService.locate(engine) }
        return detected[engine]
    }

    /// Finds the installed CLIs and how Claude Code is billed, off the main thread.
    func refreshAgents() {
        let claudeOverride = ((cliOverrides[.claude] ?? "") as NSString).expandingTildeInPath
        Task.detached {
            let found = Dictionary(uniqueKeysWithValues: Engine.allCases.compactMap { e in AgentService.locate(e).map { (e, $0) } })
            let claude = claudeOverride.isEmpty ? found[.claude] : URL(fileURLWithPath: claudeOverride)
            let billing = claude.map(AgentService.billing(of:)) ?? .unknown
            await MainActor.run {
                AppModel.shared.detected = found
                AppModel.shared.billing = billing
            }
        }
    }

    /// The CLI, after checking Claude Code is new enough to audit. Shows an alert and returns nil otherwise.
    private func checkedCLI(silent: Bool = false) -> URL? {
        guard let cli = resolveCLI() else {
            if !silent { showError(L("%@ not found", engine.name), AgentError.notFound(engine)) }
            return nil
        }
        if !cliChecked, engine == .claude {
            if let v = AgentService.version(of: cli), !AgentService.isAtLeast(v, AgentService.minimumClaudeVersion) {
                if !silent { showError(L("Claude Code is out of date"), AgentError.tooOld(v)) }
                return nil
            }
        }
        cliChecked = true
        return cli
    }

    private func showError(_ title: String, _ error: Error) {
        alert = AlertInfo(title: title, message: error.localizedDescription, actions: [.init(title: L("OK"), role: .cancel) {}])
    }

    nonisolated static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The audit no longer matches what's in the editor (saved or not).
    func isAssessmentStale(_ doc: Doc) -> Bool {
        guard let a = assessments[doc.id] else { return false }
        return a.contentHash != Self.hash(text(for: doc))
    }

    /// The saved file changed since its audit.
    private func savedContentChanged(_ doc: Doc) -> Bool {
        guard let a = assessments[doc.id] else { return false }
        return a.contentHash != Self.hash(doc.primary.content)
    }

    static func reconcileJobID(_ agentsID: String) -> String { "reconcile:" + agentsID }

    func reconcileJob(for doc: Doc) -> AgentJob? {
        pair(for: doc).flatMap { jobs[Self.reconcileJobID($0.agents.id)] }
    }

    // MARK: Prompt audits

    private func isAuditable(_ doc: Doc) -> Bool {
        !doc.primary.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Files with no audit yet, or whose saved content changed since the last one.
    var auditCandidates: [Doc] {
        guard let scan else { return [] }
        return scan.projects.flatMap { $0.docIDs.compactMap { scan.docs[$0] } }
            .filter { isAuditable($0) && (assessments[$0.id] == nil || savedContentChanged($0)) }
    }

    var runningAudits: Int { jobs.values.filter { $0.kind == .audit && $0.isRunning && !$0.isQueued }.count }

    /// Average cost of this agent's past audits. Only Claude Code reports one.
    var typicalAuditCost: Double? {
        let costs = assessments.values.filter { ($0.engine ?? "claude") == engine.rawValue }.compactMap(\.costUSD)
        if costs.isEmpty { return engine == .claude ? 0.8 : nil }
        return costs.reduce(0, +) / Double(costs.count)
    }

    var typicalAuditSeconds: Double {
        let times = assessments.values.compactMap(\.durationSeconds)
        return times.isEmpty ? 60 : times.reduce(0, +) / Double(times.count)
    }

    func auditCurrent() { if let d = currentDoc { audit(d) } }

    /// Audit one file now (ahead of anything queued).
    func audit(_ doc: Doc) {
        if let job = jobs[doc.id], job.isRunning { return }
        guard checkedCLI() != nil else { return }
        showInspector = true
        if isDirty(doc.id) {
            alert = AlertInfo(
                title: L("Save before auditing?"),
                message: L("The audit reads %@ from disk, so your unsaved edits wouldn't be included.", doc.primary.displayName),
                actions: [
                    .init(title: L("Save and Audit")) { [weak self] in
                        guard let self, self.save(doc.id) else { return }
                        self.enqueueAudits([doc.id], front: true)
                    },
                    .init(title: L("Audit Saved Version")) { [weak self] in self?.enqueueAudits([doc.id], front: true) },
                    .init(title: L("Cancel"), role: .cancel) {},
                ])
            return
        }
        enqueueAudits([doc.id], front: true)
    }

    func confirmAuditAll() {
        let docs = auditCandidates.filter { jobs[$0.id] == nil }
        guard !docs.isEmpty, checkedCLI() != nil else { return }
        let minutes = max(1, Int((typicalAuditSeconds * Double(docs.count) / Double(auditConcurrency) / 60).rounded(.up)))
        var message = L("%1$@ reads each file and its project without changing anything. This takes about %2$d min.", engine.name, minutes) + "\n"
        if engine == .claude, case .plan(let plan) = billing {
            message += L("It counts toward your Claude %@ plan's usage limits.", plan)
        } else if engine == .claude, billing == .metered, let cost = typicalAuditCost {
            message += L("Estimated cost: about $%d.", Int(max(1, (cost * Double(docs.count)).rounded())))
        } else {
            message += L("It counts toward your %@ usage.", engine.name)
        }
        alert = AlertInfo(
            title: LN(docs.count, "Audit %d file?", "Audit %d files?"),
            message: message,
            actions: [
                .init(title: L("Audit")) { [weak self] in self?.enqueueAudits(docs.map(\.id)) },
                .init(title: L("Cancel"), role: .cancel) {},
            ])
    }

    /// Queue re-audits for files whose saved content changed since their last audit.
    func queueChangedAudits() {
        guard scan != nil else { return }
        let changed = auditCandidates.filter { assessments[$0.id] != nil && jobs[$0.id] == nil && !isDirty($0.id) }
        if !changed.isEmpty, checkedCLI(silent: true) != nil { enqueueAudits(changed.map(\.id)) }
    }

    func enqueueAudits(_ ids: [String], front: Bool = false) {
        var added: [String] = []
        for id in ids where jobs[id] == nil || jobs[id]?.error != nil {
            var job = AgentJob(kind: .audit)
            job.isQueued = true
            jobs[id] = job
            added.append(id)
        }
        if front {
            auditQueue.removeAll { ids.contains($0) }
            auditQueue.insert(contentsOf: ids.filter { jobs[$0]?.isQueued == true }, at: 0)
        } else {
            auditQueue.append(contentsOf: added)
        }
        pumpAuditQueue()
    }

    private func pumpAuditQueue() {
        while runningAudits < auditConcurrency, !auditQueue.isEmpty {
            startAudit(auditQueue.removeFirst())
        }
    }

    private func startAudit(_ id: String) {
        guard let doc = doc(id), let cli = resolveCLI() else { jobs[id] = nil; return }
        let cwd: URL, path: String
        if doc.role == .global {
            cwd = doc.primary.containingDir
            path = doc.primary.name
        } else {
            let root = URL(fileURLWithPath: doc.projectID, isDirectory: true)
            cwd = root
            path = Scanner.relative(doc.primary.url, to: root) ?? doc.primary.name
        }
        let hash = Self.hash(doc.primary.content)
        let engine = engine, model = agentModel
        jobs[id]?.isQueued = false
        jobs[id]?.startedAt = Date()
        jobs[id]?.task = Task { [weak self] in
            do {
                var result = try await AgentService.audit(engine: engine, relativePath: path, cwd: cwd, cli: cli,
                                                          model: model, language: .active) { step in
                    Task { @MainActor in AppModel.shared.jobs[id]?.steps.append(step) }
                }
                result.contentHash = hash
                self?.assessments[id] = result
                AssessmentStore.save(self?.assessments ?? [:])
                self?.jobs[id] = nil
            } catch {
                if !Task.isCancelled {
                    self?.jobs[id]?.isRunning = false
                    self?.jobs[id]?.error = error.localizedDescription
                    if case AgentError.limit(let message) = error { self?.pauseAudits(message) }
                }
            }
            self?.pumpAuditQueue()
        }
    }

    /// After a usage limit, the files still waiting would all fail the same way. Take them off the queue
    /// and say so once, instead of marking each one failed.
    private func pauseAudits(_ message: String) {
        let waiting = auditQueue
        guard !waiting.isEmpty else { return }
        auditQueue.removeAll()
        for id in waiting { jobs[id] = nil }
        alert = AlertInfo(title: L("Audits paused"),
                          message: message + "\n" + LN(waiting.count, "%d file was left unaudited.", "%d files were left unaudited."),
                          actions: [.init(title: L("OK"), role: .cancel) {}])
    }

    func cancelJob(_ id: String) {
        auditQueue.removeAll { $0 == id }
        jobs[id]?.task?.cancel()
        jobs[id] = nil
        pumpAuditQueue()
    }

    func stopAllAudits() {
        auditQueue.removeAll()
        for (id, job) in jobs where job.kind == .audit {
            job.task?.cancel()
            jobs[id] = nil
        }
    }

    // MARK: Merge

    func reconcile(_ doc: Doc) {
        guard let pair = pair(for: doc) else { return }
        let jobID = Self.reconcileJobID(pair.agents.id)
        if jobs[jobID]?.isRunning == true { return }
        guard let cli = resolveCLI() else {
            showError(L("%@ not found", engine.name), AgentError.notFound(engine))
            return
        }
        compare = nil
        let agentsText = text(for: pair.agents), claudeText = text(for: pair.claude)
        let agentsID = pair.agents.id, claudeID = pair.claude.id
        let project = doc.projectName, dir = URL(fileURLWithPath: doc.projectID, isDirectory: true), engine = engine, model = agentModel
        var job = AgentJob(kind: .reconcile)
        job.task = Task { [weak self] in
            do {
                let result = try await AgentService.reconcile(
                    engine: engine, projectName: project, dir: dir, agentsText: agentsText, claudeText: claudeText,
                    cli: cli, model: model, language: .active) { step in
                    Task { @MainActor in AppModel.shared.jobs[jobID]?.steps.append(step) }
                }
                self?.jobs[jobID] = nil
                self?.reconcileReview = ReconcileReview(agentsID: agentsID, claudeID: claudeID, result: result)
            } catch {
                if Task.isCancelled { self?.jobs[jobID] = nil; return }
                self?.jobs[jobID]?.isRunning = false
                self?.jobs[jobID]?.error = error.localizedDescription
            }
        }
        jobs[jobID] = job
    }

    /// Puts the merged text into both files and saves them together, so neither is left half merged.
    func applyReconcile(_ review: ReconcileReview) {
        setText(review.result.agentsMD, for: review.agentsID)
        setText(review.result.claudeMD, for: review.claudeID)
        reconcileReview = nil
        if save(review.agentsID) { save(review.claudeID) }
        select(review.agentsID)
    }
}

enum AssessmentStore {
    static var url: URL {
        let dir = LaunchOptions.storeDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Rulebook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("assessments.json")
    }

    static func load() -> [String: Assessment] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Assessment].self, from: data)) ?? [:]
    }

    static func save(_ assessments: [String: Assessment]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(assessments) { try? data.write(to: url, options: .atomic) }
    }
}
