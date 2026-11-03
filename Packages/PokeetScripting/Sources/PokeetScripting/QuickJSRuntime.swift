import CQuickJS
import Foundation
import PokeetCore

/// A sandboxed JavaScript runtime built on QuickJS.
///
/// QuickJS is an interpreter: it needs no JIT entitlement, and unlike JavaScriptCore
/// its public API exposes interrupt, heap and stack limits, which is what makes it
/// safe to run model-generated code inside the app process.
public final class QuickJSRuntime: ScriptRuntime {
    public let name = "javascript"
    public let displayName = "JavaScript"
    public let aliases = ["js", "ecmascript", "quickjs"]

    public init() {}

    public func run(_ request: ScriptRequest, files: any ScriptFileSystem) async throws -> ScriptResult {
        let state = HostState(files: files, limits: request.limits, arguments: request.arguments)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    do {
                        continuation.resume(returning: try Self.execute(request, state: state))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            // The engine polls this flag from its interrupt handler, so cancellation
            // stops the interpreter instead of only abandoning the caller.
            state.cancel()
        }
    }

    /// One runtime per run keeps runs isolated; a QuickJS runtime costs about a millisecond.
    private static let queue = DispatchQueue(label: "com.pokeet.quickjs", qos: .userInitiated)

    private static func execute(_ request: ScriptRequest, state: HostState) throws -> ScriptResult {
        guard let runtime = JS_NewRuntime() else {
            throw ScriptRuntimeError.startup("could not allocate a JavaScript runtime")
        }
        defer { JS_FreeRuntime(runtime) }

        JS_SetMemoryLimit(runtime, request.limits.memoryBytes)
        JS_SetMaxStackSize(runtime, request.limits.stackBytes)

        guard let context = JS_NewContext(runtime) else {
            throw ScriptRuntimeError.startup("could not create a JavaScript context")
        }
        defer { JS_FreeContext(context) }

        let start = pokeet_now_ms()
        let deadline = start + Double(request.limits.wallClockMilliseconds)
        var host = PokeetHost(
            opaque: Unmanaged.passUnretained(state).toOpaque(),
            dispatch: hostDispatch,
            deadline_ms: deadline,
            cancelled: state.cancellationPointer
        )

        return try withUnsafeMutablePointer(to: &host) { hostPointer in
            pokeet_install_host(context, hostPointer)

            let argumentsJSON = (try? JSONSerialization.data(withJSONObject: state.arguments))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            if case .error(let message) = evaluate(
                context,
                source: "globalThis.__pokeetArgs = \(argumentsJSON);",
                filename: "pokeet-args.js"
            ) {
                if state.isCancelled {
                    return cancelledResult(state, start: start)
                }
                throw ScriptRuntimeError.startup("could not install script arguments: \(message)")
            }

            if case .error(let message) = evaluate(context, source: Self.prelude, filename: "pokeet-prelude.js") {
                if state.isCancelled {
                    return cancelledResult(state, start: start)
                }
                throw ScriptRuntimeError.startup("prelude failed: \(message)")
            }

            let outcome = evaluate(context, source: request.source, filename: request.filename)
            let duration = pokeet_now_ms() - start

            let termination: ScriptTermination
            let exitCode: Int
            switch outcome {
            case .ok:
                termination = .exited
                exitCode = state.exitCode ?? 0
            case .error(let message):
                if let explicit = state.exitCode {
                    termination = .exited
                    exitCode = explicit
                } else if pokeet_now_ms() >= deadline {
                    termination = .timedOut
                    exitCode = 1
                } else if state.isCancelled {
                    termination = .cancelled
                    exitCode = 1
                } else if message == "null" || message == "undefined"
                    || message.lowercased().contains("out of memory") {
                    termination = .outOfMemory
                    exitCode = 1
                } else {
                    termination = .threw(message)
                    exitCode = 1
                }
            }

            return ScriptResult(
                exitCode: exitCode,
                stdout: state.standardOutput,
                stderr: state.standardError,
                termination: termination,
                outputTruncated: state.outputTruncated,
                durationMilliseconds: duration
            )
        }
    }

    private static func cancelledResult(_ state: HostState, start: Double) -> ScriptResult {
        ScriptResult(
            exitCode: 1,
            stdout: state.standardOutput,
            stderr: state.standardError,
            termination: .cancelled,
            outputTruncated: state.outputTruncated,
            durationMilliseconds: pokeet_now_ms() - start
        )
    }

    private enum Evaluation {
        case ok
        case error(String)
    }

    private static func evaluate(_ context: OpaquePointer, source: String, filename: String) -> Evaluation {
        let value: JSValue = source.withCString { pointer in
            filename.withCString { namePointer in
                JS_Eval(
                    context,
                    pointer,
                    source.utf8.count,
                    namePointer,
                    JS_EVAL_TYPE_GLOBAL
                )
            }
        }

        if JS_IsException(value) {
            let exception = JS_GetException(context)
            defer { JS_FreeValue(context, exception) }
            guard let text = JS_ToCString(context, exception) else {
                return .error("unknown error")
            }
            defer { JS_FreeCString(context, text) }
            return .error(String(cString: text))
        }

        JS_FreeValue(context, value)
        return .ok
    }
}

