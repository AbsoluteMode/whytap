import XCTest
@testable import Sidekey

/// The sprite sheet, the route over the window, the balloon around him and
/// the local guide: everything about Lil Bro that is plain data.
final class LilBroAtlasTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/LilBro")
    }

    func test_the_built_in_sheet_is_the_one_in_resources() throws {
        for (name, embedded) in [("lilbro-hood.json", LilBroAtlasData.json),
                                 ("lilbro-hood-light.png", LilBroAtlasData.lightPNG),
                                 ("lilbro-hood-dark.png", LilBroAtlasData.darkPNG)] {
            let file = try Data(contentsOf: resources.appendingPathComponent(name))
            XCTAssertEqual(file.base64EncodedString(), embedded,
                           "\(name) changed: run python3 scripts/lilbro-embed-atlas.py")
        }
    }

    func test_every_pose_has_frames_and_every_frame_is_drawn() throws {
        let atlas = try XCTUnwrap(LilBroAtlas.shared)
        XCTAssertGreaterThanOrEqual(atlas.spec.frames.count, 36)
        XCTAssertEqual(atlas.pointSize, CGSize(width: 28, height: 32))
        for pose in LilBroPose.allCases {
            let animation = atlas.animation(for: pose)
            XCTAssertFalse(animation.frames.isEmpty, pose.rawValue)
            for frame in animation.frames {
                XCTAssertNotNil(atlas.image(frame, dark: false), frame)
                XCTAssertNotNil(atlas.image(frame, dark: true), frame)
            }
        }
    }

    func test_a_looping_pose_repeats_and_a_single_one_holds_its_last_frame() throws {
        let atlas = try XCTUnwrap(LilBroAtlas.shared)
        let run = atlas.animation(for: .run)
        XCTAssertTrue(run.loop)
        let lap = Double(run.ms * run.frames.count) / 1000
        XCTAssertEqual(atlas.frameName(for: .run, elapsed: 0), atlas.frameName(for: .run, elapsed: lap))
        let jump = atlas.animation(for: .jump)
        XCTAssertFalse(jump.loop)
        XCTAssertEqual(atlas.frameName(for: .jump, elapsed: 60), jump.frames.last)
    }

    func test_a_broken_sheet_is_refused_rather_than_drawn_wrong() {
        let json = Data(#"{"version":1,"cell":{"width":14,"height":16},"columns":8,"pointsPerPixel":2,"frames":["a"],"animations":{"idle":{"frames":["a"],"ms":100,"loop":true}}}"#.utf8)
        XCTAssertThrowsError(try LilBroAtlas(json: json, lightPNG: Data(), darkPNG: Data()))
    }
}

final class LilBroPlannerTests: XCTestCase {
    /// Sidebar entry at the bottom left; a card high in the pane, a card
    /// just above the entry, and a low wide card in the pane.
    private func map() -> LilBroMap {
        var map = LilBroMap()
        map.bounds = CGRect(x: 0, y: 0, width: 960, height: 560)
        map.spots = [.home: CGRect(x: 10, y: 470, width: 200, height: 34),
                     .sidebar: CGRect(x: 0, y: 0, width: 220, height: 460),
                     .pane: CGRect(x: 221, y: 0, width: 739, height: 560)]
        map.blocks = [CGRect(x: 245, y: 90, width: 690, height: 150),
                      CGRect(x: 245, y: 420, width: 690, height: 100),
                      CGRect(x: 10, y: 400, width: 200, height: 30)]
        return map
    }

    func test_along_his_own_block_he_just_runs() {
        let moves = LilBroPlanner.route(from: CGPoint(x: 60, y: 471), to: CGPoint(x: 150, y: 471),
                                        in: map(), reduceMotion: false)
        XCTAssertEqual(moves, [.run(to: CGPoint(x: 150, y: 471))])
    }

    func test_a_block_within_reach_is_one_jump() {
        let moves = LilBroPlanner.route(from: CGPoint(x: 176, y: 471), to: CGPoint(x: 300, y: 421),
                                        in: map(), reduceMotion: false)
        XCTAssertEqual(moves, [.jump(to: CGPoint(x: 300, y: 421))])
    }

