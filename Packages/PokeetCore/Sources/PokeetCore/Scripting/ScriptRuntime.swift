import Foundation

/// Resource limits for one sandboxed script run.
public struct ScriptLimits: Sendable, Equatable {
    /// Wall-clock budget enforced by the engine's interrupt handler, not by the caller.
    public var wallClockMilliseconds: Int
    /// Hard heap limit for the script runtime.
    public var memoryBytes: Int
    /// Maximum native stack the script may use before the engine aborts.
    public var stackBytes: Int
    /// Maximum captured stdout plus stderr.
    public var outputBytes: Int
    /// Largest single file a script may read.
    public var maxReadBytes: Int
    /// Largest single file a script may propose writing.
    public var maxWriteBytes: Int
    /// Largest total buffered writes and number of distinct files a script may touch.
    public var maxWriteFiles: Int

    public init(
        wallClockMilliseconds: Int = 15_000,
        memoryBytes: Int = 64 * 1_024 * 1_024,
        stackBytes: Int = 512 * 1_024,
        outputBytes: Int = 16_000,
        maxReadBytes: Int = 512_000,
        maxWriteBytes: Int = 200_000,
        maxWriteFiles: Int = 20
    ) {
        self.wallClockMilliseconds = min(max(500, wallClockMilliseconds), 60_000)
        self.memoryBytes = min(max(4 * 1_024 * 1_024, memoryBytes), 256 * 1_024 * 1_024)
        self.stackBytes = min(max(128 * 1_024, stackBytes), 4 * 1_024 * 1_024)
        self.outputBytes = min(max(1_000, outputBytes), 64_000)
        self.maxReadBytes = min(max(1_000, maxReadBytes), 2_000_000)
        self.maxWriteBytes = min(max(1_000, maxWriteBytes), WorkspaceLimits.maxWriteBytes)
        self.maxWriteFiles = min(max(1, maxWriteFiles), 100)
    }
}

public struct ScriptRequest: Sendable {
    public var source: String
    public var filename: String
    public var arguments: [String]
    public var limits: ScriptLimits
    /// Nil means this run cannot reach the network at all.
    public var network: ScriptNetworkAccess?

    public init(
        source: String,
        filename: String = "script.js",
        arguments: [String] = [],
        limits: ScriptLimits = ScriptLimits(),
        network: ScriptNetworkAccess? = nil
    ) {
        self.source = source
        self.filename = filename
        self.arguments = arguments
        self.limits = limits
        self.network = network
    }
}

public enum ScriptTermination: Sendable, Equatable {
    case exited
    case threw(String)
    case timedOut
    case outOfMemory
    case cancelled
}

public struct ScriptResult: Sendable {
    public var exitCode: Int
    public var stdout: String
    public var stderr: String
    public var termination: ScriptTermination
    public var outputTruncated: Bool
    public var durationMilliseconds: Double

    public init(
        exitCode: Int,
        stdout: String,
        stderr: String,
        termination: ScriptTermination,
        outputTruncated: Bool = false,
        durationMilliseconds: Double = 0
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.termination = termination
        self.outputTruncated = outputTruncated
        self.durationMilliseconds = durationMilliseconds
    }
}

/// A language runtime that can execute short, untrusted scripts inside the app process.
///
/// Implementations must enforce `ScriptRequest.limits` themselves: the agent loop's
/// timeout only stops waiting, it cannot stop a runaway interpreter.
public protocol ScriptRuntime: Sendable {
    var name: String { get }
    var displayName: String { get }
    var aliases: [String] { get }
    func run(_ request: ScriptRequest, files: any ScriptFileSystem) async throws -> ScriptResult
}

public struct ScriptRuntimes: Sendable {
    private let runtimes: [String: any ScriptRuntime]

    public init(_ runtimes: [any ScriptRuntime] = []) {
        var table: [String: any ScriptRuntime] = [:]
        for runtime in runtimes {
            table[runtime.name.lowercased()] = runtime
            for alias in runtime.aliases {
                table[alias.lowercased()] = runtime
            }
        }
        self.runtimes = table
    }

    public static let empty = ScriptRuntimes()

    public var isEmpty: Bool { runtimes.isEmpty }

    /// Canonical runtime names, for error messages and tool descriptions.
    public var names: [String] {
        Array(Set(runtimes.values.map { $0.name })).sorted()
    }

    public func runtime(named name: String) -> (any ScriptRuntime)? {
        runtimes[name.lowercased()]
    }
}

public enum ScriptRuntimeError: Error, Sendable, Equatable, LocalizedError {
    case unavailable
    case unknownRuntime(String, available: [String])
    case startup(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Script execution is not available in this build."
        case .unknownRuntime(let name, let available):
            if available.isEmpty {
                "Unknown runtime '\(name)': no script runtimes are installed."
            } else {
                "Unknown runtime '\(name)'. Available runtimes: \(available.joined(separator: ", "))."
            }
        case .startup(let message):
            "Script runtime failed to start: \(message)"
        }
    }
}
