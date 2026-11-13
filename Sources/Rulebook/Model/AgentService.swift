import Foundation

/// A coding agent's CLI that can run audits and merges.
enum Engine: String, CaseIterable, Identifiable, Sendable {
    case claude, codex

    var id: String { rawValue }
    var name: String { self == .claude ? "Claude Code" : "Codex" }
    var command: String { rawValue }
}

/// Result of a prompt audit on one file.
struct Assessment: Codable, Hashable {
    struct Finding: Codable, Hashable, Identifiable {
        var severity: String
        var title: String
        var detail: String
        var quote: String
        var suggestion: String
        var id: String { title + "|" + quote }
    }
    /// How an audit came out, worst first.
    enum Grade: Int, Comparable {
        case serious, minor, clean
        static func < (a: Grade, b: Grade) -> Bool { a.rawValue < b.rawValue }
    }

    /// The agent's own 0 to 100. Not shown: files with serious findings have scored above files with none.
    var score: Int
    /// The audit at a glance, taken from its most serious finding.
    var grade: Grade {
        if issues.contains(where: { $0.severity == "high" }) { return .serious }
        if issues.contains(where: { $0.severity == "medium" }) { return .minor }
        return .clean
    }
    var verdict: String
    var summary: String
    var strengths: [String]
    var issues: [Finding]
    var revised: String
    /// Hash of the saved file content that was audited.
    var contentHash: String
    var date: Date
    var model: String
    var costUSD: Double?
    var durationSeconds: Double?
    /// Which CLI ran it. Missing in audits stored by early versions, which only had Claude Code.
    var engine: String?
}

struct ReconcileResult: Hashable {
    var agentsMD: String
    var claudeMD: String
    var notes: [String]
}

enum AgentError: LocalizedError {
    case notFound(Engine)
    case tooOld(String)
    /// The run ended, and this is the best account of why.
    case failed(String)
    /// The agent stopped without a result for a reason that may not repeat: a dropped connection,
    /// an overloaded service, a missing report. Worth one more try.
    case interrupted(String)
    /// A usage or rate limit. Starting more runs now would fail the same way.
    case limit(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let engine):
            return L("Couldn't find the %@ command. Install %@, or set its path in Settings.", engine.command, engine.name)
        case .tooOld(let version):
            return L("Audits need Claude Code %@ or later, and this Mac has %@. Run `claude update`.", AgentService.minimumClaudeVersion, version)
        case .failed(let message), .interrupted(let message), .limit(let message):
            return message
        }
    }
}

/// What a run left behind, for explaining a failure.
struct Transcript {
    var status: Int32 = 0
    var stderr = ""
    var events = 0
    var lastEvent = ""
    /// Lines on stdout that weren't JSON events: the CLI talking in plain text.
    var stray: [String] = []
    var timedOut = false
}

/// Runs an agent CLI headless with the user's existing login.
///
/// Every run is read-only. Claude Code gets `--restricted` (settings files, and with them permission
/// allow-lists and hooks, don't apply), `--strict-mcp-config` (no MCP servers) and read-only tools.
/// Codex gets its read-only sandbox and `--ignore-user-config`.
enum AgentService {
    struct Run {
        let structured: Data
        let costUSD: Double?
        let duration: Double
    }

    final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    /// `/doctor prompt-audit` arrived in this Claude Code version.
    static let minimumClaudeVersion = "2.1.283"

    // MARK: Locating the CLI

    static func locate(_ engine: Engine) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let name = engine.command
        var candidates = [
            "\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)", "\(home)/.bun/bin/\(name)",
        ]
        if engine == .claude { candidates.insert("\(home)/.claude/local/claude", at: 1) }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Fall back to the login shell's PATH.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let path = capture(shell, ["-lc", "command -v \(name)"])?.split(separator: "\n").last.map(String.init),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// "2.1.322" from `claude --version` ("2.1.322 (Claude Code)") or `codex --version` ("codex-cli 0.167.2").
    static func version(of cli: URL) -> String? {
        capture(cli.path, ["--version"])?.split(separator: " ")
            .first { $0.first?.isNumber == true }.map(String.init)
    }

