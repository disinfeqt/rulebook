import SwiftUI

/// What there is to do about the open file: what's wrong with it, a skill's other files, and its audit.
struct InspectorView: View {
    let doc: Doc
    let issues: [Issue]
    let editor: EditorController
    @Environment(AppModel.self) private var model

    var body: some View {
        let files = doc.skill?.files.isEmpty == false
        let audit = model.jobs[doc.id] != nil || model.assessments[doc.id] != nil
        // Who reads the file is in the bar under the editor. The inspector is for what there is to do about it.
        if issues.isEmpty && !files && !audit {
            Text("No Issues")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            sections
        }
    }

    private var sections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !issues.isEmpty {
                    InspectorSection("Issues") {
                        ForEach(issues) { issue in
                            IssueRow(issue: issue, doc: doc, editor: editor)
                        }
                    }
                }
                if let skill = doc.skill, !skill.files.isEmpty {
                    InspectorSection("Files") {
                        SkillFiles(skill: skill, dir: doc.primary.resolvedURL.deletingLastPathComponent())
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
        VStack(alignment: .leading, spacing: 14) {
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

/// The files a skill ships next to its SKILL.md. Agents read them only when the skill tells them to.
struct SkillFiles: View {
    let skill: SkillInfo
    let dir: URL
    private let limit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(skill.files.prefix(limit)) { file in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(file.path).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(Int64(file.size).formatted(.byteCount(style: .file))).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent(file.path)]) }
                .help("Reveal in Finder")
            }
            if skill.files.count > limit {
                Text(LN(skill.files.count - limit, "and %d more", "and %d more")).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
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
                .font(.callout)
                .foregroundStyle(issue.severity.color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                Text(issue.detail.inlineMarkdown)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions.padding(.top, 4)
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
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Stop", action: onCancel).controlSize(.small)
            }
        } else if let error = job.error {
            VStack(alignment: .leading, spacing: 6) {
                Text(error)
                    .font(.callout)
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

/// An audit: its verdict, the button for its edits, then each finding. The summary is left to the CLI:
/// next to the verdict and the findings it only says the same things again.
struct AssessmentView: View {
    let doc: Doc
    let assessment: Assessment
    let editor: EditorController
    @Environment(AppModel.self) private var model

    var body: some View {
        let stale = model.isAssessmentStale(doc)
        VStack(alignment: .leading, spacing: 4) {
            Text(assessment.verdict).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(stale ? L("%@. The file changed since this audit.", assessment.date.formatted(.relative(presentation: .named)))
                       : assessment.date.formatted(.relative(presentation: .named)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !assessment.revised.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button("Review Suggested Edits") {
                model.revisionReview = RevisionReview(docID: doc.id, revised: assessment.revised)
            }
        }

        ForEach(assessment.issues.sorted { rank($0) < rank($1) }) { finding in
            FindingRow(finding: finding, editor: editor)
        }
    }

    private func rank(_ finding: Assessment.Finding) -> Int {
        ["high": 0, "medium": 1][finding.severity] ?? 2
    }
}

/// A finding, set like an issue: what's wrong and why. A click shows the text it's about in the editor,
/// and the edit it proposes is in Review Suggested Edits.
struct FindingRow: View {
    let finding: Assessment.Finding
    let editor: EditorController

    private var color: Color {
        switch finding.severity {
        case "high": return .red
        case "medium": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        let quote = finding.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                Text(finding.detail.inlineMarkdown)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !quote.isEmpty { editor.reveal(quote, beep: false) } }
        .help(quote.isEmpty ? "" : L("Show in the file"))
    }
}
