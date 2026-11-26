import Foundation

/// Where Lil Bro takes the person: a feature's screen or row, a sidebar tab,
/// one row of a tab (scrolled to and outlined), or the API keys.
enum LilBroDestination: Equatable {
    case feature(AppFeature)
    case tab(SettingsWindowTab)
    case row(LilBroRow)
    case apiKeys

    var title: String {
        switch self {
        case .feature(let feature): return FeatureCatalog.info(for: feature).name
        case .tab(let tab): return tab.resolved.title
        case .row(let row): return row.title
        case .apiKeys: return "API keys"
        }
    }
}

/// An answer: a few sentences, optional points, and the place he opens when
/// the model decided the person asked to go there.
struct LilBroAnswer: Equatable {
    var paragraphs: [String]
    var bullets: [String] = []
    var destination: LilBroDestination?
}

/// What came back for one question.
enum LilBroReply: Equatable {
    case answer(LilBroAnswer)
    /// Answers from whytap.ai are turned off: nothing was sent; the card
    /// that turns them on and asks this question.
    case answersOff
    /// Under the three characters whytap.ai takes; nothing was sent.
    case tooShort
    /// whytap.ai could not be reached: no internet or it did not answer in time.
    case offline
    /// whytap.ai answered with an error of its own; trying again later may work.
    case unavailable
    /// Today's questions are used up, for this Mac or for everyone.
    case limit

    var isAnswersOff: Bool { self == .answersOff }
}

/// One question with what he knows around it: the screen the person is on
/// (`tab` or `tab/feature` raw ids) and up to three earlier exchanges.
struct LilBroQuestion: Equatable {
    struct Exchange: Equatable {
        let question: String
        let answer: String
    }

    var text: String
    var screen: String = ""
    var history: [Exchange] = []
}

/// Who answers: whytap.ai. There are no scripted answers on this Mac; the
/// model decides whether to answer in the balloon or open a place.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md (REV 10)
@MainActor
protocol LilBroBrain {
    func reply(to question: LilBroQuestion) async -> LilBroReply
}
