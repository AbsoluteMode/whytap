import AppKit
import CoreGraphics
import Foundation

/// What Lil Bro is doing, as the sprite sheet names it.
enum LilBroPose: String, CaseIterable {
    case idle, walk, run, jump, fall, land, climb, prop, hit, caught, think, sad, ask, done, hover, point
}

/// One animation of the sheet: frame names, how long each is shown, and
/// whether it repeats or holds its last frame.
struct LilBroAnimation: Decodable, Equatable {
    let frames: [String]
    let ms: Int
    let loop: Bool
}

/// The sprite sheet of Lil Bro ("Hood"): a PNG grid of 14x16 pixel cells and
/// a JSON index. Both themes share one layout; the dark sheet only lightens
/// the outline. The mascot faces right in every frame and is mirrored to
/// face left.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md
final class LilBroAtlas {
    struct Spec: Decodable {
        struct Cell: Decodable { let width: Int; let height: Int }
        let version: Int
        let cell: Cell
        let columns: Int
        let pointsPerPixel: Int
        let frames: [String]
        let animations: [String: LilBroAnimation]
    }

    enum LoadError: Error { case badData, badImage, missingFrame(String), missingPose(String) }

    let spec: Spec
    private let light: [String: CGImage]
    private let dark: [String: CGImage]

    /// The sheet built into the app (`LilBroAtlasData`); nil only if that
    /// data is broken, which `LilBroAtlasTests` rules out.
    static let shared: LilBroAtlas? = try? LilBroAtlas(
        json: Data(base64Encoded: LilBroAtlasData.json) ?? Data(),
        lightPNG: Data(base64Encoded: LilBroAtlasData.lightPNG) ?? Data(),
        darkPNG: Data(base64Encoded: LilBroAtlasData.darkPNG) ?? Data())

    init(json: Data, lightPNG: Data, darkPNG: Data) throws {
        let spec = try JSONDecoder().decode(Spec.self, from: json)
        for pose in LilBroPose.allCases {
            guard let animation = spec.animations[pose.rawValue] else { throw LoadError.missingPose(pose.rawValue) }
            for frame in animation.frames where !spec.frames.contains(frame) { throw LoadError.missingFrame(frame) }
        }
        self.spec = spec
        light = try Self.slice(lightPNG, spec: spec)
        dark = try Self.slice(darkPNG, spec: spec)
    }

    /// Size of one frame in points.
    var pointSize: CGSize {
        CGSize(width: spec.cell.width * spec.pointsPerPixel, height: spec.cell.height * spec.pointsPerPixel)
    }

    func animation(for pose: LilBroPose) -> LilBroAnimation {
        spec.animations[pose.rawValue] ?? LilBroAnimation(frames: [spec.frames[0]], ms: 100, loop: true)
    }

    /// The frame to show `elapsed` seconds into `pose`.
    func frameName(for pose: LilBroPose, elapsed: TimeInterval) -> String {
        let animation = animation(for: pose)
        let step = max(0, Int(elapsed * 1000) / max(1, animation.ms))
        let index = animation.loop ? step % animation.frames.count : min(step, animation.frames.count - 1)
        return animation.frames[index]
    }

    func image(_ frame: String, dark isDark: Bool) -> CGImage? {
        (isDark ? dark : light)[frame]
    }

    private static func slice(_ png: Data, spec: Spec) throws -> [String: CGImage] {
        guard let rep = NSBitmapImageRep(data: png), let sheet = rep.cgImage else { throw LoadError.badImage }
        var frames: [String: CGImage] = [:]
        for (index, name) in spec.frames.enumerated() {
            let rect = CGRect(x: (index % spec.columns) * spec.cell.width,
                              y: (index / spec.columns) * spec.cell.height,
                              width: spec.cell.width, height: spec.cell.height)
            guard let frame = sheet.cropping(to: rect) else { throw LoadError.missingFrame(name) }
            frames[name] = frame
        }
        return frames
    }
}
