import SwiftUI

/// One row of the skills table: a skill, or a link or folder in a skills folder that isn't one. It carries the
/// values the columns sort by.
struct SkillRow: Identifiable {
    let id: String
    let entry: SkillEntry
    /// Nil for a link that points nowhere and for an empty folder.
    let doc: Doc?
    let name: String
    let project: String
    /// Where `npx skills` installed it from. Empty for a skill it doesn't manage.
    let source: String
    let description: String
    let issue: Issue?
    /// More agents load it the higher it is, as in the overview.
    let readBy: Int
    /// What the name and description take up in every session, where every skill is listed.
    let listed: Int
    /// What SKILL.md takes up once an agent uses the skill.
    let tokens: Int
    let urgency: Int
    let modified: Date
}

/// Every skill in the projects and in the home folder: who loads it and what's wrong with it.
struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\SkillRow.urgency, order: .reverse),
                                    KeyPathComparator(\SkillRow.name)]

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
                        table(rows)
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
    }

    private var subtitle: String {
        let path = model.rootPath?.tildePath ?? ""
        guard let scan = model.scan else { return path }
        let attention = scan.skills.filter { entry in
            entry.docID.flatMap { scan.docs[$0] }?.needsAttention ?? ((entry.issue?.severity ?? .info) >= .warning)
        }.count
        return attention == 0 ? path : path + " — " + LN(attention, "%d skill needs attention", "%d skills need attention")
    }

    /// The sidebar's search field and the attention filter narrow this list too.
    private func rows(_ scan: ScanResult) -> [SkillRow] {
        let query = model.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return scan.skills.compactMap { entry in
            let doc = entry.docID.flatMap(model.doc)
            let text = doc.map(model.text(for:)) ?? ""
            let description = SkillScan.frontmatter(in: text)?.description ?? ""
            let issue = doc == nil ? entry.issue : doc?.topIssue
            if model.attentionOnly, (issue?.severity ?? .info) < .warning, !(doc.map { model.isDirty($0.id) } ?? false) { return nil }
            if !query.isEmpty, ![entry.name, entry.projectName, description, doc?.skill?.source ?? ""]
                .contains(where: { $0.lowercased().contains(query) }) {
                return nil
            }
            return SkillRow(
                id: entry.id, entry: entry, doc: doc, name: entry.name,
                project: doc.map { $0.relativeDir.isEmpty ? $0.projectName : $0.projectName + "/" + $0.relativeDir } ?? entry.projectName,
                source: doc?.skill?.source ?? "", description: description, issue: issue, readBy: doc?.readByRank ?? -1,
                listed: doc == nil ? 0 : SkillScan.listingTokens(name: entry.name, description: description),
                tokens: MarkdownScan.stats(text).tokens,
                urgency: issue.map { $0.severity >= .warning ? $0.severity.rawValue + 1 : 0 } ?? 0,
                modified: doc?.primary.modified ?? .distantPast)
        }
    }

    private func table(_ rows: [SkillRow]) -> some View {
        // Cells and the row menu are given the model, as in the overview: a table cell doesn't always get the
        // window's environment on macOS.
        let model = model
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Skill", value: \.name) { row in
                HStack(spacing: 6) {
                    Text(row.name).foregroundStyle(row.doc == nil ? HierarchicalShapeStyle.secondary : .primary)
                    if let doc = row.doc, model.isDirty(doc.id) {
                        Circle().fill(.secondary).frame(width: 6, height: 6).help("Unsaved changes")
                    }
                }
                .lineLimit(1)
                .help(row.description)
            }
            .width(min: 120, ideal: 220, max: 360)
            TableColumn("Project", value: \.project) { row in
                Text(row.project).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 90, ideal: 150, max: 260)
            TableColumn("Installed From", value: \.source) { row in
                Text(row.source).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(row.source.isEmpty ? "" : L("`npx skills` manages this skill. Updating it there replaces the folder, so changes made here don't last.").replacingOccurrences(of: "`", with: ""))
            }
            .width(min: 90, ideal: 190, max: 300)
            TableColumn("Read By", sortUsing: KeyPathComparator(\SkillRow.readBy)) { row in
                if let doc = row.doc {
                    Text(doc.readBy)
                        .foregroundStyle(.secondary)
                        .help([doc.readers.claude, doc.readers.others].map(\.note).filter { !$0.isEmpty }.joined(separator: "\n"))
                }
            }
            .width(min: 90, ideal: 120, max: 180)
            TableColumn("Issue", sortUsing: KeyPathComparator(\SkillRow.urgency, order: .reverse)) { row in
                if let issue = row.issue {
                    Label {
                        Text(issue.title)
                    } icon: {
                        Image(systemName: issue.severity.icon).foregroundStyle(issue.severity.color)
                    }
                    .help(issue.detail.replacingOccurrences(of: "`", with: ""))
                }
            }
            .width(min: 160, ideal: 320)
            TableColumn("Tokens", sortUsing: KeyPathComparator(\SkillRow.listed, order: .reverse)) { row in
                if row.doc != nil {
                    Text(verbatim: row.listed.formatted())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(L("The name and description, listed in every session. All of SKILL.md, loaded when the skill is used, is ≈%@ tokens.", row.tokens.formatted()))
                }
            }
            .width(min: 56, ideal: 64, max: 90)
            TableColumn("Modified", sortUsing: KeyPathComparator(\SkillRow.modified, order: .reverse)) { row in
                if let date = row.doc?.primary.modified {
                    Text(date.listStyle).foregroundStyle(.secondary)
                }
            }
            .width(min: 96, ideal: 150, max: 200)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: String.self) { ids in
            if let row = ids.first.flatMap({ byID[$0] }) {
                if let doc = row.doc {
                    Button("Open") { model.openSkill(doc.id) }
                    SkillMenu(doc: doc).environment(model)
                } else {
                    if case .removeSkillLink(let url)? = row.issue?.fixes.first {
                        Button("Remove Link…") { model.removeSkillLink(url) }
                    } else {
                        Button("Move to Trash…") { model.confirmTrash(row.entry) }
                    }
                    Divider()
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.entry.dir]) }
                }
            }
        } primaryAction: { ids in
            guard let row = ids.first.flatMap({ byID[$0] }) else { return }
            if let doc = row.doc {
                model.openSkill(doc.id)
            } else if case .removeSkillLink(let url)? = row.issue?.fixes.first {
                model.removeSkillLink(url)
            }
        }
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
