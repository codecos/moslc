# NOTICE

## 本仓库的来历

本项目是 **Mos** 的修改版（fork），基于原作者 Caldis 的 Mos 源码。

- 上游项目：Mos — <https://github.com/Caldis/Mos>
- 上游版权：Copyright (c) 2017-2026 Caldis. All rights reserved.
- 基线版本：上游 `4.3.0-beta-20260820.1` 之后的源码快照（2026-11）
- 修改版：moslc（本仓库），最后修改 2026-11-22

## 许可证

本修改版沿用上游许可：**CC BY-NC 4.0**（Attribution-NonCommercial 4.0 International）。

- 协议全文：<https://creativecommons.org/licenses/by-nc/4.0/>
- 中文说明：<https://creativecommons.org/licenses/by-nc/4.0/deed.zh-hans>
- 本地副本：[LICENSE](LICENSE)

按协议要求，本文件用于履行 **署名（BY）** 与 **修改说明** 义务。本修改版**不得用于商业目的**，也不得发布到 App Store。

## 相对上游的修改点

以下为本修改版相对上述基线的全部已知差异。未列出的代码与资源与基线一致。

### 1. 平滑器：一阶插值 → 二阶临界阻尼低通（LC 等效）

`Mos/ScrollCore/ScrollPoster.swift`

上游每帧按 `Interpolator.lerp(current, buffer, duration)` 把位置拉向目标：位置连续，但速度在起步瞬间直接跳到最大，观感是“硬起步”。本修改版改成二阶临界阻尼系统：

```
x'' = ω² (target - x) - 2ζω x'    (ζ = 1)
ω   = 1.6 / τ
τ   = -1 / (60 · ln(1 - duration))   // 由原 duration 换算，到位时间贴近原手感
```

- 位置与速度都作为状态推进（`velocity`），速度从 0 连续上升、过峰后平滑衰减
- 每帧 4 个子步的半隐式欧拉积分，`ω·h` 在任意刷新率下都足够小，高刷不会发散
- 换向（`buffer` 反号）与 `brake()`（`ScrollPoster.swift:158`）时清零 `velocity` 与 `pending`，避免带着上一方向的速度冲过头
- 代价是帧间位移本身不均匀（起步小、中段大、尾部小），均匀性交给下一节的 sigma-delta 解决

### 2. sigma-delta 量化投递

位置是浮点的，但注入事件必须是整数 pt。上游在小数处直接取整、余量丢弃；本修改版把余量顺延：

- `pending` 累积未投递的小数位移，`out = pending.rounded()`，投出后 `pending -= out`（`ScrollPoster.swift:582` 起）
- 不足 1pt 的帧不投事件，同时把该帧时长累加进 `unpostedStepNs`；下次投递连时长一起补上，时间戳与位移不会错位
- 收敛判据同时看连续位置与量化余量：`residualMagnitude > deadZone`（`:556`）与 `outputSettled`（`:606`），保证余量小于死区才真正停止
- 60Hz 长测：401 / 400 / 403 帧，每帧均值 4.55~4.57pt，净位移 1823~1833pt，帧间隔 σ 2.42ms

### 3. 时间轴改为 vsync 驱动

`Mos/ScrollCore/ScrollPoster.swift`（`processing(hostTime:)`，`:448`）

| 项 | 上游 | 本修改版 |
| --- | --- | --- |
| dt 来源 | 回调被调起的时刻（`CFAbsoluteTimeGetCurrent`） | `CVDisplayLink` 的 `inOutputTime.hostTime`，即 vsync 时刻 |
| 标称帧长 | 硬编码 `1.0 / 60.0` | `nominalFrameInterval`（`:50`）读 `linkNominalHz`，取不到退回 60Hz |
| dt 钳位 | `[0.5, 1.5] × 16.67ms` | `[0.5, 3] × 本屏帧长`，上界再与 50ms 取小 |
| 预热窗口 | 固定 6 帧 | 按 ~100ms 折算（60Hz 仍 6 帧，144Hz 14 帧），预热期强制用标称帧长 |
| dt 平滑 | 每帧固定 25% | 60ms 时间常数 `1 - exp(-dt / 0.06)`，60Hz 下 α≈0.2425 |

