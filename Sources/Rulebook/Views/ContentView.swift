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
                    DocDetailView(doc: doc).id(id)
                } else {
                    ContentUnavailableView("File Not Found", systemImage: "doc.questionmark")
                }
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

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                Label("Overview", systemImage: "square.grid.2x2")
                    .tag(SidebarItem.overview)
            }
            // A project is one row, named for the project. Its file is only named when it has several.
            let projects = model.visibleProjects
            let crowded = Set((model.scan?.projects ?? []).filter { $0.docIDs.count > 1 }.map(\.id))
            ForEach(projects.filter(\.isGlobal)) { project in
                Section(project.name) { rows(project, naming: .file) }
            }
            if projects.contains(where: { !$0.isGlobal }) {
                Section("Projects") {
                    ForEach(projects.filter { !$0.isGlobal }) { project in
                        rows(project, naming: crowded.contains(project.id) ? .both : .project)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.searchText, placement: .sidebar)
        .overlay {
            if model.scan != nil, model.visibleProjects.isEmpty {
                if !model.searchText.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                } else if model.attentionOnly {
                    Text("Nothing needs attention").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func rows(_ project: Project, naming: DocRow.Naming) -> some View {
        ForEach(project.docIDs, id: \.self) { id in
            if let doc = model.doc(id) {
                DocRow(doc: doc, naming: naming).tag(SidebarItem.doc(id))
                    .contextMenu { DocMenu(doc: doc) }
            }
        }
    }
}

struct DocRow: View {
    /// What a row is called: its file, its project, or the project with the file beside it.
    enum Naming { case file, project, both }

    let doc: Doc
    var naming: Naming = .file
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Label {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(naming == .file ? doc.title : doc.projectName)
                        .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    if naming == .both {
                        Text(doc.title).lineLimit(1).truncationMode(.middle)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                if let issue = doc.topIssue {
                    Image(systemName: issue.severity.icon).foregroundStyle(issue.severity.color)
                } else {
                    Image(systemName: "doc.text")
                }
            }
            if model.isDirty(doc.id) {
                Circle().fill(.secondary).frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
            Spacer(minLength: 4)
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
                           baseDir: doc.primary.containingDir, controller: editor)
            Divider()
            StatusBar(doc: doc, stats: insights.stats)
        }
        .navigationTitle(doc.title)
        .navigationSubtitle(model.isDirty(doc.id) ? L("%@ — Edited", doc.projectName) : doc.projectName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.audit(doc) } label: { ToolbarTitle("Audit") }
                    .disabled(model.jobs[doc.id].map { $0.error == nil } ?? false)
                    .help("Check this file against its project for outdated or conflicting instructions")
                Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .help("Show or hide the inspector")
            }
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView(doc: doc, issues: issues, editor: editor)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .onAppear {
            if model.focusEditorOnAppear {
                model.focusEditorOnAppear = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { editor.focus() }
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
                .help("A rough estimate of the context this file takes up in every session")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
