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

/// The sidebar reads like a contents page: names without icons, what belongs to a place set in under it, and
/// anything to act on, with the counts, in a column at the trailing edge.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// How far a row is set in under the one it belongs to.
    private let inset: CGFloat = 14

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            // What's in every place, by kind.
            Section {
                Text("Rules")
                    .tag(SidebarItem.overview)
                // A second way to look at the rules, so it sits under them.
                Text("Repeated Rules")
                    .padding(.leading, inset)
                    .tag(SidebarItem.repeatedRules)
                    .help("Rules written into more than one project. One you want everywhere could live in a global file instead.")
                Text("Skills")
                    .tag(SidebarItem.skills)
                    .help("The skills in your projects and your home folder, and which agents load each one.")
            }
            // Then each place with what it holds: its instruction files, and a row for its skills.
            let places = model.sidebarPlaces
            ForEach(places.filter(\.isGlobal)) { place in
                Section(place.name) {
                    files(place, naming: .file)
                    skills(place)
                }
            }
            if places.contains(where: { !$0.isGlobal }) {
                Section("Projects") {
                    ForEach(places.filter { !$0.isGlobal }) { place in
                        if place.fileCount == 1, place.project != nil {
                            // A project with one file is that file, under the project's name.
                            files(place, naming: .project)
                        } else {
                            // One with several, or with skills alone, is a name over what it holds.
                            Text(place.name).foregroundStyle(.secondary).selectionDisabled()
                            files(place, naming: .file).padding(.leading, inset)
                        }
                        skills(place).padding(.leading, inset)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.searchText, placement: .sidebar)
        .overlay {
            if model.scan != nil, model.sidebarPlaces.isEmpty {
                if !model.searchText.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                } else if model.attentionOnly {
                    Text("Nothing needs attention").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func files(_ place: SidebarPlace, naming: DocRow.Naming) -> some View {
        ForEach(place.project?.docIDs ?? [], id: \.self) { id in
            if let doc = model.doc(id) {
                DocRow(doc: doc, naming: naming).tag(SidebarItem.doc(id))
                    .contextMenu { DocMenu(doc: doc) }
            }
        }
    }

    /// A place's skills as one row with their count: there can be dozens, so they open as a list.
    @ViewBuilder private func skills(_ place: SidebarPlace) -> some View {
        if let count = place.skills {
            HStack(spacing: 6) {
                Text("Skills")
                Spacer(minLength: 4)
                if place.skillsNeedAttention { SidebarMark(severity: .warning) }
                if count > 0 {
                    Text(verbatim: count.formatted())
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .tag(SidebarItem.skillsIn(place.id))
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
            Text(naming == .file ? doc.title : doc.projectName).lineLimit(1).truncationMode(.middle)
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