    /// How Claude Code runs are paid for. `total_cost_usd` in its output is always priced at API rates,
    /// so for a claude.ai login it's an equivalent, not a charge.
    enum Billing: Equatable, Sendable {
        /// Logged in with a Claude plan (e.g. "Max"): runs are included and count toward the plan's usage limits.
        case plan(String)
        /// An API key or cloud provider: runs are billed per token.
        case metered
        case unknown
    }

    /// From `claude auth status`.
    static func billing(of cli: URL) -> Billing {
        guard let json = capture(cli.path, ["auth", "status", "--json"]),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              obj["loggedIn"] as? Bool == true else { return .unknown }
        let method = (obj["authMethod"] as? String ?? "").lowercased()
        let provider = (obj["apiProvider"] as? String ?? "firstParty")
        if method == "claude.ai", provider == "firstParty" {
            let plan = (obj["subscriptionType"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return .plan(plan ?? "Claude")
        }
        return method.isEmpty ? .unknown : .metered
    }

    static func isAtLeast(_ version: String, _ minimum: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    private static func capture(_ executable: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let out = Pipe()
        p.standardInput = FileHandle.nullDevice   // or a CLI that reads its input would wait forever
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // MARK: Running

    /// How long one run may take before it's stopped. Audits and merges usually finish in a minute or two.
    static let timeout: TimeInterval = 20 * 60

    /// Starts `cli` with `args`, writes `prompt` to its stdin and hands every JSON line of stdout to `onEvent`.
    ///
    /// Output is split on line feeds only. JSON may carry other Unicode line separators inside its
    /// strings, and a reader that breaks on those cuts an event in half and loses it. Anything on
    /// stdout that isn't a JSON event is kept in the transcript, since that is how a CLI reports
    /// trouble it can't express as an event.
    private static func stream(cli: URL, args: [String], cwd: URL, prompt: String,
                               onEvent: ([String: Any]) -> Void) async throws -> Transcript {
        let process = Process()
        process.executableURL = cli
        process.arguments = args
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = (["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
                       + [env["PATH"] ?? ""]).joined(separator: ":")
        process.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let errBuffer = Buffer()
        stderr.fileHandleForReading.readabilityHandler = { handle in errBuffer.append(handle.availableData) }

        // A plain blocking read on its own thread. It ends when the CLI closes its output.
        let reader = stdout.fileHandleForReading
        let chunks = AsyncStream<Data> { continuation in
            Thread.detachNewThread {
                while let data = try? reader.read(upToCount: 1 << 16), !data.isEmpty { continuation.yield(data) }
                continuation.finish()
            }
        }
        // If a helper the CLI started keeps the pipe open after the CLI itself is gone, stop waiting for it.
        process.terminationHandler = { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { try? reader.close() }
        }

        try process.run()
        let writer = stdin.fileHandleForWriting
        let payload = Data(prompt.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: payload)
            try? writer.close()
        }

        let timedOut = Buffer()
        let deadline = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.append(Data([1]))
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }

        return try await withTaskCancellationHandler {
            var transcript = Transcript()
            var pending = Data()
            func take(_ line: Data) {
                guard !line.isEmpty else { return }
                if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                    transcript.events += 1
                    transcript.lastEvent = [obj["type"] as? String, obj["subtype"] as? String].compactMap { $0 }.joined(separator: "/")
                    onEvent(obj)
                } else {
                    let text = String(decoding: line.prefix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { transcript.stray = Array((transcript.stray + [text]).suffix(5)) }
                }
            }
            for await chunk in chunks {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    take(pending[pending.startIndex..<newline])
                    pending = Data(pending[pending.index(after: newline)...])
                }
            }
            take(pending)
            process.waitUntilExit()
            stderr.fileHandleForReading.readabilityHandler = nil
            try Task.checkCancellation()
            transcript.status = process.terminationStatus
            transcript.stderr = errBuffer.string.trimmingCharacters(in: .whitespacesAndNewlines)
            transcript.timedOut = !timedOut.string.isEmpty
            return transcript
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Runs the agent once more if the first run was cut short for a reason that may not repeat.
    static func run(engine: Engine, prompt: String, schema: String, appendSystemPrompt: String? = nil,
                    cwd: URL, cli: URL, model: String, allowSkills: Bool = false,
                    progress: @escaping @Sendable (String) -> Void) async throws -> Run {
        func attempt() async throws -> Run {
            try await runOnce(engine: engine, prompt: prompt, schema: schema, appendSystemPrompt: appendSystemPrompt,
                              cwd: cwd, cli: cli, model: model, allowSkills: allowSkills, progress: progress)
        }
        do {
            return try await attempt()
        } catch AgentError.interrupted {
            progress(L("Trying again"))
            try await Task.sleep(for: .seconds(5))
            do {
                return try await attempt()
            } catch AgentError.interrupted(let message) {
                throw AgentError.failed(message)
            }
        }
    }

    private static func runOnce(engine: Engine, prompt: String, schema: String, appendSystemPrompt: String?,
                                cwd: URL, cli: URL, model: String, allowSkills: Bool,
                                progress: @escaping @Sendable (String) -> Void) async throws -> Run {
        let started = Date()
        switch engine {
        case .claude:
            var args = ["-p", "--restricted", "--strict-mcp-config",
                        "--output-format", "stream-json", "--verbose",
                        "--json-schema", schema,
                        "--tools", (["Read", "Glob", "Grep"] + (allowSkills ? ["Skill"] : [])).joined(separator: ","),
                        "--disallowedTools", "Edit,Write,NotebookEdit,Bash",
                        "--no-session-persistence", "--max-turns", "40"]
            if !model.isEmpty { args += ["--model", model] }
            if let appendSystemPrompt { args += ["--append-system-prompt", appendSystemPrompt] }
            var final: [String: Any]?
            var said = ""        // an error an event carried, in the agent's words
            var limit = ""       // a limit Claude Code announced, with when it resets
            let transcript = try await stream(cli: cli, args: args, cwd: cwd, prompt: prompt) { obj in
                switch obj["type"] as? String {
                case "assistant":
                    let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                    for block in content where block["type"] as? String == "tool_use" {
                        progress(describe(tool: block["name"] as? String ?? "", input: block["input"] as? [String: Any] ?? [:], cwd: cwd))
                    }
                    // An API failure arrives as an assistant message with an `error` field and the reason as text.
                    if let error = obj["error"] as? String {
                        let text = content.compactMap { $0["text"] as? String }.joined(separator: " ")
                        said = text.isEmpty ? error : text
                    }
                case "rate_limit_event":
                    let info = obj["rate_limit_info"] as? [String: Any] ?? [:]
                    if let status = info["status"] as? String, !status.hasPrefix("allowed") {
                        limit = (info["resetsAt"] as? Double).map {
                            L("The limit resets %@.", Date(timeIntervalSince1970: $0).formatted(.relative(presentation: .named)))
                        } ?? L("Try again later.")
                    }
                case "result":
                    final = obj
                default:
                    break
                }
            }
            guard let final else {
                throw explain(engine, transcript, said: said, limit: limit, cwd: cwd)
            }
            let text = final["result"] as? String ?? ""
            if (final["is_error"] as? Bool) != true {
                if let structured = final["structured_output"], !(structured is NSNull) {
                    return Run(structured: try JSONSerialization.data(withJSONObject: structured),
                               costUSD: final["total_cost_usd"] as? Double, duration: Date().timeIntervalSince(started))
                }
                // Sometimes the report comes back as the reply's text instead of through the structured channel.
                if let data = jsonObject(in: text) {
                    return Run(structured: data, costUSD: final["total_cost_usd"] as? Double, duration: Date().timeIntervalSince(started))
                }
                log(engine, transcript, said: "no structured output; result text: " + text.prefix(300), cwd: cwd)
                throw AgentError.interrupted(L("%@ finished without the report Rulebook asked for.", engine.name))
            }
            if final["subtype"] as? String == "error_max_turns" {
                throw AgentError.failed(L("%@ ran out of steps before it finished. The project may be too large to check in one run.", engine.name))
            }
            let status = (final["api_error_status"] as? Int).map { " (HTTP \($0))" } ?? ""
            throw explain(engine, transcript, said: (said.isEmpty ? text : said) + status, limit: limit, cwd: cwd)

        case .codex:
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rulebook-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let schemaURL = tmp.appendingPathComponent("schema.json"), resultURL = tmp.appendingPathComponent("result.json")
            try schema.write(to: schemaURL, atomically: true, encoding: .utf8)
            var args = ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config",
                        "--sandbox", "read-only", "--color", "never", "--cd", cwd.path,
                        "--output-schema", schemaURL.path, "--output-last-message", resultURL.path]
            if !model.isEmpty { args += ["--model", model] }
            args.append("-")
            let fullPrompt = appendSystemPrompt.map { prompt + "\n\n" + $0 } ?? prompt
            var said = ""
            let transcript = try await stream(cli: cli, args: args, cwd: cwd, prompt: fullPrompt) { obj in
                let item = obj["item"] as? [String: Any]
                switch obj["type"] as? String {
                case "item.started" where item?["type"] as? String == "command_execution":
                    progress(describe(command: item?["command"] as? String ?? ""))
                case "turn.failed":
                    said = (obj["error"] as? [String: Any])?["message"] as? String ?? said
                case "error":
                    said = obj["message"] as? String ?? said
                default:
                    break
                }
            }
            if said.isEmpty, let data = try? Data(contentsOf: resultURL), let report = jsonObject(in: String(decoding: data, as: UTF8.self)) {
                return Run(structured: report, costUSD: nil, duration: Date().timeIntervalSince(started))
            }
            throw explain(engine, transcript, said: said, limit: "", cwd: cwd)
        }
    }

    // MARK: Explaining failures

    /// The JSON object in `text`, whether it is the whole text or wrapped in a code fence or a sentence.
    static func jsonObject(in text: String) -> Data? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return nil }
        let data = Data(text[open...close].utf8)
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any] ? data : nil
    }

