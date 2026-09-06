//
//  LCAppBannerViewController.swift
//  LiveContainerSwiftUI
//

import Foundation
import SwiftUI
import UIKit

struct LCAppBannerConfiguration {
    let model: LCAppModel
    let dynamicColors: Bool
    let darkModeIcon: Bool
}


final class LCAppBannerViewController: UIViewController, UIContextMenuInteractionDelegate, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        
    private let delegate: LCAppBannerDelegate
    private let bannerView = LCAppBannerRootView()
    private var configuration: LCAppBannerConfiguration
    private var exportTemporaryDirectory: URL?
    
    init(delegate: LCAppBannerDelegate, config: LCAppBannerConfiguration) {
        self.delegate = delegate
        self.configuration = config
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = bannerView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        preferredContentSize = CGSize(width: 0, height: LCAppBannerRootView.bannerHeight)
        bannerView.runControl.addTarget(self, action: #selector(runButtonTapped), for: .touchUpInside)
        bannerView.addInteraction(UIContextMenuInteraction(delegate: self))

        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(bannerDoubleTapped))
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.cancelsTouchesInView = false
        bannerView.addGestureRecognizer(doubleTapGesture)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection == nil || traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            refreshView()
        }
    }

    deinit {
        cleanupExportTemporaryDirectory()
    }

    func update(
        model: LCAppModel,
        dynamicColors: Bool,
        darkModeIcon: Bool
    ) {
        loadViewIfNeeded()
        configuration = LCAppBannerConfiguration(
            model: model,
            dynamicColors: dynamicColors,
            darkModeIcon: darkModeIcon
        )
        refreshView()
    }

    private func refreshView() {
        bannerView.update(
            model: configuration.model,
            appInfo: configuration.model.appInfo,
            dynamicColors: configuration.dynamicColors,
            darkModeIcon: configuration.darkModeIcon,
            traitCollection: traitCollection
        )
    }

    @objc private func bannerDoubleTapped(_ gestureRecognizer: UITapGestureRecognizer) {
        let location = gestureRecognizer.location(in: bannerView.runControl)
        guard !bannerView.runControl.bounds.contains(location) else {
            return
        }
        openSettings()
    }

    @objc private func runButtonTapped() {
        if #available(iOS 16.0, *),
           let currentDataFolder = configuration.model.uiSelectedContainer?.folderName,
           MultitaskManager.isUsing(container: currentDataFolder) {
            var found = false
            if #available(iOS 16.1, *) {
                found = MultitaskWindowManager.openExistingAppWindow(dataUUID: currentDataFolder)
            }
            if !found {
                found = MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: currentDataFolder)
            }
            if found {
                return
            }
        }

        Task { [weak self] in
            await self?.runApp()
        }
    }

    private func runApp(multitask: Bool? = nil) async {
        if configuration.model.appInfo.isLocked && !DataManager.shared.model.isHiddenAppUnlocked {
            do {
                if !(try await LCUtils.authenticateUser()) {
                    return
                }
            } catch {
                showError(error.localizedDescription)
                return
            }
        }

        do {
            try await configuration.model.runApp(multitask: multitask)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func makeContextMenu() -> UIMenu {
        let model = configuration.model
        let appInfo = model.appInfo
        var menuChildren: [UIMenuElement] = []

        // 1. Containers Picker (Equivalent to a Menu with single selection)
        if model.uiContainers.count > 1 {
            let containerActions = model.uiContainers.map { [weak self] container in
                UIAction(
                    title: container.name,
                    state: container == model.uiSelectedContainer ? .on : .off
                ) { _ in
                    model.uiSelectedContainer = container
                    self?.refreshView()
                }
            }
            menuChildren.append(UIMenu(title: "Containers", options: .displayInline, children: containerActions))
        }

        // 2. Main Section
        var sectionChildren: [UIMenuElement] = []
        if !model.uiIsShared, model.uiSelectedContainer != nil {
            sectionChildren.append(UIAction(
                title: "lc.appBanner.openDataFolder".loc,
                image: UIImage(systemName: "folder")
            ) { [weak self] _ in
                self?.openDataFolder()
            })
        }

        // Multitask Toggle
        if #available(iOS 16.0, *) {
            let shouldLaunchInMultitaskMode = model.shouldLaunchInMultitaskMode
            sectionChildren.append(UIAction(
                title: shouldLaunchInMultitaskMode ? "lc.appBanner.run".loc : "lc.appBanner.multitask".loc,
                image: UIImage(systemName: shouldLaunchInMultitaskMode ? "play.fill" : "macwindow.badge.plus")
            ) { [weak self] _ in
                Task { [weak self] in
                    await self?.runApp(multitask: !shouldLaunchInMultitaskMode)
                }
            })
        }

        let addToHomeScreenMenu = UIMenu(
            title: "lc.appBanner.addToHomeScreen".loc,
            image: UIImage(systemName: "plus.app"),
            children: [
                UIAction(title: "lc.appBanner.copyLaunchUrl".loc, image: UIImage(systemName: "link")) { [weak self] _ in
                    self?.copyLaunchUrl()
                },
                UIAction(title: "lc.appBanner.saveAppIcon".loc, image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                    Task { [weak self] in
                        await self?.saveIcon()
                    }
                },
                UIAction(title: "lc.appBanner.createAppClip".loc, image: UIImage(systemName: "appclip")) { [weak self] _ in
                    Task { [weak self] in
                        await self?.createAppClip()
                    }
                }
            ]
        )
        sectionChildren.append(addToHomeScreenMenu)

        sectionChildren.append(UIAction(
            title: "lc.tabView.settings".loc,
            image: UIImage(systemName: "gear")
        ) { [weak self] _ in
            self?.openSettings()
        })

        if !model.uiIsShared {
            sectionChildren.append(UIAction(
                title: "lc.appBanner.uninstall".loc,
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                Task { [weak self] in
                    await self?.uninstall()
                }
            })
        }

        menuChildren.append(UIMenu(
            title: appInfo.relativeBundlePath ?? "",
            options: .displayInline,
            children: sectionChildren
        ))
        return UIMenu(title: "", children: menuChildren)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.makeContextMenu()
        }
    }

    private func openSettings() {
        delegate.openNavigationView(view: AnyView(LCAppSettingsView(model: configuration.model)))
    }

    private func openDataFolder() {
        guard let folderName = configuration.model.uiSelectedContainer?.folderName,
              let url = URL(string: "shareddocuments://\(LCPath.dataPath.path)/\(folderName)") else {
            return
        }
        UIApplication.shared.open(url)
    }

    private func uninstall() async {
        let appInfo = configuration.model.appInfo
        let displayName = appInfo.displayName() ?? configuration.model.displayName
        let shouldUninstall = await presentConfirmation(
            title: "lc.appBanner.confirmUninstallTitle".loc,
            message: "lc.appBanner.confirmUninstallMsg %@".localizeWithFormat(displayName),
            confirmTitle: "lc.appBanner.uninstall".loc,
            cancelTitle: "lc.common.cancel".loc
        )
        guard shouldUninstall == true else {
            return
        }

        var shouldRemoveAppFolders = false
        let containers = appInfo.containers
        if !containers.isEmpty {
            shouldRemoveAppFolders = await presentConfirmation(
                title: "lc.appBanner.deleteDataTitle".loc,
                message: "lc.appBanner.deleteDataMsg %@".localizeWithFormat(displayName),
                confirmTitle: "lc.common.delete".loc,
                cancelTitle: "lc.common.no".loc
            ) == true
        }

        do {
            guard let bundlePath = appInfo.bundlePath() else {
                throw CocoaError(.fileNoSuchFile)
            }

            let fileManager = FileManager.default
            // Read these before deleting the bundle. Guest App Group data is
            // stored outside Data/Application/<container UUID>, so it cannot
            // be discovered after the app bundle is gone.
            let appGroupIdentifiers = applicationGroupIdentifiers(for: appInfo)
            let dataUUIDs = Set(containers.map(\.folderName).filter { !$0.isEmpty })

            try fileManager.removeItem(atPath: bundlePath)
            delegate.removeApp(app: configuration.model)

            if shouldRemoveAppFolders {
                var cleanupErrors: [Error] = []
                for container in containers {
                    let dataUUID = container.folderName
                    do {
                        try removeContainerData(container, fileManager: fileManager)
                    } catch {
                        cleanupErrors.append(error)
                    }

                    // Clean both the current keychain namespace and the
                    // legacy host-defaults preference bucket.
                    LCUtils.removeAppKeychain(dataUUID: dataUUID)
                    LCSharedUtils.removeLegacyPreferences(forDataUUID: dataUUID)
                    DataManager.shared.model.appDataFolderNames.removeAll { $0 == dataUUID }
                }

                // App Group data lives outside the container directory. Only
                // remove a group when no remaining installed app declares the
                // same group, otherwise shared app data could be destroyed.
                do {
                    try removeUnusedAppGroupData(
                        appGroupIdentifiers,
                        excluding: configuration.model,
                        fileManager: fileManager
                    )
                } catch {
                    cleanupErrors.append(error)
                }

                clearUninstallRuntimeState(
                    appInfo: appInfo,
                    dataUUIDs: dataUUIDs
                )

                if let cleanupError = cleanupErrors.first {
                    throw cleanupError
                }
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func removeContainerData(_ container: LCContainer, fileManager: FileManager) throws {
        let containerURL = container.containerURL.standardizedFileURL
        guard fileManager.fileExists(atPath: containerURL.path) else {
            return
        }

        if container.storageBookMark != nil {
            // External/bookmarked storage belongs to the user. Delete its
            // contents, including LCContainerInfo.plist, but keep the folder
            // itself so the bookmark remains non-destructive to its parent.
            let contents = try fileManager.contentsOfDirectory(
                at: containerURL,
                includingPropertiesForKeys: nil,
                options: []
            )
            for item in contents {
                try fileManager.removeItem(at: item)
            }
        } else {
            // Use the resolved container URL instead of reconstructing a path
            // from LCPath.dataPath. This also covers containers moved to the
            // shared LiveContainer directory.
            try fileManager.removeItem(at: containerURL)
        }
    }

    private func applicationGroupIdentifiers(for appInfo: LCAppInfo) -> Set<String> {
        guard let bundlePath = appInfo.bundlePath(),
              let info = NSDictionary(contentsOfFile: "\(bundlePath)/Info.plist"),
              let executable = info["CFBundleExecutable"] as? String else {
            return []
        }

        let executablePath = "\(bundlePath)/\(executable)"
        guard let entitlementXML = getExecutableEntitlementXML(executablePath),
              let data = entitlementXML.data(using: .utf8),
              let entitlementDict = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let groups = entitlementDict["com.apple.security.application-groups"] as? [String] else {
            return []
        }

        return Set(groups.filter { !$0.isEmpty && !$0.contains("/") })
    }

    private func removeUnusedAppGroupData(
        _ groupIdentifiers: Set<String>,
        excluding removedApp: LCAppModel,
        fileManager: FileManager
    ) throws {
        guard !groupIdentifiers.isEmpty else {
            return
        }

        let remainingApps = DataManager.shared.model.apps
            .filter { $0 !== removedApp }
            + DataManager.shared.model.hiddenApps.filter { $0 !== removedApp }
        var groupsUsedByRemainingApps = Set<String>()
        for app in remainingApps {
            groupsUsedByRemainingApps.formUnion(applicationGroupIdentifiers(for: app.appInfo))
        }

        let groupsToRemove = groupIdentifiers.subtracting(groupsUsedByRemainingApps)
        let roots = [LCPath.appGroupPath, LCPath.lcGroupAppGroupPath]
        for group in groupsToRemove {
            for root in roots {
                let groupURL = root.appendingPathComponent(group, isDirectory: true)
                if fileManager.fileExists(atPath: groupURL.path) {
                    try fileManager.removeItem(at: groupURL)
                }
            }
        }
    }

    private func clearUninstallRuntimeState(appInfo: LCAppInfo, dataUUIDs: Set<String>) {
        let relativeBundlePath = appInfo.relativeBundlePath
        let appURLSchemes = Set((appInfo.urlSchemes() as? [String]) ?? [])

        let defaults = UserDefaults.standard
        if let selected = defaults.string(forKey: "selected"), selected == relativeBundlePath {
            defaults.removeObject(forKey: "selected")
        }
        if let selectedContainer = defaults.string(forKey: "selectedContainer"), dataUUIDs.contains(selectedContainer) {
            defaults.removeObject(forKey: "selectedContainer")
        }
        if let launchURL = defaults.string(forKey: "launchAppUrlScheme"),
           let scheme = URL(string: launchURL)?.scheme,
           appURLSchemes.contains(scheme) {
            defaults.removeObject(forKey: "launchAppUrlScheme")
        }

        guard let sharedDefaults = UserDefaults.lcShared() else {
            return
        }
        if var guestSchemes = sharedDefaults.array(forKey: "LCGuestURLSchemes") as? [String] {
            guestSchemes.removeAll { appURLSchemes.contains($0) }
            sharedDefaults.set(guestSchemes, forKey: "LCGuestURLSchemes")
        }

        if LCUtils.appGroupUserDefault.string(forKey: "LCLaunchExtensionBundleID") == relativeBundlePath {
            LCUtils.appGroupUserDefault.removeObject(forKey: "LCLaunchExtensionBundleID")
            LCUtils.appGroupUserDefault.removeObject(forKey: "LCLaunchExtensionContainerName")
            LCUtils.appGroupUserDefault.removeObject(forKey: "LCLaunchExtensionLaunchURL")
            LCUtils.appGroupUserDefault.removeObject(forKey: "LCLaunchExtensionLaunchDate")
        }

        if let bundleIdentifier = appInfo.bundleIdentifier(),
           let relativeBundlePath,
           var customOrder = LCUtils.appGroupUserDefault.array(forKey: "LCCustomSortOrder") as? [String] {
            let uniqueIdentifier = "\(bundleIdentifier):\(relativeBundlePath)"
            customOrder.removeAll { $0 == uniqueIdentifier }
            LCUtils.appGroupUserDefault.set(customOrder, forKey: "LCCustomSortOrder")
        }
    }



    private func copyLaunchUrl() {
        guard let relativeBundlePath = configuration.model.appInfo.relativeBundlePath else {
            return
        }

        if let folderName = configuration.model.uiSelectedContainer?.folderName {
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(relativeBundlePath)&container-folder-name=\(folderName)"
        } else {
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(relativeBundlePath)"
        }
    }

    private func createAppClip() async {
        guard let style = await delegate.promptForGeneratedIconStyle() else {
            return
        }

        do {
            guard let profile = configuration.model.appInfo.generateWebClipConfig(
                withContainerId: configuration.model.uiSelectedContainer?.folderName,
                iconStyle: style
            ) else {
                throw CocoaError(.propertyListWriteInvalid)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
            delegate.installMdm(data: data)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func saveIcon() async {
        guard let style = await delegate.promptForGeneratedIconStyle() else {
            return
        }

        do {
            guard let image = configuration.model.appInfo.generateLiveContainerWrappedIcon(with: style),
                  let imageData = image.pngData() else {
                throw CocoaError(.fileWriteUnknown)
            }

            cleanupExportTemporaryDirectory()
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

            let rawDisplayName = configuration.model.appInfo.displayName() ?? configuration.model.displayName
            let displayName = rawDisplayName.replacingOccurrences(of: "/", with: "_")
            let fileURL = temporaryDirectory.appendingPathComponent("\(displayName) Icon.png")
            try imageData.write(to: fileURL, options: .atomic)
            exportTemporaryDirectory = temporaryDirectory

            guard viewIfLoaded?.window != nil, presentedViewController == nil else {
                cleanupExportTemporaryDirectory()
                return
            }

            let documentPicker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
            documentPicker.delegate = self
            documentPicker.presentationController?.delegate = self
            present(documentPicker, animated: true)
        } catch {
            cleanupExportTemporaryDirectory()
            showError(error.localizedDescription)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        cleanupExportTemporaryDirectory()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cleanupExportTemporaryDirectory()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        cleanupExportTemporaryDirectory()
    }

    private func cleanupExportTemporaryDirectory() {
        guard let exportTemporaryDirectory else {
            return
        }
        try? FileManager.default.removeItem(at: exportTemporaryDirectory)
        self.exportTemporaryDirectory = nil
    }
}
