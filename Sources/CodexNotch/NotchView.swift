import SwiftUI

struct NotchView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shakeCount: CGFloat = 0

    var body: some View {
        ZStack {
            NotchSurface(status: model.status, feedback: model.actionFeedback)

            if model.isExpanded {
                expandedContent
                    .padding(18)
                    .transition(.opacity.combined(with: .scale(scale: 0.975, anchor: .top)))
            } else {
                collapsedContent
                    .padding(.horizontal, 14)
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: model.isExpanded ? 24 : 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: model.isExpanded ? 24 : 18, style: .continuous))
        .modifier(ShakeEffect(shakes: shakeCount))
        .onChange(of: model.isExpanded) { _, expanded in
            NotificationCenter.default.post(name: .codexNotchExpansionChanged, object: expanded)
        }
        .onChange(of: model.feedbackNonce) { _, _ in
            guard model.actionFeedback == .denied, !reduceMotion else { return }
            withAnimation(.linear(duration: 0.42)) { shakeCount += 4 }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88), value: model.isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex Notch")
        .contextMenu {
            if model.workspaceMode == .codex {
                Button("Return to terminal", action: model.returnToTerminal)
                Button("New Codex thread", action: model.newThread)
            }
            Divider()
            Button("Quit Codex Notch") { NSApplication.shared.terminate(nil) }
        }
    }

    private var collapsedContent: some View {
        HStack(spacing: 10) {
            StatusGlyph(status: model.status)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.status.title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(model.activity)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            Image(systemName: model.needsAttention ? "exclamationmark" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(model.needsAttention ? Color.yellow : .white.opacity(0.34))
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 14) {
            header
            Divider().overlay(.white.opacity(0.09))
            transcript
            if let interaction = model.pendingInteraction {
                interactionView(interaction)
            }
            composer
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            StatusGlyph(status: model.status)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(model.activity)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.47))
                    .lineLimit(1)
            }
            Spacer()
            Text(model.workspaceMode == .terminal ? "ZSH" : "CODEX")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(model.workspaceMode == .terminal ? .white.opacity(0.42) : .cyan.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white.opacity(0.05), in: Capsule())
            if model.workspaceMode == .codex {
                HeaderButton(icon: "terminal", label: "Return to terminal", action: model.returnToTerminal)
                HeaderButton(icon: "plus", label: "New thread", action: model.newThread)
            } else if model.terminalBusy {
                HeaderButton(icon: "stop.fill", label: "Interrupt command", action: model.interruptTerminal)
            }
            HeaderButton(
                icon: model.isPinned ? "pin.fill" : "pin",
                label: model.isPinned ? "Unpin" : "Keep open",
                action: model.togglePinned
            )
            HeaderButton(icon: "xmark", label: "Collapse", action: model.collapse)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.entries.isEmpty {
                        EmptyTranscript(mode: model.workspaceMode)
                    } else {
                        ForEach(model.entries) { entry in
                            MessageRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: model.pendingInteraction == nil ? .infinity : 170)
            .onChange(of: model.entries) { _, entries in
                guard let last = entries.last else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func interactionView(_ interaction: PendingInteraction) -> some View {
        switch interaction.kind {
        case .questions(let questions):
            VStack(spacing: 10) {
                ForEach(questions) { question in
                    QuestionCard(question: question, model: model)
                }
            }
        case .approval(let title, let detail, let allowsSessionApproval):
            ApprovalCard(
                title: title,
                detail: detail,
                allowsSessionApproval: allowsSessionApproval,
                approve: { model.answerApproval("accept") },
                approveSession: { model.answerApproval("acceptForSession") },
                deny: { model.answerApproval("decline") }
            )
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(model.composerPlaceholder, text: $model.composerText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1...4)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.09), lineWidth: 1)
                }
                .onSubmit(model.sendComposer)

            Button(action: model.sendComposer) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(model.canSend ? .black : .white.opacity(0.28))
                    .background(model.canSend ? Color.white : Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send to Codex")
        }
    }
}

private struct NotchSurface: View {
    let status: NotchStatus
    let feedback: ActionFeedback?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.025, green: 0.026, blue: 0.031).opacity(0.985))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.055), .clear],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: 380
                            )
                        )
                }
                .overlay {
                    border(phase: phase)
                }
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(.white.opacity(0.1))
                        .frame(width: 80, height: 1)
                        .padding(.top, 1)
                }
        }
    }

    @ViewBuilder
    private func border(phase: TimeInterval) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        if feedback == .denied {
            shape.stroke(Color.red.opacity(0.95), lineWidth: 2.4)
        } else if feedback == .approved {
            shape.stroke(Color.green.opacity(0.95), lineWidth: 2.4)
        } else if feedback == .choiceChanged {
            shape.stroke(Color.cyan.opacity(0.95), lineWidth: 2.2)
        } else if status == .working {
            shape.stroke(
                AngularGradient(
                    colors: [.pink, .orange, .yellow, .green, .cyan, .blue, .purple, .pink],
                    center: .center,
                    angle: .degrees(phase * 42)
                ),
                lineWidth: 2
            )
        } else if status == .needsInput {
            shape.stroke(Color.yellow.opacity(0.42 + 0.5 * abs(sin(phase * 4.2))), lineWidth: 2.2)
        } else if status == .done {
            shape.stroke(Color.green.opacity(0.52), lineWidth: 1.5)
        } else {
            shape.stroke(Color.white.opacity(0.1), lineWidth: 1)
        }
    }
}

