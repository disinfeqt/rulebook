import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            if model.rootPath == nil {
                WelcomeView()
            } else if case .doc(let id)? = model.selection {
                if let doc = model.doc(id) {
                    DocDetailView(doc: doc)
                } else {
                    ContentUnavailableView("File Not Found", systemImage: "doc.questionmark")
                }
            } else if model.selection == .repeatedRules {
                RepeatedRulesView()
            } else if model.showsSkills {
                skills(in: model.skillsPlace)
            } else {
                OverviewView()
            }
        }
        .sheet(item: $model.compare) { request in
            CompareSheet(request: request)
        }
        .sheet(item: $model.revisionReview) { review in
            RevisionSheet(review: review)
        }
        .sheet(item: $model.reconcileReview) { review in
            ReconcileSheet(review: review)
        }
        .alert(model.alert?.title ?? "", isPresented: Binding(
            get: { model.alert != nil },
            set: { if !$0 { model.alert = nil } }
        ), presenting: model.alert) { info in
            ForEach(info.actions) { action in
                Button(action.title, role: action.role) { action.run() }
            }
        } message: { info in
            Text(info.message)
        }
        .task {
            if model.scan == nil { model.rescan() }
            if LaunchOptions.showSettings { openSettings() }
            if LaunchOptions.showRepeatedRules { model.selection = .repeatedRules }
            if LaunchOptions.showSkills { model.selection = .skills }
            if let place = LaunchOptions.skillsPlace { model.selection = .skillsIn(place) }
        }
    }
}

extension ContentView {
    /// Every skill, or one place's. A skill opens on top of the list, so Back returns to the list where it was left.
    private func skills(in place: String?) -> some View {
        @Bindable var model = model
        return NavigationStack(path: $model.skillPath) {
            SkillsView(scope: place)
                .navigationDestination(for: String.self) { id in
                    if let doc = model.doc(id) {
                        DocDetailView(doc: doc)
                    } else {
                        ContentUnavailableView("File Not Found", systemImage: "doc.questionmark")
                    }
                }
        }
    }
}

/// First launch: nothing is scanned until the user says where their projects are.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Choose Your Projects Folder", systemImage: "folder")
        } description: {
            Text("Rulebook finds the CLAUDE.md and AGENTS.md files of every project inside it.")
        } actions: {
            Button("Choose Folder…") { model.chooseFolder() }
        }
        .navigationTitle("Rulebook")
    }
}

// MARK: Sidebar