上游的钳位在 144Hz 下会把真实 6.94ms 抬到 8.33ms（时间轴快 20%），240Hz 下快 100%，表现就是“换高刷屏后滚动变快、行程变短”。

### 4. 事件时间戳逐帧推进

上游一串平滑帧共享用户滚动那一刻的旧时间戳；接收方用它估计手势速度，时间戳不前进就被当成零速度。

- 每投一帧把时间戳推进一个 vsync 步长：`lastPostedTimestamp + frameStepNs`
- 相邻事件间隔因此严格等于刷新周期（60Hz 恒 16.67ms），接收方算出的速度稳定
- 只有落后真实时间超过 50ms（掉帧或时钟偏差）才重新对齐，不做逐帧对齐，避免把调度抖动写回间隔

### 5. 时间戳单位标定与同步投递

`Mos/ScrollCore/ScrollDispatchContext.swift`

- **单位现场标定**：不同系统/架构上 `CGEvent.timestamp` 可能是纳秒，也可能是 mach tick（24MHz）。capture 时用 `event.timestamp / clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` 求 `timestampScale`（限定在 0.01~1.5），注入时按它换算，避免时间戳落到未来或过去导致接收方跳帧
- **同步投递**：`enqueue` 由 `postQueue.async` 改为 `postQueue.sync`。投递必须在当帧合成之前落到目标进程；async 的队列唤醒延迟（几十微秒到几毫秒）会让同一帧内容有时更新 0 次、有时 2 次，观感是撕裂与一跳一顿

### 6. 模拟触控板默认开启

`Mos/Options/Options.swift`、`Mos/Utils/Constants.swift`

- `smoothSimTrackpad` 默认值 `false → true`
- 首次运行（该键未写入）跟随默认值，而不是 `bool(forKey:)` 得到的 `false`

理由：不带 phase 序列时接收方按“滚轮”处理，手感与触控板差一截。

### 7. 移除 Sparkle 更新通道

`Mos/Info.plist`、`Mos/Managers/UpdateManager.swift`

- 删除 `SUFeedURL` 与 `SUPublicEDKey`，`SUEnableAutomaticChecks` 设为 `false`
- 无 feed 时 `UpdateManager` 短路：`startingUpdater: false`，跳过启动检查

理由：本地改名分发版不接官方 appcast，否则会被官方更新包覆盖。

### 8. 应用标识改为独立 bundle id

`Mos.xcodeproj/project.pbxproj`

| 项 | 上游 | 本修改版 |
| --- | --- | --- |
| `PRODUCT_NAME`（Release） | `Mos` | `moslc` |
| `PRODUCT_NAME`（Debug） | `Mos` | `moslc Debug` |
| `PRODUCT_BUNDLE_IDENTIFIER` | `me.caldis.Mos` | `me.local.moslc`（Debug 为 `me.local.moslc.debug`） |

目的：与系统内已安装的官方 Mos 并存，偏好设置与辅助功能授权互不干扰。

随标识调整的字符串：

- `Mos/Shortcut/ShortcutExecutor.swift:556`：分布式通知名改为 `me.local.moslc.openTarget`
- `Mos/Logi/Debug/LogiDebugPanel.swift`：自动日志队列 label 与日志目录名同步为 `moslc`

## 未修改的部分

- 输入侧保持上游行为：`ScrollCore.swift` 的抬平（`1 line → step`）、加速度与放大系数、`Options` 其余默认值
- 界面、本地化以及备份/遥控等其他功能未改动

源码快照中还包含基线之后由上游提交的修复（例如修饰键族匹配 `#840`，涉及 `RecordedEvent.swift` 与 `ScrollCore.swift`），这些**不是**本修改版的改动，随快照原样保留。

## 免责

本修改版由第三方维护，与原作者 Caldis 无关，亦未获其背书。按 CC BY-NC 4.0 的 “No warranties” 条款，不提供任何形式的担保。
