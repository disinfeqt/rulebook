import SwiftUI

/// Everything about the open file that isn't its text: who reads it, what's wrong with it, and its audit.
struct InspectorView: View {
    let doc: Doc
    let issues: [Issue]
    let editor: EditorController
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                InspectorSection("Read By") {
                    ReaderRow(name: "Claude Code", access: doc.readers.claude)
                    ReaderRow(name: L("Codex and other agents"), access: doc.readers.others)
                }
                if !issues.isEmpty {
                    InspectorSection("Issues") {
                        ForEach(issues) { issue in
                            IssueRow(issue: issue, doc: doc, editor: editor)
                        }
                    }
                }
                if model.jobs[doc.id] != nil || model.assessments[doc.id] != nil {
                    InspectorSection("Audit") {
                        if let job = model.jobs[doc.id] {
                            JobProgress(job: job, onCancel: { model.cancelJob(doc.id) }, onRetry: { model.audit(doc) })
                        }
                        if let assessment = model.assessments[doc.id] {
                            AssessmentView(doc: doc, assessment: assessment, editor: editor)
                        }
                    }
                }
            }
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        Divider()
    }
}

struct ReaderRow: View {
    let name: String
    let access: Access

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: access.reads ? "checkmark" : "minus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(access.reads ? .secondary : .tertiary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(access.reads ? .primary : .secondary)
                if !access.note.isEmpty {
                    Text(access.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct IssueRow: View {
    let issue: Issue
    let doc: Doc
    let editor: EditorController
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: issue.severity.icon)
                .font(.caption)
                .foregroundStyle(issue.severity.color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title).fixedSize(horizontal: false, vertical: true)
                Text(issue.detail.inlineMarkdown)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions.padding(.top, 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let r = issue.reveal { editor.reveal(r) } }
    }

    @ViewBuilder private var actions: some View {
        if issue.fixes.contains(.reconcile), let job = model.reconcileJob(for: doc) {
            JobProgress(job: job,
                        onCancel: { model.cancelJob(AppModel.reconcileJobID(model.pair(for: doc)?.agents.id ?? "")) },
                        onRetry: { model.reconcile(doc) })
        } else if !issue.fixes.isEmpty {
            HStack(spacing: 6) {
                ForEach(issue.fixes, id: \.self) { fix in
                    Button(fix.label) { model.perform(fix, on: doc) }
                }
            }
            .controlSize(.small)
        }
    }
}

struct JobProgress: View {
    let job: AgentJob
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        if job.isQueued {
            HStack {
                Text("Waiting to start").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
            }
            .font(.callout)
            .controlSize(.small)
        } else if job.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(job.steps.last ?? L("Starting…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Stop", action: onCancel).controlSize(.small)
            }
        } else if let error = job.error {
            VStack(alignment: .leading, spacing: 6) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("Try Again", action: onRetry)
                    Button("Dismiss", action: onCancel)
                }
                .controlSize(.small)
            }
        }
    }
}

struct AssessmentView: View {
    let doc: Doc
    let assessment: Assessment
    let editor: EditorController
    @Environment(AppModel.self) private var model
    @State private var showFullSummary = false

    var body: some View {
        let stale = model.isAssessmentStale(doc)
        VStack(alignment: .leading, spacing: 4) {
            Text(assessment.verdict).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(assessment.date.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.secondary)
            if stale {
                Text("The file changed since this audit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Text(assessment.summary.inlineMarkdown)
            .font(.callout)
            .lineLimit(showFullSummary ? nil : 3)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture { showFullSummary.toggle() }

        ForEach(assessment.issues.sorted { rank($0) < rank($1) }) { finding in
            FindingRow(finding: finding, editor: editor)
        }

        if !assessment.revised.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button("Review Suggested Edits") {
                model.revisionReview = RevisionReview(docID: doc.id, revised: assessment.revised)
            }
        }
    }

    private func rank(_ finding: Assessment.Finding) -> Int {
        ["high": 0, "medium": 1][finding.severity] ?? 2
    }
}

/// A finding shows its title. Clicking it opens the explanation and selects the quoted text in the editor.
struct FindingRow: View {
    let finding: Assessment.Finding
    let editor: EditorController
    @State private var expanded = false

    private var color: Color {
        switch finding.severity {
        case "high": return .red
        case "medium": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.title).fixedSize(horizontal: false, vertical: true)
                if expanded {
                    Text(finding.detail.inlineMarkdown)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !finding.suggestion.isEmpty {
                        Text(finding.suggestion.inlineMarkdown)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            expanded.toggle()
            if expanded, !finding.quote.isEmpty { editor.reveal(finding.quote, beep: false) }
        }
    }
}
