import CPython
import Foundation
import PokeetCore

/// Sandboxed CPython, held to the same contract as `QuickJSRuntime`.
///
/// Spike status: proves the interpreter can be started, interrupted and capped
/// inside the process. Filesystem access is not bridged yet — `files` is unused,
/// so `open()` in a script cannot see the workspace.
public final class PythonRuntime: ScriptRuntime, @unchecked Sendable {
    public let name = "python"
    public let displayName = "Python"
    public let aliases = ["py", "python3"]

    /// `home` is the directory holding `lib/python3.x` — the bundled stdlib on iOS.
    /// Nil uses the interpreter's compiled-in prefix, which is only correct when the
    /// binary runs on the machine that built it. The interpreter is a process-wide
    /// singleton, so the first runtime to run wins.
    private let home: String?

    public init(home: String? = nil) {
        self.home = home
    }

    public func run(_ request: ScriptRequest, files: any ScriptFileSystem) async throws -> ScriptResult {
        let started = Date()
        let home = self.home
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    do {
                        continuation.resume(returning: try Self.execute(request, home: home, files: files, startedAt: started))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            // The watchdog's mechanism, reused: cancel means "stop the interpreter".
            pokeet_py_interrupt()
        }
    }

    /// One interpreter per process, one run at a time: CPython cannot be torn down
    /// and rebuilt cheaply, and the GIL makes parallel runs pointless anyway.
    private static let queue = DispatchQueue(label: "com.pokeet.python", qos: .userInitiated)

    private static func execute(
        _ request: ScriptRequest,
        home: String?,
        files: any ScriptFileSystem,
        startedAt: Date
    ) throws -> ScriptResult {
        guard pokeet_py_start_with_home(home) == 0 else {
            throw ScriptRuntimeError.startup("CPython could not start")
        }

        guard pokeet_py_bootstrap(PythonPrelude.source) == 0 else {
            throw ScriptRuntimeError.startup("the Python sandbox prelude failed to load")
        }

        // Enforced by a watchdog because CPython has no interrupt handler; the agent
        // loop's own timeout can only stop waiting. It repeats: the asynchronous
        // exception is one-shot, so a script that catches KeyboardInterrupt and keeps
        // going would otherwise escape.
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        watchdog.schedule(
            deadline: .now() + .milliseconds(request.limits.wallClockMilliseconds),
            repeating: .milliseconds(250)
        )
        watchdog.setEventHandler { pokeet_py_interrupt() }
        watchdog.resume()
        defer { watchdog.cancel() }

        var stdoutPointer: UnsafeMutablePointer<CChar>?
        var stderrPointer: UnsafeMutablePointer<CChar>?
        var errorTypePointer: UnsafeMutablePointer<CChar>?
        var errorMessagePointer: UnsafeMutablePointer<CChar>?

        let host = PythonHost(files: files)
        var bridge = PokeetPyHost(
            opaque: Unmanaged.passUnretained(host).toOpaque(),
            dispatch: pythonHostDispatch
        )
        var termination: Int32 = 0

        let status = withUnsafeMutablePointer(to: &bridge) { pointer -> Int32 in
            pokeet_py_install_host(pointer)
            defer { pokeet_py_clear_host() }
            return pokeet_py_run(
                request.source,
                request.filename,
                request.limits.memoryBytes,
                &stdoutPointer,
                &stderrPointer,
                &termination,
                &errorTypePointer,
                &errorMessagePointer
            )
        }

        defer {
            pokeet_py_free(stdoutPointer)
            pokeet_py_free(stderrPointer)
            pokeet_py_free(errorTypePointer)
            pokeet_py_free(errorMessagePointer)
        }

        guard status == 0 else {
            throw ScriptRuntimeError.startup("CPython refused the run")
        }

        let stdout = stdoutPointer.map { String(cString: $0) } ?? ""
        let stderr = stderrPointer.map { String(cString: $0) } ?? ""
        let errorType = errorTypePointer.map { String(cString: $0) } ?? "Error"
        let errorMessage = errorMessagePointer.map { String(cString: $0) } ?? ""

        let outcome: (ScriptTermination, Int)
        switch termination {
        case 2: outcome = (.timedOut, 1)
        case 3: outcome = (.outOfMemory, 1)
        case 1: outcome = (.threw("\(errorType): \(errorMessage)"), 1)
        default: outcome = (.exited, 0)
        }

        let limit = request.limits.outputBytes
        let truncated = stdout.utf8.count + stderr.utf8.count > limit

        return ScriptResult(
            exitCode: outcome.1,
            stdout: String(decoding: stdout.utf8.prefix(limit), as: UTF8.self),
            stderr: String(decoding: stderr.utf8.prefix(limit), as: UTF8.self),
            termination: outcome.0,
            outputTruncated: truncated,
            durationMilliseconds: Date().timeIntervalSince(startedAt) * 1000
        )
    }
}

public extension PythonRuntime {
    /// The stdlib staged into the app bundle by `scripts/fetch-python.sh`, arranged as
    /// `<home>/lib/python3.x` because that is what the interpreter looks for.
    static func bundledHome(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "python-home", withExtension: nil) else {
            return nil
        }
        let lib = url.appendingPathComponent("lib")
        let hasStdlib = (try? FileManager.default.contentsOfDirectory(atPath: lib.path))?
            .contains { $0.hasPrefix("python3.") } ?? false
        return hasStdlib ? url.path : nil
    }
}

/// The interpreter's own accounting, for the memory test.
public var pythonAllocatedBytes: Int {
    Int(pokeet_py_allocated())
}