// MARK: - Host bridge

private final class HostState: @unchecked Sendable {
    let files: any ScriptFileSystem
    let limits: ScriptLimits
    let arguments: [String]

    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var truncated = false
    private var explicitExitCode: Int?
    private let cancellationFlag: UnsafeMutablePointer<Int32>

    init(files: any ScriptFileSystem, limits: ScriptLimits, arguments: [String]) {
        self.files = files
        self.limits = limits
        self.arguments = arguments
        self.cancellationFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        self.cancellationFlag.initialize(to: 0)
    }

    deinit {
        cancellationFlag.deinitialize(count: 1)
        cancellationFlag.deallocate()
    }

    var standardOutput: String { stdoutBuffer }
    var standardError: String { stderrBuffer }
    var outputTruncated: Bool { truncated }
    var exitCode: Int? { explicitExitCode }
    var cancellationPointer: UnsafeMutablePointer<Int32> { cancellationFlag }
    var isCancelled: Bool { cancellationFlag.pointee != 0 }

    func cancel() {
        cancellationFlag.pointee = 1
    }

    func handle(_ operation: String, argumentsJSON: String) throws -> String {
        let payload = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)))
            as? [String: Any] ?? [:]

        switch operation {
        case "log":
            let level = payload["level"] as? String ?? "log"
            let text = payload["text"] as? String ?? ""
            append(text, isError: level == "warn" || level == "error")
            return "{}"

        case "fs.read":
            let path = try requiredPath(payload)
            return try encode(["content": files.read(path)])

        case "fs.write":
            let path = try requiredPath(payload)
            guard let content = payload["content"] as? String else {
                throw ScriptRuntimeError.startup("fs.write requires a string 'content'.")
            }
            try files.write(path, content: content)
            return try encode(["ok": true])

        case "fs.exists":
            let path = try requiredPath(payload)
            return try encode(["exists": files.exists(path)])

        case "fs.list":
            let path = payload["path"] as? String ?? ""
            let recursive = payload["recursive"] as? Bool ?? false
            let entries = try files.list(path, recursive: recursive)
            let encoded = entries.map { entry -> [String: Any] in
                [
                    "path": entry.path,
                    "name": (entry.path as NSString).lastPathComponent,
                    "isDirectory": entry.isDirectory
                ]
            }
            return try encode(["entries": encoded])

        case "fs.info":
            let path = try requiredPath(payload)
            let info = try files.info(path)
            return try encode([
                "path": info.path,
                "exists": info.exists,
                "isDirectory": info.isDirectory,
                "sizeBytes": info.sizeBytes,
                "lineCount": info.lineCount,
                "isText": info.isText
            ])

        case "process.exit":
            explicitExitCode = payload["code"] as? Int ?? 0
            return "{}"

        default:
            throw ScriptRuntimeError.startup("unknown host operation '\(operation)'")
        }
    }

    private func requiredPath(_ payload: [String: Any]) throws -> String {
        guard let path = payload["path"] as? String, !path.isEmpty else {
            throw ScriptRuntimeError.startup("a non-empty 'path' is required.")
        }
        return path
    }

    private func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ScriptRuntimeError.startup("could not encode a host response")
        }
        return text
    }

    private func append(_ text: String, isError: Bool) {
        let used = stdoutBuffer.utf8.count + stderrBuffer.utf8.count
        // Keep one byte for the trailing newline so the cap is a hard limit.
        let remaining = limits.outputBytes - used - 1
        guard remaining > 0 else {
            truncated = true
            return
        }
        var slice = text
        if slice.utf8.count > remaining {
            slice = String(decoding: Array(slice.utf8).prefix(remaining), as: UTF8.self)
            truncated = true
        }
        if isError {
            stderrBuffer += slice + "\n"
        } else {
            stdoutBuffer += slice + "\n"
        }
    }
}

private func hostDispatch(
    opaque: UnsafeMutableRawPointer?,
    operation: UnsafePointer<CChar>?,
    arguments: UnsafePointer<CChar>?,
    error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> UnsafeMutablePointer<CChar>? {
    guard let opaque else {
        return nil
    }
    let state = Unmanaged<HostState>.fromOpaque(opaque).takeUnretainedValue()
    let name = operation.map { String(cString: $0) } ?? ""
    let payload = arguments.map { String(cString: $0) } ?? "{}"

    do {
        let response = try state.handle(name, argumentsJSON: payload)
        return strdup(response)
    } catch let failure {
        let message = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
        error?.pointee = strdup(message)
        return nil
    }
}
