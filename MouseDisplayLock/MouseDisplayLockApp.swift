import SwiftUI
import AppKit
import CoreGraphics
import ApplicationServices
import Combine
import UniformTypeIdentifiers


// ============================================================
// MARK: - App
// ============================================================

@main
struct MouseDisplayLockApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @StateObject
    private var manager = LockManager.shared

    var body: some Scene {

        MenuBarExtra {

            ContentView(
                manager: manager
            )

        } label: {

            Image(
                systemName:
                    manager.menuBarIcon
            )
        }
        .menuBarExtraStyle(.window)
    }
}


// ============================================================
// MARK: - App Delegate
// ============================================================

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {

        LockManager.shared.start()
    }


    func applicationWillTerminate(
        _ notification: Notification
    ) {

        LockManager.shared.stop()
    }
}


// ============================================================
// MARK: - Lock Manager
// ============================================================

final class LockManager: ObservableObject {

    static let shared =
        LockManager()


    // ========================================================
    // MARK: Published
    // ========================================================

    /*
     * 用户真正的锁定开关。
     *
     * isLocked 表示用户是否打开了锁定。
     */

    @Published private(set)
    var isLocked = false


    @Published private(set)
    var lockedDisplayID:
        CGDirectDisplayID?


    @Published private(set)
    var lockedDisplayName:
        String?


    struct SelectedApp:
        Identifiable,
        Codable,
        Hashable
    {
        let id: String
        let name: String
        let path: String
    }


    @Published
    var selectedApplications:
        [SelectedApp] = []


    /*
     * 当前目标应用是否前台。
     */

    @Published private(set)
    var isApplicationActive = true


    // ========================================================
    // MARK: Soft Boundary State
    // ========================================================

    /*
     * 当前是否真正激活软边界限制。
     *
     * isLocked：
     *     用户是否打开锁定。
     *
     * isBoundaryActive：
     *     当前是否正在限制鼠标不能跨屏。
     */

    private var isBoundaryActive =
        false


    // ========================================================
    // MARK: Relative Mouse Mode
    // ========================================================

    /*
     * 缓存：所有屏幕的最大 Y（Cocoa 坐标）。
     * 用于 Quartz ↔ Cocoa 转换，避免每次事件都遍历 NSScreen。
     */

    private var cachedGlobalMaxY:
        CGFloat = 0


    // ========================================================
    // MARK: Menu / Status
    // ========================================================

    var menuBarIcon: String {

        if !isLocked {
            return "lock.open"
        }


        if !selectedApplications.isEmpty &&
            !isApplicationActive {

            return "lock.slash"
        }


        if isBoundaryActive {
            return "lock.fill"
        }


        return "lock"
    }


    var statusText: String {

        if !isLocked {
            return "未锁定"
        }


        if !selectedApplications.isEmpty &&
            !isApplicationActive {

            return "已锁定 · 应用未激活"
        }


        if isBoundaryActive {

            return "已锁定 · 软边界限制"
        }


        return "已锁定 · 等待应用激活"
    }


    var statusColor: Color {

        if !isLocked {
            return .secondary
        }


        if !selectedApplications.isEmpty &&
            !isApplicationActive {

            return .orange
        }


        if isBoundaryActive {

            return .green
        }


        return .yellow
    }


    // ========================================================
    // MARK: Event Monitor
    // ========================================================

    private var keyboardMonitor:
        Any?


    private var workspaceActivateObserver:
        NSObjectProtocol?


    private var workspaceDeactivateObserver:
        NSObjectProtocol?


    private var applicationTimer:
        Timer?


    private var displayConfigurationObserver:
        NSObjectProtocol?


    /*
     * 预转换的屏幕边界（Quartz 坐标）。
     *
     * 避免在每个鼠标事件中都做坐标转换。
     */

    private var cachedScreenFrameInQuartz:
        CGRect?

    /*
     * 缓存：屏幕边界（Cocoa 坐标）。
     */

    private var cachedScreenFrame:
        NSRect?

    /*
     * 缓存：屏幕缩放系数。
     */

    private var cachedScaleFactor:
        CGFloat = 1.0


    // ========================================================
    // MARK: UserDefaults
    // ========================================================

    private let selectedAppsKey =
        "MouseDisplayLock.SelectedApplications"


    // ========================================================
    // MARK: Init
    // ========================================================

    private init() {

        if let data =
            UserDefaults.standard.data(
                forKey:
                    selectedAppsKey
            ),
            let apps = try? JSONDecoder().decode(
                [SelectedApp].self,
                from:
                    data
            )
        {

            selectedApplications =
                apps
        }
    }


    // ========================================================
    // MARK: Start
    // ========================================================

    func start() {

        requestAccessibilityPermission()

        installKeyboardMonitor()

        installWorkspaceMonitor()

        installDisplayConfigurationMonitor()

        updateApplicationState()
    }


    // ========================================================
    // MARK: Stop
    // ========================================================

