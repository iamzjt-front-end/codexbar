import Foundation

/// App 级后台续期/刷新调度器。
/// 独立于菜单 View 生命周期 —— MenuBarExtra(.window) 的内容 View 只在弹出时存在，
/// 其内的 Timer 菜单关闭就停。后台续期必须由这个常驻对象驱动。
@MainActor
final class BackgroundRefresher {
    static let shared = BackgroundRefresher()
    private init() {}

    private var timer: Timer?
    private var tickTask: Task<Void, Never>?
    private var activeTickID: UInt64?
    private var nextTickID: UInt64 = 1
    private let store = TokenStore.shared

    /// 启动：可立即跑一次，之后每 interval 秒跑一次
    func start(interval: TimeInterval = 300, runImmediately: Bool = true) {
        stop()
        if runImmediately {
            // 启动时立即检查一次（覆盖"开机就有账号临近过期"）
            scheduleTick()
        }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleTick()
            }
        }
        // common 模式，避免菜单弹出/交互时定时器被挂起
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tickTask?.cancel()
        tickTask = nil
        activeTickID = nil
    }

    private func scheduleTick() {
        guard tickTask == nil else { return }
        let tickID = nextTickID
        nextTickID &+= 1
        activeTickID = tickID
        tickTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if activeTickID == tickID {
                    tickTask = nil
                    activeTickID = nil
                }
            }
            await tick()
        }
    }

    /// 一轮：先续期临近过期的账号，再刷新用量
    private func tick() async {
        await RefreshService.shared.refreshExpiring(store: store)
        await WhamService.shared.refreshAll(store: store)
    }
}