    private static func mentions(_ text: String, _ words: [String]) -> Bool {
        let lowered = text.lowercased()
        return words.contains { lowered.contains($0) }
    }

    /// Turns a run that produced no usable result into an error that says what the CLI reported.
    static func explain(_ engine: Engine, _ transcript: Transcript, said: String, limit: String, cwd: URL) -> AgentError {
        log(engine, transcript, said: said, cwd: cwd)
        if transcript.timedOut {
            return .failed(L("%1$@ was stopped after %2$d minutes without finishing.", engine.name, Int(timeout / 60)))
        }
        // The most specific account available: an event's error, then plain text on stdout, then stderr.
        let candidates = [said, transcript.stray.suffix(3).joined(separator: " "),
                          transcript.stderr.split(separator: "\n").suffix(3).joined(separator: " ")]
        var report = candidates.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
        if report.count > 400 { report = String(report.prefix(400)) + "…" }

        if !limit.isEmpty || mentions(report, ["usage limit", "rate limit", "rate_limit", "limit reached", "hit your limit", "http 429", "quota", "credit balance"]) {
            return .limit([L("%@ has reached its usage limit.", engine.name), limit.isEmpty ? report : limit]
                .filter { !$0.isEmpty }.joined(separator: " "))
        }
        if mentions(report, ["/login", "not logged in", "invalid api key", "authentication", "http 401", "unauthorized", "oauth token"]) {
            return .failed(L("%1$@ isn't signed in. Run `%2$@` in Terminal and sign in, then try again. It said: %3$@", engine.name, engine.command, report))
        }
        if report.isEmpty {
            return .interrupted(L("%1$@ exited (status %2$d) without reporting a result. The details are in %3$@.",
                                  engine.name, Int(transcript.status), logURL.path.tildePath))
        }
        let message = L("%1$@ stopped: %2$@", engine.name, report)
        let passing = mentions(report, ["overloaded", "http 5", "timeout", "timed out", "econnreset", "network", "fetch failed", "socket", "connection"])
        return passing ? .interrupted(message) : .failed(message)
    }