    func stop() {

        /*
         * 无论当前状态如何，
         * 都必须先恢复系统鼠标。
         */

        disableBoundaryMode()


        removeKeyboardMonitor()


        if let observer =
            workspaceActivateObserver {

            NSWorkspace.shared
                .notificationCenter
                .removeObserver(
                    observer
                )

            workspaceActivateObserver = nil
        }


        if let observer =
            workspaceDeactivateObserver {

            NSWorkspace.shared
                .notificationCenter
                .removeObserver(
                    observer
                )

            workspaceDeactivateObserver = nil
        }


        if let observer =
            displayConfigurationObserver {

            NotificationCenter.default
                .removeObserver(
                    observer
                )

            displayConfigurationObserver = nil
        }


        applicationTimer?.invalidate()

        applicationTimer = nil


        isLocked = false

        lockedDisplayID = nil

        lockedDisplayName = nil
    }


    // ========================================================
    // MARK: Effective Lock State
    // ========================================================

    var shouldLockMouse: Bool {

        guard isLocked else {
            return false
        }


        /*
         * 没有选择应用：
         *
         * 用户手动锁定后立即启用边界限制。
         */

        guard
            !selectedApplications.isEmpty
        else {

            return true
        }


        /*
         * 选择了应用：
         *
         * 只要有一个目标 App 前台，就启用边界限制。
         */

        return isApplicationActive
    }


    // ========================================================
    // MARK: Toggle
    // ========================================================

    func toggleLock() {

        if isLocked {

            unlock()

        } else {

            lockCurrentDisplay()
        }
    }


    // ========================================================
    // MARK: Lock Current Display
    // ========================================================

    func lockCurrentDisplay() {

        let cocoaMouse =
            NSEvent.mouseLocation


        guard let screen =
            NSScreen.screens.first(
                where: {
                    $0.frame.contains(
                        cocoaMouse
                    )
                }
            )
        else {

            print(
                "❌ 无法确定鼠标所在显示器"
            )

            return
        }


        guard let displayID =
            Self.displayID(
                for: screen
            )
        else {

            print(
                "❌ 无法获取显示器 ID"
            )

            return
        }


        lockedDisplayID =
            displayID


        lockedDisplayName =
            screen.localizedName


        isLocked =
            true


        print(
            """
            🔒 Mouse Display Lock

            Display:
            \(screen.localizedName)

            ID:
            \(displayID)

            Mode:
            Soft Boundary
            """
        )


        /*
         * 根据当前前台状态决定是否立即启用
         * 软边界限制。
         */

        updateApplicationState()
    }


    // ========================================================
    // MARK: Unlock
    // ========================================================

    func unlock() {

        /*
         * 第一件事永远是恢复系统鼠标。
         */

        disableBoundaryMode()


        isLocked =
            false


        lockedDisplayID =
            nil


        lockedDisplayName =
            nil


        print(
            "🔓 Mouse Display Lock disabled"
        )
    }


    // ========================================================
    // MARK: Soft Boundary
    // ========================================================

    // ========================================================
    // MARK: Relative Mouse State
    // ========================================================

    /*
     * CGEventTap 用于拦截鼠标事件。
     *
     * 只用一个来源：
     *   - 可以捕获所有应用（包括我们自己）的事件
     *   - 不会重复处理 → 没有异常加速度
     */

    private var relativeEventTapPort:
        CFMachPort?

    private var relativeEventTapSource:
        CFRunLoopSource?


    /*
     * 当前光标位置（Cocoa 坐标）。
     *
     * dissociated 模式下，物理鼠标移动不自动移动光标，
     * 我们通过 delta 累加并 Warp 控制光标位置。
     *
     * 由 positionLock 保护（EventTap 线程写，Warp 线程读）。
     */

    private var currentCursorPosition:
        NSPoint = .zero


    /*
     * 上次 Warp 到的位置（Cocoa 坐标）。
     * 用于跳过无变化的 Warp。
     */

    private var lastWarpPosition:
        NSPoint = .zero


    /*
     * ============================================================
     * 诊断统计（排查卡顿用）
     * ============================================================
     *
     * 只在异常时输出日志，避免 8000Hz 事件刷爆控制台。
     *
     * 阈值：
     *   - 事件间隔 > 20ms（正常 ~1ms）
     *   - 锁等待 > 2ms（正常 <0.1ms）
     *   - Warp 执行 > 5ms（正常 1-3ms）
     *   - Warp 间隔 > 12ms（正常 4ms）
     */

    private var lastEventTimeNanos:
        UInt64 = 0

    private var lastWarpTimeNanos:
        UInt64 = 0

    private var eventCount:
        UInt64 = 0

    private var warpCount:
        UInt64 = 0

    private var maxEventGap:
        UInt64 = 0

    private var maxWarpGap:
        UInt64 = 0

    private var maxLockWait:
        UInt64 = 0

    private var maxWarpDuration:
        UInt64 = 0

    private var lastStatsTimeNanos:
        UInt64 = 0


    /*
     * 位置锁：保护 currentCursorPosition 的跨线程访问。
     *
     *   - EventTap 线程（~1000Hz）：写 currentCursorPosition
     *   - Warp 定时器线程（250Hz）：读 currentCursorPosition
     *
     * os_unfair_lock 无竞争时 ~20ns，适合高频场景。
     */

    private let positionLock =
        NSLock()


    /*
     * 异步 Warp 定时器。
     *
     * 在专用队列上以 250Hz（4ms）运行，
     * 与显示器刷新率（160Hz）解耦：
     *   - EventTap 线程只累加 delta，零 IPC，高频无压力
     *   - Warp 线程独立运行，即使阻塞也不影响事件接收
     *
     * 250Hz > 160Hz，确保每个显示器帧至少 1 次 Warp。
     */

