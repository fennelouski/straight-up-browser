//
//  OrientationLock_iOS.swift
//  Browser (iOS)
//
//  A scene-aware rotation lock used by the compact page menu. The application
//  delegate supplies UIKit's supported-orientation mask; geometry updates make
//  a newly selected orientation take effect immediately when the scene permits.
//

import SwiftUI
import UIKit

enum BrowserOrientationLock: String, CaseIterable, Equatable {
    case unlocked
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    var title: String {
        switch self {
        case .unlocked: "Unlocked"
        case .portrait: "Portrait"
        case .portraitUpsideDown: "Portrait Upside Down"
        case .landscapeLeft: "Landscape Left"
        case .landscapeRight: "Landscape Right"
        }
    }

    var systemImage: String {
        self == .unlocked ? "rectangle.rotate" : "lock.rotation"
    }

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .unlocked:
            UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        }
    }
}

@MainActor
final class OrientationLockController: ObservableObject {
    static let shared = OrientationLockController()

    @Published private(set) var selection: BrowserOrientationLock = .unlocked

    private var appSelection: BrowserOrientationLock = .unlocked
    private var sceneURLs: [String: URL] = [:]
    private var domainLocks: [String: (host: String, orientation: BrowserOrientationLock)] = [:]
    private init() {}

    func updateContext(_ url: URL?, scene: UIWindowScene?) {
        guard let scene else { return }
        let key = scene.session.persistentIdentifier
        if MobileDomainRotation.host(sceneURLs[key]) != MobileDomainRotation.host(url) { domainLocks.removeValue(forKey: key) }
        sceneURLs[key] = url
        update(scene)
    }

    func supportedMask(for window: UIWindow?) -> UIInterfaceOrientationMask {
        guard let scene = window?.windowScene else { return appSelection.mask }
        return effectiveSelection(for: scene).mask
    }

    func apply(_ newSelection: BrowserOrientationLock) {
        appSelection = newSelection
        updateScenes(requestGeometry: true)
    }

    func setDomainRule(_ value: String?, url: URL) {
        let defaults = UserDefaults.standard
        let old = defaults.data(forKey: MobileChromeSettings.rotationRules) ?? Data()
        defaults.set(MobileDomainRotation.setting(value, for: url, in: old), forKey: MobileChromeSettings.rotationRules)
        domainLocks = domainLocks.filter { $0.value.host != MobileDomainRotation.host(url) }
        updateScenes()
    }

    func lockCurrentOrientation(for url: URL) {
        setDomainRule("locked", url: url)
    }

    private func currentOrientation(_ scene: UIWindowScene) -> BrowserOrientationLock {
        switch scene.interfaceOrientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: .unlocked
        }
    }

    private func effectiveSelection(for scene: UIWindowScene) -> BrowserOrientationLock {
        let rules = MobileDomainRotation.rules(UserDefaults.standard.data(forKey: MobileChromeSettings.rotationRules) ?? Data())
        let key = scene.session.persistentIdentifier
        guard let host = MobileDomainRotation.host(sceneURLs[key]), let rule = rules[host] else {
            domainLocks.removeValue(forKey: key)
            return appSelection
        }
        guard rule == "locked" else { domainLocks.removeValue(forKey: key); return .unlocked }
        if domainLocks[key]?.host != host {
            domainLocks[key] = (host, currentOrientation(scene))
        }
        return domainLocks[key]?.orientation ?? .unlocked
    }

    private func updateScenes(requestGeometry: Bool = false) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes where scene.activationState == .foregroundActive {
            update(scene, requestGeometry: requestGeometry)
        }
    }

    private func update(_ scene: UIWindowScene, requestGeometry: Bool = false) {
        let resolved = effectiveSelection(for: scene)
        selection = resolved
        scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        // Domain rules constrain future autorotation at the current interface
        // orientation. They never request a rotation or attempt to read/override
        // system rotation lock. Only the existing explicit app rotation menu
        // retains its user-requested geometry operation.
        guard requestGeometry else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: resolved.mask)) { error in
            Logger.log("Could not update interface orientation: \(error.localizedDescription)", type: "Orientation")
        }
    }
}

@MainActor
final class BrowserAppDelegate_iOS: NSObject, UIApplicationDelegate {
    private var historyFlushTask: UIBackgroundTaskIdentifier = .invalid

    func flushHistoryInBackground() {
        guard historyFlushTask == .invalid else { return }
        historyFlushTask = UIApplication.shared.beginBackgroundTask(withName: "Save browser history") { [weak self] in
            Task { @MainActor in self?.finishHistoryFlush() }
        }
        let identifier = historyFlushTask
        Task {
            await BrowsingHistoryStore.shared.flush()
            await DownloadManager.shared.flush()
            if historyFlushTask == identifier { finishHistoryFlush() }
        }
    }

    private func finishHistoryFlush() {
        guard historyFlushTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(historyFlushTask)
        historyFlushTask = .invalid
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLockController.shared.supportedMask(for: window)
    }
}
