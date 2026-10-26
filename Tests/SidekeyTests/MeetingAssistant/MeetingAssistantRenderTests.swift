import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class MeetingAssistantRenderTests: XCTestCase {
    func testNativePilotStatesOffscreen() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_MEETING_ASSISTANT_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTap Meeting Assistant render directory for offscreen visual checks.")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "meeting-assistant-render-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MeetingAssistantModel(directory: directory, defaults: defaults)
        for scheme in [ColorScheme.light, .dark] {
            try render(model, scheme: scheme, name: "empty", directory: directory)
            model.spaces = [.init(version: 1, id: "project", name: "Whytap", purpose: "", instructions: "", sources: [])]
            model.selectedSpaceID = "project"
            try render(model, scheme: scheme, name: "ready", directory: directory)
            model.audioConnecting = true
            try render(model, scheme: scheme, name: "connecting", directory: directory)
            model.audioConnecting = false; model.listening = true
            try render(model, scheme: scheme, name: "listening", directory: directory)
            model.listening = false; model.releasingAudio = true
            try render(model, scheme: scheme, name: "stopping", directory: directory)
            model.releasingAudio = false
            model.pending = (0..<5).map { .init(question: "Какие изменения нужны для пилота \($0 + 1)?") }
            model.completed = (0..<20).map { .init(question: "Как подключить источники проекта \($0 + 1)?") }
            model.selected = .init(question: "Как подготовить Space проекта?", conclusion: "Создай Space через Codex или Claude Code.",
                                   points: ["Укажи **репозиторий и папки**, которые нужны для встречи.", "Проверь **выбранные модели** речи и ответов."],
                                   followups: [.init(title: "Какие папки включить?"), .init(title: "Как проверить доступ?")])
            model.answerVisible = true
            model.screenshots = (0..<6).map { index in .init(image: fixturePhoto(index), payload: .init(data: Data(), mimeType: "image/jpeg")) }
            model.layoutHeight = 1084; model.bodyLimit = 250
            try render(model, scheme: scheme, name: "populated", directory: directory)
            model.layoutHeight = 620; model.bodyLimit = 56
            try render(model, scheme: scheme, name: "short", directory: directory)
            model.spaces = []; model.pending = []; model.completed = []; model.selected = nil
            model.answerVisible = false; model.screenshots = []; model.layoutHeight = 1084
        }
    }
    private func fixturePhoto(_ index: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 320, height: 200))
        image.lockFocus()
        NSColor(calibratedWhite: index.isMultiple(of: 2) ? 0.9 : 0.25, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 320, height: 200).fill()
        ("ДЕМО \(index + 1)" as NSString).draw(at: NSPoint(x: 22, y: 135), withAttributes: [.font: NSFont.systemFont(ofSize: 28, weight: .bold), .foregroundColor: NSColor.systemBlue])
        NSColor.systemBlue.withAlphaComponent(0.2).setFill()
        NSRect(x: 22, y: 100, width: 210, height: 12).fill()
        NSRect(x: 22, y: 70, width: 165, height: 12).fill()
        image.unlockFocus()
        return image
    }
    func testHoverSessionStatesOffscreen() throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_MEETING_ASSISTANT_RENDER_DIR"] else {
            throw XCTSkip("Set render directory for offscreen magic icon checks.")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [CGFloat(310), 312, 354] {
            try saveHover(VStack(spacing: 16) {
                ForEach(0..<4) { index in
                    self.magicHeader(width: width, phase: [.off, .connecting, .listening, .stopping][index])
                }
            }.padding(.vertical, 12),
                width: width + 36, height: 224, name: "magic-states-\(Int(width))", directory: directory)
            try saveHover(hoverComposition(width: width),
                width: width + 36, height: 244, name: "magic-composition-\(Int(width))", directory: directory)
        }
        try saveHover(HStack(spacing: 12) {
            ForEach(0..<4) { index in
                MeetingAssistantMagicGlyph(phase: index == 3 ? .stopping : .listening)
                    .frame(width: 28, height: 28)
                    .background(MeetingAssistantHoverSurface(hovered: index == 0 || index == 3,
                        pressed: index == 1 || index == 3, focused: index == 2 || index == 3, enabled: index != 3))
            }
        }.padding(16), width: 220, height: 60, name: "magic-feedback", directory: directory)
    }
    private func magicHeader(width: CGFloat, phase: MeetingAssistantHoverState.Phase) -> some View {
        HStack(spacing: 0) {
            Spacer().frame(width: width - IslandFrameLayout.rightSideWidth)
            IslandMeetingRecordingSlotView(snapshot: .init(duration: 132, levels: [0.2, 0.4, 0.7, 0.4, 0.6, 0.3], isPaused: false), onStop: {})
                .frame(width: IslandFrameLayout.rightSideWidth)
            IslandMeetingAssistantControl(state: .init(available: true, phase: phase), setEnabled: { _ in }, reduceMotionOverride: true)
                .frame(width: IslandMeetingAssistantPlacement.extensionWidth)
        }
        .frame(height: 38).background(alignment: .leading) {
            IslandCameraSurface(compactWidth: width, compactHeight: 38, meetingSuggestionActive: false,
                trailingExtension: IslandMeetingAssistantPlacement.extensionWidth, animatesWidthChange: false)
                .frame(width: width + IslandMeetingAssistantPlacement.extensionWidth, height: 38)
        }
    }
    private func hoverComposition(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            magicHeader(width: width, phase: .listening)
            VStack(spacing: 0) {
                IslandHoverSearchField(text: .constant(""), onFocusChange: { _ in }, onCommand: { _ in })
                    .frame(height: IslandHoverToolSearch.fieldHeight)
                    .padding(.horizontal, 10).padding(.vertical, IslandHoverToolSearch.fieldVerticalInset)
                HStack(spacing: IslandHoverControlsLayout.columnSpacing) {
                    hoverTile("Record", icon: "record.circle", width: width)
                    hoverTile("Meeting Assistant", icon: "person.wave.2", width: width)
                    hoverTile("Settings", icon: "gearshape", width: width)
                }
                .padding(.horizontal, IslandHoverControlsLayout.horizontalInset)
                .frame(height: IslandHoverControlsLayout.gridHeight(toolCount: 3))
                Rectangle().fill(.white.opacity(0.10)).frame(height: IslandHoverControlsLayout.dividerHeight)
                Text("Questions and answers for this meeting")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.76))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                    .frame(height: IslandHoverControlsLayout.descriptionHeight)
            }.frame(width: width).background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 18))
        }
    }
    private func hoverTile(_ title: String, icon: String, width: CGFloat) -> some View {
        IslandHoverPanelControl(title: title, systemImage: icon, pdfResource: nil, label: nil,
            circleSize: IslandHoverPanelControl.iconSize, accessibilityLabel: title,
            width: (width - IslandHoverControlsLayout.horizontalInset * 2 - IslandHoverControlsLayout.columnSpacing * 2) / 3,
            action: {})
    }
    private func saveHover<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String, directory: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .top).clipped().background(Color(white: 0.10))
            .environment(\.colorScheme, .dark).transaction { $0.disablesAnimations = true })
        host.appearance = NSAppearance(named: .darkAqua) // The real IslandPanel pins darkAqua too.
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name).png"))
    }
    private func render(_ model: MeetingAssistantModel, scheme: ColorScheme, name: String, directory: URL) throws {
        let host = NSHostingView(rootView: MeetingAssistantView(model: model, openSettings: { _ in }).environment(\.colorScheme, scheme))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 354, height: 900)
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.setFrameSize(host.fittingSize)
        }
        if name == "short" { XCTAssertLessThanOrEqual(host.fittingSize.height, 572, "The module must fit with 24pt screen margins") }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }
}