    private var warpTimer:
        DispatchSourceTimer?

    private let warpQueue =
        DispatchQueue(
            label: "com.mouseDisplayLock.warp",
            qos: .userInteractive
        )


    /*
     * EventTap 运行在专用线程上，避免阻塞主线程。
     *
     *   - relativeMouseThread：  运行 EventTap 的专用线程
     *   - relativeMouseRunLoop： 线程的 RunLoop，用于 CFRunLoopStop
     *   - installSemaphore：     同步 install 完成（EventTap 创建就绪）
     *   - exitSemaphore：        同步线程退出（确保清理完成）
     */

    private var relativeMouseThread:
        Thread?

    private var relativeMouseRunLoop:
        CFRunLoop?

    private let installSemaphore =
        DispatchSemaphore(value: 0)

    private let exitSemaphore =
        DispatchSemaphore(value: 0)


    // ========================================================
    // MARK: Boundary Mode
    // ========================================================

    private func enableBoundaryMode() {

        guard !isBoundaryActive else {
            return
        }


        guard let screenFrame =
            lockedScreenFrame()
        else {
            return
        }


        /*
         * 预缓存所有值，避免在每个鼠标事件中计算。
         */

        cachedScreenFrame =
            screenFrame

        cachedScaleFactor =
            NSScreen
                .screens
                .first?
                .backingScaleFactor ?? 1.0


        /*
         * 缓存全局最大 Y（Cocoa 坐标），用于 Quartz ↔ Cocoa 转换。
         */

        cachedGlobalMaxY =
            NSScreen
                .screens
                .map { $0.frame.maxY }
                .max() ?? 0


        /*
         * 预计算屏幕的 Quartz 边界。
         *
         * CGEvent.location 使用 Quartz 坐标（原点左上，Y 向下）。
         * NSScreen.frame 使用 Cocoa 坐标（原点左下，Y 向上）。
         *
         * Quartz Y = globalMaxY - cocoaMaxY
         *           = globalMaxY - (cocoaMinY + height)
         */

        let quartzMinX =
            screenFrame.minX

        let quartzMinY =
            cachedGlobalMaxY - screenFrame.maxY

        cachedScreenFrameInQuartz =
            CGRect(
                x: quartzMinX,
                y: quartzMinY,
                width: screenFrame.width,
                height: screenFrame.height
            )


        isBoundaryActive =
            true


        /*
         * 记录当前光标位置作为起始点，
         * 并限制在屏幕内。
         */

        var mouseLocation =
            NSEvent.mouseLocation

        mouseLocation.x =
            min(
                max(
                    mouseLocation.x,
                    screenFrame.minX
                ),
                screenFrame.maxX
            )

        mouseLocation.y =
            min(
                max(
                    mouseLocation.y,
                    screenFrame.minY
                ),
                screenFrame.maxY
            )

        currentCursorPosition =
            mouseLocation

        lastWarpPosition =
            mouseLocation


        /*
         * 解除鼠标与光标的关联。
         *
         * 必须 dissociate：非 dissociated 模式下 CGEventTap 无法
         * 阻止光标越界（event.location 是通知不是指令）。
         * dissociated 后光标位置完全由我们通过 Warp 控制。
         *
         * Warp 由专用定时器线程异步执行（250Hz），
         * 不阻塞 EventTap 事件接收。
         */

        CGAssociateMouseAndMouseCursorPosition(
            0
        )


        /*
         * 启动异步 Warp 定时器（250Hz，4ms 间隔）。
         *
         * 250Hz > 160Hz 显示器，确保每帧至少 1 次 Warp。
         * 在专用队列上运行，与 EventTap 线程隔离。
         */

        startWarpTimer()


        /*
         * 安装 CGEventTap（listenOnly，读取 delta）。
         */

        installRelativeMouseMonitor()


        /*
         * 禁用"晃动鼠标以定位"功能。
         */

        disableCursorMagnification()


        print(
            "🧱 Soft Boundary ENABLED (Relative Mouse + Async Warp)"
        )
    }


    private func disableBoundaryMode() {

        guard isBoundaryActive else {
            return
        }


        isBoundaryActive =
            false


        /*
         * 先停止 Warp 定时器，避免 dissociated 状态下
         * 恢复关联后还在 Warp。
         */

        stopWarpTimer()


        removeRelativeMouseMonitor()


        /*
         * 恢复鼠标与光标的关联。
         */

        CGAssociateMouseAndMouseCursorPosition(
            1
        )


        /*
         * 恢复用户原来的"晃动鼠标以定位"设置。
         */

        restoreCursorMagnification()


        print(
            "🧱 Soft Boundary DISABLED"
        )
    }


    // ========================================================
    // MARK: Cursor Magnification (Shake to Locate)
    // ========================================================

    private func disableCursorMagnification() {

        NSApp.presentationOptions.insert(
            .disableCursorLocationAssistance
        )
    }


    private func restoreCursorMagnification() {

        NSApp.presentationOptions.remove(
            .disableCursorLocationAssistance
        )
    }


    // ========================================================
    // MARK: Relative Mouse Monitor
    // ========================================================

