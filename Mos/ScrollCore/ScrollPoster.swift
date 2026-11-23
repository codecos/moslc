//
//  ScrollPoster.swift
//  Mos
//
//  Created by Caldis on 2020/12/3.
//  Copyright © 2020 Caldis. All rights reserved.
//

import Cocoa
import os

class ScrollPoster {

    // 单例
    static let shared = ScrollPoster()
    init() { NSLog("Module initialized: ScrollPoster") }

    // 插值器
    private let filter = ScrollFilter()
    // 发送器
    private var poster: CVDisplayLink?
    // 滚动数据
    private var current = (y: 0.0, x: 0.0)  // 当前滚动距离
    private var delta = (y: 0.0, x: 0.0)  // 滚动方向记录
    private var buffer = (y: 0.0, x: 0.0)  // 滚动缓冲距离
    // 滚动配置
    private var shifting = false
    private var duration = Options.shared.scroll.durationTransition
    // 输入节奏追踪
    private var lastManualEventTime: CFTimeInterval = 0.0
    // 上一帧输出时间: duration 是按 60Hz 为基准的每帧比例, 需要按真实帧间隔换算
    private var lastFrameTime: CFTimeInterval = 0.0
    // CVDisplayLink 的 hostTime 换算成秒用的时钟频率
    private static let hostClockFrequency = CVGetHostClockFrequency()
    // 二阶低通(LC 等效)的速度状态: 与 current 同步推进, 保证位置与速度都连续
    private var velocity = (y: 0.0, x: 0.0)
    // sigma-delta 余量: 不足死区的位移留到后续帧, 不直接丢弃
    private var pending = (y: 0.0, x: 0.0)
    // sigma-delta 的量化余量与"未投递帧的累计时长"
    // 余量保留小数位移, 时长保留给时间戳, 二者一起顺延到下一次投递
    private var unpostedStepNs: Double = 0
    // 上一次注入事件的时间戳, 保证逐帧单调递增
    private var lastPostedTimestamp: CGEventTimestamp = 0
    private var manualInputEnded = true
    // 帧长预热计数: CVDisplayLink 启动初期的 timestamp 不可信, 这几帧强制用标称帧长
    private var warmupFrames = 0
    // 当前 display link 的标称帧长 (秒), 取不到时退回 60Hz。
    // 不能写死 1/60: 144Hz 下真实帧长 6.94ms 会被钳位抬到 8.33ms, 时间轴凭空快 20%,
    // 240Hz 下快 100% —— 表现就是"换高刷屏后滚动变快、行程变短", 与刷新率脱钩才算达标
    private var nominalFrameInterval: CFTimeInterval {
        guard let link = poster, linkNominalHz(link) > 1 else { return 1.0 / 60.0 }
        return 1.0 / linkNominalHz(link)
    }
    // 平滑后的帧长: 抑制 vsync 序列的孤立偏差
    private var smoothedFrameDt: CFTimeInterval = 0
    private var momentumActive = false
    private var momentumEndScheduledTime: CFTimeInterval? = nil
    private var trackingEndScheduledTime: CFTimeInterval? = nil
    // 阈值: 鼠标滚轮事件间隔低于 continuationThreshold 视为持续跟随
    //      介于 continuationThreshold 与 separationThreshold 之间模拟惯性衔接
    private let manualContinuationThreshold: CFTimeInterval = 0.18
    private let manualSeparationThreshold: CFTimeInterval = 0.45
    private let trackingEndAdvance: CFTimeInterval = 0.04
    private let momentumEndDelay: CFTimeInterval = 0.13
    // 状态锁和投递上下文
    private var stateLock = os_unfair_lock_s()
    private let dispatchContext = ScrollDispatchContext.shared
    // 滚动配置快照: 主线程在 update 时捕获, CVDisplayLink 线程只读, 避免热路径跨线程读 Options/ScrollCore
    private struct ConfigSnapshot {
        var deadZone: Double
    }
    private var config = ConfigSnapshot(deadZone: 1.0)
    // CVDisplayLink 恢复机制
    private var keeper: Timer?
    private var lastCallbackTime: CFTimeInterval = 0.0
    private var lastRecreateAttempt: CFTimeInterval = 0.0
    private let recreateCooldown: CFTimeInterval = 3.0
    // CVDisplayLink 刷新率自纠 (issue #958):
    // 显示器唤醒/重连时会先短暂报告过渡刷新率 (如先 60Hz 再升 144Hz), 若重建正好落在这个窗口,
    // 就会把 link 绑到偏低的刷新率, 使平滑滚动只按低帧率绘制 (卡顿), 而现有恢复机制识别不了.
    // 对策: 每次建立 link 后延迟复查若干次, 发现 link 标称率明显低于显示器实际率就重建追平.
    private var rateVerifyTimer: Timer?
    private var rateVerifyAttemptsLeft = 0
    private var isVerifying = false
    private let rateVerifyDelays: [TimeInterval] = [2.0, 4.0, 8.0]
    private let rateVerifyRatio = 0.7
    // 主线程访问, 无需锁
    var isAvailable: Bool { return poster != nil }
    // phase 写入判定的按进程缓存 (post 在 display link 线程, stop 在主线程, 需加锁)
    private let phaseGateLock = NSLock()
    private var phaseGateByPID: [pid_t: Bool] = [:]
    // 最近一次投递的目标进程: stop() 时可能没有可用的 pending 事件, 用它做兜底判定
    private var lastTargetPID: pid_t = 0
}

