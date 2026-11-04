import Foundation

public struct RunScriptTool: AgentTool {
    public static let toolName = "run_script"
    public static let defaultTimeoutMilliseconds = 15_000
    /// Kept below the agent loop's tool timeout so the engine interrupts before the caller gives up.
    public static let maximumTimeoutMilliseconds = 55_000
    public static let maximumSourceBytes = 60_000

    private let network: NetworkClient
    private let runtimes: [String]

    /// A script reads a whole document, unlike `http_request`, which renders a preview.
    public static let networkLimits = NetworkClient.Limits(maxBodyBytes: 262_144)

    /// `network` is injectable so tests can stub transport without stubbing the sandbox.
    public init(
        network: NetworkClient = NetworkClient(limits: RunScriptTool.networkLimits),
        runtimes: [String] = ["javascript", "python"]
    ) {
        self.network = network
        self.runtimes = runtimes
    }

    public var capabilities: Set<ToolCapability> { [.runScript] }

    public var schema: ToolSchema {
        ToolSchema(
            name: Self.toolName,
            description: """
            Run a short script in the on-device sandbox and return its output. \
            There is no shell and no package manager. \
            Network requests go through the app's policy: https:// only, redirects \
            re-checked, no sockets. Use http.get/http.post or fetch() in JavaScript, and \
            urllib.request.urlopen(Request) in Python — urlopen returns the response for \
            any status (call raise_for_status() or read .status), and there are no \
            environment variables to read secrets from. \
            JavaScript otherwise uses the sandbox API (console, assert, fs, path, \
            require for relative CommonJS files). Python is a full interpreter with a \
            trimmed standard library: open() reads and writes project files, and \
            `import pokeet` lists, checks and inspects them. \
            Reads see the repository; writes are captured as diff proposals and are not \
            applied until the user approves them.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "runtime": .object([
                        "type": .string("string"),
                        "description": .string("Script runtime. Available: \(runtimes.joined(separator: ", ")).")
                    ]),
                    "script": .object([
                        "type": .string("string"),
                        "description": .string("Inline script source. Prefer this: the source is shown in the review card.")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Run an existing file in the repository instead of inline source.")
                    ]),
                    "args": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Arguments exposed as process.argv.")
                    ]),
                    "timeout_ms": .object([
                        "type": .string("integer"),
                        "description": .string("Wall-clock budget in milliseconds. Defaults to 15000, maximum 55000.")
                    ])
                ]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    public func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        try Task.checkCancellation()

        struct Arguments: Decodable {
            var runtime: String?
            var script: String?
            var path: String?
            var args: [String]?
            var timeout_ms: Int?
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        let runtimes = context.scripting ?? .empty
        guard !runtimes.isEmpty else {
            throw ScriptRuntimeError.unavailable
        }

        let runtimeName = (arguments.runtime ?? "javascript")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let runtime = runtimes.runtime(named: runtimeName) else {
            throw ScriptRuntimeError.unknownRuntime(runtimeName, available: runtimes.names)
        }

        let inline = arguments.script?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = arguments.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard inline.isEmpty != path.isEmpty else {
            throw ToolError.invalidInput("Provide exactly one of 'script' or 'path'.")
        }

        let filename: String
        let source: String
        if !path.isEmpty {
            do {
                try context.workspace.validate(path)
                source = try context.workspace.read(path, maxBytes: Self.maximumSourceBytes)
            } catch {
                throw ToolError.workspace(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
            filename = path
        } else {
            source = inline
            filename = "script.\(runtime.name == "python" ? "py" : "js")"
        }

        guard source.utf8.count <= Self.maximumSourceBytes else {
            throw ToolError.invalidInput(
                "Script source is too large (max \(Self.maximumSourceBytes) bytes)."
            )
        }

        let timeout = min(
            max(500, arguments.timeout_ms ?? Self.defaultTimeoutMilliseconds),
            Self.maximumTimeoutMilliseconds
        )
        let limits = ScriptLimits(wallClockMilliseconds: timeout)
        let files = OverlayScriptFileSystem(workspace: context.workspace, limits: limits)
        let request = ScriptRequest(
            source: source,
            filename: filename,
            arguments: arguments.args ?? [],
            limits: limits,
            network: ScriptNetworkAccess(client: network, policy: context.networkPolicy)
        )

        let result = try await runtime.run(request, files: files)
        return Self.output(for: result, runtime: runtime, files: files, timeout: timeout)
    }

    private static func output(
        for result: ScriptResult,
        runtime: any ScriptRuntime,
        files: any ScriptFileSystem,
        timeout: Int
    ) -> ToolOutput {
        var sections: [String] = []

        switch result.termination {
        case .exited:
            sections.append("\(runtime.displayName) · exit \(result.exitCode) · \(Int(result.durationMilliseconds)) ms")
        case .threw(let message):
            // The first line is all the collapsed trace shows, so it has to carry the
            // reason; the traceback stays for when the row is expanded.
            let headline = message
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map { $0.count > 120 ? String($0.prefix(120)) + "…" : String($0) }
                ?? "uncaught error"
            sections.append(
                "\(runtime.displayName) · uncaught error · \(headline) · "
                    + "\(Int(result.durationMilliseconds)) ms\n\(message)"
            )
        case .timedOut:
            sections.append(
                "\(runtime.displayName) · stopped after the \(timeout) ms limit. "
                    + "The script was interrupted mid-run, so any buffered writes were discarded. "
                    + "Simplify it, narrow the work, or raise timeout_ms."
            )
        case .outOfMemory:
            sections.append(
                "\(runtime.displayName) · stopped: script exceeded the memory limit. "
                    + "Avoid materializing large arrays or strings; stream over files instead."
            )
        case .cancelled:
            sections.append("\(runtime.displayName) · cancelled.")
        }

        if !result.stdout.isEmpty {
            sections.append("stdout:\n" + result.stdout)
        }
        if !result.stderr.isEmpty {
            sections.append("stderr:\n" + result.stderr)
        }
        if result.outputTruncated {
            sections.append("[output truncated at the sandbox limit]")
        }
        if result.stdout.isEmpty, result.stderr.isEmpty, case .exited = result.termination {
            sections.append("(no output)")
        }

        let interrupted: Bool
        switch result.termination {
        case .timedOut, .cancelled:
            interrupted = true
        case .exited, .threw, .outOfMemory:
            interrupted = false
        }

        let proposals = interrupted ? [] : files.proposals()
        if !proposals.isEmpty {
            let summary = proposals
                .map { "\($0.path) (+\($0.addedLines)/-\($0.removedLines))" }
                .joined(separator: ", ")
            sections.append("Proposed changes awaiting approval: \(summary)")
        }

        return ToolOutput(content: sections.joined(separator: "\n\n"), proposals: proposals)
    }
}
