import Foundation

/// Launch arguments for demos and screenshots. None of them are saved to preferences.
///
///     --root <folder>   scan this folder instead of the one in Settings
///     --no-global       leave out ~/.claude/CLAUDE.md and ~/.codex/AGENTS.md
///     --store <folder>  keep audit results here instead of Application Support
///     --agent <name>    with --audit: run it with `claude` or `codex` instead of the first one found
///     --model <name>    with --audit: use this model instead of the agent's default
///     --command <path>  with --audit: run this executable as the agent, for testing how failures are reported
///     --settings        open the Settings window at launch
///     --repeated-rules  open on Repeated Rules
///     --skills          open on Skills
///     --skills-in <folder>  open on the skills of one project, or of the home folder with `global`
///     --open-skill-sets show the skills a project got from one source opened out, not as one row
///     --tour <count>    step through the sidebar that many times, print what each step cost, and quit
enum LaunchOptions {
    static func value(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
        return (args[i + 1] as NSString).expandingTildeInPath
    }

    static var root: String? { value("--root") }
    static var noGlobal: Bool { CommandLine.arguments.contains("--no-global") }
    static var storeDir: String? { value("--store") }
    /// Opens Settings at launch, for screenshots.
    static var showSettings: Bool { CommandLine.arguments.contains("--settings") }
    /// Opens on Repeated Rules instead of the overview, for the website's screenshot.
    static var showRepeatedRules: Bool { CommandLine.arguments.contains("--repeated-rules") }
    static var showSkills: Bool { CommandLine.arguments.contains("--skills") }
    /// How many steps through the sidebar to time, for finding what makes a switch slow.
    static var tour: Int? { value("--tour").flatMap(Int.init) }
    /// The place whose skills to open on: a project's path, or "global".
    static var skillsPlace: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "--skills-in"), i + 1 < CommandLine.arguments.count else { return nil }
        let value = CommandLine.arguments[i + 1]
        return value == "global" ? value : URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
    }
    /// Opens every set of skills on the Skills page, for a picture that shows what's inside one.
    static var openSkillSets: Bool { CommandLine.arguments.contains("--open-skill-sets") }
}
