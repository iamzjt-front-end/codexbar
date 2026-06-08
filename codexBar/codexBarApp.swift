import AppKit
import Combine
import QuartzCore
import SwiftUI

@main
struct codexBarApp: App {
    @StateObject private var store = TokenStore.shared
    @StateObject private var oauth = OAuthManager.shared
    @StateObject private var language = LanguageSettings.shared
    @StateObject private var refreshFrequency = RefreshFrequencySettings.shared
    @StateObject private var codexSessionStatus = CodexSessionStatusService.shared
    @StateObject private var codexHookInstaller = CodexHookInstallerService.shared

    init() {
        // App 级后台续期，脱离菜单 View 生命周期（菜单关闭时 View 不存在，其内 Timer 不跑）
        BackgroundRefresher.shared.start(interval: RefreshFrequencySettings.shared.selection.backgroundInterval)
        CodexSessionStatusService.shared.start()
        CodexHookInstallerService.shared.start()
        AppStatusBarController.shared.start(
            store: TokenStore.shared,
            oauth: OAuthManager.shared,
            language: LanguageSettings.shared,
            refreshFrequency: RefreshFrequencySettings.shared,
            codexSessionStatus: CodexSessionStatusService.shared,
            codexHookInstaller: CodexHookInstallerService.shared
        )
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class AppStatusBarController: NSObject {
    static let shared = AppStatusBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []
    private var capsuleView: StatusBarCapsuleView?
    private var lastStatusItemWidth: CGFloat = 0

    private weak var store: TokenStore?
    private weak var oauth: OAuthManager?
    private weak var language: LanguageSettings?
    private weak var refreshFrequency: RefreshFrequencySettings?
    private weak var codexSessionStatus: CodexSessionStatusService?
    private weak var codexHookInstaller: CodexHookInstallerService?

    func start(
        store: TokenStore,
        oauth: OAuthManager,
        language: LanguageSettings,
        refreshFrequency: RefreshFrequencySettings,
        codexSessionStatus: CodexSessionStatusService,
        codexHookInstaller: CodexHookInstallerService
    ) {
        guard statusItem == nil else { return }

        NSApplication.shared.setActivationPolicy(.accessory)

        self.store = store
        self.oauth = oauth
        self.language = language
        self.refreshFrequency = refreshFrequency
        self.codexSessionStatus = codexSessionStatus
        self.codexHookInstaller = codexHookInstaller

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.image = nil
            button.title = ""
            button.imagePosition = .noImage
            button.wantsLayer = true
            button.layer?.masksToBounds = false
            button.sendAction(on: [.leftMouseUp])
            installStatusContentView(in: button)
        }

        installObservers()
        updateStatusItem()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover?.isShown == true {
            popover?.performClose(nil)
            return
        }
        showMenuPopover()
    }

    private func installObservers() {
        guard let store, let language, let codexSessionStatus, let codexHookInstaller else { return }

        store.$accounts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        language.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        codexSessionStatus.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        codexHookInstaller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
    }

    private func installStatusContentView(in button: NSStatusBarButton) {
        let view = StatusBarCapsuleView()
        view.frame = button.bounds
        view.autoresizingMask = [.width, .height]
        button.addSubview(view)
        capsuleView = view
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button,
              let capsuleView,
              let store,
              let codexSessionStatus,
              let codexHookInstaller else { return }
        let quotaLabel = Self.quotaLabel(from: store)
        let iconName = Self.iconName(from: store)
        let width = StatusBarCapsuleView.width(for: quotaLabel)
        let light: CodexSessionLight = codexHookInstaller.state.needsAction ? .offline : codexSessionStatus.status.light

        if abs(lastStatusItemWidth - width) > 0.5 {
            statusItem?.length = width
            lastStatusItemWidth = width
        }

        capsuleView.frame = button.bounds
        capsuleView.configure(iconName: iconName, quotaLabel: quotaLabel, light: light)
        button.toolTip = codexHookInstaller.state.needsAction ? L.codexHookTooltipNeedsInstall : codexSessionStatus.helpText
    }

    private func showMenuPopover() {
        guard let button = statusItem?.button,
              let store,
              let oauth,
              let language,
              let refreshFrequency,
              let codexSessionStatus,
              let codexHookInstaller else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 300, height: 620)
        popover.contentViewController = FirstMouseHostingController(
            rootView: MenuBarView()
                .environmentObject(store)
                .environmentObject(oauth)
                .environmentObject(language)
                .environmentObject(refreshFrequency)
                .environmentObject(codexSessionStatus)
                .environmentObject(codexHookInstaller)
        )
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private static func quotaLabel(from store: TokenStore) -> String {
        guard let active = store.accounts.first(where: { $0.isActive }) else {
            return "--·--"
        }
        return "\(Int(active.primaryUsedPercent))%·\(Int(active.secondaryUsedPercent))%"
    }

    private static func iconName(from store: TokenStore) -> String {
        let ref: [TokenAccount]
        if let active = store.accounts.first(where: { $0.isActive }) {
            ref = [active]
        } else {
            ref = store.accounts
        }
        if ref.contains(where: { $0.isBanned }) {
            return "xmark.circle.fill"
        }
        if ref.contains(where: { $0.secondaryExhausted }) {
            return "exclamationmark.triangle.fill"
        }
        if ref.contains(where: { $0.quotaExhausted || $0.primaryUsedPercent >= 80 || $0.secondaryUsedPercent >= 80 }) {
            return "bolt.circle.fill"
        }
        return "terminal.fill"
    }
}

private final class FirstMouseHostingController<Content: View>: NSViewController {
    private let rootView: Content

