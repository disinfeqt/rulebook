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
                    if doc.skill != nil { AppModel.shared.openSkill(path) } else { AppModel.shared.select(path) }
                    if args.contains("--compare") {
                        try? await Task.sleep(for: .seconds(1))
                        AppModel.shared.openCompare(doc)
                    }
                }
            }
        }
        if let steps = LaunchOptions.tour {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Tour.run(steps: steps) }
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

/// Steps through the sidebar as Next File and Previous File do, and prints how long the main thread worked on
/// each step. It changes the selection from inside the app, so it needs no keystrokes and no focus.
@MainActor
enum Tour {
    private static func cpuSeconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }

    static func run(steps: Int) {
        var costs: [Double] = []
        func step(_ n: Int, since: Double) {
            // What the main thread used since the last step is the cost of that step, late work included.
            if n > 0 { costs.append((cpuSeconds() - since) * 1000) }
            guard n < steps else {
                let sorted = costs.sorted()
                print(String(format: "%d steps: median %.0f ms, mean %.0f ms, worst %.0f ms of main-thread time each",
                             costs.count, sorted[sorted.count / 2], costs.reduce(0, +) / Double(costs.count), sorted.last ?? 0))
                exit(0)
            }
            let start = cpuSeconds()
            // Six forward, four back, so the steps stay inside a short list too.
            AppModel.shared.move(n % 10 < 6 ? 1 : -1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { step(n + 1, since: start) }
        }
        step(0, since: cpuSeconds())
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
            // The sidebar's switch, which stays in the same project where it can.
            Button("Rules") { model.sidebarKind = .rules }
                .keyboardShortcut("1")
            Button("Skills") { model.sidebarKind = .skills }
                .keyboardShortcut("2")
            Divider()
            Button("All Projects") { model.selection = model.sidebarKind == .skills ? .skills : .overview }
                .keyboardShortcut("0")
            Button("Repeated Rules") { model.selection = .repeatedRules }
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
                .disabled(model.currentDoc == nil || model.currentDoc?.skill != nil)
            Button("Audit All…") { model.confirmAuditAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift, .option])
            Button("Stop Audits") { model.stopAllAudits() }
            Divider()
            Button("Compare AGENTS.md and CLAUDE.md") { if let d = model.currentDoc { model.openCompare(d) } }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(model.currentDoc?.siblingID == nil || model.currentDoc?.skill != nil)
            Button("Merge AGENTS.md and CLAUDE.md…") { if let d = model.currentDoc { model.reconcile(d) } }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model.currentDoc?.siblingID == nil || model.currentDoc?.skill != nil)
        }
    }
}
