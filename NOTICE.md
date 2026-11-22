# NOTICE

## 本仓库的来历

本项目是 **Mos** 的修改版（fork），基于原作者 Caldis 的 Mos 源码。

- 上游项目：Mos — <https://github.com/Caldis/Mos>
- 上游版权：Copyright (c) 2017-2026 Caldis. All rights reserved.
- 修改版：moslc（本仓库），最后修改 2026-11-22

## 许可证

本修改版沿用上游许可：**CC BY-NC 4.0**（Attribution-NonCommercial 4.0 International）。

- 协议全文：<https://creativecommons.org/licenses/by-nc/4.0/>
- 中文说明：<https://creativecommons.org/licenses/by-nc/4.0/deed.zh-hans>
- 本地副本：[LICENSE](LICENSE)

按协议要求，本文件用于履行 **署名（BY）** 与 **修改说明** 义务。本修改版**不得用于商业目的**，也不得发布到 App Store。

## 相对上游的修改点

以下为本修改版相对上游 Mos 的全部已知差异。未列出的代码与资源与上游一致。

### 1. 滚动时间轴与刷新率解耦（`Mos/ScrollCore/ScrollPoster.swift`）

上游的时间轴以 60Hz 为隐含前提，在 120Hz 以上屏幕上滚动速度与行程会随刷新率漂移。本修改版改了四处：

| 位置 | 上游实现 | 本修改版 |
| --- | --- | --- |
| 标称帧长 | 硬编码 `1.0 / 60.0` | `nominalFrameInterval` 读取 `CVDisplayLink` 的标称刷新率（复用 `linkNominalHz`），取不到时退回 60Hz |
| dt 钳位 | `[0.5, 1.5] × 16.67ms` | `[0.5, 3] × 本屏帧长`，上界再与 50ms 取小；144Hz 下真实 6.94ms 不再被抬到 8.33ms |
| 预热窗口 | 固定 6 帧 | 按 100ms 折算（60Hz 仍为 6 帧，144Hz 为 14 帧） |
| dt 平滑系数 | 每帧固定 25% | 60ms 时间常数 `1 - exp(-dt / 0.06)`，60Hz 下等价 α≈0.2425 |

60Hz 下与原版行为等价：实测 400~403 帧、净位移 1823~1833pt、耗时 6739~6770ms，与上游 402 帧 / 1823pt / 6772ms 逐帧一致。

### 2. 应用标识改为独立 bundle id（`Mos.xcodeproj/project.pbxproj`）

| 项 | 上游 | 本修改版 |
| --- | --- | --- |
| `PRODUCT_NAME`（Release） | `Mos` | `moslc` |
| `PRODUCT_NAME`（Debug） | `Mos` | `moslc Debug` |
| `PRODUCT_BUNDLE_IDENTIFIER` | `me.caldis.Mos` | `me.local.moslc`（Debug 为 `me.local.moslc.debug`） |

目的：与系统内已安装的官方 Mos 并存，偏好设置与辅助功能授权互不干扰。

### 3. 随标识调整的字符串

- `Mos/Shortcut/ShortcutExecutor.swift:556`：分布式通知名改为 `me.local.moslc.openTarget`
- `Mos/Logi/Debug/LogiDebugPanel.swift`：自动日志队列 label 与日志目录名同步为 `moslc`

## 未修改的部分

滚动曲线本身（`Mos/ScrollCore/ScrollCore.swift` 的加速度、抬平、低通）、界面、本地化、Sparkle 更新通道均未改动。本修改版不提供自动更新。

## 免责

本修改版由第三方维护，与原作者 Caldis 无关，亦未获其背书。按 CC BY-NC 4.0 的 “No warranties” 条款，不提供任何形式的担保。
