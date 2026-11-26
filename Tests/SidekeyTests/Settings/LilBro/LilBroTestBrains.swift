@testable import Sidekey

/// whytap.ai in the window tests: a fixed reply, no network. By default the
/// answer opens Drop, as the model does when the person asks to set up
/// dictation.
struct LilBroFixedBrain: LilBroBrain {
    var reply: LilBroReply = .answer(LilBroAnswer(paragraphs: ["Drop types what you say into any text field."],
                                                  bullets: ["Hold its shortcut and speak"],
                                                  destination: .feature(.drop)))
    func reply(to question: LilBroQuestion) async -> LilBroReply { reply }
}
