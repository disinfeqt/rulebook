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
            ForEach(model.visibleProjects) { project in
                Section(project.name) {
                    ForEach(project.docIDs, id: \.self) { id in
                        if let doc = model.doc(id) {
                            DocRow(doc: doc).tag(SidebarItem.doc(id))
                        }
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
}

struct DocRow: View {
    let doc: Doc
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(doc.title).lineLimit(1).truncationMode(.middle)
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
        .help(doc.topIssue?.title ?? "")
    }
}

/// A file's audit at a glance: queued, running, failed, or the score.
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
            Text(verbatim: "\(assessment.score)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(stale ? .tertiary : .secondary)
                .help(stale ? L("The file changed since this audit") : assessment.verdict)
        }
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
                Button("Audit") { model.audit(doc) }
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
