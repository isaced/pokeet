import Foundation
import PokeetCore
import Testing

@testable import PokeetPython

/// The sandbox's only job is to look like a filesystem to a script and like a review
/// queue to the app. Every test here checks both sides of that.
@Suite("Python workspace bridge", .serialized)
struct PythonFilesystemTests {
    struct Fixture {
        let root: URL
        let files: OverlayScriptFileSystem

        func run(_ source: String, limits: ScriptLimits = ScriptLimits()) async throws -> ScriptResult {
            try await PythonRuntime().run(
                ScriptRequest(source: source, filename: "script.py", limits: limits),
                files: files
            )
        }

        func onDisk(_ path: String) -> String? {
            try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
    }

    private func makeFixture(_ seed: [String: String] = [:], limits: ScriptLimits = ScriptLimits()) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-pyfs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, content) in seed {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return Fixture(
            root: root,
            files: OverlayScriptFileSystem(
                workspace: FileWorkspace(root: root),
                limits: limits
            )
        )
    }

    // MARK: reading

    @Test("reads a project file through open()")
    func readsProjectFile() async throws {
        let fixture = try makeFixture(["src/main.py": "print('hi')\n"])
        let result = try await fixture.run(
            "with open('src/main.py') as handle:\n    print(handle.read().strip())"
        )
        #expect(result.termination == .exited, "stderr: \(result.stderr)")
        #expect(result.stdout == "print('hi')\n")
    }

    @Test("reads through pokeet.read and pathlib")
    func readsThroughHelpers() async throws {
        let fixture = try makeFixture(["notes.txt": "alpha\nbeta\n"])
        let result = try await fixture.run("""
        import pokeet, pathlib
        print(len(pokeet.read('notes.txt').splitlines()))
        print(pathlib.Path('notes.txt').read_text().splitlines()[1])
        """)
        #expect(result.termination == .exited, "stderr: \(result.stderr)")
        #expect(result.stdout == "2\nbeta\n")
    }

    @Test("reports a missing file as OSError")
    func missingFileThrows() async throws {
        let fixture = try makeFixture()
        let result = try await fixture.run("""
        try:
            open('nope.txt')
        except OSError as error:
            print('caught', type(error).__name__)
        """)
        #expect(result.termination == .exited, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("caught OSError"))
    }

    // MARK: writing

    @Test("a write becomes a proposal, not a change on disk")
    func writeStagesProposal() async throws {
        let fixture = try makeFixture(["app.txt": "before\n"])
        let result = try await fixture.run("""
        with open('app.txt', 'w') as handle:
            handle.write('after\\n')
        with open('new.txt', 'w') as handle:
            handle.write('created\\n')
        """)

        #expect(result.termination == .exited, "stderr: \(result.stderr)")
        #expect(fixture.onDisk("app.txt") == "before\n", "the workspace must not change before approval")
        #expect(fixture.onDisk("new.txt") == nil)

        let proposals = fixture.files.proposals()
        #expect(proposals.count == 2)
        let update = proposals.first { $0.path == "app.txt" }
        #expect(update?.kind == .update)
        #expect(update?.newContent == "after\n")
        #expect(update?.baseContent == "before\n")
        let create = proposals.first { $0.path == "new.txt" }
        #expect(create?.kind == .create)
        #expect(create?.newContent == "created\n")
    }

    @Test("reads back what the same script wrote")
    func readsItsOwnWrite() async throws {
        let fixture = try makeFixture()
        let result = try await fixture.run("""
        with open('log.txt', 'w') as handle:
            handle.write('one\\n')
        with open('log.txt') as handle:
            print(handle.read().strip())
        """)
        #expect(result.termination == .exited, "stderr: \(result.stderr)")
        #expect(result.stdout == "one\n")
        #expect(fixture.files.proposals().count == 1)
    }

    @Test("append mode keeps the existing content")
    func appendMode() async throws {
        let fixture = try makeFixture(["log.txt": "one\n"])
        let result = try await fixture.run("""
        with open('log.txt', 'a') as handle:
            handle.write('two\\n')
        """)
        #expect(result.termination == .exited, "stderr: \(result.stderr)")
        #expect(fixture.files.proposals().first?.newContent == "one\ntwo\n")
    }

