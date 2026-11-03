import Foundation

enum ChatBubblePresentation: Equatable {
    case normal
    case trace
    case traceText
    case notice
}

struct ChatTurnHeader: Identifiable, Equatable {
    let id: UUID
    let isRunning: Bool
    let isExpanded: Bool
    let duration: TimeInterval?
    let stepCount: Int
    let hasFinalAnswer: Bool
}

enum ChatRow: Identifiable, Equatable {
    case turnHeader(ChatTurnHeader)
    case bubble(ChatViewModel.Bubble, ChatBubblePresentation)

    var id: String {
        switch self {
        case .turnHeader(let header):
            "turn-\(header.id.uuidString)"
        case .bubble(let bubble, _):
            bubble.id.uuidString
        }
    }
}

enum ChatTranscriptBuilder {
    static func rows(
        from visible: ArraySlice<ChatViewModel.Bubble>,
        isRunning: Bool,
        overrides: [UUID: Bool]
    ) -> [ChatRow] {
        let bubbles = Array(visible)
        guard !bubbles.isEmpty else { return [] }

        var rows: [ChatRow] = []
        var index = 0
        while index < bubbles.count {
            let bubble = bubbles[index]
            if bubble.role == .user {
                rows.append(.bubble(bubble, .normal))
                index += 1
                continue
            }

            var end = index
            while end < bubbles.count, bubbles[end].role != .user {
                end += 1
            }
            rows.append(contentsOf: rowsForTurn(
                Array(bubbles[index..<end]),
                isCurrent: isRunning && end == bubbles.count,
                overrides: overrides
            ))
            index = end
        }
        return rows
    }

    private static func rowsForTurn(
        _ turn: [ChatViewModel.Bubble],
        isCurrent: Bool,
        overrides: [UUID: Bool]
    ) -> [ChatRow] {
        guard let first = turn.first else { return [] }

        let finalAssistantIndex = turn.lastIndex { $0.role == .assistant }
        let stepCount = turn.enumerated().reduce(into: 0) { count, pair in
            guard pair.offset != finalAssistantIndex else { return }
            switch pair.element.role {
            case .reasoning, .tool, .assistant:
                count += 1
            default:
                break
            }
        }

        guard stepCount > 0 else {
            return turn.map { .bubble($0, presentation(for: $0)) }
        }

        let defaultExpanded = isCurrent || finalAssistantIndex == nil
        let isExpanded = overrides[first.id] ?? defaultExpanded
        let duration = turn.compactMap(\.runDuration).last

        var rows: [ChatRow] = [
            .turnHeader(ChatTurnHeader(
                id: first.id,
                isRunning: isCurrent,
                isExpanded: isExpanded,
                duration: duration,
                stepCount: stepCount,
                hasFinalAnswer: finalAssistantIndex != nil
            ))
        ]

        for (offset, bubble) in turn.enumerated() {
            if offset == finalAssistantIndex {
                rows.append(.bubble(bubble, .normal))
                continue
            }

            if isExpanded {
                switch bubble.role {
                case .assistant:
                    rows.append(.bubble(bubble, .traceText))
                case .reasoning, .tool:
                    rows.append(.bubble(bubble, .trace))
                default:
                    rows.append(.bubble(bubble, presentation(for: bubble)))
                }
            } else if bubble.role == .notice || bubble.role == .error || bubble.role == .todo {
                rows.append(.bubble(bubble, presentation(for: bubble)))
            }
        }
        return rows
    }

    private static func presentation(
        for bubble: ChatViewModel.Bubble
    ) -> ChatBubblePresentation {
        switch bubble.role {
        case .notice:
            .notice
        default:
            .normal
        }
    }
}