    init(rootView: Content) {
        self.rootView = rootView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = FirstMouseHostingView(rootView: rootView)
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class StatusBarCapsuleView: NSView {
    private static let height: CGFloat = 20
    private static let leftPadding: CGFloat = 0
    private static let rightPadding: CGFloat = 2
    private static let iconSize: CGFloat = 16
    private static let textGap: CGFloat = 3
    private static let lightGap: CGFloat = 7
    private static let textRenderPadding: CGFloat = 4
    private static let dotSize: CGFloat = 8.4
    private static let dotGap: CGFloat = 5.0
    private static let lightsWidth = dotSize * 3 + dotGap * 2
    private static let textFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: textFont,
        .foregroundColor: NSColor.white.withAlphaComponent(0.93)
    ]

    private let iconView = NSImageView()
    private let textField = NSTextField(labelWithString: "")
    private let lightsView = StatusTrafficLightsView(dotSize: dotSize, dotGap: dotGap)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    static func width(for quotaLabel: String) -> CGFloat {
        let textWidth = measuredTextWidth(for: quotaLabel)
        return leftPadding + iconSize + textGap + textWidth + lightGap + lightsWidth + rightPadding
    }

    func configure(iconName: String, quotaLabel: String, light: CodexSessionLight) {
        iconView.image = Self.statusIcon(systemName: iconName)
        if textField.stringValue != quotaLabel {
            textField.stringValue = quotaLabel
        }
        lightsView.configure(light: light)
        needsLayout = true
    }

    override func layout() {
        super.layout()

        let textSize = (textField.stringValue as NSString).size(withAttributes: Self.textAttributes)
        let textWidth = Self.measuredTextWidth(for: textField.stringValue)
        let iconRect = NSRect(
            x: Self.leftPadding,
            y: (bounds.height - Self.iconSize) / 2,
            width: Self.iconSize,
            height: Self.iconSize
        )
        iconView.frame = iconRect

        textField.frame = NSRect(
            x: iconRect.maxX + Self.textGap,
            y: (bounds.height - textSize.height) / 2 - 0.3,
            width: textWidth,
            height: textSize.height + 1
        )

        lightsView.frame = NSRect(
            x: textField.frame.minX + textWidth + Self.lightGap,
            y: 0,
            width: Self.lightsWidth,
            height: bounds.height
        )
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(iconView)

        textField.font = Self.textFont
        textField.textColor = NSColor.white.withAlphaComponent(0.93)
        textField.backgroundColor = .clear
        textField.isBezeled = false
        textField.isEditable = false
        textField.isSelectable = false
        textField.drawsBackground = false
        textField.translatesAutoresizingMaskIntoConstraints = true
        addSubview(textField)

        lightsView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(lightsView)
    }

    private static func measuredTextWidth(for text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: textAttributes).width) + textRenderPadding
    }

    private static func statusIcon(systemName: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: NSColor.white.withAlphaComponent(0.93)))
        return NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}

private final class StatusTrafficLightsView: NSView {
    private static let coreBreathingAnimationKey = "codexbar.coreBreathing"
    private static let glowBreathingAnimationKey = "codexbar.glowBreathing"