// MARK: - 滚动数据更新控制
extension ScrollPoster {
    func update(event: CGEvent, duration: Double, y: Double, x: Double, speed: Double, amplification: Double = 1) -> Self {
        guard dispatchContext.capture(event: event) else {
            return self
        }
        os_unfair_lock_lock(&stateLock)
        defer { os_unfair_lock_unlock(&stateLock) }
        // 捕获本次手势的配置快照 (主线程读 Options/ScrollCore, CVDisplayLink 线程只读)
        captureConfigSnapshotLocked()
        // 更新滚动配置
        self.duration = duration
        // 更新滚动数据
        if y*delta.y > 0 {
            buffer.y += y * speed * amplification
        } else {
            buffer.y = y * speed * amplification
            current.y = 0.0
            // 换向: 清零速度与余量, 否则二阶系统会带着上一方向的速度冲过头
            velocity.y = 0.0
            pending.y = 0.0
        }
        if x*delta.x > 0 {
            buffer.x += x * speed * amplification
        } else {
            buffer.x = x * speed * amplification
            current.x = 0.0
            velocity.x = 0.0
            pending.x = 0.0
        }
        delta = (y: y, x: x)
        let now = CFAbsoluteTimeGetCurrent()
        let interval = lastManualEventTime > 0.0 ? now - lastManualEventTime : nil
        let separatedByTime = interval == nil ? true : interval! >= manualSeparationThreshold
        let phase = ScrollPhase.shared.phase
        let separatedPhase = (phase == .Idle || phase == .Leave || phase == .MomentumEnd || phase == .TrackingEnd)
        let separated = manualInputEnded || separatedByTime || separatedPhase
        let plan = ScrollPhase.shared.onManualInputDetected(isSeparated: separated)
        perform(plan, emitTargetImmediately: false)
        lastManualEventTime = now
        manualInputEnded = false
        momentumActive = false
        momentumEndScheduledTime = nil
        trackingEndScheduledTime = nil
        return self
    }

    func updateShifting(enable: Bool) {
        os_unfair_lock_lock(&stateLock)
        shifting = enable
        os_unfair_lock_unlock(&stateLock)
    }
    func shift(with nextValue: ( y: Double, x: Double )) -> (y: Double, x: Double) {
        // 如果按下 Shift, 则始终将滚动转为横向
        if shifting {
            // 判断哪个轴有值, 有值则赋给 X
            // 某些鼠标 (MXMaster/MXAnywhere), 按下 Shift 后会显式转换方向为横向, 此处针对这类转换进行归一化处理
            if nextValue.y != 0.0 && nextValue.x == 0.0 {
                return (y: nextValue.x, x: nextValue.y)
            } else {
                return (y: nextValue.y, x: nextValue.x)
            }
        } else {
            return (y: nextValue.y, x: nextValue.x)
        }
    }
    func brake() {
        os_unfair_lock_lock(&stateLock)
        buffer = current
        // 刹车即停: 速度与未投递余量一起归零, 不留残余惯性
        velocity = (y: 0.0, x: 0.0)
        pending = (y: 0.0, x: 0.0)
        unpostedStepNs = 0
        perform(ScrollPhase.shared.onMomentumFinish(), emitTargetImmediately: true)
        manualInputEnded = true
        momentumActive = false
        momentumEndScheduledTime = nil
        os_unfair_lock_unlock(&stateLock)
    }
    func reset() {
        dispatchContext.invalidateAll()
        os_unfair_lock_lock(&stateLock)
        resetUnlocked()
        os_unfair_lock_unlock(&stateLock)
    }

#if DEBUG
    func captureConfigSnapshotForTests() {
        os_unfair_lock_lock(&stateLock)
        captureConfigSnapshotLocked()
        os_unfair_lock_unlock(&stateLock)
    }
    var configSnapshotForTests: Double {
        os_unfair_lock_lock(&stateLock)
        defer { os_unfair_lock_unlock(&stateLock) }
        return config.deadZone
    }

#endif

