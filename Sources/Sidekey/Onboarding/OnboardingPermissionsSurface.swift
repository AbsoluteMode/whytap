import Foundation
import SwiftUI

enum OnboardingPermissionStatus: Equatable {
    case pending
    case requesting
    case granted
    case denied
}

/// Backing surface for `OnboardingPermissionsScreen`. The screen is
/// generic over this protocol so it works against the live
/// `RealOnboardingPermissionsSurface` (Whytap app, wires into
/// `PermissionsHelper`) and the `MockPermissionsSurface` used by
/// `OnboardingPreview` without a separate view file. Inherits
/// `ObservableObject` so `@ObservedObject` bindings refresh as the surface
/// pushes state changes.
@MainActor
protocol OnboardingPermissionsSurface: ObservableObject {
    var mic: OnboardingPermissionStatus { get }
    var accessibility: OnboardingPermissionStatus { get }

    var allRequiredGranted: Bool { get }

    /// Called from `.onAppear` so the surface can begin polling
    /// (real) or start its scripted cycle (mock).
    func start()

    /// Called from `.onDisappear` so the surface can tear down
    /// background work without leaking.
    func stop()

    func requestMic()
    func requestAccessibility()
}
