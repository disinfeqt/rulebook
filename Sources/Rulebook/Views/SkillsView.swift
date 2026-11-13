import SwiftUI

/// One row of the skills table: a skill, something in a skills folder that isn't one, or the skills one project
/// got from one source, which open under it. It carries the values the columns sort by.
struct SkillRow: Identifiable {
    let id: String
    /// Nil for a row that stands for several skills.
    var entry: SkillEntry? = nil
    /// Nil for a link that points nowhere, for an empty folder and for a row of several skills.
    var doc: Doc? = nil
    /// The skill's name, or for several skills their source, so they sort among the names.
    let name: String
    let project: String
    /// Where it was installed from: the repository `npx skills` got it from, or claude.ai for a skill synced
    /// from the account. Empty for a skill of the user's own.
    let source: String
    var description = ""
    var issue: Issue? = nil
    /// Who loads it, in a word or two.
    let readBy: String
    /// More agents load it the higher it is, as in the overview.
    let readByRank: Int
    /// What the name and description take up in every session, where every skill is listed.
    let listed: Int
    /// What SKILL.md takes up once an agent uses the skill.
    let tokens: Int
    let urgency: Int
    let modified: Date
    /// The skills of a row that stands for several. They don't repeat its project and source.
    var children: [SkillRow] = []
    var isChild = false

    var isGroup: Bool { !children.isEmpty }
    /// How many of the skills under this row have something to fix.
    var attention: Int { children.filter { $0.urgency > 0 }.count }
}

