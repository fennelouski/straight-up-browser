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

enum BrowserOrientationLock: CaseIterable, Equatable {
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

    private init() {}

    func apply(_ newSelection: BrowserOrientationLock) {
        selection = newSelection

        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            guard scene.activationState == .foregroundActive else { continue }
            scene.windows.forEach {
                $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(
                .iOS(interfaceOrientations: newSelection.mask)
            ) { error in
                Logger.log(
                    "Could not update interface orientation: \(error.localizedDescription)",
                    type: "Orientation"
                )
            }
        }
    }
}

@MainActor
final class BrowserAppDelegate_iOS: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLockController.shared.selection.mask
    }
}
