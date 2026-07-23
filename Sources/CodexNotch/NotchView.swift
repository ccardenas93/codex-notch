import AppKit
import SwiftUI

struct NotchView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shakeCount: CGFloat = 0
    @State private var showBrainDeck = false

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
            NotificationCenter.default.post(
                name: .codexNotchExpansionChanged,
                object: model,
                userInfo: ["expanded": expanded]
            )
        }
        .onChange(of: model.feedbackNonce) { _, _ in
            guard model.actionFeedback == .denied, !reduceMotion else { return }
            withAnimation(.linear(duration: 0.42)) { shakeCount += 4 }
        }
        .onChange(of: model.workspaceMode) { _, mode in
            if mode == .terminal { showBrainDeck = false }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88), value: model.isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex Notch")
        .contextMenu {
            if model.workspaceMode == .codex {
                Button("Return to terminal", action: model.returnToTerminal)
                Button("New Codex thread", action: model.newThread)
            }
            if model.canCloseNotch {
                Button("Close this notch", role: .destructive, action: model.requestCloseNotch)
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
            if model.workspaceMode == .codex {
                CodexControlStrip(model: model)
            }
            if model.workspaceMode == .codex, !model.queuedMessages.isEmpty {
                MessageQueueStrip(model: model)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if model.workspaceMode == .codex, showBrainDeck {
                BrainDeck(model: model)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            transcript
            if model.showCloseConfirmation {
                CloseNotchCard(
                    cancel: model.cancelCloseNotch,
                    close: model.confirmCloseNotch
                )
            } else if let interaction = model.pendingInteraction {
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
                HeaderButton(
                    icon: "brain.head.profile",
                    label: "Choose model and effort",
                    isActive: showBrainDeck
                ) {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
                        showBrainDeck.toggle()
                    }
                }
                HeaderButton(icon: "terminal", label: "Return to terminal", action: model.returnToTerminal)
            } else if model.terminalBusy {
                HeaderButton(icon: "stop.fill", label: "Interrupt command", action: model.interruptTerminal)
            }
            HeaderButton(
                icon: model.canAddNotch ? "plus" : "6.circle.fill",
                label: model.canAddNotch
                    ? "Add notch (\(model.notchCount)/6)"
                    : "Maximum of six notches",
                isDisabled: !model.canAddNotch,
                action: model.addNotch
            )
            HeaderButton(icon: "minus", label: "Collapse", action: model.collapse)
            HeaderButton(
                icon: model.isPinned ? "pin.fill" : "pin",
                label: model.isPinned ? "Unpin" : "Keep open",
                action: model.togglePinned
            )
            if model.canCloseNotch {
                HeaderButton(
                    icon: "xmark",
                    label: "Close this notch",
                    action: model.requestCloseNotch
                )
            }
        }
    }

    private var transcript: some View {
        Group {
            if model.entries.isEmpty {
                ScrollView {
                    EmptyTranscript(mode: model.workspaceMode)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            } else {
                SelectableTranscript(entries: model.entries)
            }
        }
        .frame(maxHeight: model.pendingInteraction == nil ? .infinity : 170)
    }

private struct SelectableTranscript: NSViewRepresentable {
    let entries: [ChatEntry]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 5)
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.allowsUndo = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Terminal and Codex transcript")
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let previousLength = textView.string.utf16.count
        let selection = textView.selectedRange()
        let shouldPreserveSelection = selection.length > 0
        let rendered = Self.render(entries)

        guard textView.textStorage?.isEqual(to: rendered) != true else { return }
        textView.textStorage?.setAttributedString(rendered)

        if shouldPreserveSelection, NSMaxRange(selection) <= rendered.length {
            textView.setSelectedRange(selection)
        } else if rendered.length > previousLength {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private static func render(_ entries: [ChatEntry]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 8
        paragraph.lineBreakMode = .byWordWrapping

        for entry in entries {
            let label = label(for: entry.role)
            let labelColor: NSColor = entry.role == .user || entry.role == .terminalCommand
                ? NSColor.systemCyan.withAlphaComponent(0.82)
                : NSColor.white.withAlphaComponent(0.34)
            result.append(NSAttributedString(
                string: "\(label)  ",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: labelColor,
                    .paragraphStyle: paragraph,
                ]
            ))

            let opacity: CGFloat
            switch entry.role {
            case .terminalOutput: opacity = 0.64
            case .user: opacity = 0.74
            default: opacity = 0.9
            }
            result.append(NSAttributedString(
                string: entry.text + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
                    .foregroundColor: NSColor.white.withAlphaComponent(opacity),
                    .paragraphStyle: paragraph,
                ]
            ))
        }
        return result
    }

    private static func label(for role: ChatEntry.Role) -> String {
        switch role {
        case .user: return "YOU"
        case .assistant: return "CX"
        case .system: return "•"
        case .terminalCommand: return "$"
        case .terminalOutput: return "›"
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
                Image(systemName: model.hasActiveCodexTurn ? "text.badge.plus" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(model.canSend ? .black : .white.opacity(0.28))
                    .background(model.canSend ? Color.white : Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(model.hasActiveCodexTurn ? "Queue for Codex" : "Send to Codex")
        }
    }
}

private struct CodexControlStrip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 7) {
            Button {
                model.setCollaborationMode(model.collaborationMode == "plan" ? "default" : "plan")
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.collaborationMode == "plan" ? "map.fill" : "hammer.fill")
                        .font(.system(size: 8.5, weight: .bold))
                    Text(model.collaborationMode == "plan" ? "PLAN" : "BUILD")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.7)
                }
                .foregroundStyle(model.collaborationMode == "plan" ? Color.purple : Color.cyan)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(.white.opacity(0.045), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(
                            (model.collaborationMode == "plan" ? Color.purple : Color.cyan).opacity(0.25),
                            lineWidth: 1
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(model.hasActiveCodexTurn)
            .opacity(model.hasActiveCodexTurn ? 0.48 : 1)
            .help(model.hasActiveCodexTurn ? "Mode is locked during an active turn" : "Switch Build / Plan mode")

            ContextMeter(
                label: model.contextLabel,
                fraction: model.contextRemainingFraction
            )

            HStack(spacing: 4) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: 8))
                Text("Q \(model.queuedMessages.count)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(model.queuedMessages.isEmpty ? .white.opacity(0.28) : .yellow.opacity(0.8))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(.white.opacity(0.035), in: Capsule())

            Spacer()

            Text(model.modelSelectionSummary.uppercased())
                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.28))
                .lineLimit(1)

            if model.hasActiveCodexTurn {
                Button(action: model.interruptCodexTurn) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 7.5))
                        Text(model.isStoppingTurn ? "STOPPING" : "STOP")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Color.red.opacity(0.1), in: Capsule())
                    .overlay { Capsule().stroke(Color.red.opacity(0.28), lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .disabled(model.isStoppingTurn)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop the active Codex turn")
            }
        }
        .frame(height: 28)
    }
}

