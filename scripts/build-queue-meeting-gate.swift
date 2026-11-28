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
// WHY: .project-docs/decisions/2026-11-28-meeting-gate-foreign-microphone.md
//      (supersedes the call-app and browser rules of 2026-11-24-meeting-gate-whytap-activity.md)
// An install interrupts only Whytap. Whytap's own capture (meeting, Notes, dictation,
// agent voice, Subtitles) runs in its process, so its input flag is the authoritative
// "Whytap is recording" signal. A microphone or speaker held only by another app
// (a call, a browser broadcast, Discord, macOS speech services) is not Whytap's work
// and never defers an install.
let whytapApps = ["com.rootwise.sidekey"]  // .beta and helpers match by prefix
func matches(_ bid: String, _ list: [String]) -> Bool {
    list.contains { bid == $0 || bid.hasPrefix($0 + ".") }
}
func classify(_ rows: [AudioActivity], complete: Bool) -> Gate {
    let active = rows.filter { $0.input || $0.output }
    let ids = active.map { $0.bundle?.lowercased() ?? "" }
    // Whytap capturing anything (a meeting, Notes, dictation) is what an install breaks.
    if zip(active, ids).contains(where: { $0.input && matches($1, whytapApps) }) {
        return Gate(status: "busy", reason: "whytap_capturing_audio")
    }
    // An input user whose bundle ID could not be read might be Whytap itself.
    if zip(active, ids).contains(where: { $0.input && $1.isEmpty }) {
        return Gate(status: "busy", reason: "microphone_in_use")
    }
    // An unreadable process may be Whytap, so an incomplete snapshot is never idle.
    guard complete else { return Gate(status: "unknown", reason: "incomplete_audio_snapshot") }
    // Every active input user is positively identified as another app. The reason
    // string is kept because build-queue-meeting-gate.py matches it.
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
    let whytap = row(true, false, "com.rootwise.sidekey")
    expect([], true, "clear")
    expect([], false, "unknown")
    // Whytap's own capture always defers, with or without other apps alongside.
    expect([whytap], true, "busy", "whytap_capturing_audio")
    expect([row(true, false, "com.rootwise.sidekey.beta")], true, "busy", "whytap_capturing_audio")
    expect([row(true, true, "com.rootwise.sidekey.helper")], true, "busy", "whytap_capturing_audio")
    expect([discord, coreSpeech, whytap], true, "busy", "whytap_capturing_audio")
    expect([row(true, false, "com.google.Chrome.helper"), whytap], true, "busy",
        "whytap_capturing_audio")
    expect([row(true, false, "us.zoom.xos"), whytap], false, "busy", "whytap_capturing_audio")
    // Whytap holding only output (no capture) is not recording.
    expect([row(false, true, "com.rootwise.sidekey")], true, "clear")
    // A microphone held only by another app is not Whytap's work.
    expect([row(true, false, "com.google.Chrome.helper")], true, "clear")
    expect([row(true, true, "com.google.Chrome.helper"), row(true, true, "com.apple.WebKit.GPU")],
        true, "clear")
    expect([row(true, false, "company.thebrowser.browser.helper")], true, "clear")
    expect([row(true, true, "us.zoom.xos")], true, "clear")
    expect([row(true, false, "com.apple.FaceTime")], true, "clear")
    expect([row(true, false, "ru.yandex.telemost")], true, "clear")
    expect([row(true, false, "com.microsoft.teams2")], true, "clear")
    expect([row(true, false, "com.example.unknowncaller")], true, "clear")
    expect([discord, coreSpeech], true, "clear")
    expect([coreSpeech], true, "clear")
    // Foreign output (media, a muted call, a call app) never defers.
    expect([row(false, true, "com.microsoft.teams2.modulehost")], true, "clear")
    expect([row(false, true, "company.thebrowser.browser.helper")], true, "clear")
    expect([row(false, true, "com.apple.WebKit.GPU")], true, "clear")
    expect([row(false, true, nil)], true, "clear")
    expect([row(false, true, "com.apple.Music")], true, "clear")
    expect([row(false, false, "us.zoom.xos")], true, "clear")
    // Unreadable state stays closed: an input user without a bundle ID, or a
    // process the snapshot could not read, might be Whytap.
    expect([row(true, false, nil)], false, "busy", "microphone_in_use")
    expect([row(true, false, nil)], true, "busy", "microphone_in_use")
    expect([discord, row(true, false, nil)], true, "busy", "microphone_in_use")
    expect([discord], false, "unknown")
    expect([row(true, false, "com.google.Chrome.helper")], false, "unknown")
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