    private func resetUnlocked() {
        // 重置数值
        dispatchContext.clearContext()
        current = ( y: 0.0, x: 0.0 )
        delta = ( y: 0.0, x: 0.0 )
        buffer = ( y: 0.0, x: 0.0 )
        velocity = ( y: 0.0, x: 0.0 )
        pending = ( y: 0.0, x: 0.0 )
        unpostedStepNs = 0
        lastPostedTimestamp = 0
        // 重置插值器
        filter.reset()
        ScrollPhase.shared.reset()
        manualInputEnded = true
        momentumActive = false
        lastManualEventTime = 0.0
        lastFrameTime = 0.0
        momentumEndScheduledTime = nil
        trackingEndScheduledTime = nil
    }
}

// MARK: - 插值数据发送控制
extension ScrollPoster {
    // 初始化 CVDisplayLink
    func create() {
        // 清理旧的 CVDisplayLink
        if let old = poster {
            if CVDisplayLinkIsRunning(old) {
                CVDisplayLinkStop(old)
            }
            poster = nil
        }
        // 创建新的 CVDisplayLink, 检查返回值
        var newPoster: CVDisplayLink?
        let result = CVDisplayLinkCreateWithActiveCGDisplays(&newPoster)
        if result == kCVReturnSuccess, let validPoster = newPoster {
            CVDisplayLinkSetOutputCallback(validPoster, { (displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext) -> CVReturn in
                // 传入 vsync 时刻 (inOutputTime.hostTime), 而不是让 processing 自己取当前时间:
                // 回调实际被调起的时刻带有毫秒级抖动, 用它算 dt 会让每帧步长忽大忽小,
                // 位移序列不匀, 看起来就是"没有垂直同步"的抖动。
                ScrollPoster.shared.processing(hostTime: inOutputTime.pointee.hostTime)
                return kCVReturnSuccess
            }, nil)
            poster = validPoster
            // 建立成功后安排刷新率复查; 复查内部触发的重建 (isVerifying) 不重置复查序列
            if !isVerifying { scheduleRateVerify() }
        } else {
            poster = nil
            NSLog("ScrollPoster: CVDisplayLink creation failed (%d)", result)
        }
    }
    // 启动事件发送器
    func tryStart() {
        guard let validPoster = poster else {
            if !recreateDisplayLink() {
                // cooldown 拒绝了重建; 清理陈旧 buffer 防止恢复后滚动跳变
                reset()
            }
            return
        }
        if !CVDisplayLinkIsRunning(validPoster) {
            let result = CVDisplayLinkStart(validPoster)
            if result == kCVReturnSuccess {
                // 给 keeper 一个宽限期, 防止误判新启动的 poster 为僵尸
                os_unfair_lock_lock(&stateLock)
                lastCallbackTime = CFAbsoluteTimeGetCurrent()
                // CVDisplayLink 刚启动的前几帧 inOutputTime 序列不规整,
                // 这几帧固定用标称帧长, 避免"起步几帧走太少、下一帧走太多"。
                // 预热窗口按时间折算(约 100ms): 固定 6 帧在 144Hz 下只有 41ms, 跨不过异常期
                let startHz = linkNominalHz(validPoster)
                warmupFrames = max(3, Int(((startHz > 1 ? startHz : 60.0) * 0.1).rounded()))
                smoothedFrameDt = 0
                os_unfair_lock_unlock(&stateLock)
            } else {
                let _ = recreateDisplayLink()
            }
        }
    }
    // 停止事件发送器
    func stop(_ requestedPhase: Phase = Phase.MomentumEnd) {
        // 停止循环, 然后准备发送最后一次事件
        if let validPoster = poster {
            CVDisplayLinkStop(validPoster)
        }
        // 失效旧会话异步帧，收尾帧使用新代次
        dispatchContext.advanceGeneration()
        os_unfair_lock_lock(&stateLock)

        let plan: ScrollPhase.TransitionPlan
        if requestedPhase == Phase.MomentumEnd {
            plan = ScrollPhase.shared.onMomentumFinish()
        } else {
            plan = ScrollPhase.shared.onManualInputEnded()
        }

        // 发送结束事件: Chromium 系需要完整收尾序列, 其余应用只补一帧 TrackingEnd
        if shouldWriteScrollPhase(pid: lastKnownTargetPID()) {
            perform(plan, emitTargetImmediately: true)
        } else {
            if let snapshot = dispatchContext.preparePostingSnapshot(),
               shouldWriteScrollPhase(for: snapshot.event),
               let phaseValues = phaseValues(for: .TrackingEnd) {
                _ = post(
                    snapshot,
                    (y: 0.0, x: 0.0),
                    phaseOverride: phaseValues,
                    fallbackToCurrentPhase: false
                )
            }
        }
        manualInputEnded = true
        momentumActive = false
        // 重置参数 (不递增 generation, 保留本次收尾帧有效性)
        resetUnlocked()
        os_unfair_lock_unlock(&stateLock)
    }
    // 重建 CVDisplayLink (带冷却期)
    @discardableResult
    func recreateDisplayLink() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRecreateAttempt >= recreateCooldown else { return false }
        lastRecreateAttempt = now
        create()
        if let validPoster = poster {
            let result = CVDisplayLinkStart(validPoster)
            if result == kCVReturnSuccess {
                os_unfair_lock_lock(&stateLock)
                lastCallbackTime = CFAbsoluteTimeGetCurrent()
                os_unfair_lock_unlock(&stateLock)
            } else {
                NSLog("ScrollPoster: CVDisplayLink start failed after recreate (%d)", result)
            }
        }
        return true
    }
    // 守护定时器 (与 Interceptor 的 keeper 模式一致)
    func startKeeper() {
        keeper?.invalidate()
        keeper = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.healthCheck()
        }
    }
    func stopKeeper() {
        keeper?.invalidate()
        keeper = nil
        rateVerifyTimer?.invalidate()
        rateVerifyTimer = nil
        rateVerifyAttemptsLeft = 0
    }
    private func healthCheck() {
        guard let validPoster = poster else {
            recreateDisplayLink()
            return
        }
        if CVDisplayLinkIsRunning(validPoster) {
            os_unfair_lock_lock(&stateLock)
            let lastTime = lastCallbackTime
            os_unfair_lock_unlock(&stateLock)
            // lastTime > 0 避免首次回调前误判
            if lastTime > 0 && CFAbsoluteTimeGetCurrent() - lastTime > 2.0 {
                NSLog("ScrollPoster: zombie CVDisplayLink detected, recreating")
                recreateDisplayLink()
            }
        }
    }

    // MARK: 刷新率自纠 (见属性处说明)
    // 建立 link 后调用: 重置复查序列并安排第一次复查
    private func scheduleRateVerify() {
        rateVerifyAttemptsLeft = rateVerifyDelays.count
        armNextRateVerify()
    }
    private func armNextRateVerify() {
        rateVerifyTimer?.invalidate()
        guard rateVerifyAttemptsLeft > 0 else { rateVerifyTimer = nil; return }
        let delay = rateVerifyDelays[rateVerifyDelays.count - rateVerifyAttemptsLeft]
        rateVerifyTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.verifyRateAndFixIfNeeded()
        }
    }
    // 复查: link 标称率明显低于显示器实际率 -> 重建追平 (幂等, 不受 recreateCooldown 限制)
    private func verifyRateAndFixIfNeeded() {
        rateVerifyAttemptsLeft -= 1
        guard let current = poster else { rateVerifyTimer = nil; return }
        let nominal = linkNominalHz(current)
        let maxHz = maxActiveDisplayHz()
        guard nominal > 1, maxHz > 1, nominal < maxHz * rateVerifyRatio else {
            // 已追平显示器刷新率, 结束复查
            rateVerifyTimer = nil
            rateVerifyAttemptsLeft = 0
            return
        }
        NSLog("ScrollPoster: display link rate %.0fHz below display %.0fHz, recreating", nominal, maxHz)
        // 保持原运行状态: 若正在滚动 (running) 则重建后重新启动
        let wasRunning = CVDisplayLinkIsRunning(current)
        isVerifying = true
        create()
        isVerifying = false
        if wasRunning, let refreshed = poster {
            CVDisplayLinkStart(refreshed)
        }
        // 自纠说明显示器仍在过渡: 清除冷却, 让后续 screenChange 能及时用最终配置重建
        lastRecreateAttempt = 0
        // 这次重建可能仍落在过渡态, 继续后续复查直到追平或用尽次数
        armNextRateVerify()
    }
}