/// The sidebar is one row per place, and a switch at its top says what a place shows: its instruction files or
/// its skills. It reads like a contents page: names without icons, and anything to act on, with the counts, in a
/// column at the trailing edge.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// How far a row is set in under the one it belongs to.
    private let inset: CGFloat = 14

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            if model.sidebarKind == .skills { skills } else { rules }
        }
        .listStyle(.sidebar)
        // Names without icons need less room than the system's sidebar rows give them. The rows keep the
        // text size of the medium ones.
        .environment(\.sidebarRowSize, .small)
        .safeAreaInset(edge: .top, spacing: 0) {
            KindSwitch(kind: $model.sidebarKind, labels: [L("Rules"), L("Skills")])
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
        .searchable(text: $model.searchText, placement: .sidebar)
        .overlay {
            if model.scan != nil, model.sidebarKind == .skills ? model.skillPlaces.isEmpty : model.visibleProjects.isEmpty {
                if !model.searchText.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                } else if model.attentionOnly {
                    Text("Nothing needs attention").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Rules

    /// Every instruction file by place. A project with one file is one row, named for the project.
    @ViewBuilder private var rules: some View {
        Section {
            Text("All Projects")
                .font(.body)
                .tag(SidebarItem.overview)
            Text("Repeated Rules")
                .font(.body)
                .tag(SidebarItem.repeatedRules)
                .help("Rules written into more than one project. One you want everywhere could live in a global file instead.")
        }
        let projects = model.visibleProjects
        let several = Set((model.scan?.projects ?? []).filter { $0.docIDs.count > 1 }.map(\.id))
        ForEach(projects.filter(\.isGlobal)) { project in
            Section(project.name) { files(project, naming: .file) }
        }
        if projects.contains(where: { !$0.isGlobal }) {
            Section("Projects") {
                ForEach(projects.filter { !$0.isGlobal }) { project in
                    if several.contains(project.id) {
                        Text(project.name).font(.body).foregroundStyle(.secondary).selectionDisabled()
                        files(project, naming: .file).padding(.leading, inset)
                    } else {
                        files(project, naming: .project)
                    }
                }
            }
        }
    }

    private func files(_ project: Project, naming: DocRow.Naming) -> some View {
        ForEach(project.docIDs, id: \.self) { id in
            if let doc = model.doc(id) {
                DocRow(doc: doc, naming: naming).tag(SidebarItem.doc(id))
                    .contextMenu { DocMenu(doc: doc) }
            }
        }
    }

    // MARK: Skills

    /// The places that have skills, each with its count. A click opens that place's skills.
    @ViewBuilder private var skills: some View {
        let places = model.skillPlaces
        Section {
            SkillPlaceRow(name: L("All Projects"), count: places.reduce(0) { $0 + $1.count },
                          needsAttention: places.contains(where: \.needsAttention))
                .tag(SidebarItem.skills)
                .help("The skills in your projects and your home folder, and which agents load each one.")
            ForEach(places.filter(\.isGlobal)) { place in
                SkillPlaceRow(name: place.name, count: place.count, needsAttention: place.needsAttention)
                    .tag(SidebarItem.skillsIn(place.id))
            }
        }
        if places.contains(where: { !$0.isGlobal }) {
            Section("Projects") {
                ForEach(places.filter { !$0.isGlobal }) { place in
                    SkillPlaceRow(name: place.name, count: place.count, needsAttention: place.needsAttention)
                        .tag(SidebarItem.skillsIn(place.id))
                }
            }
        }
    }
}

/// The switch at the top of the sidebar: the system's segmented control, with its two halves as wide as the
/// sidebar. A SwiftUI picker in that style stays as narrow as its labels.
struct KindSwitch: NSViewRepresentable {
    @Binding var kind: SidebarKind
    let labels: [String]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = kind == .rules ? 0 : 1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.fittingSize.width, height: nsView.fittingSize.height)
    }

    final class Coordinator: NSObject {
        var parent: KindSwitch
        init(_ parent: KindSwitch) { self.parent = parent }

        @MainActor @objc func changed(_ sender: NSSegmentedControl) {
            parent.kind = sender.selectedSegment == 0 ? .rules : .skills
        }
    }
}

/// A place on the Skills side of the sidebar: its name, a sign that one of its skills needs fixing, and how many
/// it has.
struct SkillPlaceRow: View {
    let name: String
    let count: Int
    let needsAttention: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(name).font(.body).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if needsAttention { SidebarMark(severity: .warning) }
            if count > 0 {
                Text(verbatim: count.formatted())
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The sign at the trailing edge of a sidebar row that something there needs fixing.
struct SidebarMark: View {
    let severity: Severity

    var body: some View {
        Image(systemName: severity.icon)
            .font(.caption)
            .foregroundStyle(severity.color)
            .frame(width: 16)
    }
}

struct DocRow: View {
    /// What a row is called: its file, or its project when it's the project's only file.
    enum Naming { case file, project }

    let doc: Doc
    var naming: Naming = .file
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Text(naming == .file ? doc.title : doc.projectName).font(.body).lineLimit(1).truncationMode(.middle)
            if model.isDirty(doc.id) {
                Circle().fill(.secondary).frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
            Spacer(minLength: 4)
            if let issue = doc.topIssue { SidebarMark(severity: issue.severity) }
            AuditBadge(doc: doc)
        }
        .help(doc.topIssue?.title ?? doc.primary.url.path.tildePath)
    }
}

/// A file's audit at a glance: queued, running, failed, or a dot the color of its most serious finding.
struct AuditBadge: View {
    let doc: Doc
    @Environment(AppModel.self) private var model