private struct ContextMeter: View {
    let label: String
    let fraction: Double?

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: fraction ?? 0)
                    .stroke(contextColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(.white.opacity(0.035), in: Capsule())
        .help("Estimated model context remaining")
    }

    private var contextColor: Color {
        guard let fraction else { return .white.opacity(0.2) }
        if fraction < 0.15 { return .red }
        if fraction < 0.35 { return .yellow }
        return .cyan
    }
}

private struct MessageQueueStrip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text("QUEUE")
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.yellow.opacity(0.62))

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(model.queuedMessages.enumerated()), id: \.element.id) { index, message in
                        HStack(spacing: 5) {
                            Text("\(index + 1)")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundStyle(.yellow.opacity(0.6))
                            Text(message.text)
                                .font(.system(size: 9.5, design: .rounded))
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)
                                .frame(maxWidth: 150)
                            Button {
                                model.removeQueuedMessage(message.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(.white.opacity(0.04), in: Capsule())
                    }
                }
            }
            .scrollIndicators(.hidden)

            if !model.hasActiveCodexTurn {
                Button(action: model.runNextQueuedMessage) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                        .frame(width: 24, height: 24)
                        .background(Color.green.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Run next queued message")
            }

            Button(action: model.clearQueuedMessages) {
                Image(systemName: "trash")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.28))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Clear queue")
        }
        .frame(height: 26)
    }
}

private struct CloseNotchCard: View {
    let cancel: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 20))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 3) {
                Text("Stop this workspace?")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Its running command or Codex turn will be terminated. Other notches stay open.")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            ActionButton(title: "Keep it", tint: .white, action: cancel)
            ActionButton(title: "Stop & close", tint: .red, action: close)
        }
        .padding(12)
        .background(Color.red.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.red.opacity(0.28), lineWidth: 1)
        }
    }
}

private struct BrainDeck: View {
    @ObservedObject var model: AppModel
    @State private var hoveredModelID: String?