    private func installRelativeMouseMonitor() {

        guard relativeMouseThread == nil else {
            return
        }


        /*
         * 在专用线程上创建并运行 CGEventTap。
         *
         * 原因：
         *   - EventTap 回调是同步的，CGWarpMouseCursorPosition
         *     是跨进程 IPC，可能阻塞
         *   - 如果在主线程，Warp 阻塞会连带卡住菜单 UI、
         *     Timer、Workspace 通知等所有主线程任务
         *   - 专用线程隔离阻塞，主线程保持流畅
         *
         * CGEventTap 只有一个来源，不会重复处理。
         */

        let userInfo =
            Unmanaged<LockManager>
                .passUnretained(self)
                .toOpaque()


        let thread = Thread { [weak self] in

            guard let self = self else {
                return
            }

            self.runRelativeMouseLoop(
                userInfo: userInfo
            )
        }

        thread.name =
            "com.mouseDisplayLock.relativeMouse"


        /*
         * 提升到 .userInteractive，与 warpQueue 一致。
         *
         * EventTap 线程与 Warp 线程通过 positionLock 同步：
         *   - 若 QoS 不一致（Default < UserInteractive），
         *     Warp 线程等锁时发生优先级反转
         *   - 高频锁竞争下（8000Hz 鼠标），调度开销被放大
         *   - 设为相同 QoS，避免反转导致的偶发延迟
         */

        thread.qualityOfService =
            .userInteractive

        thread.start()

        relativeMouseThread = thread


        /*
         * 等待 EventTap 创建完成，确保返回时已就绪。
         * 子线程设置 relativeMouseRunLoop 后 signal，
         * 主线程 wait 后即可安全访问。
         */

        installSemaphore.wait()
    }


    /*
     * 专用线程入口：创建 EventTap 并运行 RunLoop。
     *
     * 所有 EventTap 资源（port、source）都在此线程内
     * 创建、运行、销毁，避免跨线程访问。
     */

    private func runRelativeMouseLoop(
        userInfo: UnsafeMutableRawPointer
    ) {

        let runLoop =
            CFRunLoopGetCurrent()

        relativeMouseRunLoop =
            runLoop


        let eventMask: CGEventMask = (
            1 << CGEventType.mouseMoved.rawValue |
            1 << CGEventType.leftMouseDragged.rawValue |
            1 << CGEventType.rightMouseDragged.rawValue |
            1 << CGEventType.otherMouseDragged.rawValue
        )


        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: {
                (
                    _,
                    _,
                    event,
                    userInfo
                ) -> Unmanaged<CGEvent>? in

                guard
                    let userInfo = userInfo
                else {
                    return Unmanaged.passUnretained(
                        event
                    )
                }


                let manager =
                    Unmanaged<LockManager>
                        .fromOpaque(userInfo)
                        .takeUnretainedValue()


                /*
                 * 诊断：检测事件接收间隔。
                 *
                 * 正常 ~1ms（8000Hz 鼠标合并后），
                 * 超过 20ms 说明 EventTap 被阻塞。
                 */

                let now =
                    DispatchTime.now()
                        .uptimeNanoseconds

                let lastEvent =
                    manager.lastEventTimeNanos

                if lastEvent != 0 {

                    let gap =
                        now - lastEvent

                    if gap > 20_000_000 {

                        print(
                            "⚠️ [EventTap] 事件间隔 \(gap / 1_000_000)ms"
                        )
                    }

                    if gap > manager.maxEventGap {

                        manager.maxEventGap =
                            gap
                    }
                }

                manager.lastEventTimeNanos =
                    now

                manager.eventCount =
                    manager.eventCount &+ 1


                /*
                 * 从 CGEvent 中获取 delta。
                 *
                 * delta 是系统加速度处理后的像素位移，
                 * 累加后 Warp 即可，手感接近系统原生。
                 */

                let deltaX =
                    event.getDoubleValueField(
                        .mouseEventDeltaX
                    )

                let deltaY =
                    event.getDoubleValueField(
                        .mouseEventDeltaY
                    )


                manager.handleRelativeMouseDelta(
                    deltaX: CGFloat(deltaX),
                    deltaY: CGFloat(deltaY)
                )


                /*
                 * 诊断：周期性输出统计（每 1 秒）。
                 */

                if manager.lastStatsTimeNanos == 0 {

                    manager.lastStatsTimeNanos =
                        now
                } else if
                    now - manager.lastStatsTimeNanos
                        >= 1_000_000_000
                {

                    let elapsedSec =
                        Double(
                            now - manager.lastStatsTimeNanos
                        ) / 1_000_000_000

                    let hz =
                        Double(manager.eventCount) / elapsedSec

                    let warpHz =
                        Double(manager.warpCount) / elapsedSec

                    print(
                        "📊 [Stats] 事件 \(Int(hz))Hz | Warp \(Int(warpHz))Hz | 最大间隔 事件\(manager.maxEventGap / 1_000_000)ms Warp\(manager.maxWarpGap / 1_000_000)ms | 锁等待\(manager.maxLockWait / 1_000_000)ms | Warp耗时\(manager.maxWarpDuration / 1_000_000)ms"
                    )

                    manager.eventCount = 0
                    manager.warpCount = 0
                    manager.maxEventGap = 0
                    manager.maxWarpGap = 0
                    manager.maxLockWait = 0
                    manager.maxWarpDuration = 0
                    manager.lastStatsTimeNanos = now
                }


                return Unmanaged.passUnretained(
                    event
                )
            },
            userInfo: userInfo
        ) else {

            DispatchQueue.main.async {
                print(
                    "❌ Failed to create relative mouse Event Tap"
                )
            }

            relativeMouseRunLoop =
                nil

            installSemaphore.signal()

            return
        }


