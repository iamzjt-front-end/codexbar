import AppKit
import Combine
import QuartzCore
import SwiftUI

@main
struct codexBarApp: App {
    init() {
        // 单元测试会把测试包注入应用进程；此时禁止启动真实刷新、hooks 和更新任务。
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        TokenStore.shared.startMonitoringActiveAuthFile()
        // App 级后台续期，脱离菜单 View 生命周期（菜单关闭时 View 不存在，其内 Timer 不跑）
        BackgroundRefresher.shared.start(interval: RefreshFrequencySettings.shared.selection.backgroundInterval)
        CodexRadarService.shared.start()
        CodexHookInstallerService.shared.start()
        TaskCenterService.shared.onRequestOpenCodex = {
            CodexApplicationActivator.activate()
        }
        TaskCenterService.shared.start()
        AppUpdateService.shared.startPeriodicChecks()
        AppStatusBarController.shared.start(
            store: TokenStore.shared,
            oauth: OAuthManager.shared,
            language: LanguageSettings.shared,
            refreshFrequency: RefreshFrequencySettings.shared,
            quotaDisplay: QuotaDisplaySettings.shared,
            taskCenter: TaskCenterService.shared,
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
    private weak var quotaDisplay: QuotaDisplaySettings?
    private weak var taskCenter: TaskCenterService?
    private weak var codexHookInstaller: CodexHookInstallerService?

    func start(
        store: TokenStore,
        oauth: OAuthManager,
        language: LanguageSettings,
        refreshFrequency: RefreshFrequencySettings,
        quotaDisplay: QuotaDisplaySettings,
        taskCenter: TaskCenterService,
        codexHookInstaller: CodexHookInstallerService
    ) {
        guard statusItem == nil else { return }

        NSApplication.shared.setActivationPolicy(.accessory)

        self.store = store
        self.oauth = oauth
        self.language = language
        self.refreshFrequency = refreshFrequency
        self.quotaDisplay = quotaDisplay
        self.taskCenter = taskCenter
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
        guard let store, let language, let quotaDisplay, let taskCenter, let codexHookInstaller else { return }

        store.$accounts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        language.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        quotaDisplay.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        quotaDisplay.$amountMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        quotaDisplay.$showStatusLights
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        taskCenter.$snapshot
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
              let quotaDisplay,
              let taskCenter,
              let codexHookInstaller else { return }
        let quotaState = Self.quotaState(from: store, amountMode: quotaDisplay.amountMode)
        let iconName = Self.iconName(from: store)
        let width = StatusBarCapsuleView.width(
            for: quotaState,
            mode: quotaDisplay.mode,
            showStatusLights: quotaDisplay.showStatusLights
        )
        let light: CodexSessionLight = codexHookInstaller.state.needsAction
            ? .offline
            : taskCenter.snapshot.aggregateLight

        if abs(lastStatusItemWidth - width) > 0.5 {
            statusItem?.length = width
            lastStatusItemWidth = width
        }

        capsuleView.frame = button.bounds
        capsuleView.configure(
            iconName: iconName,
            quotaState: quotaState,
            mode: quotaDisplay.mode,
            light: light,
            showStatusLights: quotaDisplay.showStatusLights
        )
        button.toolTip = Self.taskStatusToolTip(
            snapshot: taskCenter.snapshot,
            hookState: codexHookInstaller.state
        )
    }

    private func showMenuPopover() {
        guard let button = statusItem?.button,
              let store,
              let oauth,
              let language,
              let refreshFrequency,
              let quotaDisplay,
              let taskCenter,
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
                .environmentObject(quotaDisplay)
                .environmentObject(taskCenter)
                .environmentObject(codexHookInstaller)
                .environmentObject(AppUpdateService.shared)
        )
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private static func quotaState(from store: TokenStore, amountMode: QuotaAmountMode) -> StatusBarQuotaState {
        guard let active = store.accounts.first(where: { $0.isActive }) else {
            return StatusBarQuotaState.empty
        }
        let weeklyDisplayPercent = amountMode.displayPercent(forUsedPercent: active.weeklyUsedPercent)
        return StatusBarQuotaState(
            text: "7d \(Int(weeklyDisplayPercent))%",
            weeklyDisplayPercent: weeklyDisplayPercent,
            weeklyUsedPercent: active.weeklyUsedPercent
        )
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
        if ref.contains(where: { $0.weeklyExhausted }) {
            return "exclamationmark.triangle.fill"
        }
        if ref.contains(where: { $0.weeklyUsedPercent >= 80 }) {
            return "bolt.circle.fill"
        }
        return "terminal.fill"
    }

    private static func taskStatusToolTip(
        snapshot: TaskCenterSnapshot,
        hookState: CodexHookInstallState
    ) -> String {
        guard !hookState.needsAction else { return L.codexHookTooltipNeedsInstall }
        let summary = L.taskStatusSummary(
            needsAttention: snapshot.needsAttentionCount,
            running: snapshot.runningCount
        )
        guard let record = snapshot.mostUrgent else { return summary }
        return "\(summary) · \(record.projectName) · \(L.taskStatusPhase(record.phase))"
    }
}

private struct StatusBarQuotaState {
    let text: String
    let weeklyDisplayPercent: Double?
    let weeklyUsedPercent: Double?

    static let empty = StatusBarQuotaState(
        text: "7d --",
        weeklyDisplayPercent: nil,
        weeklyUsedPercent: nil
    )

    var hasBars: Bool {
        weeklyDisplayPercent != nil
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
    private static let leftPadding: CGFloat = 0
    private static let rightPadding: CGFloat = 2
    private static let iconSize: CGFloat = 16
    private static let textGap: CGFloat = 3
    private static let barsGap: CGFloat = 0
    private static let lightGap: CGFloat = 2
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
    private let barsView = StatusQuotaBarsView()
    private let lightsView = StatusTrafficLightsView(dotSize: dotSize, dotGap: dotGap)
    private var quotaState = StatusBarQuotaState.empty
    private var quotaMode: QuotaDisplayMode = .numbers
    private var showStatusLights = true

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

    static func width(for quotaState: StatusBarQuotaState, mode: QuotaDisplayMode, showStatusLights: Bool) -> CGFloat {
        let contentWidth = contentWidth(for: quotaState, mode: mode)
        let contentGap = mode == .bars && quotaState.hasBars ? barsGap : textGap
        let statusLightsWidth = showStatusLights ? lightGap + lightsWidth : 0
        return leftPadding + iconSize + contentGap + contentWidth + statusLightsWidth + rightPadding
    }

    func configure(
        iconName: String,
        quotaState: StatusBarQuotaState,
        mode: QuotaDisplayMode,
        light: CodexSessionLight,
        showStatusLights: Bool
    ) {
        iconView.image = Self.statusIcon(systemName: iconName)
        self.quotaState = quotaState
        quotaMode = mode
        self.showStatusLights = showStatusLights
        if textField.stringValue != quotaState.text {
            textField.stringValue = quotaState.text
        }
        barsView.configure(
            weeklyDisplayPercent: quotaState.weeklyDisplayPercent ?? 0,
            weeklyUsedPercent: quotaState.weeklyUsedPercent ?? 0
        )
        lightsView.configure(light: light)
        lightsView.isHidden = !showStatusLights
        needsLayout = true
    }

    override func layout() {
        super.layout()

        let textSize = (textField.stringValue as NSString).size(withAttributes: Self.textAttributes)
        let useBars = quotaMode == .bars && quotaState.hasBars
        let contentGap = useBars ? Self.barsGap : Self.textGap
        let contentWidth = Self.contentWidth(for: quotaState, mode: quotaMode)
        let iconRect = NSRect(
            x: Self.leftPadding,
            y: (bounds.height - Self.iconSize) / 2,
            width: Self.iconSize,
            height: Self.iconSize
        )
        iconView.frame = iconRect

        let contentX = iconRect.maxX + contentGap
        if useBars {
            textField.isHidden = true
            barsView.isHidden = false
            barsView.frame = NSRect(
                x: contentX,
                y: 0,
                width: StatusQuotaBarsView.preferredWidth,
                height: bounds.height
            )
        } else {
            barsView.isHidden = true
            textField.isHidden = false
            textField.frame = NSRect(
                x: contentX,
                y: (bounds.height - textSize.height) / 2 - 0.3,
                width: contentWidth,
                height: textSize.height + 1
            )
        }

        if showStatusLights {
            lightsView.isHidden = false
            lightsView.frame = NSRect(
                x: contentX + contentWidth + Self.lightGap,
                y: 0,
                width: Self.lightsWidth,
                height: bounds.height
            )
        } else {
            lightsView.isHidden = true
            lightsView.frame = .zero
        }
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

        barsView.translatesAutoresizingMaskIntoConstraints = true
        barsView.isHidden = true
        addSubview(barsView)

        lightsView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(lightsView)
    }

    private static func contentWidth(for quotaState: StatusBarQuotaState, mode: QuotaDisplayMode) -> CGFloat {
        if mode == .bars && quotaState.hasBars {
            return StatusQuotaBarsView.preferredWidth
        }
        return measuredTextWidth(for: quotaState.text)
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

private final class StatusQuotaBarsView: NSView {
    private static let label = "7d"
    private static let itemGap: CGFloat = 4
    private static let trackWidth: CGFloat = 44
    private static let trackHeight: CGFloat = 3.2
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let maximumLabelWidth = ceil(textSize(label, font: labelFont).width)
    private static let maximumValueWidth = ceil(textSize("100%", font: valueFont).width)
    private static let labelTextYOffset: CGFloat = -0.2
    private static let valueTextYOffset: CGFloat = -0.2
    private static let fillAnimationKey = "codexbar.quotaFill"
    private static let fillAnimationDuration: CFTimeInterval = 0.38

    static let preferredWidth = maximumLabelWidth + itemGap + trackWidth + itemGap + maximumValueWidth

    private struct RowLayout {
        let labelRect: NSRect
        let trackRect: NSRect
        let valueRect: NSRect
    }

    private let weeklyFillLayer = CAShapeLayer()
    private var weeklyDisplayPercent: Double = 0
    private var weeklyUsedPercent: Double = 0
    private var hasLaidOutFillLayers = false
    private var lastFillBounds: NSRect = .zero

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupFillLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupFillLayers()
    }

    func configure(
        weeklyDisplayPercent: Double,
        weeklyUsedPercent: Double
    ) {
        let nextWeeklyDisplay = Self.clamped(weeklyDisplayPercent)
        let nextWeeklyUsed = Self.clamped(weeklyUsedPercent)
        let displayChanged = self.weeklyDisplayPercent != nextWeeklyDisplay
        guard self.weeklyDisplayPercent != nextWeeklyDisplay ||
            self.weeklyUsedPercent != nextWeeklyUsed else { return }
        let weeklyFromPath = weeklyFillLayer.presentation()?.path ?? weeklyFillLayer.path
        self.weeklyDisplayPercent = nextWeeklyDisplay
        self.weeklyUsedPercent = nextWeeklyUsed
        updateFillLayers(
            animated: displayChanged && hasLaidOutFillLayers && window != nil && !isHidden,
            weeklyFromPath: weeklyFromPath
        )
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if !hasLaidOutFillLayers || !NSEqualRects(lastFillBounds, bounds) {
            updateFillLayers(animated: false)
            lastFillBounds = bounds
        }
        hasLaidOutFillLayers = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawRow(
            label: Self.label,
            displayPercent: weeklyDisplayPercent,
            centerY: bounds.midY
        )
    }

    private func drawRow(label: String, displayPercent: Double, centerY: CGFloat) {
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let value = Self.valueText(for: displayPercent)
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.valueFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.98)
        ]
        let rowLayout = layoutRow(label: label, value: value, centerY: centerY)

        (label as NSString).draw(in: rowLayout.labelRect, withAttributes: labelAttributes)
        drawPill(rowLayout.trackRect, color: NSColor.white.withAlphaComponent(0.18))
        (value as NSString).draw(in: rowLayout.valueRect, withAttributes: valueAttributes)
    }

    private func setupFillLayers() {
        wantsLayer = true
        layer?.masksToBounds = false

        weeklyFillLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        weeklyFillLayer.masksToBounds = false
        weeklyFillLayer.opacity = 0
        weeklyFillLayer.zPosition = 1
        layer?.addSublayer(weeklyFillLayer)
    }

    private func drawPill(_ rect: NSRect, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }

    private func updateFillLayers(
        animated: Bool,
        weeklyFromPath: CGPath? = nil
    ) {
        guard bounds.width > 0 else { return }
        updateFillLayer(
            weeklyFillLayer,
            displayPercent: weeklyDisplayPercent,
            usedPercent: weeklyUsedPercent,
            centerY: bounds.midY,
            animated: animated,
            fromPath: weeklyFromPath
        )
    }

    private func updateFillLayer(
        _ fillLayer: CAShapeLayer,
        displayPercent: Double,
        usedPercent: Double,
        centerY: CGFloat,
        animated: Bool,
        fromPath: CGPath?
    ) {
        let newPath = fillPath(displayPercent: displayPercent, centerY: centerY)
        let newOpacity: Float = displayPercent > 0 ? 1 : 0
        let oldPath = fromPath ?? fillLayer.presentation()?.path ?? fillLayer.path ?? newPath
        let oldOpacity = fillLayer.presentation()?.opacity ?? fillLayer.opacity

        fillLayer.removeAnimation(forKey: Self.fillAnimationKey)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = bounds
        fillLayer.fillColor = Self.color(forUsedPercent: usedPercent).cgColor
        fillLayer.path = newPath
        fillLayer.opacity = newOpacity
        CATransaction.commit()

        guard animated else { return }

        let pathAnimation = CABasicAnimation(keyPath: "path")
        pathAnimation.fromValue = oldPath
        pathAnimation.toValue = newPath

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = oldOpacity
        opacityAnimation.toValue = newOpacity

        let group = CAAnimationGroup()
        group.animations = [pathAnimation, opacityAnimation]
        group.duration = Self.fillAnimationDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = true
        fillLayer.add(group, forKey: Self.fillAnimationKey)
    }

    private func fillPath(displayPercent: Double, centerY: CGFloat) -> CGPath {
        let trackRect = self.trackRect(displayPercent: displayPercent, centerY: centerY)
        let fillWidth: CGFloat
        if displayPercent > 0 {
            fillWidth = max(Self.trackHeight, trackRect.width * CGFloat(displayPercent) / 100)
        } else {
            fillWidth = Self.trackHeight
        }
        let fillRect = NSRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: fillWidth,
            height: trackRect.height
        )
        return CGPath(
            roundedRect: fillRect,
            cornerWidth: fillRect.height / 2,
            cornerHeight: fillRect.height / 2,
            transform: nil
        )
    }

    private func layoutRow(label: String, value: String, centerY: CGFloat) -> RowLayout {
        let labelSize = Self.textSize(label, font: Self.labelFont)
        let valueSize = Self.textSize(value, font: Self.valueFont)
        let contentWidth = labelSize.width + Self.itemGap + Self.trackWidth + Self.itemGap + valueSize.width
        let leadingInset = max((bounds.width - contentWidth) / 2, 0)
        let labelRect = NSRect(
            x: leadingInset,
            y: centerY - labelSize.height / 2 + Self.labelTextYOffset,
            width: labelSize.width,
            height: labelSize.height
        )
        let trackRect = NSRect(
            x: labelRect.maxX + Self.itemGap,
            y: centerY - Self.trackHeight / 2,
            width: Self.trackWidth,
            height: Self.trackHeight
        )
        let valueRect = NSRect(
            x: trackRect.maxX + Self.itemGap,
            y: centerY - valueSize.height / 2 + Self.valueTextYOffset,
            width: valueSize.width,
            height: valueSize.height
        )
        return RowLayout(labelRect: labelRect, trackRect: trackRect, valueRect: valueRect)
    }

    private func trackRect(displayPercent: Double, centerY: CGFloat) -> NSRect {
        layoutRow(
            label: Self.label,
            value: Self.valueText(for: displayPercent),
            centerY: centerY
        ).trackRect
    }

    private static func textSize(_ text: String, font: NSFont) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    private static func valueText(for displayPercent: Double) -> String {
        "\(Int(clamped(displayPercent)))%"
    }

    private static func color(forUsedPercent usedPercent: Double) -> NSColor {
        CodexStatusPalette.nsColor(forUsedPercent: usedPercent)
    }

    private static func clamped(_ percent: Double) -> Double {
        min(max(percent, 0), 100)
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
