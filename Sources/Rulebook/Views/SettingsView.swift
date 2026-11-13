import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        @Bindable var model = model
        let engine = model.engine
        Form {
            Section {
                LabeledContent("Projects folder") {
                    HStack {
                        Text(model.rootPath?.tildePath ?? L("None"))
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { model.chooseFolder() }
                    }
                }
                Toggle("Include the global files in ~/.claude and ~/.codex", isOn: $model.includeGlobal)
                Picker("Language", selection: $model.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.label).tag(language)
                    }
                }
            } footer: {
                if model.language != model.launchLanguage {
                    Text("The language changes the next time you open Rulebook.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section {
                Picker("Agent", selection: $model.engine) {
                    ForEach(Engine.allCases) { engine in
                        Text(verbatim: engine.name).tag(engine)
                    }
                }
                TextField("Model", text: Binding(get: { model.models[engine] ?? "" },
                                                 set: { model.models[engine] = $0.isEmpty ? nil : $0 }),
                          prompt: Text("Default"))
                TextField("Command", text: Binding(get: { model.cliOverrides[engine] ?? "" },
                                                   set: { model.cliOverrides[engine] = $0.isEmpty ? nil : $0 }),
                          prompt: Text(model.detected[engine]?.path.tildePath ?? L("Not found")))
                Toggle("Audit files again when they change", isOn: $model.autoReaudit)
                Picker("Audits at once", selection: $model.auditConcurrency) {
                    ForEach(1...4, id: \.self) { count in
                        Text(verbatim: "\(count)").tag(count)
                    }
                }
            } header: {
                Text("Audits and Merges")
            } footer: {
                Text("The agent runs with your existing login. It reads your projects and can't change them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle("Check for updates automatically", isOn: Binding(get: { updater.checksAutomatically },
                                                                         set: { updater.checksAutomatically = $0 }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