private struct StatusGlyph: View {
    let status: NotchStatus

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().fill(baseColor.opacity(0.12))
                if status == .working || status == .connecting || status == .terminalRunning {
                    Circle()
                        .trim(from: 0.12, to: 0.72)
                        .stroke(
                            status == .working
                                ? AnyShapeStyle(AngularGradient(colors: [.pink, .yellow, .green, .cyan, .purple, .pink], center: .center))
                                : AnyShapeStyle(Color.white.opacity(0.8)),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(phase * 150))
                        .padding(4)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(baseColor)
                }
            }
        }
    }

    private var baseColor: Color {
        switch status {
        case .terminal, .terminalRunning: return .white
        case .needsInput: return .yellow
        case .done: return .green
        case .failed: return .red
        default: return .white
        }
    }

    private var icon: String {
        switch status {
        case .terminal: return "terminal"
        case .terminalRunning: return "ellipsis"
        case .ready: return "sparkle"
        case .needsInput: return "questionmark"
        case .done: return "checkmark"
        case .failed: return "exclamationmark"
        default: return "circle.fill"
        }
    }
}

private struct EmptyTranscript: View {
    let mode: WorkspaceMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode == .terminal ? "YOUR ALWAYS-ON TERMINAL" : "YOUR ALWAYS-ON CODEX")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.35))
            Text(mode == .terminal ? "Ready when you are." : "What should we build?")
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(
                mode == .terminal
                    ? "Run normal zsh commands here. Type “codex” when you want to enter the Codex workspace."
                    : "Write a task below. The notch will stay out of the way and expand whenever Codex needs you."
            )
                .font(.system(size: 12.5, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 18)
    }
}

private struct MessageRow: View {
    let entry: ChatEntry

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(labelColor)
                .frame(width: 24, alignment: .leading)
                .padding(.top, 3)
            Text(entry.text)
                .font(.system(size: 12.5, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(entry.role == .terminalOutput ? 0.64 : entry.role == .user ? 0.74 : 0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var label: String {
        switch entry.role {
        case .user: return "YOU"
        case .assistant: return "CX"
        case .system: return "•"
        case .terminalCommand: return "$"
        case .terminalOutput: return "›"
        }
    }

    private var labelColor: Color {
        switch entry.role {
        case .user, .terminalCommand: return .cyan.opacity(0.8)
        default: return .white.opacity(0.35)
        }
    }
}

private struct QuestionCard: View {
    let question: CodexQuestion
    @ObservedObject var model: AppModel
    @State private var customText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.header.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(.yellow.opacity(0.75))
            Text(question.prompt)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            ForEach(question.choices) { choice in
                let selected = model.selectedAnswers[question.id] == choice.label
                Button {
                    model.choose(questionID: question.id, answer: choice.label)
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(selected ? Color.cyan : .white.opacity(0.12))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.label)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            if !choice.detail.isEmpty {
                                Text(choice.detail)
                                    .font(.system(size: 10.5, weight: .regular, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                        }
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(selected ? Color.cyan.opacity(0.11) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if question.acceptsCustomAnswer {
                HStack(spacing: 8) {
                    TextField("Tell Codex differently…", text: $customText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .rounded))
                        .onSubmit { model.submitCustomAnswer(questionID: question.id, text: customText) }
                    Button("Send") {
                        model.submitCustomAnswer(questionID: question.id, text: customText)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white, in: Capsule())
                    .disabled(customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(9)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
        }
        .padding(13)
        .background(Color.yellow.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.yellow.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct ApprovalCard: View {
    let title: String
    let detail: String
    let allowsSessionApproval: Bool
    let approve: () -> Void
    let approveSession: () -> Void
    let deny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("APPROVAL")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(.yellow.opacity(0.75))
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(4)

            HStack(spacing: 8) {
                ActionButton(title: "Approve", tint: .green, action: approve)
                if allowsSessionApproval {
                    ActionButton(title: "Always this session", tint: .white, action: approveSession)
                }
                ActionButton(title: "Deny", tint: .red, action: deny)
            }
        }
        .padding(13)
        .background(Color.yellow.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.yellow.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct ActionButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(tint == .white ? .black : .white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(tint == .white ? tint : tint.opacity(0.22), in: Capsule())
                .overlay { Capsule().stroke(tint.opacity(0.45), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

private struct HeaderButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.54))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.055), in: Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(shakes * .pi * 2), y: 0))
    }
}