    func test_a_block_too_high_to_jump_needs_the_ladder_from_underneath() {
        // From the low card up to the high one: he stands under it, climbs, runs.
        let moves = LilBroPlanner.route(from: CGPoint(x: 300, y: 421), to: CGPoint(x: 700, y: 91),
                                        in: map(), reduceMotion: false)
        XCTAssertEqual(moves.count, 3)
        guard case .run(let foot, _) = moves[0], case .ladder(let from, let to) = moves[1],
              case .run(let end, _) = moves[2] else { return XCTFail("\(moves)") }
        XCTAssertEqual(foot.y, 421)
        XCTAssertEqual(from, foot)
        XCTAssertEqual(to, CGPoint(x: foot.x, y: 91))
        XCTAssertGreaterThan(LilBroPlanner.maxJumpRise, 0)
        XCTAssertEqual(end, CGPoint(x: 700, y: 91))
    }

    func test_from_home_to_a_high_block_elsewhere_he_drops_to_the_floor_then_climbs() {
        let moves = LilBroPlanner.route(from: CGPoint(x: 176, y: 471), to: CGPoint(x: 600, y: 91),
                                        in: map(), reduceMotion: false)
        guard let ladderIndex = moves.firstIndex(where: { if case .ladder = $0 { return true }; return false }),
              case .ladder(let from, let to) = moves[ladderIndex] else { return XCTFail("\(moves)") }
        XCTAssertEqual(from.y, 554, "the window floor")
        XCTAssertEqual(to.y, 91)
        XCTAssertTrue((245...935).contains(from.x), "the ladder stands under the card")
    }

    func test_with_reduced_motion_he_appears_there() {
        let moves = LilBroPlanner.route(from: CGPoint(x: 176, y: 471), to: CGPoint(x: 600, y: 91),
                                        in: map(), reduceMotion: true)
        XCTAssertEqual(moves, [.appear(at: CGPoint(x: 600, y: 91))])
    }

    func test_already_there_is_no_move() {
        XCTAssertEqual(LilBroPlanner.route(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 11, y: 10),
                                           in: map(), reduceMotion: false), [])
    }

    func test_cards_scrolled_out_of_the_pane_are_not_platforms() {
        var map = map()
        map.blocks.append(CGRect(x: 245, y: 900, width: 690, height: 80))
        map.blocks.append(CGRect(x: 245, y: -200, width: 690, height: 80))
        XCTAssertEqual(map.platforms.count, 3)
        XCTAssertEqual(map.homeStand, CGPoint(x: 176, y: 471))
    }

    func test_a_jump_arcs_above_both_ends() {
        let segment = LilBroSegment.jump(from: CGPoint(x: 0, y: 100), to: CGPoint(x: 100, y: 100), at: Date(timeIntervalSince1970: 0))
        let middle = segment.position(at: Date(timeIntervalSince1970: segment.duration / 2))
        XCTAssertLessThan(middle.y, 100)
        XCTAssertEqual(segment.position(at: Date(timeIntervalSince1970: 99)), CGPoint(x: 100, y: 100))
    }
}

final class LilBroBalloonLayoutTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 960, height: 560)
    private let balloon = CGSize(width: 296, height: 150)
    private let field = CGSize(width: 210, height: 30)

    private func assertInside(_ layout: LilBroBalloonLayout, file: StaticString = #filePath, line: UInt = #line) {
        let inner = bounds.insetBy(dx: 9, dy: 9)
        XCTAssertTrue(inner.contains(layout.balloon), "\(layout.balloon)", file: file, line: line)
        XCTAssertTrue(inner.contains(layout.field), "\(layout.field)", file: file, line: line)
        XCTAssertFalse(layout.balloon.intersects(layout.field), file: file, line: line)
    }

    func test_in_the_middle_the_balloon_is_above_him_with_the_tail_down() {
        let layout = LilBroBalloonLayout.around(feet: CGPoint(x: 400, y: 400), balloon: balloon, field: field,
                                                bounds: bounds, target: nil)
        XCTAssertEqual(layout.tail, .down)
        XCTAssertLessThan(layout.balloon.maxY, 400 - 31)
        assertInside(layout)
    }

    func test_near_the_top_it_hangs_below_him() {
        let layout = LilBroBalloonLayout.around(feet: CGPoint(x: 400, y: 80), balloon: balloon, field: field,
                                                bounds: bounds, target: nil)
        XCTAssertEqual(layout.tail, .up)
        assertInside(layout)
    }

    func test_at_the_right_edge_everything_stays_in_the_window() {
        let layout = LilBroBalloonLayout.around(feet: CGPoint(x: 938, y: 360), balloon: balloon, field: field,
                                                bounds: bounds, target: nil)
        assertInside(layout)
        XCTAssertLessThan(layout.field.maxX, 938 - 14, "the field moves to his left")
    }

    func test_at_the_bottom_edge_the_balloon_is_above() {
        let layout = LilBroBalloonLayout.around(feet: CGPoint(x: 520, y: 554), balloon: balloon, field: field,
                                                bounds: bounds, target: nil)
        XCTAssertEqual(layout.tail, .down)
        assertInside(layout)
    }

    func test_on_a_block_the_balloon_does_not_cover_it() {
        let target = CGRect(x: 245, y: 300, width: 690, height: 90)
        let layout = LilBroBalloonLayout.around(feet: CGPoint(x: 889, y: 301), balloon: balloon, field: field,
                                                bounds: bounds, target: target)
        XCTAssertLessThanOrEqual(layout.balloon.maxY, target.minY)
        assertInside(layout)
    }

    func test_without_the_little_guy_it_grows_from_the_sidebar_entry() {
        let entry = CGRect(x: 10, y: 470, width: 200, height: 34)
        let layout = LilBroBalloonLayout.above(entry: entry, balloon: balloon, field: field, bounds: bounds)
        XCTAssertLessThan(layout.field.maxY, entry.minY)
        XCTAssertLessThan(layout.balloon.maxY, layout.field.minY)
        XCTAssertEqual(layout.balloon.minX, entry.minX)
    }
}