    var body: some View {
        if let job = model.jobs[doc.id] {
            if job.isQueued {
                Image(systemName: "clock").foregroundStyle(.secondary).help("Waiting to be audited")
            } else if job.isRunning {
                ProgressView().controlSize(.small)
            } else if let error = job.error {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red).help(error)
            }
        } else if model.reconcileJob(for: doc)?.isRunning == true {
            ProgressView().controlSize(.small)
        } else if let assessment = model.assessments[doc.id] {
            let stale = model.isAssessmentStale(doc)
            // Hollow once the file has changed, because the audit is about an older version.
            Group {
                if stale {
                    Circle().strokeBorder(assessment.grade.color, lineWidth: 1.5)
                } else {
                    Circle().fill(assessment.grade.color)
                }
            }
            .frame(width: 9, height: 9)
            .frame(width: 16)
            .help(stale ? L("The file changed since this audit") : assessment.verdict)
            .accessibilityLabel(assessment.verdict)
        }
    }
}

/// What you can do with a file, for the menus that open on a right click.
struct DocMenu: View {
    let doc: Doc
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Audit") { model.audit(doc) }
            .disabled(model.jobs[doc.id].map { $0.error == nil } ?? false)
        if doc.siblingID != nil {
            Button("Compare AGENTS.md and CLAUDE.md") { model.openCompare(doc) }
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
    }
}

/// A text-only toolbar button. The system's capsule hugs bare text, so this gives it room at the sides.
struct ToolbarTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title).padding(.horizontal, 6)
    }
}

// MARK: Detail

/// One file in the editor, with its inspector. The view stays when another file is chosen, so the toolbar and
/// the inspector's column aren't built again for each one. Only the editor is, to keep each file's own undo.
struct DocDetailView: View {
    let doc: Doc
    @Environment(AppModel.self) private var model
    @State private var editor = EditorController()

    var body: some View {
        @Bindable var model = model
        let insights = model.insights(for: doc)
        let issues = model.issues(for: doc, insights: insights)
        VStack(spacing: 0) {
            MarkdownEditor(text: Binding(get: { model.text(for: doc) },
                                         set: { model.setText($0, for: doc.id) }),
                           baseDir: doc.primary.containingDir, isSkill: doc.skill != nil, controller: editor)
                .id(doc.id)
            Divider()
            StatusBar(doc: doc, stats: insights.stats)
        }
        .navigationTitle(doc.title)
        .navigationSubtitle(model.isDirty(doc.id) ? L("%@ — Edited", doc.projectName) : doc.projectName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if doc.skill == nil {
                    Button { model.audit(doc) } label: { ToolbarTitle("Audit") }
                        .disabled(model.jobs[doc.id].map { $0.error == nil } ?? false)
                        .help("Check this file against its project for outdated or conflicting instructions")
                }
                Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .help("Show or hide the inspector")
            }
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView(doc: doc, issues: issues, editor: editor)
                .id(doc.id)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
        .onChange(of: doc.id, initial: true) {
            let line = model.revealLineOnAppear
            model.revealLineOnAppear = nil
            if model.focusEditorOnAppear || line != nil {
                model.focusEditorOnAppear = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let line { editor.reveal(line: line) } else { editor.focus() }
                }
            }
        }
    }
}

struct StatusBar: View {
    let doc: Doc
    let stats: TextStats

    var body: some View {
        HStack(spacing: 12) {
            Text(doc.primary.url.path.tildePath)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Text(LN(stats.lines, "%d line", "%d lines"))
            Text(L("≈%d tokens", stats.tokens))
                .help(doc.skill == nil ? L("A rough estimate of the context this file takes up in every session")
                                       : L("A rough estimate of the context this skill takes up once an agent uses it"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
