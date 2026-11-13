import SwiftUI

struct DiffView: View {
    let leftTitle: String
    let rightTitle: String
    let leftText: String
    let rightText: String
    var leftTint: Color = .red
    var rightTint: Color = .green

    var body: some View {
        let rows = LineDiff.sideBySide(leftText, rightText)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                columnHeader(leftTitle, tint: leftTint)
                Divider()
                columnHeader(rightTitle, tint: rightTint)
            }
            .frame(height: 32)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 0) {
                            cell(row.left, highlight: row.kind == .leftOnly || row.kind == .changed ? leftTint : nil,
                                 empty: row.left == nil)
                            Divider()
                            cell(row.right, highlight: row.kind == .rightOnly || row.kind == .changed ? rightTint : nil,
                                 empty: row.right == nil)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func columnHeader(_ title: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.6)).frame(width: 9, height: 9)
            Text(title).font(.callout.weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    private func cell(_ line: (no: Int, text: String)?, highlight: Color?, empty: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: line.map { "\($0.no)" } ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .trailing)
            Text(verbatim: line?.text.isEmpty == false ? line!.text : " ")
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(highlight.map { $0.opacity(0.13) } ?? (empty ? Color.secondary.opacity(0.05) : Color.clear))
    }
}

/// The shared frame of the three sheets: a diff or other content, and one row of buttons under it.
struct SheetFrame<Content: View, Leading: View, Buttons: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let leading: Leading
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            HStack(spacing: 10) {
                leading
                Spacer()
                buttons
            }
            .padding(14)
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 560, idealHeight: 720)
    }
}

struct CompareSheet: View {
    let request: CompareRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let agents = model.doc(request.agentsID), let claude = model.doc(request.claudeID) {
            let a = model.text(for: agents), c = model.text(for: claude)
            SheetFrame {
                DiffView(leftTitle: L("%@, read by other agents", agents.primary.displayName),
                         rightTitle: L("%@, read by Claude Code", claude.primary.displayName),
                         leftText: a, rightText: c, leftTint: .orange, rightTint: .blue)
            } leading: {
                Text(L("%d%% alike", Int((LineDiff.compare(a, c).similarity * 100).rounded())))
                    .foregroundStyle(.secondary)
            } buttons: {
                Button("Merge…") {
                    model.reconcile(agents)
                    dismiss()
                }
                .disabled(model.reconcileJob(for: agents)?.isRunning == true)
                .help(L("%@ combines both into one AGENTS.md and a CLAUDE.md that imports it. You review the result before it's saved.", model.engine.name))
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .onExitCommand { dismiss() }
        }
    }
}

struct RevisionSheet: View {
    let review: RevisionReview
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let doc = model.doc(review.docID) {
            SheetFrame {
                DiffView(leftTitle: L("Current"), rightTitle: L("Suggested"),
                         leftText: model.text(for: doc), rightText: review.revised)
            } leading: {
                Text("Applying leaves the file unsaved, so you can still edit or undo.")
                    .foregroundStyle(.secondary)
            } buttons: {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply to Editor") {
                    model.setText(review.revised, for: doc.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct ReconcileSheet: View {
    let review: ReconcileReview
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        if let agents = model.doc(review.agentsID), let claude = model.doc(review.claudeID) {
            SheetFrame {
                switch tab {
                case 0:
                    DiffView(leftTitle: L("Current"), rightTitle: L("Merged"),
                             leftText: model.text(for: agents), rightText: review.result.agentsMD)
                case 1:
                    DiffView(leftTitle: L("Current"), rightTitle: L("Merged"),
                             leftText: model.text(for: claude), rightText: review.result.claudeMD)
                default:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(review.result.notes, id: \.self) { note in
                                Text(note.inlineMarkdown).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            } leading: {
                Picker("", selection: $tab) {
                    Text(verbatim: "AGENTS.md").tag(0)
                    Text(verbatim: "CLAUDE.md").tag(1)
                    Text("Notes").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } buttons: {
                Button("Cancel") { model.reconcileReview = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Both Files") { model.applyReconcile(review) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
