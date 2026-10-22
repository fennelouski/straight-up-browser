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

    /// The iPadOS preference locks the current orientation, rather than forcing
    /// a target orientation. Wait until an explicit app geometry request reaches
    /// its target; domain locks already capture the current scene orientation.
    func prefersSceneLock(for scene: UIWindowScene?) -> Bool {
        guard let scene else { return false }
        let resolved = effectiveSelection(for: scene)
        return resolved != .unlocked && resolved == currentOrientation(scene)
    }

    func restoreSceneLockAfterActivation(_ scene: UIWindowScene?) {
        guard #available(iOS 26.0, *), let scene,
              scene.windows.contains(where: { $0.rootViewController is BrowserOrientationRootController }) else { return }
        let resolved = effectiveSelection(for: scene)
        // iPadOS releases its conditional lock while our scene is backgrounded.
        // Re-establish the orientation already chosen by the user, if the system
        // permits. New domain navigation still never makes a geometry request.
        update(scene, requestGeometry: resolved != .unlocked && resolved != currentOrientation(scene))
    }

    func apply(_ newSelection: BrowserOrientationLock) {
        appSelection = newSelection
        updateScenes(requestGeometry: true)
    }

    func setDomainRule(_ value: String?, url: URL) {
        let defaults = BrowserProfile.defaults
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
        let rules = MobileDomainRotation.rules(BrowserProfile.defaults.data(forKey: MobileChromeSettings.rotationRules) ?? Data())
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
        scene.windows.forEach {
            $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if #available(iOS 26.0, *), $0.rootViewController is BrowserOrientationRootController {
                $0.rootViewController?.setNeedsUpdateOfPrefersInterfaceOrientationLocked()
            }
        }
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

/// SwiftUI owns its hosting controller and scene lifecycle. On iPadOS 26 only,
/// retain that controller as a child of a small UIKit root so the system can
/// query its documented orientation-lock preference. No private hosting types,
/// method replacement, scene configuration or full-screen opt-out is involved.
@available(iOS 26.0, *)
final class BrowserOrientationRootController: UIViewController {
    private let content: UIViewController

    init(content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDidActivate(_:)),
            name: UIScene.didActivateNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.view.topAnchor.constraint(equalTo: view.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        content.didMove(toParent: self)
    }

    override var prefersInterfaceOrientationLocked: Bool {
        OrientationLockController.shared.prefersSceneLock(for: view.window?.windowScene)
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        OrientationLockController.shared.supportedMask(for: view.window)
    }

    override var childForStatusBarHidden: UIViewController? { content }
    override var childForStatusBarStyle: UIViewController? { content }
    override var childForHomeIndicatorAutoHidden: UIViewController? { content }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { content }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene,
              scene.windows.contains(where: { $0.rootViewController === self }) else { return }
        // The WebKit view may not yet be reattached when the app notification
        // arrives. The UIKit root owns a stable scene attachment at activation.
        OrientationLockController.shared.restoreSceneLockAfterActivation(scene)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            // A requested app orientation can now be locked at its destination.
            self?.setNeedsUpdateOfPrefersInterfaceOrientationLocked()
        }
    }
}

@available(iOS 26.0, *)
struct BrowserOrientationRootAttachment: UIViewRepresentable {
    func makeUIView(context: Context) -> AttachmentView { AttachmentView() }
    func updateUIView(_ uiView: AttachmentView, context: Context) {}

    final class AttachmentView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard UIDevice.current.userInterfaceIdiom == .pad else { return }
            // Defer until SwiftUI has finished attaching the existing root.
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window, let content = window.rootViewController,
                      !(content is BrowserOrientationRootController) else { return }
                window.rootViewController = BrowserOrientationRootController(content: content)
            }
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
