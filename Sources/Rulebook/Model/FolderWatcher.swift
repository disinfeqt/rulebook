import CoreServices
import Foundation

/// Tells the app when an instruction file or a skill changes on disk, so the lists follow what an editor, a
/// terminal or `npx skills` does without the app being left and come back to.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void

    /// Watches everything under `folders`. `onChange` is called off the main thread, at most about once a second,
    /// and only for changes that could alter what the app shows.
    init(folders: [URL], onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info, let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            if changed.contains(where: FolderWatcher.matters) {
                Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
            }
        }
        // The app's own saves and fixes already scan again, so its own writes are left out.
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf
        stream = FSEventStreamCreate(nil, callback, &context, folders.map(\.path) as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, UInt32(flags))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
            FSEventStreamStart(stream)
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private static let names: Set<String> = ["claude.md", "agents.md", "claude.local.md", "skills-lock.json", ".skill-lock.json"]

    /// Whether a changed path is an instruction file, something in a skills folder, or one of the files
    /// `npx skills` keeps. A projects folder sees thousands of other changes during a build or an install.
    static func matters(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("/node_modules/") { return false }
        if names.contains((lower as NSString).lastPathComponent) { return true }
        return SkillHome.allCases.contains { lower.contains("/" + $0.folder) }
    }
}
