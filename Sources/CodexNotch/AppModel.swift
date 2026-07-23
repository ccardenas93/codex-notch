import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var workspaceMode: WorkspaceMode = .terminal
    @Published var status: NotchStatus = .terminal
    @Published var activity = "~  ·  type codex to enter Codex"
    @Published var entries: [ChatEntry] = []
    @Published var pendingInteraction: PendingInteraction?
    @Published var selectedAnswers: [String: String] = [:]
    @Published var isExpanded = false
    @Published var isPinned = false
    @Published var composerText = ""
    @Published var actionFeedback: ActionFeedback?
    @Published var feedbackNonce = 0
    @Published var terminalBusy = false
    @Published var availableModels: [CodexModelOption] = []
    @Published var selectedModelID: String?
    @Published var selectedEffort: String?
    @Published var canAddNotch = true
    @Published var canCloseNotch = false
    @Published var notchCount = 1
    @Published var showCloseConfirmation = false
    @Published var collaborationMode = "default"
    @Published var contextUsedTokens: Int64 = 0
    @Published var contextWindowTokens: Int64?
    @Published var queuedMessages: [QueuedCodexMessage] = []
    @Published var isStoppingTurn = false

    var onAddNotch: (() -> Void)?
    var onCloseNotch: (() -> Void)?

    private let server = CodexServer()
    private let terminal = TerminalSession()
    private var threadID: String?
    private var turnID: String?
    private var queuedPrompt: String?
    private var didInitialize = false
    private var serverStarted = false
    private var hoverGeneration = 0
    private var pointerInside = false
    private var panelFocused = false
    private let persistedThreadKey: String
    private let persistedModelKey: String
    private let persistedEffortKey: String
    private let persistedModeKey: String

    init(slot: Int = 0) {
        let suffix = slot == 0 ? "" : ".slot\(slot + 1)"
        persistedThreadKey = "CodexNotch.threadID\(suffix)"
        persistedModelKey = "CodexNotch.model\(suffix)"
        persistedEffortKey = "CodexNotch.effort\(suffix)"
        persistedModeKey = "CodexNotch.mode\(suffix)"
        collaborationMode = UserDefaults.standard.string(forKey: persistedModeKey) ?? "default"
    }

    var needsAttention: Bool { pendingInteraction != nil }
    var canSend: Bool {
        let hasText = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch workspaceMode {
        case .terminal: return hasText
        case .codex: return hasText && threadID != nil
        }
    }

    var composerPlaceholder: String {
        if workspaceMode == .terminal {
            return "Run a command…  (type codex to enter)"
        }
        return turnID == nil ? "Tell Codex what to do…" : "Queue a follow-up…"
    }

    var selectedModel: CodexModelOption? {
        availableModels.first(where: { $0.id == selectedModelID })
    }

    var modelSelectionSummary: String {
        guard let selectedModel else { return "Codex default" }
        return "\(selectedModel.displayName) · \(selectedEffort ?? selectedModel.defaultEffort)"
    }

    var hasActiveCodexTurn: Bool { turnID != nil }

    var contextRemainingFraction: Double? {
        guard let contextWindowTokens, contextWindowTokens > 0 else { return nil }
        return max(0, min(1, Double(contextWindowTokens - contextUsedTokens) / Double(contextWindowTokens)))
    }

    var contextLabel: String {
        guard let fraction = contextRemainingFraction else { return "CTX —" }
        return "CTX \(Int((fraction * 100).rounded()))%"
    }

    func start() {
        server.onEvent = { [weak self] event in self?.handle(event) }
        server.onTermination = { [weak self] reason in
            self?.serverStarted = false
            guard self?.workspaceMode == .codex else { return }
            self?.status = .failed(reason)
            self?.activity = reason
            self?.isExpanded = true
        }
        terminal.onCommandStarted = { [weak self] command in
            self?.terminalBusy = true
            self?.status = .terminalRunning
            self?.activity = command
        }
        terminal.onOutput = { [weak self] output in
            self?.entries.append(ChatEntry(role: .terminalOutput, text: output))
        }
        terminal.onCommandFinished = { [weak self] status in
            self?.terminalBusy = false
            self?.status = .terminal
            self?.activity = status == 0 ? "~  ·  ready" : "Command exited with status \(status)"
        }
        terminal.onTermination = { [weak self] reason in
            self?.terminalBusy = false
            self?.status = .failed(reason)
            self?.activity = reason
        }

        do {
            try terminal.start()
        } catch {
            status = .failed(error.localizedDescription)
            activity = error.localizedDescription
            isExpanded = true
        }
    }

    func shutdown() {
        terminal.stop()
        server.stop()
    }

    func setHovered(_ hovered: Bool) {
        hoverGeneration += 1
        let generation = hoverGeneration
        pointerInside = hovered
        if hovered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
                guard let self,
                      self.hoverGeneration == generation,
                      self.pointerInside else { return }
                self.isExpanded = true
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self,
                      self.hoverGeneration == generation,
                      !self.pointerInside,
                      !self.panelFocused,
                      !self.isPinned else { return }
                self.isExpanded = false
            }
        }
    }

    func togglePinned() {
        isPinned.toggle()
        isExpanded = isPinned || needsAttention
    }

    func collapse() {
        isPinned = false
        isExpanded = false
    }

    func minimizeForFocusLoss() {
        hoverGeneration += 1
        pointerInside = false
        panelFocused = false
        isPinned = false
        isExpanded = false
    }

    func panelDidBecomeKey() {
        panelFocused = true
    }

    func sendComposer() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composerText = ""
        switch workspaceMode {
        case .terminal:
            runTerminalInput(text)
        case .codex:
            if text == "exit" || text == "/exit" {
                returnToTerminal()
            } else {
                sendPrompt(text)
            }
        }
    }

    func interruptTerminal() {
        guard workspaceMode == .terminal, terminalBusy else { return }
        activity = "Interrupting command"
        terminal.interrupt()
    }

    func interruptCodexTurn() {
        guard let threadID, let turnID, !isStoppingTurn else { return }
        isStoppingTurn = true
        activity = "Stopping Codex"
        server.request(
            method: "turn/interrupt",
            params: ["threadId": threadID, "turnId": turnID]
        ) { [weak self] result in
            if case .failure(let error) = result {
                self?.isStoppingTurn = false
                self?.status = .failed(error.localizedDescription)
                self?.activity = error.localizedDescription
            }
        }
    }

    func setCollaborationMode(_ mode: String) {
        guard turnID == nil, mode == "default" || mode == "plan" else { return }
        collaborationMode = mode
        UserDefaults.standard.set(mode, forKey: persistedModeKey)
        activity = mode == "plan" ? "Plan mode · next turn" : "Build mode · next turn"
        triggerFeedback(.choiceChanged)
    }

    func removeQueuedMessage(_ id: UUID) {
        queuedMessages.removeAll(where: { $0.id == id })
    }

    func clearQueuedMessages() {
        queuedMessages.removeAll()
    }

    func runNextQueuedMessage() {
        guard turnID == nil, !queuedMessages.isEmpty else { return }
        let next = queuedMessages.removeFirst()
        sendPrompt(next.text)
    }

    func addNotch() {
        guard canAddNotch else {
            activity = "Six notches is the maximum"
            return
        }
        onAddNotch?()
    }

    func requestCloseNotch() {
        guard canCloseNotch else { return }
        if terminalBusy || turnID != nil {
            showCloseConfirmation = true
            isExpanded = true
        } else {
            onCloseNotch?()
        }
    }

    func confirmCloseNotch() {
        guard canCloseNotch else { return }
        showCloseConfirmation = false
        onCloseNotch?()
    }

    func cancelCloseNotch() {
        showCloseConfirmation = false
    }

    func returnToTerminal() {
        guard turnID == nil else {
            activity = "Wait for the Codex turn to finish before exiting"
            return
        }
        workspaceMode = .terminal
        status = .terminal
        activity = "~  ·  type codex to return"
        pendingInteraction = nil
        selectedAnswers.removeAll()
    }

    func sendPrompt(_ text: String) {
        guard let threadID else {
            queuedPrompt = text
            return
        }
        if turnID != nil {
            queuedMessages.append(QueuedCodexMessage(text: text))
            activity = "\(queuedMessages.count) follow-up\(queuedMessages.count == 1 ? "" : "s") queued"
            return
        }

        entries.append(ChatEntry(role: .user, text: text))
        status = .working
        activity = "Understanding your request"
        pendingInteraction = nil
        selectedAnswers = [:]

        var params: [String: Any] = [
            "threadId": threadID,
            "input": [["type": "text", "text": text]],
            "cwd": FileManager.default.homeDirectoryForCurrentUser.path,
        ]
        if let selectedModel {
            params["model"] = selectedModel.model
            params["effort"] = selectedEffort ?? selectedModel.defaultEffort
            params["collaborationMode"] = [
                "mode": collaborationMode,
                "settings": [
                    "model": selectedModel.model,
                    "reasoning_effort": selectedEffort ?? selectedModel.defaultEffort,
                    "developer_instructions": NSNull(),
                ],
            ]
        }

        server.request(method: "turn/start", params: params) { [weak self] result in
            if case .failure(let error) = result {
                self?.status = .failed(error.localizedDescription)
                self?.activity = error.localizedDescription
            }
        }
    }

    func choose(questionID: String, answer: String) {
        selectedAnswers[questionID] = answer
        triggerFeedback(.choiceChanged)
        submitAnswersIfComplete()
    }

    func submitCustomAnswer(questionID: String, text: String) {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        selectedAnswers[questionID] = answer
        triggerFeedback(.choiceChanged)
        submitAnswersIfComplete()
    }

    func answerApproval(_ decision: String) {
        guard let interaction = pendingInteraction else { return }
        let result: [String: Any]
        switch interaction.responseStyle {
        case .standardApproval:
            result = ["decision": decision]
        case .legacyApproval:
            let legacyDecision: Any
            switch decision {
            case "accept": legacyDecision = "approved"
            case "acceptForSession": legacyDecision = "approved_for_session"
            default: legacyDecision = ["denied": ["rejection": "User declined in Codex Notch"]]
            }
            result = ["decision": legacyDecision]
        case .permissions(let requested):
            result = [
                "permissions": decision == "decline" ? [:] : requested,
                "scope": decision == "acceptForSession" ? "session" : "turn",
            ]
        case .elicitation:
            result = ["action": decision == "decline" ? "decline" : "accept"]
        case .questions:
            return
        }
        server.respond(id: interaction.requestID, result: result)
        triggerFeedback(decision == "decline" ? .denied : .approved)
        pendingInteraction = nil
        status = .working
        activity = decision == "decline" ? "Continuing without that action" : "Approval sent"
        scheduleFeedbackCollapse()
    }

    func newThread() {
        guard workspaceMode == .codex else { return }
        guard turnID == nil else { return }
        UserDefaults.standard.removeObject(forKey: persistedThreadKey)
        threadID = nil
        entries.removeAll()
        pendingInteraction = nil
        selectedAnswers.removeAll()
        status = .connecting
        activity = "Opening a fresh Codex thread"
        startNewThread()
    }

    func selectModel(_ modelID: String) {
        guard let model = availableModels.first(where: { $0.id == modelID }) else { return }
        selectedModelID = model.id
        let savedEffort = UserDefaults.standard.string(forKey: persistedEffortKey)
        if let savedEffort, model.supportedEfforts.contains(where: { $0.value == savedEffort }) {
            selectedEffort = savedEffort
        } else {
            selectedEffort = model.defaultEffort
        }
        UserDefaults.standard.set(model.id, forKey: persistedModelKey)
        UserDefaults.standard.set(selectedEffort, forKey: persistedEffortKey)
        if turnID == nil {
            activity = modelSelectionSummary
        }
        triggerFeedback(.choiceChanged)
    }

    func selectEffort(_ effort: String) {
        guard let selectedModel,
              selectedModel.supportedEfforts.contains(where: { $0.value == effort }) else { return }
        selectedEffort = effort
        UserDefaults.standard.set(effort, forKey: persistedEffortKey)
        if turnID == nil {
            activity = modelSelectionSummary
        }
        triggerFeedback(.choiceChanged)
    }

    private func runTerminalInput(_ text: String) {
        if terminalBusy {
            entries.append(ChatEntry(role: .terminalCommand, text: text))
            terminal.sendInput(text + "\n")
            return
        }

        if text == "clear" {
            entries.removeAll()
            status = .terminal
            activity = "~  ·  ready"
            return
        }
        if text == "exit" {
            collapse()
            return
        }

        let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.first?.lowercased() == "codex" else {
            entries.append(ChatEntry(role: .terminalCommand, text: text))
            terminal.run(text)
            return
        }

        let initialPrompt = parts.count > 1 ? String(parts[1]) : nil
        enterCodex(initialPrompt: initialPrompt)
    }

    private func enterCodex(initialPrompt: String?) {
        workspaceMode = .codex
        status = .connecting
        activity = "Starting Codex"
        entries.append(ChatEntry(role: .system, text: "Entering Codex. Type /exit to return to the terminal."))
        queuedPrompt = initialPrompt

        if serverStarted {
            if threadID != nil {
                status = .ready
                activity = "Ask Codex anything"
                if let initialPrompt {
                    queuedPrompt = nil
                    sendPrompt(initialPrompt)
                }
            } else if didInitialize {
                restoreOrCreateThread()
            }
            return
        }

        do {
            try server.start()
            serverStarted = true
            initialize()
        } catch {
            status = .failed(error.localizedDescription)
            activity = error.localizedDescription
            isExpanded = true
        }
    }

    private func initialize() {
        server.request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex_notch",
                    "title": "Codex Notch",
                    "version": "0.1.0",
                ],
                "capabilities": ["experimentalApi": true],
            ]
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.didInitialize = true
                self.server.notify(method: "initialized")
                self.loadModels()
                self.restoreOrCreateThread()
            case .failure(let error):
                self.status = .failed(error.localizedDescription)
                self.activity = error.localizedDescription
                self.isExpanded = true
            }
        }
    }

    private func loadModels() {
        server.request(
            method: "model/list",
            params: ["includeHidden": false, "limit": 100]
        ) { [weak self] result in
            guard let self, case .success(let payload) = result,
                  let rawModels = payload["data"] as? [[String: Any]] else { return }

            let models = rawModels.compactMap { raw -> CodexModelOption? in
                guard let id = raw["id"] as? String,
                      let model = raw["model"] as? String,
                      let displayName = raw["displayName"] as? String,
                      let defaultEffort = raw["defaultReasoningEffort"] as? String else { return nil }

                let efforts = (raw["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap {
                    effort -> CodexEffortOption? in
                    guard let value = effort["reasoningEffort"] as? String else { return nil }
                    return CodexEffortOption(
                        value: value,
                        description: effort["description"] as? String ?? ""
                    )
                }

                return CodexModelOption(
                    id: id,
                    model: model,
                    displayName: displayName,
                    description: raw["description"] as? String ?? "",
                    defaultEffort: defaultEffort,
                    supportedEfforts: efforts,
                    isDefault: raw["isDefault"] as? Bool ?? false
                )
            }
            guard !models.isEmpty else { return }
            availableModels = models

            let savedModel = UserDefaults.standard.string(forKey: persistedModelKey)
            let initial = models.first(where: { $0.id == savedModel })
                ?? models.first(where: \.isDefault)
                ?? models[0]
            selectedModelID = initial.id

            let savedEffort = UserDefaults.standard.string(forKey: persistedEffortKey)
            if let savedEffort, initial.supportedEfforts.contains(where: { $0.value == savedEffort }) {
                selectedEffort = savedEffort
            } else {
                selectedEffort = initial.defaultEffort
            }
        }
    }

    private func restoreOrCreateThread() {
        if let saved = UserDefaults.standard.string(forKey: persistedThreadKey), !saved.isEmpty {
            server.request(method: "thread/resume", params: ["threadId": saved]) { [weak self] result in
                switch result {
                case .success(let payload): self?.acceptThread(from: payload, fallback: saved)
                case .failure: self?.startNewThread()
                }
            }
        } else {
            startNewThread()
        }
    }

    private func startNewThread() {
        guard didInitialize else { return }
        server.request(
            method: "thread/start",
            params: ["cwd": FileManager.default.homeDirectoryForCurrentUser.path]
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let payload): self.acceptThread(from: payload, fallback: nil)
            case .failure(let error):
                self.status = .failed(error.localizedDescription)
                self.activity = error.localizedDescription
                self.isExpanded = true
            }
        }
    }

    private func acceptThread(from payload: [String: Any], fallback: String?) {
        let thread = payload["thread"] as? [String: Any]
        guard let id = thread?["id"] as? String ?? fallback else {
            status = .failed("Codex did not return a thread identifier.")
            return
        }
        threadID = id
        UserDefaults.standard.set(id, forKey: persistedThreadKey)
        status = .ready
        activity = "Ask Codex anything"
        if let queuedPrompt {
            self.queuedPrompt = nil
            sendPrompt(queuedPrompt)
        }
    }

    private func handle(_ message: [String: Any]) {
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]

        if message["id"] != nil {
            handleServerRequest(id: message["id"]!, method: method, params: params)
            return
        }

        switch method {
        case "turn/started":
            let turn = params["turn"] as? [String: Any]
            turnID = turn?["id"] as? String
            isStoppingTurn = false
            status = .working
            activity = "Codex is thinking"

        case "item/started":
            if let item = params["item"] as? [String: Any],
               let detail = ProtocolParser.statusDetail(from: item) {
                activity = detail
            }

        case "item/agentMessage/delta":
            guard let delta = params["delta"] as? String else { return }
            let itemID = params["itemId"] as? String
            appendAssistant(delta: delta, itemID: itemID)
            activity = "Writing the response"

        case "turn/plan/updated":
            activity = "Updating the plan"

        case "turn/diff/updated":
            activity = "Preparing file changes"

        case "thread/tokenUsage/updated":
            guard let tokenUsage = params["tokenUsage"] as? [String: Any],
                  let last = tokenUsage["last"] as? [String: Any] else { return }
            contextUsedTokens = (last["inputTokens"] as? NSNumber)?.int64Value ?? contextUsedTokens
            if let window = tokenUsage["modelContextWindow"] as? NSNumber {
                contextWindowTokens = window.int64Value
            }

        case "thread/settings/updated":
            if let settings = params["threadSettings"] as? [String: Any],
               let collaboration = settings["collaborationMode"] as? [String: Any],
               let mode = collaboration["mode"] as? String {
                collaborationMode = mode
                UserDefaults.standard.set(mode, forKey: persistedModeKey)
            }

        case "turn/completed":
            let wasStopping = isStoppingTurn
            isStoppingTurn = false
            turnID = nil
            pendingInteraction = nil
            selectedAnswers.removeAll()
            let turn = params["turn"] as? [String: Any]
            let turnStatus = turn?["status"] as? String ?? "completed"
            if turnStatus == "completed" {
                status = .done
                activity = "Turn complete"
            } else if turnStatus == "interrupted" {
                status = .ready
                activity = queuedMessages.isEmpty ? "Stopped" : "Stopped · \(queuedMessages.count) queued"
            } else {
                status = .failed("Turn ended: \(turnStatus)")
                activity = "Turn ended: \(turnStatus)"
            }
            isExpanded = isPinned
            if !wasStopping, turnStatus == "completed", !queuedMessages.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    self?.runNextQueuedMessage()
                }
            }

        case "error":
            let error = params["error"] as? [String: Any]
            let message = error?["message"] as? String ?? params["message"] as? String ?? "Unknown Codex error"
            status = .failed(message)
            activity = message
            isExpanded = true

        default:
            break
        }
    }

    private func handleServerRequest(id: Any, method: String, params: [String: Any]) {
        switch method {
        case "item/tool/requestUserInput":
            let questions = ProtocolParser.questions(from: params)
            pendingInteraction = PendingInteraction(
                requestID: id,
                method: method,
                kind: .questions(questions),
                responseStyle: .questions
            )
            selectedAnswers.removeAll()
            status = .needsInput
            activity = questions.first?.prompt ?? "Codex has a question"
            isExpanded = true

        case "item/commandExecution/requestApproval":
            let command = params["command"] as? String ?? "Run the requested command"
            let reason = params["reason"] as? String
            pendingInteraction = PendingInteraction(
                requestID: id,
                method: method,
                kind: .approval(title: "Allow this command?", detail: reason ?? command, allowsSessionApproval: true),
                responseStyle: .standardApproval
            )
            status = .needsInput
            activity = "Command approval needed"
            isExpanded = true

        case "item/fileChange/requestApproval":
            pendingInteraction = PendingInteraction(
                requestID: id,
                method: method,
                kind: .approval(title: "Apply these file changes?", detail: "Codex is ready to edit files in this workspace.", allowsSessionApproval: false),
                responseStyle: .standardApproval
            )
            status = .needsInput
            activity = "File-change approval needed"
            isExpanded = true

        case "execCommandApproval":
            let command = (params["command"] as? [String])?.joined(separator: " ")
                ?? params["command"] as? String
                ?? "Run the requested command"
            let detail = params["reason"] as? String ?? command
            pendingInteraction = PendingInteraction(
                requestID: id,
                method: method,
                kind: .approval(title: "Allow this command?", detail: detail, allowsSessionApproval: true),
                responseStyle: .legacyApproval
            )
            presentInteraction("Command approval needed")

        case "applyPatchApproval":
            let files = (params["fileChanges"] as? [String: Any])?.keys.sorted().joined(separator: "\n")
            pendingInteraction = PendingInteraction(
                requestID: id,
                method: method,
                kind: .approval(
                    title: "Apply these file changes?",
                    detail: params["reason"] as? String ?? files ?? "Codex is ready to edit files.",
                    allowsSessionApproval: params["grantRoot"] != nil
                ),
                responseStyle: .legacyApproval
            )
            presentInteraction("File-change approval needed")

        case "item/permissions/requestApproval":
            let permissions = params["permissions"] as? [String: Any] ?? [:]
            let reason = params["reason"] as? String
            let cwd = params["cwd"] as? String
            pendingInteraction = PendingInteraction(
                requestID: id,
                method: method,
                kind: .approval(
                    title: "Grant extra access?",
                    detail: reason ?? cwd.map { "Codex is requesting access from \($0)." } ?? "Codex is requesting additional permissions.",
                    allowsSessionApproval: true
                ),
                responseStyle: .permissions(requested: permissions)
            )
            presentInteraction("Permission approval needed")

        case "mcpServer/elicitation/request":
            let serverName = params["serverName"] as? String ?? "Connected tool"
            let message = params["message"] as? String ?? "A connected tool needs your confirmation."
            pendingInteraction = PendingInteraction(
                requestID: id,
                method: method,
                kind: .approval(title: "\(serverName) is asking", detail: message, allowsSessionApproval: false),
                responseStyle: .elicitation
            )
            presentInteraction("Connected tool needs input")

        default:
            pendingInteraction = PendingInteraction(
                requestID: id,
                method: method,
                kind: .approval(
                    title: "Codex needs confirmation",
                    detail: "Request: \(method)\nThis request type is newer than Codex Notch. Accept only if you recognize it.",
                    allowsSessionApproval: false
                ),
                responseStyle: .standardApproval
            )
            presentInteraction("Confirmation needed")
        }
    }

    private func presentInteraction(_ message: String) {
        status = .needsInput
        activity = message
        isExpanded = true
    }

    private func submitAnswersIfComplete() {
        guard let interaction = pendingInteraction,
              case .questions(let questions) = interaction.kind,
              questions.allSatisfy({ selectedAnswers[$0.id] != nil }) else { return }

        let answers = Dictionary(uniqueKeysWithValues: questions.compactMap { question -> (String, Any)? in
            guard let answer = selectedAnswers[question.id] else { return nil }
            return (question.id, ["answers": [answer]])
        })
        server.respond(id: interaction.requestID, result: ["answers": answers])
        pendingInteraction = nil
        selectedAnswers.removeAll()
        status = .working
        activity = "Answer sent"
        scheduleFeedbackCollapse()
    }

    private func appendAssistant(delta: String, itemID: String?) {
        if let itemID,
           let index = entries.lastIndex(where: { $0.role == .assistant && $0.itemID == itemID }) {
            entries[index].text += delta
        } else {
            entries.append(ChatEntry(role: .assistant, text: delta, itemID: itemID))
        }
    }

    private func triggerFeedback(_ feedback: ActionFeedback) {
        feedbackNonce += 1
        let nonce = feedbackNonce
        actionFeedback = feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard self?.feedbackNonce == nonce else { return }
            self?.actionFeedback = nil
        }
    }

    private func scheduleFeedbackCollapse() {
        let nonce = feedbackNonce
        isExpanded = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.82) { [weak self] in
            guard let self, self.feedbackNonce == nonce, !self.needsAttention else { return }
            self.isExpanded = self.isPinned
        }
    }
}
