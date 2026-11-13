import SwiftUI

/// One row of the overview table: an instruction file, or a repository that has none. It carries the values
/// the columns sort by.
struct OverviewRow: Identifiable {
    let id: String
    let project: String
    /// Which file this is, shown next to the project name when the name alone doesn't say.
    let path: String?
    /// Nil for a repository without an instruction file.
    let doc: Doc?
    let folder: URL
    /// More agents read it the higher it is: 3 for all of them, -1 for a repository without a file.
    let readBy: Int
    let tokens: Int
    let lines: Int
    /// How bad the file's audit is: 3 for serious findings, 2 for minor ones, 1 when clean and 0 with no audit.
    let audit: Int
    /// 1 to 3 by the severity of the file's most serious issue, so a file with an issue sorts above one without.
    let urgency: Int
    let modified: Date
}

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\OverviewRow.urgency, order: .reverse)]

    var body: some View {
        Group {
            if let scan = model.scan {
                if scan.projects.isEmpty && scan.missing.isEmpty {
                    ContentUnavailableView {
                        Label("No Instruction Files", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text(L("There's no CLAUDE.md or AGENTS.md in %@.", scan.root.path.tildePath))
                    }
                } else {
                    let rows = rows(scan)
                    if rows.isEmpty && !model.searchText.isEmpty {
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
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Rules")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.jobs.values.contains(where: { $0.kind == .audit && $0.error == nil }) {
                    Button { model.stopAllAudits() } label: { ToolbarTitle("Stop Audits") }
                } else {
                    Button { model.confirmAuditAll() } label: { ToolbarTitle("Audit All…") }
                        .disabled(model.auditCandidates.isEmpty)
                        .help("Audit every file that is new or has changed since its last audit")
                }
            }
        }
    }

    private var subtitle: String {
        let path = model.rootPath?.tildePath ?? ""
        let attention = model.scan?.docs.values.filter { $0.skill == nil && $0.needsAttention }.count ?? 0
        return attention == 0 ? path : path + " — " + LN(attention, "%d file needs attention", "%d files need attention")
    }

    /// The files the sidebar shows, so its search field and attention filter narrow the table too, followed by
    /// the repositories that have no instruction file.
    private func rows(_ scan: ScanResult) -> [OverviewRow] {
        var rows: [OverviewRow] = []
        for project in model.visibleProjects {
            let several = (scan.projects.first { $0.id == project.id }?.docIDs.count ?? 0) > 1
            for doc in project.docIDs.compactMap(model.doc) {
                let stats = MarkdownScan.stats(model.text(for: doc))
                let audit = switch model.assessments[doc.id]?.grade {
                case .serious: 3
                case .minor: 2
                case .clean: 1
                case nil: 0
                }
                rows.append(OverviewRow(
                    id: doc.id, project: doc.projectName,
                    path: several || !doc.relativeDir.isEmpty || doc.role == .global ? doc.title : nil,
                    doc: doc, folder: doc.locationDir, readBy: doc.readByRank, tokens: stats.tokens, lines: stats.lines,
                    audit: audit, urgency: doc.topIssue.map { $0.severity.rawValue + 1 } ?? 0,
                    modified: doc.primary.modified ?? .distantPast))
            }
        }
        if !model.attentionOnly {
            let query = model.searchText.trimmingCharacters(in: .whitespaces).lowercased()
            for folder in scan.missing where query.isEmpty || folder.lastPathComponent.lowercased().contains(query) {
                rows.append(OverviewRow(
                    id: "missing:" + folder.path, project: folder.lastPathComponent, path: nil, doc: nil, folder: folder,
                    readBy: -1, tokens: 0, lines: 0, audit: 0, urgency: 0, modified: .distantPast))
            }
        }
        return rows
    }

    private func table(_ rows: [OverviewRow]) -> some View {
        // Each cell is hosted on its own, and on macOS it doesn't always get the window's environment: reading
        // AppModel from it crashed when sorting moved the rows. So cells and the row menu are given the model.
        let model = model
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        // Text columns sort A to Z first. The others start with what matters most: the files fewest agents read,
        // and the most urgent, largest, most recently changed and worst audited files.
        return Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Project", value: \.project) { row in
                HStack(spacing: 6) {
                    Text(row.project)
                        .foregroundStyle(row.doc == nil ? HierarchicalShapeStyle.secondary : .primary)
                    if let path = row.path {
                        Text(path).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .width(min: 120, ideal: 220, max: 360)
            TableColumn("Read By", sortUsing: KeyPathComparator(\OverviewRow.readBy)) { row in
                if let doc = row.doc {
                    Text(doc.readBy)
                        .foregroundStyle(.secondary)
                        .help(L("%@: %@", doc.status.label, doc.status.explanation))
                } else {
                    Text("No instruction file").foregroundStyle(.tertiary)
                }
            }
            .width(min: 90, ideal: 120, max: 180)
            TableColumn("Issue", sortUsing: KeyPathComparator(\OverviewRow.urgency, order: .reverse)) { row in
                if let issue = row.doc?.topIssue {
                    Label {
                        Text(issue.title)
                    } icon: {
                        Image(systemName: issue.severity.icon).foregroundStyle(issue.severity.color)
                    }
                    .help(issue.detail.replacingOccurrences(of: "`", with: ""))
                }
            }
            .width(min: 160, ideal: 340)
            TableColumn("Tokens", sortUsing: KeyPathComparator(\OverviewRow.tokens, order: .reverse)) { row in
                if row.doc != nil {
                    Text(verbatim: row.tokens.formatted())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(LN(row.lines, "%d line", "%d lines"))
                }
            }
            .width(min: 56, ideal: 64, max: 90)
            TableColumn("Modified", sortUsing: KeyPathComparator(\OverviewRow.modified, order: .reverse)) { row in
                if let date = row.doc?.primary.modified {
                    Text(date.listStyle).foregroundStyle(.secondary)
                }
            }
            .width(min: 96, ideal: 150, max: 200)
            TableColumn("Audit", sortUsing: KeyPathComparator(\OverviewRow.audit, order: .reverse)) { row in
                if let doc = row.doc {
                    AuditBadge(doc: doc).environment(model)
                }
            }
            .width(44)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: String.self) { ids in
            if let row = ids.first.flatMap({ byID[$0] }) {
                if let doc = row.doc {
                    Button("Open") { model.select(doc.id, focusEditor: true) }
                    DocMenu(doc: doc).environment(model)
                } else {
                    Button("Create AGENTS.md…") { model.createAgents(in: row.folder) }
                    Divider()
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.folder]) }
                }
            }
        } primaryAction: { ids in
            guard let row = ids.first.flatMap({ byID[$0] }) else { return }
            if let doc = row.doc {
                model.select(doc.id, focusEditor: true)
            } else {
                model.createAgents(in: row.folder)
            }
        }
    }

    /// Like the status bar under a Finder window: what the table holds, in one line.
    private func footer(_ rows: [OverviewRow]) -> some View {
        let files = rows.filter { $0.doc != nil }
        let missing = rows.count - files.count
        var parts = [LN(files.count, "%d file", "%d files"),
                     L("≈%@ tokens", files.reduce(0) { $0 + $1.tokens }.formatted())]
        if missing > 0 {
            parts.append(LN(missing, "%d repository without instructions", "%d repositories without instructions"))
        }
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