/// The skills in the projects and in the home folder, or those of one place: who loads each and what's wrong
/// with it.
struct SkillsView: View {
    /// The place whose skills to list: a project's path or "global". Nil for all of them.
    var scope: String? = nil
    @Environment(AppModel.self) private var model
    /// The columns of the list of every skill, and of one place's list, which leaves out the Project column:
    /// the sidebar already names the place.
    @State private var allColumns = TableColumnCustomization<SkillRow>()
    @State private var placeColumns: TableColumnCustomization<SkillRow> = {
        var columns = TableColumnCustomization<SkillRow>()
        columns[visibility: "project"] = .hidden
        return columns
    }()
    @State private var selection: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\SkillRow.urgency, order: .reverse),
                                    KeyPathComparator(\SkillRow.name)]
    /// In the list of every skill, sets start closed, so a project with forty from one source is one row. In one
    /// place's list they start open: its skills are what you came for. These are the ones toggled since.
    @State private var toggled: Set<String> = []

    /// A project's skills from one source are shown as one row from this many up.
    private let groupSize = 3

    var body: some View {
        Group {
            if let scan = model.scan {
                let rows = rows(scan)
                if scan.skills.isEmpty {
                    ContentUnavailableView {
                        Label("No Skills", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text(L("There's no .claude/skills or .agents/skills folder in %@ or in your home folder.", scan.root.path.tildePath))
                    }
                } else if rows.isEmpty && !model.searchText.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                } else if rows.isEmpty {
                    Text("Nothing needs attention").foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        table(grouped(rows))
                        Divider()
                        footer(rows)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Skills")
        .navigationSubtitle(subtitle)
        .onChange(of: scope) {
            selection = []
            toggled = []
        }
    }

    private func entries(_ scan: ScanResult) -> [SkillEntry] {
        scope == nil ? scan.skills : scan.skills.filter { $0.projectID == scope }
    }

    /// Where the skills are: the scanned folder, or the one place.
    private var subtitle: String {
        guard let scan = model.scan else { return model.rootPath?.tildePath ?? "" }
        let entries = entries(scan)
        let place = scope == nil ? scan.root.path.tildePath : (entries.first?.projectName ?? "")
        let attention = entries.filter { entry in
            entry.needsAttention
        }.count
        return attention == 0 ? place : place + " — " + LN(attention, "%d skill needs attention", "%d skills need attention")
    }

    /// Whether the list is narrowed by the sidebar's search field or the attention filter.
    private var isFiltered: Bool {
        model.attentionOnly || !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// One row per skill. The sidebar's search field and the attention filter narrow this list too.
    private func rows(_ scan: ScanResult) -> [SkillRow] {
        entries(scan).filter(model.isVisible).map { entry in
            let doc = entry.docID.flatMap(model.doc)
            let issue = doc == nil ? entry.issue : doc?.topIssue
            return SkillRow(
                id: entry.id, entry: entry, doc: doc, name: entry.name,
                project: doc.map { $0.relativeDir.isEmpty ? $0.projectName : $0.projectName + "/" + $0.relativeDir } ?? entry.projectName,
                source: entry.source, description: entry.description, issue: issue,
                readBy: doc?.readBy ?? "", readByRank: doc?.readByRank ?? -1,
                listed: doc == nil ? 0 : SkillScan.listingTokens(name: entry.name, description: entry.description),
                tokens: doc.map(model.stats(for:))?.tokens ?? 0,
                urgency: issue.map { $0.severity >= .warning ? $0.severity.rawValue + 1 : 0 } ?? 0,
                modified: doc?.primary.modified ?? .distantPast)
        }
    }

    /// The rows with each project's skills from one source put under one row. A narrowed list stays flat, so
    /// what was searched for is in sight.
    private func grouped(_ rows: [SkillRow]) -> [SkillRow] {
        guard !isFiltered else { return rows }
        var sets: [String: [SkillRow]] = [:]
        for row in rows where !row.source.isEmpty {
            sets["set:" + row.project + "\u{0}" + row.source, default: []].append(row)
        }
        var result = rows.filter { $0.source.isEmpty }
        for (id, members) in sets {
            guard members.count >= groupSize else { result += members; continue }
            let readers = Set(members.map(\.readBy))
            result.append(SkillRow(
                id: id, name: members[0].source, project: members[0].project, source: members[0].source,
                readBy: readers.count == 1 ? members[0].readBy : L("Varies"),
                readByRank: members.map(\.readByRank).min() ?? 0,
                listed: members.reduce(0) { $0 + $1.listed }, tokens: members.reduce(0) { $0 + $1.tokens },
                urgency: members.map(\.urgency).max() ?? 0,
                modified: members.map(\.modified).max() ?? .distantPast,
                children: members.map { var child = $0; child.isChild = true; return child }))
        }
        return result
    }

    private func table(_ rows: [SkillRow]) -> some View {
        // Cells and the row menu are given the model, as in the overview: a table cell doesn't always get the
        // window's environment on macOS.
        let model = model
        var byID: [String: SkillRow] = [:]
        for row in rows {
            byID[row.id] = row
            for child in row.children { byID[child.id] = child }
        }
        return Table(of: SkillRow.self, selection: $selection, sortOrder: $sortOrder,
                     columnCustomization: scope == nil ? $allColumns : $placeColumns) {
            TableColumn("Skill", value: \.name) { row in
                HStack(spacing: 6) {
                    if row.isGroup {
                        Text(LN(row.children.count, "%d skill", "%d skills"))
                    } else {
                        Text(row.name).foregroundStyle(row.doc == nil ? HierarchicalShapeStyle.secondary : .primary)
                    }
                    if let doc = row.doc, model.isDirty(doc.id) {
                        Circle().fill(.secondary).frame(width: 6, height: 6).help("Unsaved changes")
                    }
                }
                .lineLimit(1)
                .help(row.description)
            }
            .width(min: 120, ideal: 220, max: 360)
            .customizationID("skill")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Project", value: \.project) { row in
                if !row.isChild {
                    Text(row.project).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 90, ideal: 150, max: 260)
            .customizationID("project")
            TableColumn("Installed From", value: \.source) { row in
                if !row.isChild, !row.source.isEmpty {
                    Text(row.source).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(row.source == "claude.ai" ? L("Synced from your claude.ai account")
                              : L("`npx skills` manages this skill. Updating it there replaces the folder, so changes made here don't last.").replacingOccurrences(of: "`", with: ""))
                }
            }
            .width(min: 90, ideal: 190, max: 300)
            .customizationID("source")
            TableColumn("Read By", sortUsing: KeyPathComparator(\SkillRow.readByRank)) { row in
                Text(row.readBy)
                    .foregroundStyle(.secondary)
                    .help(row.doc.map { [$0.readers.claude, $0.readers.others].map(\.note).filter { !$0.isEmpty }.joined(separator: "\n") } ?? "")
            }
            .width(min: 90, ideal: 120, max: 180)
            .customizationID("readBy")
            TableColumn("Issue", sortUsing: KeyPathComparator(\SkillRow.urgency, order: .reverse)) { row in
                if let issue = row.issue {
                    Label {
                        Text(issue.title)
                    } icon: {
                        Image(systemName: issue.severity.icon).foregroundStyle(issue.severity.color)
                    }
                    .help(issue.detail.replacingOccurrences(of: "`", with: ""))
                } else if row.attention > 0 {
                    Label {
                        Text(LN(row.attention, "%d skill needs attention", "%d skills need attention"))
                    } icon: {
                        Image(systemName: Severity.warning.icon).foregroundStyle(Severity.warning.color)
                    }
                }
            }
            .width(min: 160, ideal: 320)
            .customizationID("issue")
            TableColumn("Tokens", sortUsing: KeyPathComparator(\SkillRow.listed, order: .reverse)) { row in
                if row.doc != nil || row.isGroup {
                    Text(verbatim: row.listed.formatted())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(L("The name and description, listed in every session. All of SKILL.md, loaded when the skill is used, is ≈%@ tokens.", row.tokens.formatted()))
                }
            }
            .width(min: 56, ideal: 64, max: 90)
            .customizationID("tokens")
            TableColumn("Modified", sortUsing: KeyPathComparator(\SkillRow.modified, order: .reverse)) { row in
                if row.modified != .distantPast {
                    Text(row.modified.listStyle).foregroundStyle(.secondary)
                }
            }
            .width(min: 96, ideal: 150, max: 200)
            .customizationID("modified")
        } rows: {
            ForEach(rows.sorted(using: sortOrder)) { row in
                if row.isGroup {
                    DisclosureTableRow(row, isExpanded: binding(row.id)) {
                        ForEach(row.children.sorted(using: sortOrder)) { TableRow($0) }
                    }
                } else {
                    TableRow(row)
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        // One table serves every place's list, so going from one project's skills to the next reuses its rows.
        // The list of every skill has a column more, and a table doesn't fit its columns again when one appears.
        .id(scope == nil)
        .contextMenu(forSelectionType: String.self) { ids in
            if let row = ids.first.flatMap({ byID[$0] }) {
                if row.isGroup {
                    Button(binding(row.id).wrappedValue ? "Collapse" : "Expand") { binding(row.id).wrappedValue.toggle() }
                } else if let doc = row.doc {
                    Button("Open") { model.openSkill(doc.id) }
                    SkillMenu(doc: doc).environment(model)
                } else if let entry = row.entry {
                    if case .removeSkillLink(let url)? = row.issue?.fixes.first {
                        Button("Remove Link…") { model.removeSkillLink(url) }
                    } else {
                        Button("Move to Trash…") { model.confirmTrash(entry) }
                    }
                    Divider()
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.dir]) }
                }
            }
        } primaryAction: { ids in
            guard let row = ids.first.flatMap({ byID[$0] }) else { return }
            if row.isGroup {
                binding(row.id).wrappedValue.toggle()
            } else if let doc = row.doc {
                model.openSkill(doc.id)
            } else if case .removeSkillLink(let url)? = row.issue?.fixes.first {
                model.removeSkillLink(url)
            }
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        let startsOpen = scope != nil || LaunchOptions.openSkillSets
        return Binding(get: { toggled.contains(id) != startsOpen },
                       set: { if $0 != startsOpen { toggled.insert(id) } else { toggled.remove(id) } })
    }

    /// What the table holds, and what the global skills cost: each agent lists the ones it loads in every session.
    private func footer(_ rows: [SkillRow]) -> some View {
        let skills = rows.filter { $0.doc != nil }
        let global = skills.filter { $0.doc?.skill?.isGlobal == true }
        let claude = global.filter { $0.doc?.readers.claude.reads == true }.reduce(0) { $0 + $1.listed }
        let codex = global.filter { $0.doc?.readers.others.reads == true }.reduce(0) { $0 + $1.listed }
        var parts = [LN(skills.count, "%d skill", "%d skills")]
        if claude > 0 { parts.append(L("Global skills take ≈%@ tokens of every Claude Code session", claude.formatted())) }
        if codex > 0 { parts.append(L("≈%@ of every Codex session", codex.formatted())) }
        return HStack {
            Text(parts.joined(separator: " · "))
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

/// What you can do with a skill, for the menus that open on a right click.
struct SkillMenu: View {
    let doc: Doc
    @Environment(AppModel.self) private var model

    var body: some View {
        if doc.siblingID != nil {
            Button("Compare Versions") { model.openCompare(doc) }
        }
        if model.isDirty(doc.id) {
            Divider()
            Button("Save") { model.save(doc.id) }
            Button("Revert to Saved") { model.drafts[doc.id] = nil }
        }
        Divider()
        Button("Reveal in Finder") { model.reveal(doc) }
        Button("Open in Default Editor") { model.openExternally(doc) }
        Button("Copy Path") { model.copyPath(doc) }
        Divider()
        Button("Move to Trash…") { model.confirmTrashSkill(doc) }
    }
}
