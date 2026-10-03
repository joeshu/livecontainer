//
//  LiveContainerSwiftUIApp.swift
//  LiveContainer
//
//  Created by s s on 2025/5/16.
//
import SwiftUI

@main
struct LiveContainerSwiftUIApp : SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        let fm = FileManager()
        var tempAppDataFolderNames : [String] = []
        var tempTweakFolderNames : [String] = []
        
        var tempApps: [LCAppModel] = []
        var tempArm32EmuApps: [LCAppModel] = []
        var tempHiddenApps: [LCAppModel] = []
        var tempURLSchemes: Set<String>? = DataManager.shared.model.multiLCStatus != 2 ? Set() : nil

        // Each storage area is independent: failure in shared storage must not
        // stop private containers or tweaks from being indexed.
        for (root, shared) in [(LCPath.bundlePath, false), (LCPath.lcGroupBundlePath, true)] {
            if shared && LCPath.lcGroupDocPath == LCPath.docPath { continue }
            do {
                for appURL in try LCFileOperations.directories(in: root, fileManager: fm) where appURL.pathExtension == "app" {
                    guard let newApp = LCAppInfo(bundlePath: appURL.path) else { continue }
                    newApp.relativeBundlePath = appURL.lastPathComponent
                    newApp.isShared = shared
                    let model = LCAppModel(appInfo: newApp)
                    if newApp.isHidden {
                        tempHiddenApps.append(model)
                    } else {
                        tempApps.append(model)
                        if let schemes = newApp.urlSchemes() { tempURLSchemes?.formUnion(schemes.compactMap { $0 as? String }) }
                    }
                    if newApp.is32bitEmulator { tempArm32EmuApps.append(model) }
                }
            } catch { NSLog("[LC] App index unavailable: %@", error.localizedDescription) }
        }
        do {
            tempAppDataFolderNames = try LCFileOperations.directories(in: LCPath.dataPath, fileManager: fm).map(\.lastPathComponent)
        } catch { NSLog("[LC] Container index unavailable: %@", error.localizedDescription) }
        do {
            tempTweakFolderNames = try LCFileOperations.directories(in: LCPath.tweakPath, fileManager: fm).map {
                let name = $0.lastPathComponent
                return name.hasSuffix(".disabled") ? String(name.dropLast(".disabled".count)) : name
            }
        } catch { NSLog("[LC] Tweak index unavailable: %@", error.localizedDescription) }

        DataManager.shared.model.apps = tempApps
        DataManager.shared.model.arm32EmuApps = tempArm32EmuApps
        DataManager.shared.model.hiddenApps = tempHiddenApps
        DataManager.shared.model.appDataFolderNames = tempAppDataFolderNames
        DataManager.shared.model.tweakFolderNames = tempTweakFolderNames
        if let tempURLSchemes {
            UserDefaults.lcShared().set(Array(tempURLSchemes), forKey: "LCGuestURLSchemes")
        }
    }
    
    var body: some Scene {
        WindowGroup(id: "Main") {
            LCTabView()
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .environmentObject(DataManager.shared.model)
                .environmentObject(LCAppSortManager.shared)
        }
        
        if UIApplication.shared.supportsMultipleScenes, #available(iOS 16.1, *) {
            WindowGroup(id: "appView", for: String.self) { $id in
                if let id {
                    MultitaskAppWindow(id: id)
                }
            }

        }
    }
    
}
