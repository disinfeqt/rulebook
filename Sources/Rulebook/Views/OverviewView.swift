import SwiftUI

/// One file in the overview table, with the values its columns sort by.
struct OverviewRow: Identifiable {
    let doc: Doc
    let lines: Int
    /// How bad the file's audit is: 3 for serious findings, 2 for minor ones, 1 when clean and 0 with no audit.
    let audit: Int

    var id: String { doc.id }
    var project: String { doc.projectName }
    var file: String { doc.title }
    /// 1 to 3 by the severity of the file's most serious issue, so a file with an issue sorts above one without.
    var urgency: Int { doc.topIssue.map { $0.severity.rawValue + 1 } ?? 0 }
    var modified: Date { doc.primary.modified ?? .distantPast }
}

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\OverviewRow.urgency, order: .reverse)]

    var body: some View {
        Group {
            if let scan = model.scan {
                if scan.docs.isEmpty {
                    ContentUnavailableView {
                        Label("No Instruction Files", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text(L("There's no CLAUDE.md or AGENTS.md in %@.", scan.root.path.tildePath))
                    }
                } else {
                    table(scan)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Overview")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let missing = model.scan?.missing, !missing.isEmpty {
                    Menu {
                        Section("Create AGENTS.md In") {
                            ForEach(missing, id: \.self) { url in
                                Button(url.lastPathComponent) { model.createAgents(in: url) }
                            }
                        }
                    } label: {
                        Label("New AGENTS.md", systemImage: "plus")
                    }
                    .help("Create an AGENTS.md in a repository that has no instruction files")
                }
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
        let attention = model.scan?.docs.values.filter(\.needsAttention).count ?? 0
        return attention == 0 ? path : path + " — " + LN(attention, "%d file needs attention", "%d files need attention")
    }

    private func table(_ scan: ScanResult) -> some View {
        // Each cell is hosted on its own, and on macOS it doesn't always get the window's environment: reading
        // AppModel from it crashed when sorting moved the rows. So cells and the row menu are given the model.
        let model = model
        let rows = scan.projects.flatMap { $0.docIDs.compactMap { scan.docs[$0] } }.map { doc in
            let audit = switch model.assessments[doc.id]?.grade {
            case .serious: 3
            case .minor: 2
            case .clean: 1
            case nil: 0
            }
            return OverviewRow(doc: doc, lines: MarkdownScan.stats(doc.primary.content).lines, audit: audit)
        }
        // Text columns sort A to Z first. The others start with what matters most: the most urgent, longest,
        // most recently changed and worst audited files.
        return Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Project", value: \.project)
                .width(min: 90, ideal: 160, max: 280)
            TableColumn("File", value: \.file)
                .width(min: 110, ideal: 180, max: 320)
            TableColumn("Status", sortUsing: KeyPathComparator(\OverviewRow.urgency, order: .reverse)) { row in
                if let issue = row.doc.topIssue {
                    Label {
                        Text(issue.title)
                    } icon: {
                        Image(systemName: issue.severity.icon).foregroundStyle(issue.severity.color)
                    }
                    .help(issue.detail.replacingOccurrences(of: "`", with: ""))
                } else {
                    Text(row.doc.status.label)
                        .foregroundStyle(.secondary)
                        .help(row.doc.status.explanation)
                }
            }
            .width(min: 160, ideal: 360)
            TableColumn("Lines", sortUsing: KeyPathComparator(\OverviewRow.lines, order: .reverse)) { row in
                Text(verbatim: "\(row.lines)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(50)
            TableColumn("Modified", sortUsing: KeyPathComparator(\OverviewRow.modified, order: .reverse)) { row in
                if let date = row.doc.primary.modified {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                }
            }
            .width(min: 96, ideal: 140, max: 180)
            TableColumn("Audit", sortUsing: KeyPathComparator(\OverviewRow.audit, order: .reverse)) { row in
                AuditBadge(doc: row.doc).environment(model)
            }
            .width(50)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: String.self) { ids in
            if let doc = ids.first.flatMap(model.doc) {
                Button("Open") { model.select(doc.id, focusEditor: true) }
                DocMenu(doc: doc).environment(model)
            }
        } primaryAction: { ids in
            if let id = ids.first { model.select(id, focusEditor: true) }
        }
    }
}
