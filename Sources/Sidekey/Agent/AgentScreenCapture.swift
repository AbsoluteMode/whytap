import AppKit
import ScreenCaptureKit
import WhytapCaseKit

/// One requested frame, captured by the signed app so TCC belongs to Whytap.
/// Pixels stay in the tool response; no clipboard, files, input filters or logs.
// WHY: .project-docs/decisions/2026-10-22-agent-answers-and-screen.md
@MainActor
final class AgentScreenCapture {
    typealias Capture = (CGDirectDisplayID?) async throws -> (CGDirectDisplayID, CGImage)
    private let permission: () -> Bool
    private let capture: Capture
    private let timeout: Duration
    private var busy = false

    init(permission: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() },
         timeout: Duration = .seconds(10), capture: @escaping Capture = AgentScreenCapture.captureDisplay) {
        self.permission = permission
        self.timeout = timeout
        self.capture = capture
    }

    func handle(_ args: [String: AppControlValue]) async -> AppControlResponse {
        guard Set(args.keys).isSubset(of: ["display_id"]),
              args["display_id"] == nil || args["display_id"]?.int.map({ $0 > 0 && UInt64($0) <= UInt32.max }) == true else {
            return .failure("invalid_arguments", "Use an optional positive display_id, with no other fields.")
        }
        guard !Task.isCancelled else { return .failure("cancelled", "Screen capture cancelled.") }
        guard !busy else { return .failure("busy", "A screen capture is already in progress.") }
        guard permission() else {
            return .failure("screen_permission", "Allow Whytap in System Settings → Privacy & Security → Screen Recording, then retry.")
        }
        busy = true
        defer { busy = false }
        let pending = Pending()
        let displayID = args["display_id"]?.int.map(CGDirectDisplayID.init)
        let capture = self.capture
        let work = Task { @MainActor in
            do {
                try Task.checkCancellation()
                let (display, image) = try await capture(displayID)
                try Task.checkCancellation()
                pending.finish(Self.encode(image, displayID: display))
            } catch {
                pending.finish(Task.isCancelled
                    ? .failure("cancelled", "Screen capture cancelled.")
                    : .failure("capture_failed", "Couldn’t capture this display. Check Screen Recording access and retry."))
            }
        }
        let deadline = Task { @MainActor [timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            pending.finish(.failure("capture_timeout", "Screen capture took too long. Try again."))
            work.cancel()
        }
        defer { work.cancel(); deadline.cancel() }
        return await withTaskCancellationHandler {
            await pending.wait()
        } onCancel: {
            work.cancel()
            Task { @MainActor in pending.finish(.failure("cancelled", "Screen capture cancelled.")) }
        }
    }

    private final class Pending {
        private var result: AppControlResponse?
        private var continuation: CheckedContinuation<AppControlResponse, Never>?
        func wait() async -> AppControlResponse {
            await withCheckedContinuation {
                if let result { $0.resume(returning: result) }
                else { continuation = $0 }
            }
        }
        func finish(_ response: AppControlResponse) {
            guard result == nil else { return }
            result = response
            continuation?.resume(returning: response)
            continuation = nil
        }
    }

    private static func captureDisplay(_ requested: CGDirectDisplayID?) async throws -> (CGDirectDisplayID, CGImage) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let selected = NSScreen.screens.first { $0.frame == IslandScreenResolver.currentDescriptor().frame }
        let selectedID = (selected?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let target = requested ?? selectedID ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == target }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = ScreenshotCaptureConfiguration.make(contentRect: filter.contentRect, pointPixelScale: filter.pointPixelScale)
        let scale = min(1, 1920 / Double(max(configuration.width, configuration.height)))
        configuration.width = max(1, Int(Double(configuration.width) * scale))
        configuration.height = max(1, Int(Double(configuration.height) * scale))
        configuration.scalesToFit = true
        return (target, try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration))
    }

    static func encode(_ image: CGImage, displayID: CGDirectDisplayID) -> AppControlResponse {
        let bitmap = NSBitmapImageRep(cgImage: image)
        for quality in [0.8, 0.55, 0.3] {
            if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), data.count <= 2_000_000 {
                return .success(.object(["mimeType": .string("image/jpeg"), "image": .string(data.base64EncodedString()),
                                         "width": .int(image.width), "height": .int(image.height), "display_id": .int(Int(displayID))]))
            }
        }
        return .failure("image_too_large", "The screen image is too large. Try a different display.")
    }
}
