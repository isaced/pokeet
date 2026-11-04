import CPython
import Foundation
import PokeetCore

/// Serves the sandbox filesystem to Python, one JSON operation at a time.
///
/// Mirrors the QuickJS bridge: Python only sees `_pokeet.call(op, json)`, and every
/// path, limit and write proposal is decided here.
final class PythonHost: @unchecked Sendable {
    private let files: any ScriptFileSystem
    private let network: ScriptNetworkAccess?

    init(files: any ScriptFileSystem, network: ScriptNetworkAccess?) {
        self.files = files
        self.network = network
    }

    func handle(_ operation: String, argumentsJSON: String) throws -> String {
        let payload = try decode(argumentsJSON)

        switch operation {
        case "net.request":
            guard let network else {
                throw ScriptRuntimeError.startup("network access is not available in this run")
            }
            return try ScriptNetworkBridge(access: network).handle(argumentsJSON)

        case "fs.read":
            let path = try requirePath(payload)
            return try encode(["content": files.read(path)])

        case "fs.write":
            let path = try requirePath(payload)
            guard let content = payload["content"] as? String else {
                throw ScriptRuntimeError.startup("fs.write needs a string content")
            }
            // Appending is read-then-write so the overlay keeps one buffered copy per
            // file; `read` already returns staged content for files written this run.
            let existing = payload["append"] as? Bool == true && files.exists(path)
                ? try files.read(path)
                : ""
            try files.write(path, content: existing + content)
            return try encode(["path": path, "bytes": content.utf8.count])

        case "fs.list":
            let path = payload["path"] as? String ?? "."
            let recursive = payload["recursive"] as? Bool ?? false
            let entries = try files.list(path, recursive: recursive)
            return try encode([
                "entries": entries.map { entry in
                    ["path": entry.path, "isDirectory": entry.isDirectory]
                }
            ])

        case "fs.check":
            // Path validation on its own: opening a file for writing must fail up front
            // rather than silently at close, which is what a buffered handle would do.
            let path = try requirePath(payload)
            do {
                _ = try files.info(path)
            } catch WorkspaceError.notFound {
                // A valid path that simply has nothing in it yet.
            }
            return try encode(["exists": files.exists(path)])

        case "fs.exists":
            let path = try requirePath(payload)
            return try encode(["exists": files.exists(path)])

        case "fs.info":
            let path = try requirePath(payload)
            let info = try files.info(path)
            var response: [String: Any] = [
                "path": info.path,
                "exists": info.exists,
                "isDirectory": info.isDirectory,
                "size": info.sizeBytes,
                "lines": info.lineCount,
                "isText": info.isText
            ]
            if let modified = info.modified {
                response["modified"] = modified.timeIntervalSince1970
            }
            return try encode(response)

        default:
            throw ScriptRuntimeError.startup("unknown sandbox operation '\(operation)'")
        }
    }

    private func requirePath(_ payload: [String: Any]) throws -> String {
        guard let path = payload["path"] as? String, !path.isEmpty else {
            throw ScriptRuntimeError.startup("this operation needs a path")
        }
        return path
    }

    private func decode(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8) else {
            throw ScriptRuntimeError.startup("arguments are not valid UTF-8")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScriptRuntimeError.startup("arguments must be a JSON object")
        }
        return object
    }

    private func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ScriptRuntimeError.startup("could not encode the response")
        }
        return text
    }
}

/// The trampoline CPython calls. Kept as a free function so it can be handed to C
/// as a plain function pointer.
func pythonHostDispatch(
    opaque: UnsafeMutableRawPointer?,
    operation: UnsafePointer<CChar>?,
    arguments: UnsafePointer<CChar>?,
    error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> UnsafeMutablePointer<CChar>? {
    guard let opaque else { return nil }
    let host = Unmanaged<PythonHost>.fromOpaque(opaque).takeUnretainedValue()
    let name = operation.map { String(cString: $0) } ?? ""
    let payload = arguments.map { String(cString: $0) } ?? "{}"

    do {
        return strdup(try host.handle(name, argumentsJSON: payload))
    } catch let failure {
        let message = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
        error?.pointee = strdup(message)
        return nil
    }
}
