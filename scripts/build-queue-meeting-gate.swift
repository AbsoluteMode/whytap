// Read-only builder gate: CoreAudio activity flags only, never audio or UI.
import CoreAudio
import Foundation

struct AudioActivity {
    let input: Bool
    let output: Bool
    let bundle: String?
}
struct Gate: Codable, Equatable {
    let status: String
    let reason: String
}
// WHY: .project-docs/decisions/2026-11-24-meeting-gate-whytap-activity.md
// An install interrupts only Whytap. Whytap's own capture (meeting, Notes, dictation,
// Subtitles) runs in its process, so its input flag is the authoritative "Whytap is
// recording" signal. Real call apps still defer: Whytap may be about to record them.
let whytapApps = ["com.rootwise.sidekey"]  // .beta and helpers match by prefix
let callApps = ["us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
    "com.tinyspeck.slackmacgap", "com.apple.facetime", "com.apple.avconferenced",
    "ru.keepcoder.telegram", "org.telegram.desktop", "net.whatsapp.whatsapp",
    "com.cisco.webexmeetingsapp", "ru.yandex.telemost"]
let browsers = ["com.google.chrome", "com.apple.safari", "com.apple.webkit",
    "com.brave.browser", "com.microsoft.edgemac", "company.thebrowser.browser",
    "company.thebrowser.dia", "org.mozilla.firefox"]
// Audio that is neither a meeting Whytap records nor Whytap itself: the owner's
// always-on Discord voice chat (2026-11-24) and macOS speech services, which follow
// any open microphone.
let ignoredApps = ["com.hnc.discord", "com.hnc.discordcanary", "com.hnc.discordptb",
    "com.apple.corespeech"]