    static var logURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Rulebook/agent.log")
    }

    /// Appends what is known about a failed run to the log, and keeps the log from growing without end.
    private static func log(_ engine: Engine, _ transcript: Transcript, said: String, cwd: URL) {
        let entry = """
        \(Date().formatted(.iso8601)) \(engine.command) in \(cwd.path.tildePath)
          exit status \(transcript.status)\(transcript.timedOut ? ", timed out" : ""), \(transcript.events) events, last event: \(transcript.lastEvent.isEmpty ? "none" : transcript.lastEvent)
          agent said: \(said.isEmpty ? "nothing" : said)
          stdout, not JSON: \(transcript.stray.isEmpty ? "nothing" : transcript.stray.joined(separator: " | "))
          stderr: \(transcript.stderr.isEmpty ? "nothing" : String(transcript.stderr.suffix(1500)))


        """
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = (try? Data(contentsOf: url)) ?? Data()
        if data.count > 400_000 { data = Data(data.suffix(200_000)) }
        data.append(Data(entry.utf8))
        try? data.write(to: url, options: .atomic)
    }

    /// A step of a Claude Code run, for the progress line.
    static func describe(tool: String, input: [String: Any], cwd: URL) -> String {
        func rel(_ raw: String) -> String {
            if raw.contains("/bundled-skills/") { return L("the audit guide") }
            // Standardize both sides, so /private/var/… and /var/… compare equal.
            let p = URL(fileURLWithPath: raw).standardizedFileURL.path, base = cwd.standardizedFileURL.path + "/"
            return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : p.tildePath
        }
        switch tool {
        case "Read": return L("Reading %@", rel(input["file_path"] as? String ?? ""))
        case "Glob": return L("Looking for %@", input["pattern"] as? String ?? "")
        case "Grep": return L("Searching for “%@”", input["pattern"] as? String ?? "")
        case "Skill": return L("Loading the audit guide")
        case "StructuredOutput": return L("Writing up findings")
        default: return tool
        }
    }

    /// A shell command of a Codex run, without the `/bin/zsh -lc '…'` wrapper.
    static func describe(command: String) -> String {
        var c = command
        if let r = c.range(of: " -lc ") { c = String(c[r.upperBound...]) }
        c = c.trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
        return L("Running %@", c.count > 80 ? String(c.prefix(80)) + "…" : c)
    }

    // MARK: Prompt audit

    static let auditSchema = """
    {"type":"object","additionalProperties":false,"required":["score","verdict","summary","strengths","issues","revised"],"properties":{\
    "score":{"type":"integer"},\
    "verdict":{"type":"string"},\
    "summary":{"type":"string"},\
    "strengths":{"type":"array","items":{"type":"string"}},\
    "issues":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["severity","title","detail","quote","suggestion"],"properties":{\
    "severity":{"type":"string","enum":["high","medium","low"]},"title":{"type":"string"},"detail":{"type":"string"},\
    "quote":{"type":"string"},"suggestion":{"type":"string"}}}},\
    "revised":{"type":"string"}}}
    """

    static func auditReportFormat(language: AppLanguage) -> String {
        """
        Report the finished audit as your structured final output. \
        issues: one entry per finding. title names the pattern, detail says why it's a problem here, \
        quote is the exact text from the file (empty if the finding is about something missing), \
        suggestion is the proposed edit. severity reflects impact and confidence. \
        revised: the complete audited file with every proposed edit applied, or an empty string if you propose none. \
        score: an integer from 0 to 100 for how current, accurate and conflict-free the file is. \
        verdict: a headline of 3 to 7 words. summary: 2 or 3 sentences. strengths: what to keep as is. \
        Write verdict, summary, strengths, and each issue's title, detail and suggestion in \(language.promptName). \
        Copy quote from the file unchanged, and write revised in the language the file is already written in. \
        Don't modify any files.
        """
    }

    /// The audit Codex runs. Claude Code has its own, `/doctor prompt-audit`, which Anthropic keeps current.
    static func auditPrompt(relativePath: String) -> String {
        """
        Audit the agent instruction file `\(relativePath)` in this repository. Coding agents load it into their context at the start of every session, so every line costs context and steers behavior.

        Read the file, then check it against the repository. Look for:
        - Instructions written for older, weaker models that current models over-apply: all-caps emphasis, repeated warnings, identity lines such as "You are an expert engineer", and step-by-step guidance for things a capable model does by default.
        - References to files, folders, commands, scripts or tools that this repository doesn't have. Verify each one against the manifests, build files and paths it names.
        - Facts the repository contradicts, such as versions, names and locations.
        - Rules that contradict each other, or that contradict other instruction files in the repository (AGENTS.md, CLAUDE.md, and the ones in subfolders).
        - Rules too vague to act on, and content that repeats what another loaded file already says.

        Report only what you verified. A short file that is accurate needs no findings.
        """
    }

    /// Audits one file: `/doctor prompt-audit` with Claude Code, `auditPrompt` with Codex.
    static func audit(engine: Engine, relativePath: String, cwd: URL, cli: URL, model: String, language: AppLanguage,
                      progress: @escaping @Sendable (String) -> Void) async throws -> Assessment {
        struct Payload: Decodable {
            let score: Int
            let verdict: String
            let summary: String
            let strengths: [String]
            let issues: [Assessment.Finding]
            let revised: String
        }
        let prompt: String
        switch engine {
        case .claude:
            prompt = "/doctor prompt-audit " + relativePath.replacingOccurrences(of: " ", with: "\\ ")
        case .codex:
            prompt = auditPrompt(relativePath: relativePath)
        }
        let run = try await self.run(engine: engine, prompt: prompt, schema: auditSchema,
                                     appendSystemPrompt: auditReportFormat(language: language), cwd: cwd, cli: cli,
                                     model: model, allowSkills: true, progress: progress)
        let p = try JSONDecoder().decode(Payload.self, from: run.structured)
        return Assessment(score: min(100, max(0, p.score)), verdict: p.verdict, summary: p.summary, strengths: p.strengths,
                          issues: p.issues, revised: p.revised, contentHash: "", date: Date(),
                          model: model.isEmpty ? "default" : model, costUSD: run.costUSD, durationSeconds: run.duration,
                          engine: engine.rawValue)
    }

    // MARK: Reconcile

    static let reconcileSchema = """
    {"type":"object","additionalProperties":false,"required":["agents_md","claude_md","notes"],"properties":{\
    "agents_md":{"type":"string"},"claude_md":{"type":"string"},"notes":{"type":"array","items":{"type":"string"}}}}
    """

    static func reconcile(engine: Engine, projectName: String, dir: URL, agentsText: String, claudeText: String,
                          cli: URL, model: String, language: AppLanguage,
                          progress: @escaping @Sendable (String) -> Void) async throws -> ReconcileResult {
        let prompt = """
        Two instruction files in the same folder of the repository \(projectName) have drifted apart. Claude Code reads only CLAUDE.md here, because it exists and doesn't import AGENTS.md. Codex and other agents read only AGENTS.md. So each agent misses rules the other one gets.

        <file name="AGENTS.md">
        \(agentsText)
        </file>

        <file name="CLAUDE.md">
        \(claudeText)
        </file>

        Merge them into a single source of truth:
        - "agents_md": the complete new AGENTS.md. It holds every rule that applies to any coding agent, merged from both files, without duplicates, in the clearest wording. Keep each tool-written block (between markers such as <!-- convex-ai-start --> and <!-- convex-ai-end -->, or <!-- BEGIN:name --> and <!-- END:name -->) exactly once and byte for byte.
        - "claude_md": the complete new CLAUDE.md. Its first line must be exactly "@AGENTS.md", which makes Claude Code load the shared file. After that, keep only instructions that are specific to Claude Code. If there are none, the file is just "@AGENTS.md".
        - "notes": short notes on your decisions, written in \(language.promptName): which side you kept when the files conflicted, and anything you dropped and why.

        Don't invent rules that aren't in either file. When the files contradict each other, read the repository to see which one is accurate, and prefer the more specific rule. Keep the author's voice, language and formatting. Don't modify any files.
        """
        struct Payload: Decodable { let agents_md: String; let claude_md: String; let notes: [String] }
        let run = try await self.run(engine: engine, prompt: prompt, schema: reconcileSchema, cwd: dir,
                                     cli: cli, model: model, progress: progress)
        let p = try JSONDecoder().decode(Payload.self, from: run.structured)
        func ensureNewline(_ s: String) -> String { s.hasSuffix("\n") ? s : s + "\n" }
        return ReconcileResult(agentsMD: ensureNewline(p.agents_md), claudeMD: ensureNewline(p.claude_md), notes: p.notes)
    }
}