// MARK: - 数据处理及发送
private extension ScrollPoster {
    func perform(_ plan: ScrollPhase.TransitionPlan, emitTargetImmediately: Bool, delta: (y: Double, x: Double) = (0.0, 0.0)) {
        if plan.queue.isEmpty && plan.target == nil {
            return
        }
        for item in plan.queue {
            emitPhase(item, delta: delta)
        }
        if let target = plan.target {
            if emitTargetImmediately {
                emitPhase(target, delta: delta)
            } else {
                ScrollPhase.shared.apply(phase: target.0, autoAdvance: target.1)
            }
        }
    }

    func emitPhase(_ item: (Phase, Phase?), delta: (y: Double, x: Double)) {
        ScrollPhase.shared.apply(phase: item.0, autoAdvance: item.1)
        guard let snapshot = dispatchContext.preparePostingSnapshot() else {
            ScrollPhase.shared.didDeliverFrame()
            return
        }
        let phaseOverride = shouldWriteScrollPhase(for: snapshot.event) ? phaseValues(for: item.0) : nil
        _ = post(snapshot, delta, phaseOverride: phaseOverride, fallbackToCurrentPhase: false)
    }

    // 处理滚动事件
    // hostTime: CVDisplayLink 给出的 vsync 时刻 (mach absolute time), 0 表示不可用
    func processing(hostTime: UInt64 = 0) {
        var pendingStopPhase: Phase?
        os_unfair_lock_lock(&stateLock)
        let now = CFAbsoluteTimeGetCurrent()
        lastCallbackTime = now
        // 帧间隔以 vsync 时刻为准, 而不是回调被调起的时刻。
        // 系统调起回调有 ±2~3ms 抖动: 60Hz 下 dt 名义 16.67ms, 实测在 13~20ms 间浮动,
        // 同一份剩余距离乘上忽大忽小的 dt, 每帧位移就忽多忽少, 视觉上是不匀的抖动。
        // 用 inOutputTime 后 dt 恒等于刷新周期, 位移序列严格等间隔; 掉帧时 dt 自动变
        // 两倍并一次补足, 不会变慢。
        let nominalFrame = nominalFrameInterval
        let frameTime: CFTimeInterval
        if hostTime != 0, ScrollPoster.hostClockFrequency > 0 {
            frameTime = Double(hostTime) / ScrollPoster.hostClockFrequency
        } else if lastFrameTime > 0 {
            frameTime = lastFrameTime + nominalFrame
        } else {
            frameTime = 0
        }
        var dt = lastFrameTime > 0 ? min(0.05, max(0.001, frameTime - lastFrameTime)) : nominalFrame
        if warmupFrames > 0 {
            // 启动预热: CVDisplayLink 刚起来时 inOutputTime 会给出 5.6ms / 10.8ms 这类异常值,
            // 若直接采用, 起步几帧会走得过少、紧跟一帧又走过多, 正是"每次滚动开头一顿"的来源。
            dt = nominalFrame
            warmupFrames -= 1
        } else {
            // 稳定期收紧上下界, 基准必须是本屏真实帧长而不是 60Hz:
            // 下界 0.5 帧防止高刷屏的正常 dt 被抬到 8.33ms(时间轴会快 20%~100%),
            // 上界 3 帧允许掉 1~2 帧时 dt 变大补足步长(原 1.5 倍上限会把补足截掉一半)
            let upper = min(nominalFrame * 3.0, 0.05)
            dt = min(upper, max(nominalFrame * 0.5, dt))
        }
        // 再经一阶平滑: vsync 序列里仍有 8.33 / 18.15 这类孤立偏差,
        // 不平滑的话那一帧位移会突然减半或加倍, 观感就是"滚到一半卡一下"。
        if smoothedFrameDt <= 0 {
            smoothedFrameDt = dt
        } else {
            // 时间常数 60ms 的指数平滑(不是每帧固定 25%): 每帧固定比例在高刷下
            // 时间常数会被压到 28ms, 对孤立异常帧的抑制随之变弱
            let dtAlpha = min(1.0, 1.0 - exp(-dt / 0.06))
            smoothedFrameDt += (dt - smoothedFrameDt) * dtAlpha
        }
        dt = smoothedFrameDt
        lastFrameTime = frameTime
        let startY = current.y
        let startX = current.x
        // 二阶临界阻尼低通 (LC 等效): x'' = ω²(target - x) - 2ζω·x'
        // 这是"柔和"的来源: 速度从 0 连续上升、到峰值后平滑衰减, 没有硬起步。
        // 代价是帧间位移本身不相等 (起步小、中段大、尾部小), 均匀性交给下游的
        // sigma-delta 量化解决: 位置保持连续, 投递出去的永远是整数 pt。
        let base = min(max(duration, 0.001), 0.999)
        // 由一阶等效时间常数换算: τ = -1/(60·ln(1-base)), 取 ω = 1.6/τ 让到位时间贴近原手感
        let tau = -1.0 / (60.0 * log(1.0 - base))
        let omega = 1.6 / tau
        let zeta = 1.0
        // 4 个子步: 保证 ω·h 足够小, 半隐式欧拉在任意刷新率下都稳定
        let substeps = 4
        let h = dt / Double(substeps)
        for _ in 0..<substeps {
            let accY = omega * omega * (buffer.y - current.y) - 2.0 * zeta * omega * velocity.y
            velocity.y += accY * h
            current.y += velocity.y * h
            let accX = omega * omega * (buffer.x - current.x) - 2.0 * zeta * omega * velocity.x
            velocity.x += accX * h
            current.x += velocity.x * h
        }
        // 临界阻尼理论上不会越过目标, 这里只防数值误差造成的回弹。
        // 判据必须用 < 0: 过冲意味着 current 落到 buffer 的另一侧, 与 start 相对 buffer 的
        // 方向相反, 乘积才为负。写成 > 0 会把"还在起点与目标之间正常逼近"误判成过冲,
        // 每帧把 current 直接钳到 buffer, 平滑就退化成一步到位(实测首帧即走完全程)。
        if (startY - buffer.y) * (current.y - buffer.y) < 0 {
            current.y = buffer.y
            velocity.y = 0.0
        }
        if (startX - buffer.x) * (current.x - buffer.x) < 0 {
            current.x = buffer.x
            velocity.x = 0.0
        }
        // 本帧实际位移
        let frame = (
            y: current.y - startY,
            x: current.x - startX
        )
        // 平滑滚动结果: 二阶低通已给出连续速度, 不再叠加 5 点滑动滤波
        // (那个窗口固定滞后 4 帧, 60Hz 约 66ms, 是"反应慢"的主要来源)
        let filledValue = frame
        // 变换滚动结果，将滤波后的插值映射到当前姿态（考虑灵敏度、方向等因素）
        let shiftedValue = shift(with: filledValue)
        // 检测是否已经超过手动输入的持续时间阈值，准备结束手动阶段
        if !manualInputEnded && lastManualEventTime > 0.0 && now - lastManualEventTime > manualContinuationThreshold {
            let endPlan = ScrollPhase.shared.onManualInputEnded()
            if !(endPlan.queue.isEmpty && endPlan.target == nil) {
                perform(endPlan, emitTargetImmediately: true)
            }
            manualInputEnded = true
            if trackingEndScheduledTime == nil {
                trackingEndScheduledTime = now + trackingEndAdvance
            }
        }
        // 计算缓冲值与当前位置的剩余距离，用于判断滚动是否已收敛
        // 已走完但尚未投递的 sigma-delta 余量也计入, 否则尾部零点几像素会被判为收敛而丢掉
        let residualY = buffer.y - current.y
        let residualX = buffer.x - current.x
        let residualMagnitude = max(
            residualY.magnitude + abs(pending.y),
            residualX.magnitude + abs(pending.x)
        )
        let deadZone = config.deadZone
        if manualInputEnded && residualMagnitude > deadZone {
            if !momentumActive {
                perform(ScrollPhase.shared.onMomentumStart(), emitTargetImmediately: false)
                momentumActive = true
            } else {
                perform(ScrollPhase.shared.onMomentumOngoing(), emitTargetImmediately: false)
            }
            momentumEndScheduledTime = nil
            trackingEndScheduledTime = nil
        } else if momentumActive && residualMagnitude <= deadZone {
            if momentumEndScheduledTime == nil {
                momentumEndScheduledTime = now + momentumEndDelay
            }
        } else {
            momentumEndScheduledTime = nil
            if momentumActive {
                momentumActive = false
            }
        }
        // 发送滚动结果: sigma-delta 量化调制
        // 每帧算出来的是分数位移 (例如 2.7pt)。直接投递这个分数, 接收方只能做亚像素插值:
        // 2.7pt 落在半像素上, 每帧的光栅化相位都不同, 边缘和文字随之闪烁,
        // 观感就是"显卡渲染不均匀/撕裂"。这里把位移累加成整数再发, 余量留在 pending:
        //   2.7 → +3 (余 -0.3) → +2.4 → +2 (余 0.4) → +3.1 → +3 (余 0.1) ...
        // 输出序列 3,2,3,3,2,3…, 长期平均严格等于 2.7, 而每一次投递都是整数 pt,
        // Retina 下即整数物理像素, 光栅化相位稳定 —— 这才是"每帧屏幕移动相同的像素数"。
        pending.y += shiftedValue.y
        pending.x += shiftedValue.x
        let outY = pending.y.rounded()
        let outX = pending.x.rounded()
        // 未被量化的帧, 其时长要累积到下一次投递, 否则时间戳会落后于位移
        unpostedStepNs += dt * 1_000_000_000.0
        if outY != 0 || outX != 0 {
            _ = post((y: outY, x: outX), frameStepNs: unpostedStepNs)
            pending.y -= outY
            pending.x -= outX
            unpostedStepNs = 0
        }
        // 量化后剩下的余量 (不足 1pt), 用于收敛判断
        let outputMagnitude = max(abs(pending.y), abs(pending.x))

        if let scheduled = momentumEndScheduledTime, momentumActive {
            if now >= scheduled {
                momentumEndScheduledTime = nil
                momentumActive = false
                pendingStopPhase = .MomentumEnd
            }
        }
        if pendingStopPhase == nil && manualInputEnded && !momentumActive && residualMagnitude <= deadZone {
            let pendingStop = trackingEndScheduledTime != nil && now >= trackingEndScheduledTime!
            let outputSettled = outputMagnitude <= deadZone
            if pendingStop && outputSettled {
                trackingEndScheduledTime = nil
                pendingStopPhase = .TrackingEnd
            }
        } else {
            trackingEndScheduledTime = nil
        }
        os_unfair_lock_unlock(&stateLock)
        if let phase = pendingStopPhase {
            stop(phase)
            return
        }
    }