    private let dotSize: CGFloat
    private let dotGap: CGFloat
    private let redGlowLayer = CAShapeLayer()
    private let yellowGlowLayer = CAShapeLayer()
    private let greenGlowLayer = CAShapeLayer()
    private let redLayer = CAShapeLayer()
    private let yellowLayer = CAShapeLayer()
    private let greenLayer = CAShapeLayer()
    private var currentLight: CodexSessionLight = .offline

    init(dotSize: CGFloat, dotGap: CGFloat) {
        self.dotSize = dotSize
        self.dotGap = dotGap
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        self.dotSize = 8.4
        self.dotGap = 5.0
        super.init(coder: coder)
        setup()
    }

    override func layout() {
        super.layout()
        layoutDotLayers()
        applyVisualState(animated: false)
    }

    func configure(light: CodexSessionLight) {
        currentLight = light
        applyVisualState(animated: true)
    }

    private func setup() {
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false

        [redGlowLayer, yellowGlowLayer, greenGlowLayer].forEach { glowLayer in
            glowLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            glowLayer.lineWidth = 1.0
            glowLayer.opacity = 0
            glowLayer.shadowOffset = .zero
            glowLayer.masksToBounds = false
            layer?.addSublayer(glowLayer)
        }

        [redLayer, yellowLayer, greenLayer].forEach { dotLayer in
            dotLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            dotLayer.lineWidth = 0.5
            dotLayer.shadowOffset = .zero
            dotLayer.masksToBounds = false
            layer?.addSublayer(dotLayer)
        }
    }