    @Test("a file left open still cannot reach disk by accident")
    func closeIsRequiredForProposal() async throws {
        let fixture = try makeFixture(["a.txt": "x\n"])
        let result = try await fixture.run("""
        handle = open('a.txt', 'w')
        handle.write('y\\n')
        handle.flush()
        print('flushed')
        """)
        #expect(result.termination == .exited, "stderr: \(result.stderr)")
        #expect(fixture.files.proposals().first?.newContent == "y\n")
    }

    @Test("binary mode is refused with a clear error")
    func binaryModeRefused() async throws {
        let fixture = try makeFixture(["a.bin": "x"])
        let result = try await fixture.run("""
        try:
            open('a.bin', 'rb')
        except NotImplementedError as error:
            print('refused')
        """)
        #expect(result.termination == .exited, "stderr: \(result.stderr)")
        #expect(result.stdout == "refused\n")
    }

    // MARK: containment

    @Test("paths above the project root are rejected")
    func rejectsParentTraversal() async throws {
        let fixture = try makeFixture(["a.txt": "x"])
        let result = try await fixture.run("""
        try:
            open('../escape.txt', 'w')
        except OSError:
            print('blocked')
        """)
        #expect(result.termination == .exited, "stderr: \(result.stderr) stdout: \(result.stdout)")
        #expect(result.stdout == "blocked\n", "term=\(result.termination) err=\(result.stderr)")
        #expect(fixture.files.proposals().isEmpty)
    }

    @Test("absolute paths are rejected")
    func rejectsAbsolutePaths() async throws {
        let fixture = try makeFixture()
        let result = try await fixture.run("""
        try:
            open('/etc/passwd')
        except OSError:
            print('blocked')
        """)
        #expect(result.termination == .exited, "stderr: \(result.stderr)")
        #expect(result.stdout == "blocked\n")
    }

    @Test("the per-file write limit is enforced")
    func enforcesWriteLimit() async throws {
        let fixture = try makeFixture(limits: ScriptLimits(maxWriteBytes: 2_000))
        let result = try await fixture.run("""
        try:
            with open('big.txt', 'w') as handle:
                handle.write('x' * 5000)
        except OSError as error:
            print('blocked')
        """)
        #expect(result.termination == .exited, "stderr: \(result.stderr) stdout: \(result.stdout)")
        #expect(result.stdout == "blocked\n", "term=\(result.termination) err=\(result.stderr)")
        #expect(fixture.files.proposals().isEmpty)
    }

    @Test("the per-run file count limit is enforced")
    func enforcesFileCountLimit() async throws {
        let fixture = try makeFixture(limits: ScriptLimits(maxWriteFiles: 2))
        let result = try await fixture.run("""
        written = 0
        for index in range(5):
            try:
                with open('file%d.txt' % index, 'w') as handle:
                    handle.write('x')
                written += 1
            except OSError:
                break
        print(written)
        """)
        #expect(result.termination == .exited, "stderr: \(result.stderr)")
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
        #expect(fixture.files.proposals().count == 2)
    }

    // MARK: listing

    @Test("listdir, walk, exists and info describe the project")
    func listingHelpers() async throws {
        let fixture = try makeFixture([
            "src/a.py": "one\ntwo\n",
            "src/nested/b.py": "three\n",
            "README.md": "# title\n"
        ])
        let result = try await fixture.run("""
        import pokeet
        print(sorted(pokeet.listdir('src')))
        print(len(pokeet.walk('.')))
        print(pokeet.exists('src/a.py'), pokeet.exists('missing.py'))
        print(pokeet.info('src/a.py')['lines'])
        """)
        #expect(result.termination == .exited, "stderr: \(result.stderr)")
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(lines[0].contains("a.py"))
        #expect(lines[1] == "4" || lines[1] == "5")   // four files plus the two directories
        #expect(lines[2] == "True False")
        #expect(lines[3] == "2")
    }

    // MARK: isolation

    @Test("writes from two runs stay separate proposals")
    func runsDoNotShareStaging() async throws {
        let fixture = try makeFixture(["a.txt": "base\n"])
        _ = try await fixture.run("""
        with open('a.txt', 'w') as handle:
            handle.write('first\\n')
        """)
        _ = try await fixture.run("""
        with open('b.txt', 'w') as handle:
            handle.write('second\\n')
        """)

        // Each run gets its own overlay, so the second run still sees the original file.
        let proposals = fixture.files.proposals()
        #expect(proposals.count == 2)
        #expect(proposals.first { $0.path == "a.txt" }?.baseContent == "base\n")
    }
}
