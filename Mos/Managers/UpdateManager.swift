//
//  UpdateManager.swift
//  Mos
//  Updates management via Sparkle
//

import Cocoa
import Sparkle

final class UpdateManager: NSObject {

    static let shared = UpdateManager()

    /// 本地改名分发版不再声明 SUFeedURL（避免被官方 appcast 覆盖），
    /// Sparkle 在没有 feed 时启动会报"未配置更新源"，因此整条更新链路直接短路。
    private static let isUpdateChannelAvailable: Bool = {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else { return false }
        return !feed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }()

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: Self.isUpdateChannelAvailable,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private override init() {
        super.init()
        NSLog("Module initialized: UpdateManager")
    }
}

extension UpdateManager {

    func scheduleCheckOnAppStartIfNeeded() {
        guard Self.isUpdateChannelAvailable else { return }
        guard Options.shared.update.checkOnAppStart else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        guard Self.isUpdateChannelAvailable else { return }
        updaterController.checkForUpdates(nil)
    }

    func checkForUpdatesInBackground() {
        guard Self.isUpdateChannelAvailable else { return }
        updaterController.updater.checkForUpdatesInBackground()
    }
}

extension UpdateManager: SPUUpdaterDelegate {

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Options.shared.update.includingBetaVersion ? ["beta"] : []
    }
}