    private func layoutDotLayers() {
        let dotBounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
        let path = CGPath(ellipseIn: dotBounds, transform: nil)
        let glowBounds = dotBounds.insetBy(dx: -2.2, dy: -2.2)
        let glowPath = CGPath(ellipseIn: glowBounds, transform: nil)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, slot) in [TrafficLightSlot.red, .yellow, .green].enumerated() {
            let dotLayer = layer(for: slot)
            let glowLayer = glowLayer(for: slot)
            let position = CGPoint(
                x: dotSize / 2 + CGFloat(index) * (dotSize + dotGap),
                y: bounds.midY
            )

            glowLayer.bounds = glowBounds
            glowLayer.position = position
            glowLayer.path = glowPath
            glowLayer.shadowPath = glowPath

            dotLayer.bounds = dotBounds
            dotLayer.position = position
            dotLayer.path = path
            dotLayer.shadowPath = path
        }
        CATransaction.commit()
    }

    private func applyVisualState(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.28 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))

        for slot in [TrafficLightSlot.red, .yellow, .green] {
            let dotLayer = layer(for: slot)
            let glowLayer = glowLayer(for: slot)
            let isActive = currentLight == slot.activeLight
            let isBreathing = currentLight == .running && slot == .yellow

            if currentLight == .offline {
                stopBreathing(dotLayer: dotLayer, glowLayer: glowLayer)
                dotLayer.fillColor = NSColor.white.withAlphaComponent(0.34).cgColor
                dotLayer.strokeColor = NSColor.white.withAlphaComponent(0.08).cgColor
                dotLayer.opacity = 1
                dotLayer.shadowOpacity = 0
                dotLayer.shadowRadius = 0
                dotLayer.transform = CATransform3DIdentity

                glowLayer.opacity = 0
                glowLayer.shadowOpacity = 0
                glowLayer.transform = CATransform3DIdentity
            } else {
                dotLayer.fillColor = (isActive ? slot.activeNSColor : slot.dimNSColor).cgColor
                dotLayer.strokeColor = NSColor.white.withAlphaComponent(isActive ? 0.25 : 0.08).cgColor
                dotLayer.shadowColor = slot.activeNSColor.cgColor
                dotLayer.opacity = 1
                dotLayer.shadowOpacity = isActive ? 0.64 : 0
                dotLayer.shadowRadius = isActive ? 4 : 0
                dotLayer.transform = CATransform3DIdentity

                glowLayer.fillColor = slot.activeNSColor.withAlphaComponent(isBreathing ? 0.10 : 0.04).cgColor
                glowLayer.strokeColor = slot.activeNSColor.withAlphaComponent(isBreathing ? 0.90 : 0.42).cgColor
                glowLayer.shadowColor = slot.activeNSColor.cgColor
                glowLayer.lineWidth = isBreathing ? 0.9 : 0.7
                glowLayer.shadowRadius = isActive ? 4.6 : 0
                glowLayer.shadowOpacity = isActive ? 0.24 : 0
                glowLayer.opacity = isActive ? 0.30 : 0
                glowLayer.transform = CATransform3DIdentity

                if isBreathing {
                    startBreathing(dotLayer: dotLayer, glowLayer: glowLayer)
                } else {
                    stopBreathing(dotLayer: dotLayer, glowLayer: glowLayer)
                }
            }
        }

        CATransaction.commit()
    }

    private func startBreathing(dotLayer: CAShapeLayer, glowLayer: CAShapeLayer) {
        if dotLayer.animation(forKey: Self.coreBreathingAnimationKey) == nil {
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0.62
            opacity.toValue = 1.0

            let shadowOpacity = CABasicAnimation(keyPath: "shadowOpacity")
            shadowOpacity.fromValue = 0.28
            shadowOpacity.toValue = 0.78

            let coreGroup = CAAnimationGroup()
            coreGroup.animations = [opacity, shadowOpacity]
            coreGroup.duration = 1.35
            coreGroup.autoreverses = true
            coreGroup.repeatCount = .infinity
            coreGroup.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            coreGroup.isRemovedOnCompletion = false
            dotLayer.add(coreGroup, forKey: Self.coreBreathingAnimationKey)
        }

        guard glowLayer.animation(forKey: Self.glowBreathingAnimationKey) == nil else { return }

        let glowOpacity = CABasicAnimation(keyPath: "opacity")
        glowOpacity.fromValue = 0.16
        glowOpacity.toValue = 0.66

        let glowShadowOpacity = CABasicAnimation(keyPath: "shadowOpacity")
        glowShadowOpacity.fromValue = 0.18
        glowShadowOpacity.toValue = 0.62

        let glowShadowRadius = CABasicAnimation(keyPath: "shadowRadius")
        glowShadowRadius.fromValue = 2.8
        glowShadowRadius.toValue = 8.2

        let glowGroup = CAAnimationGroup()
        glowGroup.animations = [glowOpacity, glowShadowOpacity, glowShadowRadius]
        glowGroup.duration = 1.35
        glowGroup.autoreverses = true
        glowGroup.repeatCount = .infinity
        glowGroup.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowGroup.isRemovedOnCompletion = false
        glowLayer.add(glowGroup, forKey: Self.glowBreathingAnimationKey)
    }

    private func stopBreathing(dotLayer: CAShapeLayer, glowLayer: CAShapeLayer) {
        dotLayer.removeAnimation(forKey: Self.coreBreathingAnimationKey)
        glowLayer.removeAnimation(forKey: Self.glowBreathingAnimationKey)
    }

    private func layer(for slot: TrafficLightSlot) -> CAShapeLayer {
        switch slot {
        case .red:
            return redLayer
        case .yellow:
            return yellowLayer
        case .green:
            return greenLayer
        }
    }

    private func glowLayer(for slot: TrafficLightSlot) -> CAShapeLayer {
        switch slot {
        case .red:
            return redGlowLayer
        case .yellow:
            return yellowGlowLayer
        case .green:
            return greenGlowLayer
        }
    }
}

private enum TrafficLightSlot {
    case red, yellow, green

    var activeLight: CodexSessionLight {
        switch self {
        case .red: return .needsAttention
        case .yellow: return .running
        case .green: return .ready
        }
    }

    var dimNSColor: NSColor {
        switch self {
        case .red:
            return NSColor(calibratedRed: 0.98, green: 0.20, blue: 0.18, alpha: 0.32)
        case .yellow:
            return NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.16, alpha: 0.34)
        case .green:
            return NSColor(calibratedRed: 0.23, green: 0.92, blue: 0.34, alpha: 0.32)
        }
    }

    var activeNSColor: NSColor {
        switch self {
        case .red:
            return NSColor(calibratedRed: 1.00, green: 0.20, blue: 0.18, alpha: 1.0)
        case .yellow:
            return NSColor(calibratedRed: 1.00, green: 0.88, blue: 0.18, alpha: 1.0)
        case .green:
            return NSColor(calibratedRed: 0.20, green: 0.96, blue: 0.35, alpha: 1.0)
        }
    }
}