        let runLoopSource =
            CFMachPortCreateRunLoopSource(
                kCFAllocatorDefault,
                port,
                0
            )


        CFRunLoopAddSource(
            runLoop,
            runLoopSource,
            .commonModes
        )


        relativeEventTapPort =
            port

        relativeEventTapSource =
            runLoopSource


        DispatchQueue.main.async {
            print(
                "✅ EventTap (listenOnly) started on dedicated thread"
            )
        }


        /*
         * 通知主线程 EventTap 已就绪。
         */

        installSemaphore.signal()


        /*
         * 运行 RunLoop（阻塞，直到 CFRunLoopStop 被调用）。
         */

        CFRunLoopRun()


        /*
         * RunLoop 停止后，在此线程内清理所有资源。
         * 避免跨线程访问 port/source。
         */

        CFMachPortInvalidate(port)

        CFRunLoopRemoveSource(
            runLoop,
            runLoopSource,
            .commonModes
        )

        relativeEventTapPort =
            nil

        relativeEventTapSource =
            nil

        relativeMouseRunLoop =
            nil


        /*
         * 通知主线程线程已退出，清理完成。
         */

        exitSemaphore.signal()
    }


    private func removeRelativeMouseMonitor() {

        guard let runLoop =
            relativeMouseRunLoop
        else {
            return
        }


        /*
         * 停止 RunLoop，触发子线程清理。
         * 等待线程退出，确保 port/source 已被清理，
         * 避免下次 install 时竞态。
         */

        CFRunLoopStop(runLoop)

        exitSemaphore.wait()

        relativeMouseThread =
            nil
    }


    /*
     * 处理鼠标 delta，累加位置并限制在屏幕内。
     *
     * 异步 Warp 策略：
     *   - 每个事件只累加 delta + clamp（微秒级，无 IPC）
     *   - 不调用 Warp（由 warpTimer 异步执行）
     *   - 即使 8000Hz 鼠标事件流也无压力
     *
     * 位置由 positionLock 保护，warpTimer 线程会读取最新位置 Warp。
     */

    private func handleRelativeMouseDelta(
        deltaX: CGFloat,
        deltaY: CGFloat
    ) {

        guard isBoundaryActive else {
            return
        }


        guard let screenFrame =
            cachedScreenFrame
        else {
            return
        }


        /*
         * 累加 delta。
         *
         *   - Y 轴取反（CGEvent.deltaY 和 Cocoa 坐标方向相反）
         *   - 除以 scaleFactor（Retina 屏幕上 delta 是像素单位）
         */

        let scale =
            cachedScaleFactor

        let adjustedDeltaX =
            deltaX / scale

        let adjustedDeltaY =
            -deltaY / scale


        var newX =
            currentCursorPosition.x + adjustedDeltaX

        var newY =
            currentCursorPosition.y + adjustedDeltaY


        /*
         * 限制在屏幕边界内。
         */

        newX =
            min(
                max(
                    newX,
                    screenFrame.minX
                ),
                screenFrame.maxX
            )

        newY =
            min(
                max(
                    newY,
                    screenFrame.minY
                ),
                screenFrame.maxY
            )


        /*
         * 如果位置没变化，跳过。
         */

        let dx =
            newX - currentCursorPosition.x

        let dy =
            newY - currentCursorPosition.y

        if abs(dx) < 0.01 &&
            abs(dy) < 0.01
        {
            return
        }


        /*
         * 加锁更新累加位置。
         * warpTimer 线程会在下次 tick 时读取并 Warp。
         *
         * 诊断：测量锁等待时间，排查 Warp 线程长时间持锁导致的卡顿。
         */

        let lockWaitStart =
            DispatchTime.now()
                .uptimeNanoseconds

        positionLock.lock()

        let lockWaitEnd =
            DispatchTime.now()
                .uptimeNanoseconds

        let lockWait =
            lockWaitEnd - lockWaitStart

        if lockWait > 2_000_000 {

            print(
                "⚠️ [Delta] 锁等待 \(lockWait / 1_000_000)ms"
            )
        }

        if lockWait > maxLockWait {

            maxLockWait =
                lockWait
        }

        currentCursorPosition.x =
            newX

        currentCursorPosition.y =
            newY

        positionLock.unlock()
    }


    // ========================================================
    // MARK: Async Warp Timer
    // ========================================================

    /*
     * 启动异步 Warp 定时器。
     *
     * 250Hz（4ms）在专用队列上运行：
     *   - 250Hz > 160Hz 显示器，每帧至少 1 次 Warp
     *   - 专用队列与 EventTap 线程隔离，Warp 阻塞不影响事件接收
     *   - 8000Hz 鼠标事件流不再被 Warp IPC 拖慢
     */

    private func startWarpTimer() {

        guard warpTimer == nil else {
            return
        }


        let timer =
            DispatchSource.makeTimerSource(
                queue: warpQueue
            )

        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(4)
        )


        timer.setEventHandler { [weak self] in

            self?.warpIfNeeded()
        }


        timer.resume()

        warpTimer =
            timer
    }


    private func stopWarpTimer() {

        warpTimer?.cancel()

        warpTimer =
            nil
    }


    /*
     * 读取最新累加位置，如果与上次 Warp 位置不同则 Warp。
     *
     * 在 warpQueue 上运行，与 EventTap 线程通过 positionLock 同步。
     */

    private func warpIfNeeded() {

        guard isBoundaryActive else {
            return
        }


        /*
         * 诊断：测量 warpTimer 触发间隔。
         *
         * 无论是否真正执行 Warp，每次进入此函数都更新
         * lastWarpTimeNanos，这样测的才是 warpQueue 的
         * 真实调度间隔（正常 4ms / 250Hz）。
         *
         * 若 > 12ms 说明 warpQueue 被阻塞或 QoS 被降级。
         *
         * 注意：之前把更新放在函数末尾"真正 Warp 后"才更新，
         * 导致鼠标静止时 gap 一直累计到几百 ms，是误报。
         */

        let now =
            DispatchTime.now()
                .uptimeNanoseconds

        if lastWarpTimeNanos != 0 {

            let gap =
                now - lastWarpTimeNanos

            if gap > 12_000_000 {

                print(
                    "⚠️ [Warp] 触发间隔 \(gap / 1_000_000)ms"
                )
            }

            if gap > maxWarpGap {

                maxWarpGap =
                    gap
            }
        }

        lastWarpTimeNanos =
            now


        /*
         * 加锁读取最新位置。
         */

        positionLock.lock()

        let pos =
            currentCursorPosition

        positionLock.unlock()


        /*
         * 如果位置没变化，跳过 Warp。
         */

        let dx =
            pos.x - lastWarpPosition.x

        let dy =
            pos.y - lastWarpPosition.y

        if abs(dx) < 0.01 &&
            abs(dy) < 0.01
        {
            return
        }


        lastWarpPosition =
            pos


        /*
         * 移动光标到最新位置。
         *
         * 改用 CGDisplayMoveCursorToPoint 替代 CGWarpMouseCursorPosition：
         *   - 不触发 mouse-moved 事件，避免反馈循环
         *   - 可能走不同 IPC 路径，缓解高负载下的阻塞
         *
         * 坐标转换：
         *   - Cocoa Y → 全局 Quartz Y = globalMaxY - cocoaY
         *   - 全局 Quartz → display 本地 = global - displayOrigin
         *     （CGDisplayMoveCursorToPoint 接受相对于 display
         *      左上角的本地坐标）
         */

        guard let displayID =
            lockedDisplayID
        else {
            return
        }

        guard let displayOrigin =
            cachedScreenFrameInQuartz?.origin
        else {
            return
        }

        let globalQuartzX =
            pos.x

        let globalQuartzY =
            cachedGlobalMaxY - pos.y

        let localX =
            globalQuartzX - displayOrigin.x

        let localY =
            globalQuartzY - displayOrigin.y

        let warpStart =
            DispatchTime.now()
                .uptimeNanoseconds

        CGDisplayMoveCursorToPoint(
            displayID,
            CGPoint(
                x: localX,
                y: localY
            )
        )

        let warpEnd =
            DispatchTime.now()
                .uptimeNanoseconds

        let warpDuration =
            warpEnd - warpStart


        /*
         * 更新 Warp 诊断统计。
         *
         * lastWarpTimeNanos 已在函数开头更新（反映 warpTimer
         * 触发间隔），这里只统计真正执行的 Warp 次数和耗时。
         */

        warpCount =
            warpCount &+ 1

        if warpDuration > 5_000_000 {

            print(
                "⚠️ [Warp] 执行 \(warpDuration / 1_000_000)ms"
            )
        }

        if warpDuration > maxWarpDuration {

            maxWarpDuration =
                warpDuration
        }
    }


    // ========================================================
    // MARK: Screen Helpers
    // ========================================================

    private func lockedScreenFrame()
        -> CGRect?
    {

        guard let displayID =
            lockedDisplayID
        else {
            return nil
        }


        return NSScreen
            .screens
            .first {
                screen in

                guard let id =
                    Self.displayID(
                        for: screen
                    )
                else {
                    return false
                }

                return id == displayID
            }?
            .frame
    }


    /*
     * 预计算屏幕的 Quartz 坐标。
     *
     * CGEvent.location 使用 Quartz 坐标：
     *     原点在左上角，Y 向下。
     *
     * NSScreen.frame 使用 Cocoa 坐标：
     *     原点在左下角，Y 向上。
     */

    private func cacheScreenFrameInQuartz() {

        guard let cocoaFrame =
            lockedScreenFrame()
        else {

            cachedScreenFrameInQuartz =
                nil

            return
        }


        let totalHeight =
            NSScreen
                .screens
                .map { $0.frame.maxY }
                .max() ?? 0


        cachedScreenFrameInQuartz =
            CGRect(
                x: cocoaFrame.minX,
                y: totalHeight - cocoaFrame.maxY,
                width: cocoaFrame.width,
                height: cocoaFrame.height
            )


        if let qf =
            cachedScreenFrameInQuartz
        {

            print(
                "📐 Screen (Quartz): [\(String(format: "%.0f", qf.minX)), \(String(format: "%.0f", qf.minY)), \(String(format: "%.0f", qf.maxX)), \(String(format: "%.0f", qf.maxY))]"
            )
        }
    }


    // ========================================================
    // MARK: Application Selection
    // ========================================================

    func chooseApplication() {

        let panel =
            NSOpenPanel()


        panel.title =
            "选择需要限制的应用"


        panel.message =
            "只有所选应用处于前台时才启用鼠标锁定（按住 ⌘ 可多选）"


        panel.canChooseFiles =
            true


        panel.canChooseDirectories =
            false


        panel.allowsMultipleSelection =
            true


        panel.allowedContentTypes =
            [
                .application
            ]


        guard
            panel.runModal() == .OK,
            !panel.urls.isEmpty
        else {

            return
        }


        var newApps: [SelectedApp] = []


        for url in panel.urls {

            let bundle =
                Bundle(
                    url: url
                )


            let name =
                bundle?.object(
                    forInfoDictionaryKey:
                        "CFBundleDisplayName"
                ) as? String
                ??
                bundle?.object(
                    forInfoDictionaryKey:
                        "CFBundleName"
                ) as? String
                ??
                url
                    .deletingPathExtension()
                    .lastPathComponent


            let bundleID =
                bundle?.bundleIdentifier


            guard let id = bundleID else {
                continue
            }


            if
                selectedApplications.contains(
                    where: { $0.id == id }
                )
            {
                continue
            }


            newApps.append(
                SelectedApp(
                    id: id,
                    name: name,
                    path: url.path
                )
            )
        }


        selectedApplications.append(
            contentsOf:
                newApps
        )


        saveSelectedApplications()


        updateApplicationState()
    }


    func removeApplication(
        _ app: SelectedApp
    ) {

        selectedApplications.removeAll {
            $0.id == app.id
        }


        saveSelectedApplications()


        updateApplicationState()
    }


    private func saveSelectedApplications() {

        if let data = try? JSONEncoder().encode(
            selectedApplications
        ) {

            UserDefaults.standard.set(
                data,
                forKey:
                    selectedAppsKey
            )
        }
    }


    // ========================================================
    // MARK: Clear Application
    // ========================================================

    func clearApplication() {

        /*
         * 如果当前正在 Relative Mouse，
         * 先恢复系统鼠标。
         */

        disableBoundaryMode()


        selectedApplications =
            []


        UserDefaults.standard.removeObject(
            forKey:
                selectedAppsKey
        )


        isApplicationActive =
            true


        /*
         * 如果用户之前已经打开锁定，
         * 清除应用选择后恢复为“始终锁定”。
         */

        if isLocked {

            enableBoundaryMode()
        }
    }


    // ========================================================
    // MARK: Application Monitoring
    // ========================================================

    private func installWorkspaceMonitor() {

        let center =
            NSWorkspace.shared
                .notificationCenter


        /*
         * App 激活。
         */

        workspaceActivateObserver =
            center.addObserver(
                forName:
                    NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) {
                [weak self] _ in

                self?
                    .updateApplicationState()
            }


        /*
         * App 失活。
         *
         * 目标 App 一旦失去前台，
         * 立即恢复系统鼠标。
         */

        workspaceDeactivateObserver =
            center.addObserver(
                forName:
                    NSWorkspace.didDeactivateApplicationNotification,
                object: nil,
                queue: .main
            ) {
                [weak self] _ in

                self?
                    .updateApplicationState()
            }


        /*
         * Timer 作为保险。
         */

        applicationTimer =
            Timer.scheduledTimer(
                withTimeInterval:
                    0.25,
                repeats:
                    true
            ) {
                [weak self] _ in

                self?
                    .updateApplicationState()
            }
    }


    private func updateApplicationState() {

        /*
         * ----------------------------------------------------
         * 没有选择目标 App
         * ----------------------------------------------------
         */

        guard
            !selectedApplications.isEmpty
        else {

            isApplicationActive =
                true


            if isLocked {

                enableBoundaryMode()

            } else {

                disableBoundaryMode()
            }


            return
        }


        /*
         * ----------------------------------------------------
         * 查询当前前台 App
         * ----------------------------------------------------
         */

        let frontmostBundleID =
            NSWorkspace.shared
                .frontmostApplication?
                .bundleIdentifier


        let active =
            selectedApplications.contains {
                app in

                app.id == frontmostBundleID
            }


        /*
         * 更新 Published 状态。
         */

        if active !=
            isApplicationActive {

            isApplicationActive =
                active
        }


        /*
         * ----------------------------------------------------
         * 根据前台状态切换边界限制
         * ----------------------------------------------------
         */

        if isLocked &&
            active {

            enableBoundaryMode()

        } else {

            disableBoundaryMode()
        }
    }


    // ========================================================
    // MARK: Display Configuration
    // ========================================================

    private func installDisplayConfigurationMonitor() {

        displayConfigurationObserver =
            NotificationCenter.default
                .addObserver(
                    forName:
                        NSApplication.didChangeScreenParametersNotification,
                    object: nil,
                    queue: .main
                ) {
                    [weak self] _ in

                    guard let self else {
                        return
                    }


                    /*
                     * 屏幕配置变化时，
                     * 重新评估边界限制状态。
                     */

                    if self.isLocked {

                        self.updateApplicationState()
                    }
                }
    }


    // ========================================================
    // MARK: Keyboard Shortcut
    // ========================================================

    private func installKeyboardMonitor() {

        keyboardMonitor =
            NSEvent.addGlobalMonitorForEvents(
                matching:
                    .keyDown
            ) {
                [weak self]
                event in

                let flags =
                    event.modifierFlags
                        .intersection(
                            .deviceIndependentFlagsMask
                        )


                guard
                    flags.contains(
                        .command
                    ),
                    flags.contains(
                        .option
                    )
                else {

                    return
                }


                /*
                 * L = keyCode 37
                 *
                 * ⌥⌘L
                 */

                if event.keyCode == 37 {

                    self?.toggleLock()
                }
            }
    }


    private func removeKeyboardMonitor() {

        if let monitor =
            keyboardMonitor {

            NSEvent.removeMonitor(
                monitor
            )

            keyboardMonitor = nil
        }
    }


    // ========================================================
    // MARK: Accessibility
    // ========================================================

    private func requestAccessibilityPermission() {

        let options =
            [
                kAXTrustedCheckOptionPrompt
                    .takeUnretainedValue()
                    as String:
                        true
            ]
            as CFDictionary


        if !AXIsProcessTrustedWithOptions(
            options
        ) {

            print(
                """
                ⚠️ MouseDisplayLock 需要辅助功能权限。

                系统设置
                → 隐私与安全性
                → 辅助功能
                → MouseDisplayLock
                """
            )
        }
    }


    // ========================================================
    // MARK: Display ID
    // ========================================================

    private static func displayID(
        for screen: NSScreen
    ) -> CGDirectDisplayID? {

        return screen.deviceDescription[
            NSDeviceDescriptionKey(
                "NSScreenNumber"
            )
        ] as? CGDirectDisplayID
    }
}


