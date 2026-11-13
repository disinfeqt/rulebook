import Foundation

enum FileKind: String, Hashable, Sendable {
    case claude, agents, claudeLocal
}

/// One instruction file on disk.
struct InstructionFile: Identifiable, Hashable, Sendable {
    let url: URL
    /// The real file after resolving symlinks. Writes go here.
    let resolvedURL: URL
    let kind: FileKind
    let inDotClaude: Bool
    let isSymlink: Bool
    var content: String
    var modified: Date?

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var displayName: String { inDotClaude ? ".claude/\(name)" : name }
    var containingDir: URL { url.deletingLastPathComponent() }
    /// The folder this file applies to (the parent of `.claude/` for files inside it).
    var locationDir: URL {
        inDotClaude ? containingDir.deletingLastPathComponent() : containingDir
    }
}

/// How CLAUDE.md and AGENTS.md relate in one folder.
enum PairStatus: Hashable, Sendable {
    case linkedImport
    case linkedSymlink
    case layered
    case duplicated
    case diverged(similarity: Int)
    case agentsOnly
    case agentsIgnored
    case claudeOnly
    case brokenImport
    case localOnly
    case global

    /// Status with associated values stripped, for grouping.
    var kind: PairStatus {
        if case .diverged = self { return .diverged(similarity: 0) }
        return self
    }
}

enum DocRole: Hashable, Sendable {
    case unified          // one real file, the other name points at it
    case mirrored         // identical copies, saved together
    case sharedBase       // AGENTS.md that CLAUDE.md imports and builds on
    case claudeExtension  // CLAUDE.md that imports AGENTS.md and adds more
    case diverged
    case agentsOnly
    case claudeOnly
    case local
    case global
    case extra
}

struct Access: Hashable, Sendable {
    var reads: Bool
    var note: String
}

struct Readers: Hashable, Sendable {
    var claude: Access
    var others: Access
}

enum Severity: Int, Comparable, Hashable, Sendable {
    case info = 0, warning, error
    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum Fix: Hashable, Sendable {
    case compare
    case reconcile
    case replaceWithImport(claude: URL)
    case shareWithAgents(claude: URL)
    case createClaudeImport(dir: URL)
    case removeBlocks([String])
    case retitle(String)
    case wrapInBackticks(String)
}

struct Issue: Identifiable, Hashable, Sendable {
    let id: String
    let severity: Severity
    let title: String
    let detail: String
    var fixes: [Fix] = []
    /// Text to select in the editor when the issue is clicked.
    var reveal: String? = nil
}

struct LinkInfo: Hashable, Sendable {
    let file: InstructionFile
    let viaSymlink: Bool
}

/// A logical document: what you actually edit. Linked and duplicated files collapse into one.
struct Doc: Identifiable, Hashable, Sendable {
    let id: String
    let projectID: String
    let projectName: String
    let locationDir: URL
    let relativeDir: String
    var primary: InstructionFile
    /// Identical copies that are written together with the primary file.
    var mirrors: [InstructionFile]
    /// Files that only point at this one (an `@import`-only CLAUDE.md, or a symlink).
    let linkedFrom: [LinkInfo]
    let role: DocRole
    let status: PairStatus
    let siblingID: String?
    let readers: Readers
    var staticIssues: [Issue]
    /// Static issues plus content issues for the saved text, most severe first.
    var savedIssues: [Issue] = []

    var allFiles: [InstructionFile] { [primary] + mirrors }
    var savedLevel: Severity? { savedIssues.map(\.severity).max() }
    var needsAttention: Bool { (savedLevel ?? .info) >= .warning }

    var title: String {
        if role == .global { return (primary.url.path as NSString).abbreviatingWithTildeInPath }
        return relativeDir.isEmpty ? primary.displayName : "\(relativeDir)/\(primary.displayName)"
    }
}

struct Project: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let root: URL
    var docIDs: [String]
    let status: PairStatus?
    let isGlobal: Bool
}

struct ManagedBlockGroup: Identifiable, Sendable {
    struct Variant: Sendable {
        let body: String
        let docIDs: [String]
        let paths: [String]
    }
    let name: String
    let variants: [Variant]
    var id: String { name }
    var total: Int { variants.reduce(0) { $0 + $1.paths.count } }
}

struct ScanResult: Sendable {
    let root: URL
    let date: Date
    var projects: [Project]
    var docs: [String: Doc]
    let fileCount: Int
    let foldersVisited: Int
    let missing: [URL]
    let blockGroups: [ManagedBlockGroup]
    /// Rules found in more than one project, from the saved files.
    let repeatedRules: [RepeatedRule]
    let duration: TimeInterval
}