@MainActor
final class LilBroLocalGuideTests: XCTestCase {
    private func destination(_ question: String) -> LilBroDestination? {
        if case .answer(let answer) = LilBroLocalGuide.match(question) { return answer.destination }
        return nil
    }

    func test_people_find_features_by_their_own_words() {
        XCTAssertEqual(destination("how do I dictate"), .feature(.drop))
        XCTAssertEqual(destination("Set up dictation"), .feature(.drop))
        XCTAssertEqual(destination("Turn on meeting notes"), .feature(.meetings))
        XCTAssertEqual(destination("What can the Agent do?"), .feature(.agent))
        XCTAssertEqual(destination("translate a video"), .feature(.translateSubtitles))
        XCTAssertEqual(destination("change island tools"), .feature(.hover))
    }

    func test_exact_names_win_over_broader_words() {
        // macOS settings are Permissions, though "monitor" is a feature word.
        for question in ["Where is Input Monitoring?", "allow accessibility", "Keyboard control is off",
                         "allow screen recording", "microphone access", "Is system audio allowed?",
                         "where is Post Event"] {
            XCTAssertEqual(destination(question), .tab(.permissions), question)
        }
        // A setting named as context of a feature request is that feature.
        XCTAssertEqual(destination("How do I dictate with my microphone?"), .feature(.drop))
        XCTAssertEqual(destination("How do I translate system audio with Subtitles?"),
                       .feature(.translateSubtitles))
        for setting in ["Input Monitoring", "Accessibility", "Keyboard control", "Screen Recording",
                        "Microphone", "System audio", "Post Event"] {
            XCTAssertEqual(destination("How do I use Drop after enabling \(setting)?"), .feature(.drop), setting)
        }
        // The most specific feature word wins over an earlier feature's alias.
        XCTAssertEqual(destination("How do I use Google voice search?"), .feature(.googleSearch))
        XCTAssertEqual(destination("google search shortcut"), .feature(.googleSearch))
        // Ordinary questions keep their place.
        XCTAssertEqual(destination("how do I dictate"), .feature(.drop))
        XCTAssertEqual(destination("voice typing"), .feature(.drop))
        XCTAssertEqual(destination("dictation shortcut"), .feature(.drop))
        XCTAssertEqual(destination("server monitor dashboard"), .feature(.monitor))
        XCTAssertEqual(destination("Turn on meeting notes"), .feature(.meetings))
    }

    func test_a_hotkey_is_not_an_api_key() {
        XCTAssertEqual(destination("change a hotkey"), .tab(.hotkeys))
        XCTAssertEqual(destination("where do I paste my OpenAI key"), .apiKeys)
        XCTAssertEqual(destination("allow the microphone"), .tab(.permissions))
    }

    func test_an_answer_says_what_the_feature_does_from_the_catalog() {
        guard case .answer(let answer) = LilBroLocalGuide.match("dictation") else { return XCTFail() }
        let info = FeatureCatalog.info(for: .drop)
        XCTAssertEqual(answer.paragraphs.first, info.about.isEmpty ? "Drop: \(info.line)" : info.about)
        XCTAssertFalse(answer.followUps.contains("Set up dictation"))
    }

    func test_anything_else_gets_questions_he_can_answer() {
        XCTAssertEqual(LilBroLocalGuide.match("what is the meaning of life"),
                       .unknown(suggestions: LilBroLocalGuide.starters))
        for starter in LilBroLocalGuide.starters {
            XCTAssertNotNil(destination(starter), starter)
        }
    }
}
