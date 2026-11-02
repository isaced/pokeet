struct BubblePager: Equatable, Sendable {
    static let defaultPageSize = 60

    let pageSize: Int
    private(set) var start: Int = 0

    init(pageSize: Int = BubblePager.defaultPageSize) {
        self.pageSize = pageSize
    }

    /// Range of bubbles to render, always anchored to the newest entry.
    func window(total: Int) -> Range<Int> {
        let lower = min(max(start, 0), total)
        return lower..<total
    }

    mutating func reset(total: Int) {
        start = max(0, total - pageSize)
    }

    @discardableResult
    mutating func loadOlder(total: Int) -> Bool {
        guard start > 0 else { return false }
        start = max(0, start - pageSize)
        return true
    }

    mutating func clamp(total: Int) {
        guard total > 0 else {
            start = 0
            return
        }
        start = min(max(start, 0), total - 1)
    }
}
