import Foundation

struct ChatEntry: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
        case system
        case terminalCommand
        case terminalOutput
    }

    let id: UUID
    let role: Role
    var text: String
    var itemID: String?

    init(id: UUID = UUID(), role: Role, text: String, itemID: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.itemID = itemID
    }
}

struct CodexChoice: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let detail: String
}

struct CodexQuestion: Identifiable, Equatable {
    let id: String
    let header: String
    let prompt: String
    let choices: [CodexChoice]
    let acceptsCustomAnswer: Bool
}

struct CodexEffortOption: Identifiable, Equatable {
    var id: String { value }
    let value: String
    let description: String
}

struct CodexModelOption: Identifiable, Equatable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let defaultEffort: String
    let supportedEfforts: [CodexEffortOption]
    let isDefault: Bool
}

enum PendingInteractionKind: Equatable {
    case questions([CodexQuestion])
    case approval(title: String, detail: String, allowsSessionApproval: Bool)
}

struct PendingInteraction {
    let requestID: Any
    let method: String
    let kind: PendingInteractionKind
}

enum NotchStatus: Equatable {
    case terminal
    case terminalRunning
    case connecting
    case ready
    case working
    case needsInput
    case done
    case failed(String)

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .terminalRunning: return "Terminal is running"
        case .connecting: return "Connecting"
        case .ready: return "Ready"
        case .working: return "Codex is working"
        case .needsInput: return "Your input is needed"
        case .done: return "Done"
        case .failed: return "Connection issue"
        }
    }
}

enum WorkspaceMode: Equatable {
    case terminal
    case codex
}

enum ActionFeedback: Equatable {
    case approved
    case denied
    case choiceChanged
}

enum ProtocolParser {
    static func questions(from params: [String: Any]) -> [CodexQuestion] {
        guard let rawQuestions = params["questions"] as? [[String: Any]] else { return [] }

        return rawQuestions.compactMap { raw in
            guard let id = raw["id"] as? String,
                  let prompt = raw["question"] as? String else { return nil }

            let rawChoices = raw["options"] as? [[String: Any]] ?? []
            let choices = rawChoices.compactMap { option -> CodexChoice? in
                guard let label = option["label"] as? String else { return nil }
                return CodexChoice(label: label, detail: option["description"] as? String ?? "")
            }

            return CodexQuestion(
                id: id,
                header: raw["header"] as? String ?? "Question",
                prompt: prompt,
                choices: choices,
                acceptsCustomAnswer: (raw["isOther"] as? Bool) ?? true
            )
        }
    }

    static func statusDetail(from item: [String: Any]) -> String? {
        guard let type = item["type"] as? String else { return nil }
        switch type {
        case "commandExecution":
            if let command = item["command"] as? String { return "Running \(compact(command))" }
            return "Running a command"
        case "fileChange": return "Editing files"
        case "mcpToolCall":
            return "Using \((item["tool"] as? String) ?? "a tool")"
        case "webSearch": return "Searching the web"
        case "reasoning": return "Thinking through the task"
        case "agentMessage": return "Writing the response"
        default: return nil
        }
    }

    private static func compact(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 52 ? String(oneLine.prefix(49)) + "…" : oneLine
    }
}