// ============================================================
// MARK: - Content View
// ============================================================

struct ContentView: View {

    @ObservedObject
    var manager:
        LockManager


    var body: some View {

        VStack(
            alignment: .leading,
            spacing: 12
        ) {

            // ------------------------------------------------
            // Header
            // ------------------------------------------------

            HStack {

                Image(
                    systemName:
                        manager.menuBarIcon
                )
                .font(
                    .title2
                )


                VStack(
                    alignment: .leading,
                    spacing: 2
                ) {

                    Text(
                        "Mouse Display Lock"
                    )
                    .font(
                        .headline
                    )


                    Text(
                        manager.statusText
                    )
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        manager.statusColor
                    )
                }


                Spacer()
            }


            Divider()


            // ------------------------------------------------
            // Application
            // ------------------------------------------------

            Text(
                "应用限制"
            )
            .font(
                .caption
            )
            .foregroundStyle(
                .secondary
            )


            if manager.selectedApplications.isEmpty {

                HStack {

                    Image(
                        systemName:
                            "app"
                    )
                    .frame(
                        width: 24,
                        height: 24
                    )
                    .foregroundStyle(
                        .secondary
                    )


                    Text(
                        "未选择应用"
                    )
                    .foregroundStyle(
                        .secondary
                    )


                    Spacer()
                }

            } else {

                VStack(
                    spacing: 4
                ) {

                    ForEach(
                        manager.selectedApplications
                    ) {
                        app in

                        HStack {

                            Image(
                                nsImage:
                                    NSWorkspace
                                        .shared
                                        .icon(
                                            forFile:
                                                app.path
                                        )
                            )
                            .resizable()
                            .aspectRatio(
                                contentMode:
                                    .fit
                            )
                            .frame(
                                width: 20,
                                height: 20
                            )


                            Text(
                                app.name
                            )
                            .lineLimit(
                                1
                            )


                            Spacer()


                            Button {

                                manager.removeApplication(
                                    app
                                )

                            } label: {

                                Image(
                                    systemName:
                                        "xmark.circle.fill"
                                )
                                .foregroundStyle(
                                    .secondary
                                )
                            }
                            .buttonStyle(
                                .plain
                            )
                        }
                    }
                }
            }


            Button(
                "添加应用…"
            ) {

                manager.chooseApplication()
            }


            if !manager.selectedApplications.isEmpty {

                Button(
                    "清除所有应用"
                ) {

                    manager.clearApplication()
                }
            }


            Divider()


            // ------------------------------------------------
            // Status
            // ------------------------------------------------

            HStack {

                Circle()
                    .fill(
                        manager.statusColor
                    )
                    .frame(
                        width: 8,
                        height: 8
                    )


                Text(
                    manager.statusText
                )


                if let name =
                    manager.lockedDisplayName {

                    Text(
                        "· \(name)"
                    )
                    .foregroundStyle(
                        .secondary
                    )
                }


                Spacer()
            }


            // ------------------------------------------------
            // Lock
            // ------------------------------------------------

            Button {

                manager.toggleLock()

            } label: {

                HStack {

                    Image(
                        systemName:
                            manager.isLocked
                            ? "lock.open"
                            : "lock"
                    )


                    Text(
                        manager.isLocked
                        ? "解除锁定"
                        : "锁定当前显示器"
                    )


                    Spacer()


                    Text(
                        "⌥⌘L"
                    )
                    .foregroundStyle(
                        .secondary
                    )
                }
            }


            Divider()


            // ------------------------------------------------
            // Quit
            // ------------------------------------------------

            Button(
                "退出"
            ) {

                NSApplication.shared
                    .terminate(
                        nil
                    )
            }
        }
        .padding(
            16
        )
        .frame(
            width: 320
        )
    }
}
