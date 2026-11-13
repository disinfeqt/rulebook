import SwiftUI

struct RulebookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Rulebook", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1360, height: 860)
        .commands { RulebookCommands(model: model) }

        Settings {
            SettingsView().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--select"), i + 1 < args.count {
            let path = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath).standardizedFileURL.path
            Task { @MainActor in
                AppModel.shared.rescanNow()
                if let doc = AppModel.shared.doc(path) {
                    AppModel.shared.select(path)
                    if args.contains("--compare") {
                        try? await Task.sleep(for: .seconds(1))
                        AppModel.shared.openCompare(doc)
                    }
                }
            }
        }
        // Debug: save a picture of every window, then quit. Glass sidebars and toolbars only exist on screen,
        // so this asks screencapture for the real window (the terminal needs Screen Recording permission)
        // and falls back to an offscreen render, which leaves them blank.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
            // Come to the front first, so the windows are drawn as active ones.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                // The main window opens the size it was last left on this Mac. Pictures get the default size,
                // and the saved one is left alone.
                for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true {
                    window.setFrameAutosaveName("")
                    var frame = window.frame
                    frame.origin.y += frame.height - 860
                    frame.size = NSSize(width: 1360, height: 860)
                    window.setFrame(frame, display: true)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (n, window) in NSApp.windows.filter({ $0.isVisible }).enumerated() {
                    let url = dir.appendingPathComponent("window-\(n).png")
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
                    try? capture.run()
                    capture.waitUntilExit()
                    if FileManager.default.fileExists(atPath: url.path) { continue }
                    guard let view = window.contentView?.superview ?? window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
                exit(0)  // terminate(_:) is refused while a sheet is open
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared.confirmTermination()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Pick up edits made in other editors.
        if AppModel.shared.scan != nil { AppModel.shared.rescan() }
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Button("Check for Updates…") { updater.check() }
            .disabled(!updater.canCheck)
    }
}

struct RulebookCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") { model.chooseFolder() }
                .keyboardShortcut("o")
            Button("Rescan") { model.rescan() }
                .keyboardShortcut("r")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.saveCurrent() }
                .keyboardShortcut("s")
            Button("Save All") { model.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
            Button("Revert to Saved") { model.revertCurrent() }
            Divider()
            Button("Reveal in Finder") { if let d = model.currentDoc { model.reveal(d) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Open in Default Editor") { if let d = model.currentDoc { model.openExternally(d) } }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Copy Path") { if let d = model.currentDoc { model.copyPath(d) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
        }
        CommandGroup(after: .sidebar) {
            Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Toggle("Only Files That Need Attention", isOn: Binding(get: { model.attentionOnly }, set: { model.attentionOnly = $0 }))
        }
        CommandMenu("Go") {
            Button("Overview") { model.selection = .overview }
                .keyboardShortcut("0")
            Divider()
            Button("Previous File") { model.move(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next File") { model.move(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Next File That Needs Attention") { model.nextNeedingAttention() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option, .shift])
        }
        CommandMenu("Tools") {
            Button("Audit This File") { model.auditCurrent() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.currentDoc == nil)
            Button("Audit All…") { model.confirmAuditAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift, .option])
            Button("Stop Audits") { model.stopAllAudits() }
            Divider()
            Button("Compare AGENTS.md and CLAUDE.md") { if let d = model.currentDoc { model.openCompare(d) } }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(model.currentDoc?.siblingID == nil)
            Button("Merge AGENTS.md and CLAUDE.md…") { if let d = model.currentDoc { model.reconcile(d) } }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model.currentDoc?.siblingID == nil)
        }
    }
}
