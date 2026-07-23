import AppKit
import QuartzCore
import SwiftUI

final class FloatingNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchTrackingHostingView: NSHostingView<NotchView> {
    var onHoverChange: ((Bool) -> Void)?
    var onCollapsedClick: (() -> Void)?
    var isExpanded: (() -> Bool)?
    private var pointerTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if isExpanded?() == false {
            onCollapsedClick?()
            return
        }
        super.mouseDown(with: event)
    }
}

@MainActor
final class NotchPanelController: NSObject, NSWindowDelegate {
    private let panel: FloatingNotchPanel
    private let hostingView: NotchTrackingHostingView
    private let model: AppModel
    private let collapsedSize = NSSize(width: 260, height: 44)
    private let expandedSize = NSSize(width: 620, height: 520)

    init(model: AppModel) {
        self.model = model
        hostingView = NotchTrackingHostingView(rootView: NotchView(model: model))
        panel = FloatingNotchPanel(
            contentRect: NSRect(origin: .zero, size: collapsedSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        hostingView.onHoverChange = { [weak model] inside in
            model?.setHovered(inside)
        }
        hostingView.isExpanded = { [weak model] in model?.isExpanded ?? false }
        hostingView.onCollapsedClick = { [weak model] in model?.togglePinned() }
        panel.contentView = hostingView
        position(size: collapsedSize, animated: false)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: .codexNotchExpansionChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let expanded = notification.object as? Bool else { return }
            MainActor.assumeIsolated { self?.setExpanded(expanded) }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position(size: self.panel.frame.size, animated: false)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.minimizeForFocusLoss() }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        model.minimizeForFocusLoss()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.panelDidBecomeKey()
    }

    func setExpanded(_ expanded: Bool) {
        let size = expanded ? expandedSize : collapsedSize
        position(size: size, animated: true)
        panel.orderFrontRegardless()
    }

    private func position(size: NSSize, animated: Bool) {
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let top = screen.visibleFrame.maxY - 7
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: top - size.height
        )
        let frame = NSRect(origin: origin, size: size)
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
    }
}

extension Notification.Name {
    static let codexNotchExpansionChanged = Notification.Name("codexNotchExpansionChanged")
}