    /// 主线程读取当前 (全局 / 例外应用) 配置存入快照。调用方须持有 stateLock。
    func captureConfigSnapshotLocked() {
        config = ConfigSnapshot(deadZone: Options.shared.scroll.deadZone)
    }

    // 是否需要为目标应用写入完整 phase 序列。
    // Chromium 系 (Chrome 本体以及 Electron / CEF 应用) 会解析 phase, 缺少 Began/Ended
    // 时不 commit 滚动; 其余应用保持原版 Mos 形态(不写 phase), 避免个别应用收到非零
    // phase 反而把事件整体丢弃。判定按进程缓存, 只在首次遇到时做一次 bundle 检查。
    func shouldWriteScrollPhase(for event: CGEvent) -> Bool {
        shouldWriteScrollPhase(pid: pid_t(event.getIntegerValueField(.eventTargetUnixProcessID)))
    }

    func shouldWriteScrollPhase(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        phaseGateLock.lock()
        lastTargetPID = pid
        let cached = phaseGateByPID[pid]
        phaseGateLock.unlock()
        if let cached { return cached }
        let verdict = Self.isChromiumApplication(pid: pid)
        phaseGateLock.lock()
        if phaseGateByPID.count > 64 { phaseGateByPID.removeAll(keepingCapacity: true) }
        phaseGateByPID[pid] = verdict
        phaseGateLock.unlock()
        return verdict
    }