    var body: some View {
        VStack(spacing: 10) {
            if let selected = model.selectedModel {
                HStack(spacing: 10) {
                    BrainOrb(effort: model.selectedEffort ?? selected.defaultEffort)
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BRAIN DECK")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(1.3)
                            .foregroundStyle(.cyan.opacity(0.72))
                        Text(model.modelSelectionSummary)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Text("APPLIES NEXT TURN")
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.28))
                }

                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(model.availableModels) { option in
                            ModelChip(
                                option: option,
                                selected: option.id == model.selectedModelID,
                                onHover: { inside in
                                    hoveredModelID = inside ? option.id : nil
                                },
                                action: { model.selectModel(option.id) }
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)

                if let describedModel = model.availableModels.first(where: { $0.id == hoveredModelID })
                    ?? model.selectedModel {
                    HStack(spacing: 7) {
                        Image(systemName: hoveredModelID == nil ? "info.circle" : "quote.bubble")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.cyan.opacity(0.62))
                        MarqueeDescription(text: describedModel.description)
                            .id(describedModel.id)
                    }
                    .frame(height: 18)
                    .transition(.opacity)
                }

                HStack(spacing: 6) {
                    Text("FAST")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.25))
                    ForEach(selected.supportedEfforts) { effort in
                        EffortChip(
                            effort: effort,
                            selected: effort.value == model.selectedEffort,
                            action: { model.selectEffort(effort.value) }
                        )
                    }
                    Text("DEEP")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.25))
                }
            } else {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.cyan)
                    Text("Discovering the brains available to this Codex account…")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.52))
                    Spacer()
                }
            }
        }
        .padding(11)
        .background(
            LinearGradient(
                colors: [Color.cyan.opacity(0.09), Color.purple.opacity(0.055)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.cyan.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct ModelChip: View {
    let option: CodexModelOption
    let selected: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(option.displayName)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    if option.isDefault {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 4, height: 4)
                    }
                }
                Text(option.model)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(width: 126, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                selected ? Color.cyan.opacity(0.16) : Color.white.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Color.cyan.opacity(0.55) : Color.white.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(option.description)
        .onHover(perform: onHover)
    }
}

private struct MarqueeDescription: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if reduceMotion {
                ScrollView(.horizontal) {
                    descriptionText
                }
                .scrollIndicators(.hidden)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let font = NSFont.systemFont(ofSize: 9.5, weight: .regular)
                    let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
                    let overflow = max(0, textWidth - geometry.size.width)
                    let duration = max(4.5, Double(overflow / 22) + 3.0)
                    let phase = timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: duration) / duration
                    let travel = overflow * (0.5 - 0.5 * cos(phase * .pi * 2))

                    descriptionText
                        .offset(x: -travel)
                }
            }
        }
        .clipped()
        .accessibilityLabel(text)
    }

    private var descriptionText: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.48))
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct EffortChip: View {
    let effort: CodexEffortOption
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: EffortStyle.icon(for: effort.value))
                    .font(.system(size: 9, weight: .semibold))
                Text(EffortStyle.name(for: effort.value))
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                Text(effort.value.uppercased())
                    .font(.system(size: 6.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.34))
            }
            .foregroundStyle(selected ? EffortStyle.color(for: effort.value) : .white.opacity(0.6))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                selected ? EffortStyle.color(for: effort.value).opacity(0.14) : Color.white.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        selected ? EffortStyle.color(for: effort.value).opacity(0.5) : Color.clear,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .help(effort.description)
        .accessibilityLabel("\(effort.value) reasoning effort")
        .accessibilityHint(effort.description)
    }
}

private struct BrainOrb: View {
    let effort: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(EffortStyle.color(for: effort).opacity(0.12))
                Circle()
                    .trim(from: 0.08, to: 0.68)
                    .stroke(
                        AngularGradient(
                            colors: [.cyan, .purple, EffortStyle.color(for: effort), .cyan],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(phase * EffortStyle.velocity(for: effort)))
                    .padding(3)
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(EffortStyle.color(for: effort))
            }
        }
    }
}

private enum EffortStyle {
    static func name(for value: String) -> String {
        switch value.lowercased() {
        case "minimal", "none": return "Blink"
        case "low": return "Zip"
        case "medium": return "Flow"
        case "high": return "Deep"
        case "xhigh": return "Abyss"
        case "max": return "Orbit"
        case "ultra": return "Nova"
        default: return value.capitalized
        }
    }

    static func icon(for value: String) -> String {
        switch value.lowercased() {
        case "minimal", "none": return "bolt.fill"
        case "low": return "hare.fill"
        case "medium": return "sparkles"
        case "high": return "brain.head.profile"
        case "xhigh": return "tornado"
        case "max": return "globe.americas.fill"
        case "ultra": return "sun.max.fill"
        default: return "dial.medium"
        }
    }

    static func color(for value: String) -> Color {
        switch value.lowercased() {
        case "minimal", "none", "low": return .green
        case "medium": return .cyan
        case "high": return .blue
        case "xhigh": return .purple
        case "max", "ultra": return .pink
        default: return .white
        }
    }

    static func velocity(for value: String) -> Double {
        switch value.lowercased() {
        case "minimal", "none", "low": return 160
        case "medium": return 110
        case "high": return 78
        case "xhigh": return 52
        case "max", "ultra": return 34
        default: return 90
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
    var isActive = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(
                    isDisabled ? .white.opacity(0.2) : isActive ? Color.cyan : .white.opacity(0.54)
                )
                .frame(width: 28, height: 28)
                .background(isActive ? Color.cyan.opacity(0.14) : .white.opacity(0.055), in: Circle())
                .overlay {
                    Circle()
                        .stroke(isActive ? Color.cyan.opacity(0.35) : Color.clear, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
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
