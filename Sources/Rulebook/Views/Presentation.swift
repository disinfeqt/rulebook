import SwiftUI

extension PairStatus {
    var label: String {
        switch self {
        case .linkedImport, .linkedSymlink: return L("Linked")
        case .layered: return L("Layered")
        case .duplicated: return L("Duplicated")
        case .diverged(let pct): return L("Diverged, %d%% alike", pct)
        case .agentsOnly: return L("AGENTS.md only")
        case .agentsIgnored: return L("Skipped by Claude Code")
        case .claudeOnly: return L("CLAUDE.md only")
        case .brokenImport: return L("Broken import")
        case .localOnly: return L("Personal")
        case .global: return L("Global")
        }
    }

    var explanation: String {
        switch self {
        case .linkedImport: return L("CLAUDE.md only imports AGENTS.md, so every agent reads the same file.")
        case .linkedSymlink: return L("One file is a symlink to the other, so every agent reads the same file.")
        case .layered: return L("CLAUDE.md imports AGENTS.md and adds rules only Claude Code gets.")
        case .duplicated: return L("CLAUDE.md and AGENTS.md are separate copies with the same content.")
        case .diverged: return L("Separate files with different content. Claude Code reads only CLAUDE.md, and other agents read only AGENTS.md.")
        case .agentsOnly: return L("Just AGENTS.md. Claude Code and other agents all read it.")
        case .agentsIgnored: return L("Just AGENTS.md, but a CLAUDE.local.md or a parent CLAUDE.md makes Claude Code skip it.")
        case .claudeOnly: return L("Just CLAUDE.md. Other agents don't read it.")
        case .brokenImport: return L("CLAUDE.md imports an AGENTS.md that doesn't exist.")
        case .localOnly: return L("A personal CLAUDE.local.md, usually kept out of git.")
        case .global: return L("Applies to every project on this Mac.")
        }
    }
}

extension Doc {
    /// Who reads this file, in a word or two.
    var readBy: String {
        if let skill, !readers.claude.reads, skill.homes == [.codex] { return "Codex" }
        if role == .global { return primary.kind == .claude ? "Claude Code" : "Codex" }
        switch (readers.claude.reads, readers.others.reads) {
        case (true, true): return L("All agents")
        case (true, false): return "Claude Code"
        case (false, true): return L("Other agents")
        case (false, false): return L("No agent")
        }
    }

    /// The same, as the bar under the editor says it.
    var readByPhrase: String {
        if let skill, !readers.claude.reads, skill.homes == [.codex] { return L("Read by Codex") }
        if role == .global { return primary.kind == .claude ? L("Read by Claude Code") : L("Read by Codex") }
        switch (readers.claude.reads, readers.others.reads) {
        case (true, true): return L("Read by all agents")
        case (true, false): return L("Read by Claude Code")
        case (false, true): return L("Read by other agents")
        case (false, false): return L("Read by no agent")
        }
    }

    /// 3 when every agent reads the file, 2 for Claude Code alone, 1 for the others alone, 0 for none.
    var readByRank: Int { (readers.claude.reads ? 2 : 0) + (readers.others.reads ? 1 : 0) }
}

extension Date {
    /// A date the way Finder lists it: "Today at 11:52 PM", "Yesterday at 9:05 AM", "Oct 23", or with the
    /// year when it isn't this one.
    var listStyle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) || calendar.isDateInYesterday(self) { return Self.relative.string(from: self) }
        if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
            return formatted(.dateTime.month(.abbreviated).day())
        }
        return formatted(date: .abbreviated, time: .omitted)
    }

    private static let relative: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

extension Severity {
    var icon: String {
        switch self {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    /// Color is kept for things that need fixing. Notes stay gray.
    var color: Color {
        switch self {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

extension Fix {
    var label: String {
        switch self {
        case .compare: return L("Compare")
        case .reconcile: return L("Merge")
        case .replaceWithImport: return L("Replace with Import")
        case .shareWithAgents: return L("Move to AGENTS.md")
        case .createClaudeImport: return L("Create CLAUDE.md")
        case .removeBlocks: return L("Remove from This File")
        case .retitle(let name): return L("Retitle to %@", name)
        case .wrapInBackticks: return L("Wrap in Backticks")
        case .linkSkill(let home): return L("Link into %@", home.folder)
        case .moveSkillToAgents: return L("Move to %@", SkillHome.agents.folder)
        case .linkSkillCopies: return L("Replace Copy with Link")
        case .useSkillVersion: return L("Use This Version")
        case .removeSkillLink: return L("Remove Link")
        case .renameSkill(let name): return L("Rename to %@", name)
        }
    }
}

extension String {
    /// "~/Projects/app/CLAUDE.md". Honors `$HOME`, unlike `abbreviatingWithTildeInPath`.
    var tildePath: String {
        let env = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let home = URL(fileURLWithPath: env.isEmpty ? NSHomeDirectory() : env).standardizedFileURL.path
        let path = hasPrefix("/") ? URL(fileURLWithPath: self).standardizedFileURL.path : self
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Renders `code` and **bold** in text that is already localized, without looking it up as a key.
    var inlineMarkdown: AttributedString {
        (try? AttributedString(markdown: self, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(self)
    }
}

extension Doc {
    /// What the sidebar and the overview show for this file: its worst problem, or nothing.
    var topIssue: Issue? { needsAttention ? savedIssues.first : nil }
}

extension Assessment.Grade {
    var color: Color {
        switch self {
        case .serious: return .red
        case .minor: return .orange
        case .clean: return .green
        }
    }
}