func matches(_ bid: String, _ list: [String]) -> Bool {
    list.contains { bid == $0 || bid.hasPrefix($0 + ".") }
}
func isBrowser(_ bid: String) -> Bool {
    matches(bid, browsers) ||
        (bid.hasPrefix("company.thebrowser.") && bid.contains(".browser.helper"))
}
func classify(_ rows: [AudioActivity], complete: Bool) -> Gate {
    let active = rows.filter { $0.input || $0.output }
    let ids = active.map { $0.bundle?.lowercased() ?? "" }
    // Whytap capturing anything (a meeting, Notes, dictation) is what an install breaks.
    if zip(active, ids).contains(where: { $0.input && matches($1, whytapApps) }) {
        return Gate(status: "busy", reason: "whytap_capturing_audio")
    }
    for (row, bid) in zip(active, ids) where row.input {
        if matches(bid, ignoredApps) { continue }
        if matches(bid, callApps) { return Gate(status: "busy", reason: "call_app_microphone_in_use") }
        if isBrowser(bid) { return Gate(status: "busy", reason: "browser_microphone_in_use") }
        // An unidentified or unrecognized microphone user may be a call in an app this
        // list does not know.
        return Gate(status: "busy", reason: "microphone_in_use")
    }
    guard complete else { return Gate(status: "unknown", reason: "incomplete_audio_snapshot") }
    for (row, bid) in zip(active, ids) where row.output {
        if bid.isEmpty { return Gate(status: "unknown", reason: "unidentified_audio_output") }
        if matches(bid, ignoredApps) { continue }
        if matches(bid, callApps) { return Gate(status: "busy", reason: "call_app_output_active") }
        if isBrowser(bid) {
            return Gate(status: "unknown", reason: "browser_audio_may_be_a_muted_call")
        }
    }
    return Gate(status: "clear", reason: "no_call_audio_observed")
}
func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<UInt32>.size), value: UInt32 = 0
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}
func bundle(_ object: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString = "" as CFString
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
    }
    guard status == noErr else { return nil }
    return value as String
}
func snapshot() -> Gate {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
        Int(size) % MemoryLayout<AudioObjectID>.size == 0 else {
        return Gate(status: "unknown", reason: "audio_process_list_unavailable")
    }
    if size == 0 { return classify([], complete: true) }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let status = objects.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
    }
    guard status == noErr else { return Gate(status: "unknown", reason: "audio_process_list_unavailable") }
    var complete = true
    var rows: [AudioActivity] = []
    for object in objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size) {
        guard let input = number(object, kAudioProcessPropertyIsRunningInput),
            let output = number(object, kAudioProcessPropertyIsRunningOutput) else {
            complete = false; continue
        }
        rows.append(AudioActivity(input: input != 0, output: output != 0,
            bundle: input == 0 && output == 0 ? nil : bundle(object)))
    }
    return classify(rows, complete: complete)
}
if CommandLine.arguments.dropFirst() == ["--self-test"] {
    var cases = 0
    func expect(_ rows: [AudioActivity], _ complete: Bool, _ status: String, _ reason: String? = nil) {
        let gate = classify(rows, complete: complete)
        precondition(gate.status == status && (reason == nil || gate.reason == reason),
            "\(rows) -> \(gate)")
        cases += 1
    }
    func row(_ input: Bool, _ output: Bool, _ bundle: String?) -> AudioActivity {
        AudioActivity(input: input, output: output, bundle: bundle)
    }
    let discord = row(true, true, "com.hnc.Discord.helper.Renderer")
    let coreSpeech = row(true, false, "com.apple.CoreSpeech")
    expect([], true, "clear")
    expect([], false, "unknown")
    expect([row(true, false, nil)], false, "busy", "microphone_in_use")
    expect([row(true, false, "com.rootwise.sidekey")], true, "busy", "whytap_capturing_audio")
    expect([row(true, false, "com.rootwise.sidekey.beta")], true, "busy", "whytap_capturing_audio")
    expect([row(false, true, "com.microsoft.teams2.modulehost")], true, "busy")
    expect([row(false, true, "company.thebrowser.browser.helper")], true, "unknown")
    expect([row(false, true, "com.apple.WebKit.GPU")], true, "unknown")
    expect([row(false, true, nil)], true, "unknown")
    expect([row(false, true, "com.apple.Music")], true, "clear")
    expect([row(false, false, "us.zoom.xos")], true, "clear")
    // The owner's Discord voice chat with macOS speech services: nothing Whytap records.
    expect([discord], true, "clear")
    expect([discord, coreSpeech], true, "clear")
    expect([coreSpeech], true, "clear")
    expect([row(false, true, "com.hnc.Discord")], true, "clear")
    // Whytap recording while Discord holds the microphone still defers.
    expect([discord, coreSpeech, row(true, true, "com.rootwise.sidekey")], true, "busy",
        "whytap_capturing_audio")
    // Real calls still defer, with or without Discord alongside.
    expect([row(true, true, "us.zoom.xos")], true, "busy", "call_app_microphone_in_use")
    expect([discord, row(false, true, "us.zoom.xos")], true, "busy", "call_app_output_active")
    expect([row(true, false, "com.apple.FaceTime")], true, "busy", "call_app_microphone_in_use")
    expect([row(true, false, "ru.yandex.telemost")], true, "busy")
    expect([row(true, false, "com.microsoft.teams2")], true, "busy")
    expect([row(true, false, "com.google.Chrome.helper")], true, "busy", "browser_microphone_in_use")
    // An unknown microphone user may be a call app this list does not know.
    expect([row(true, false, "com.example.unknowncaller")], true, "busy", "microphone_in_use")
    expect([discord, row(true, false, nil)], true, "busy", "microphone_in_use")
    // Ignoring Discord never hides an incomplete snapshot.
    expect([discord], false, "unknown")
    print("{\"self_test\":\"passed\",\"cases\":\(cases)}")
} else if CommandLine.arguments.count == 1 {
    var samples: [Gate] = []
    for index in 0..<3 {
        if index > 0 { Thread.sleep(forTimeInterval: 1) }
        samples.append(snapshot())
    }
    struct Report: Codable { let samples: [Gate]; let observed_at: String }
    let report = Report(samples: samples, observed_at: ISO8601DateFormatter().string(from: Date()))
    print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
} else {
    fputs("Unsupported arguments\n", stderr); exit(2)
}
