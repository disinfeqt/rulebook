import SwiftUI

/// One file in the overview table, with the values its columns sort by.
struct OverviewRow: Identifiable {
    let doc: Doc
    let lines: Int
    /// -1 when the file has no audit, so unaudited files sort below every score.
    let score: Int

    var id: String { doc.id }
    var project: String { doc.projectName }
    var file: String { doc.title }
    var urgency: Int { doc.topIssue.map { $0.severity.rawValue } ?? 0 }
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
                    Button("Stop Audits") { model.stopAllAudits() }
                } else {
                    Button("Audit All…") { model.confirmAuditAll() }
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
        let rows = scan.projects.flatMap { $0.docIDs.compactMap { scan.docs[$0] } }.map { doc in
            OverviewRow(doc: doc, lines: MarkdownScan.stats(doc.primary.content).lines,
                        score: model.assessments[doc.id]?.score ?? -1)
        }
        return Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Project", value: \.project)
                .width(min: 90, ideal: 160, max: 280)
            TableColumn("File", value: \.file)
                .width(min: 110, ideal: 180, max: 320)
            TableColumn("Status", value: \.urgency) { row in
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
            TableColumn("Lines", value: \.lines) { row in
                Text(verbatim: "\(row.lines)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(50)
            TableColumn("Modified", value: \.modified) { row in
                if let date = row.doc.primary.modified {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 110, max: 130)
            TableColumn("Audit", value: \.score) { row in
                AuditBadge(doc: row.doc)
            }
            .width(50)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: String.self) { ids in
            if let doc = ids.first.flatMap(model.doc) {
                Button("Open") { model.select(doc.id, focusEditor: true) }
                Button("Audit") { model.audit(doc) }
                Divider()
                Button("Reveal in Finder") { model.reveal(doc) }
            }
        } primaryAction: { ids in
            if let id = ids.first { model.select(id, focusEditor: true) }
        }
    }
}
