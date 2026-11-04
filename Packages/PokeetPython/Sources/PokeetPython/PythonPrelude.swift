import Foundation

/// The Python side of the sandbox: `open`, `os`, `urllib.request`.
///
/// It lives in a `.py` resource rather than a Swift string so it can be linted and
/// diffed like code. A missing resource is a broken build, so it fails loudly instead
/// of booting an interpreter with no sandbox at all.
enum PythonPrelude {
    static let source: String = {
        guard let url = Bundle.module.url(forResource: "python-prelude", withExtension: "py"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "raise RuntimeError('the Python prelude is missing from the bundle')"
        }
        return text
    }()
}
