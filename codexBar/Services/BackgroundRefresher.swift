import Foundation

/// App 级后台续期/刷新调度器。
/// 独立于菜单 View 生命周期 —— MenuBarExtra(.window) 的内容 View 只在弹出时存在，
/// 其内的 Timer 菜单关闭就停。后台续期必须由这个常驻对象驱动。
@MainActor
final class BackgroundRefresher {
    static let shared = BackgroundRefresher()
    private init() {}

    private var timer: Timer?
    private let store = TokenStore.shared

    /// 启动：立即跑一次，之后每 interval 秒跑一次
    func start(interval: TimeInterval = 300) {
        stop()
        // 启动时立即检查一次（覆盖"开机就有账号临近过期"）
        Task { await tick() }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.tick() }
        }
        // common 模式，避免菜单弹出/交互时定时器被挂起
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 一轮：先续期临近过期的账号，再刷新用量
    private func tick() async {
        await RefreshService.shared.refreshExpiring(store: store)
        await WhamService.shared.refreshAll(store: store)
    }
}
