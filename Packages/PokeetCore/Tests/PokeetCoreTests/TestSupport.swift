import Foundation
import PokeetCore

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private static let lock = NSLock()
    private static let defaultHostKey = "*"

    static func setHandler(_ newHandler: Handler?) {
        setHandler(forHost: nil, newHandler)
    }

    static func setHandler(forHost host: String?, _ newHandler: Handler?) {
        lock.lock()
        if let newHandler {
            handlers[host ?? defaultHostKey] = newHandler
        } else {
            handlers.removeValue(forKey: host ?? defaultHostKey)
        }
        lock.unlock()
    }

    private static func currentHandler(for request: URLRequest) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        if let host = request.url?.host, let handler = handlers[host] {
            return handler
        }
        return handlers[defaultHostKey]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.currentHandler(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func requestBody(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let read = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let baseAddress = raw.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return stream.read(baseAddress, maxLength: raw.count)
        }
        if read <= 0 {
            break
        }
        data.append(buffer, count: read)
    }
    return data.isEmpty ? nil : data
}

struct TestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ relativePath: String, _ content: String) throws {
        let fileURL = url.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

struct FakeScriptRuntime: ScriptRuntime {
    let behaviour: @Sendable (ScriptRequest, any ScriptFileSystem) throws -> ScriptResult

    var name: String { "javascript" }
    var displayName: String { "Fake JS" }
    var aliases: [String] { ["js"] }

    func run(_ request: ScriptRequest, files: any ScriptFileSystem) async throws -> ScriptResult {
        try behaviour(request, files)
    }
}
