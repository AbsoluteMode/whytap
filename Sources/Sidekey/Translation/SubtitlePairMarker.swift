import SwiftUI

/// How the subtitle box marks where one phrase pair starts, so the reader
/// sees which part of the text belongs together. Variants are rendered for
/// the user to choose from; `none` is the plain pair.
// WHY: .project-docs/decisions/2026-11-21-subtitle-phrase-pairs.md
enum SubtitlePairMarker: String, CaseIterable {
    /// A small accent dot before the original and before the translation.
    case dot
    /// Every other pair on a faint rounded band.
    case band
    /// The first letter of the original and of the translation in the accent.
    case initial
    case none

    /// Light blue that reads on the dark box next to the white translation.
    static let accent = Color(red: 0.38, green: 0.66, blue: 1.0)
}

private struct SubtitlePairMarkerKey: EnvironmentKey {
    static let defaultValue = SubtitlePairMarker.none
}

extension EnvironmentValues {
    var subtitlePairMarker: SubtitlePairMarker {
        get { self[SubtitlePairMarkerKey.self] }
        set { self[SubtitlePairMarkerKey.self] = newValue }
    }
}