    func lastKnownTargetPID() -> pid_t {
        phaseGateLock.lock()
        defer { phaseGateLock.unlock() }
        return lastTargetPID
    }

    private static func isChromiumApplication(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return isChromiumBundle(bundleIdentifier: app.bundleIdentifier, bundleURL: app.bundleURL)
    }

    /// 纯判定, 便于单测: Chrome 本体按 bundleID, Electron / CEF 按框架目录。
    static func isChromiumBundle(bundleIdentifier: String?, bundleURL: URL?) -> Bool {
        if bundleIdentifier == "com.google.Chrome" { return true }
        guard let bundleURL else { return false }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
        let candidates = [
            "Electron Framework.framework",
            "Chromium Embedded Framework.framework",
            "Google Chrome Framework.framework",
            "Chromium Framework.framework"
        ]
        return candidates.contains {
            FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path)
        }
    }

    func phaseValues(for phase: Phase) -> (scroll: Double, momentum: Double)? {
        guard let scrollValue = PhaseValueMapping[phase]?[.Scroll],
              let momentumValue = PhaseValueMapping[phase]?[.Momentum] else {
            return nil
        }
        return (scroll: scrollValue, momentum: momentumValue)
    }

    @discardableResult
    func post(_ snapshot: ScrollDispatchContext.PostingSnapshot, _ v: (y: Double, x: Double), phaseOverride: (scroll: Double, momentum: Double)? = nil, fallbackToCurrentPhase: Bool = true, frameStepNs: Double = 0) -> Bool {
        if let override = phaseOverride {
            snapshot.event.setDoubleValueField(.scrollWheelEventScrollPhase, value: override.scroll)
            snapshot.event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: override.momentum)
        } else if fallbackToCurrentPhase,
                  shouldWriteScrollPhase(for: snapshot.event),
                  let currentPhaseValues = phaseValues(for: ScrollPhase.shared.phase) {
            snapshot.event.setDoubleValueField(.scrollWheelEventScrollPhase, value: currentPhaseValues.scroll)
            snapshot.event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: currentPhaseValues.momentum)
        }
        snapshot.event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: v.y)
        snapshot.event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: v.x)
        // 是否连续滚动: 始终为 1.0
        snapshot.event.setDoubleValueField(.scrollWheelEventIsContinuous, value: 1.0)
        // 逐帧刷新事件时间戳。模板取自用户滚下那一刻的原始事件, 若不更新, 一串平滑帧
        // 会共享同一个旧时间戳; 接收方用它估算手势速度, 时间戳不前进就被当成零速度。
        // 单位用 capture 时标定的系数换算, 避免写死纳秒/mach tick 导致时间戳跳到未来。
        // 时间戳按"上一帧 + 本帧时间步长"推进, 而不是取发送瞬间。
        // frameStepNs 来自 displayLink 的 vsync 间隔, 因此相邻事件的间隔严格等于刷新周期
        // (60Hz 恒 16.67ms)。接收方用时间戳做速度估计/插值, 间隔一旦等长, 同样的位移
        // 就算出同样的速度; 取发送瞬间则会把 postQueue 的调度抖动一并写进事件。
        // 首帧或无步长时退回真实时间, 保证与系统时钟同基准、不会落到未来。
        let nowTimestamp = CGEventTimestamp(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * snapshot.timestampScale)
        var ts: CGEventTimestamp
        if frameStepNs > 0, lastPostedTimestamp > 0 {
            ts = lastPostedTimestamp &+ CGEventTimestamp(frameStepNs * snapshot.timestampScale)
            // 只在落后真实时间超过 50ms 时重新对齐(说明中途掉帧或时钟频率有偏差),
            // 不做逐帧对齐, 否则等间隔会被真实时间的抖动带回去。
            if nowTimestamp > ts, nowTimestamp - ts > CGEventTimestamp(50_000_000.0 * snapshot.timestampScale) {
                ts = nowTimestamp
            }
        } else {
            ts = nowTimestamp
        }
        if ts <= lastPostedTimestamp {
            ts = lastPostedTimestamp &+ 1
        }
        snapshot.event.timestamp = ts
        lastPostedTimestamp = ts
        // 行增量(DeltaAxis)保持模板原值, 不清零。
        // 清零行增量是"模拟真实触控板"的做法, 但有一部分应用(跨平台引擎、SDL/Qt 系、
        // 自绘游戏)只读 deltaY, 不看 scrollingDeltaY; 收到行增量为 0 的事件会直接判为
        // 空事件丢弃, 表现就是完全滚不动 —— 这正是"开启模拟触控板后所有应用都不滚"的原因。
        // 但 FixedPtDelta 必须跟随真实位移: 它对应 NSEvent.deltaY(定点行增量), 若保留
        // 模板残值, 只读该字段的接收方(典型如 Electron 系)每帧只会看到恒定的零点几行,
        // 同样表现为滚不动。两者职责不同, 不能一起删。
        snapshot.event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: v.y)
        snapshot.event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: v.x)
        ScrollUtils.shared.markSyntheticSmoothEvent(snapshot.event)
        // 通过 CGEventPostToPid 直投目标进程:
        // 不依赖 proxy (消除崩溃), 不经过 tap 链重新路由 (动量不跟随光标)
        // ref: @shichangone MR: https://github.com/Caldis/Mos/pull/523, issue #868
        dispatchContext.enqueue(snapshot)
        ScrollPhase.shared.didDeliverFrame()
        return true
    }

    @discardableResult
    func post(_ v: (y: Double, x: Double), phaseOverride: (scroll: Double, momentum: Double)? = nil, fallbackToCurrentPhase: Bool = true, frameStepNs: Double = 0) -> Bool {
        guard let snapshot = dispatchContext.preparePostingSnapshot() else {
            return false
        }
        return post(
            snapshot,
            v,
            phaseOverride: phaseOverride,
            fallbackToCurrentPhase: fallbackToCurrentPhase,
            frameStepNs: frameStepNs
        )
    }
}

// MARK: - 显示器刷新率查询 (刷新率自纠使用)
private extension ScrollPoster {
    /// CVDisplayLink 当前绑定显示器的标称刷新率 (Hz); 无效返回 -1
    func linkNominalHz(_ link: CVDisplayLink) -> Double {
        let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
        // 无效/indefinite 周期时 timeValue 或 timeScale 为 0
        guard period.timeValue != 0, period.timeScale != 0 else { return -1 }
        let seconds = Double(period.timeValue) / Double(period.timeScale)
        return seconds > 0 ? 1.0 / seconds : -1
    }
    /// 当前活跃显示器里最高刷新率 (Hz); 取不到返回 -1
    func maxActiveDisplayHz() -> Double {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return -1 }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return -1 }
        var mx = -1.0
        for id in ids.prefix(Int(count)) {
            if let hz = CGDisplayCopyDisplayMode(id)?.refreshRate, hz > mx { mx = hz }
        }
        return mx
    }
}
