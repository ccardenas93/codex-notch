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

    private let server = CodexServer()
    private let terminal = TerminalSession()
    private var threadID: String?
    private var turnID: String?
    private var queuedPrompt: String?
    private var didInitialize = false
    private var serverStarted = false
    private var hoverGeneration = 0
    private var pointerInside = false
    private let persistedThreadKey = "CodexNotch.threadID"

    var needsAttention: Bool { pendingInteraction != nil }
    var canSend: Bool {
        let hasText = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch workspaceMode {
        case .terminal: return hasText
        case .codex: return hasText && threadID != nil
        }
    }

    var composerPlaceholder: String {
        workspaceMode == .terminal ? "Run a command…  (type codex to enter)" : "Tell Codex what to do…"
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
        isPinned = false
        isExpanded = false
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
        if let activeTurnID = turnID {
            entries.append(ChatEntry(role: .user, text: text))
            activity = "Steering the active turn"
            server.request(
                method: "turn/steer",
                params: [
                    "threadId": threadID,
                    "expectedTurnId": activeTurnID,
                    "input": [["type": "text", "text": text]],
                ]
            ) { [weak self] result in
                if case .failure(let error) = result {
                    self?.status = .failed(error.localizedDescription)
                    self?.activity = error.localizedDescription
                }
            }
            return
        }

        entries.append(ChatEntry(role: .user, text: text))
        status = .working
        activity = "Understanding your request"
        pendingInteraction = nil
        selectedAnswers = [:]

        server.request(
            method: "turn/start",
            params: [
                "threadId": threadID,
                "input": [["type": "text", "text": text]],
                "cwd": FileManager.default.homeDirectoryForCurrentUser.path,
            ]
        ) { [weak self] result in
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
        server.respond(id: interaction.requestID, result: ["decision": decision])
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
                self.restoreOrCreateThread()
            case .failure(let error):
                self.status = .failed(error.localizedDescription)
                self.activity = error.localizedDescription
                self.isExpanded = true
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

        case "turn/completed":
            turnID = nil
            pendingInteraction = nil
            selectedAnswers.removeAll()
            let turn = params["turn"] as? [String: Any]
            let turnStatus = turn?["status"] as? String ?? "completed"
            if turnStatus == "completed" {
                status = .done
                activity = "Turn complete"
            } else {
                status = .failed("Turn ended: \(turnStatus)")
                activity = "Turn ended: \(turnStatus)"
            }
            isExpanded = isPinned

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
            pendingInteraction = PendingInteraction(requestID: id, method: method, kind: .questions(questions))
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
                kind: .approval(title: "Allow this command?", detail: reason ?? command, allowsSessionApproval: true)
            )
            status = .needsInput
            activity = "Command approval needed"
            isExpanded = true

        case "item/fileChange/requestApproval":
            pendingInteraction = PendingInteraction(
                requestID: id,
                method: method,
                kind: .approval(title: "Apply these file changes?", detail: "Codex is ready to edit files in this workspace.", allowsSessionApproval: false)
            )
            status = .needsInput
            activity = "File-change approval needed"
            isExpanded = true

        default:
            server.respond(id: id, result: [:])
        }
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
