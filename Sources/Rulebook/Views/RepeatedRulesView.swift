import SwiftUI

/// A row of the repeated rules table: a rule, or one place it's written.
enum RepeatedRuleRow: Identifiable {
    case rule(RepeatedRule)
    case occurrence(RepeatedRule.Occurrence)

    var id: String {
        switch self {
        case .rule(let rule): return "rule:" + rule.id
        case .occurrence(let occurrence): return occurrence.id
        }
    }
}

/// Rules written into more than one project, each with the places it appears.
struct RepeatedRulesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []
    @State private var expanded: Set<String> = []

    var body: some View {
        Group {
            if let scan = model.scan {
                let rules = visible(scan.repeatedRules)
                if scan.repeatedRules.isEmpty {
                    ContentUnavailableView {
                        Label("No Repeated Rules", systemImage: "square.on.square")
                    } description: {
                        Text("No rule appears in more than one project.")
                    }
                } else if rules.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                } else {
                    table(rules)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Repeated Rules")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let path = model.rootPath?.tildePath ?? ""
        let count = model.scan?.repeatedRules.count ?? 0
        return count == 0 ? path : path + " — " + LN(count, "%d rule appears in more than one project",
                                                         "%d rules appear in more than one project")
    }

    /// The sidebar's search field narrows this list too, by the rule's words or a project's name.
    private func visible(_ rules: [RepeatedRule]) -> [RepeatedRule] {
        let query = model.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return rules }
        return rules.filter { rule in
            rule.occurrences.contains { $0.text.lowercased().contains(query) || $0.project.lowercased().contains(query) }
        }
    }

    private func table(_ rules: [RepeatedRule]) -> some View {
        // Table cells don't always get the window's environment on macOS, so they and the menu use this.
        let model = model
        var byID: [String: RepeatedRuleRow] = [:]
        // Copies worded like the rule above them are fainter, so the ones worded differently stand out.
        var sameWording: Set<String> = []
        for rule in rules {
            byID["rule:" + rule.id] = .rule(rule)
            let wording = RepeatedRules.normalized(rule.text)
            for occurrence in rule.occurrences {
                byID[occurrence.id] = .occurrence(occurrence)
                if RepeatedRules.normalized(occurrence.text) == wording { sameWording.insert(occurrence.id) }
            }
        }
        return Table(of: RepeatedRuleRow.self, selection: $selection) {
            TableColumn("Rule") { row in
                switch row {
                case .rule(let rule):
                    Text(rule.text).lineLimit(1).help(rule.text)
                case .occurrence(let occurrence):
                    Text(occurrence.text)
                        .lineLimit(1)
                        .foregroundStyle(sameWording.contains(occurrence.id) ? HierarchicalShapeStyle.tertiary : .secondary)
                        .help(occurrence.text)
                }
            }
            TableColumn("Projects") { row in
                switch row {
                case .rule(let rule):
                    Text(LN(rule.projectCount, "%d project", "%d projects")).foregroundStyle(.secondary)
                case .occurrence(let occurrence):
                    HStack(spacing: 6) {
                        Text(occurrence.project)
                        Text(verbatim: "\(occurrence.file):\(occurrence.line)").foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            .width(min: 140, ideal: 240, max: 360)
        } rows: {
            ForEach(rules) { rule in
                DisclosureTableRow(RepeatedRuleRow.rule(rule), isExpanded: binding(rule.id)) {
                    ForEach(rule.occurrences) { occurrence in
                        TableRow(RepeatedRuleRow.occurrence(occurrence))
                    }
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: String.self) { ids in
            switch ids.first.flatMap({ byID[$0] }) {
            case .rule(let rule):
                Button("Copy Rule") { copy(rule.text) }
            case .occurrence(let occurrence):
                Button("Open") { model.open(occurrence.docID, line: occurrence.line) }
                Button("Copy Rule") { copy(occurrence.text) }
                if let doc = model.doc(occurrence.docID) {
                    Divider()
                    Button("Reveal in Finder") { model.reveal(doc) }
                }
            case nil:
                EmptyView()
            }
        } primaryAction: { ids in
            switch ids.first.flatMap({ byID[$0] }) {
            case .rule(let rule): binding(rule.id).wrappedValue.toggle()
            case .occurrence(let occurrence): model.open(occurrence.docID, line: occurrence.line)
            case nil: break
            }
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
