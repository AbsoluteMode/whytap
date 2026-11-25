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
        // Asking to find or allow a setting is Permissions, whatever feature it is for.
        let settings = ["Input Monitoring", "Accessibility", "Keyboard control", "Screen Recording",
                        "Microphone", "System audio", "Post Event"]
        let features = ["Drop", "Meeting Notes", "Screenshots", "the Agent", "Subtitles", "Case"]
        for setting in settings {
            for feature in features {
                let question = "Where do I allow \(setting) for \(feature)?"
                XCTAssertEqual(destination(question), .tab(.permissions), question)
            }
            XCTAssertEqual(destination("How do I grant \(setting) to Drop?"), .tab(.permissions), setting)
            XCTAssertEqual(destination("where can I find \(setting)"), .tab(.permissions), setting)
        }
        XCTAssertEqual(destination("screen recording for screenshots"), .tab(.permissions))
        XCTAssertEqual(destination("Where is Input Monitoring in case I need it?"), .tab(.permissions))
        // "in case" is not the Case feature; the Case feature by name still is.
        XCTAssertEqual(destination("in case dictation stops, what do I do?"), .feature(.drop))
        XCTAssertEqual(destination("where do I keep keys in Case"), .feature(.caseVault))
        XCTAssertNil(LilBroLocalGuide.firstFeature(in: "a showcase of tools"))
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

    /// The builder's probe for ticket 581, both intent classes, one to one.
    func test_asking_for_a_setting_opens_permissions_and_a_setting_as_context_keeps_the_feature() {
        let settings = ["Input Monitoring", "Accessibility", "Keyboard control",
                        "Screen Recording", "Microphone", "System audio", "Post Event"]
        let features: [(String, AppFeature)] = [
            ("Drop", .drop), ("Agent", .agent), ("Meeting Notes", .meetings),
            ("Screenshots", .screenshots), ("Subtitles", .translateSubtitles), ("Case", .caseVault),
        ]
        var direct: [(String, LilBroDestination)] = []
        for setting in settings {
            for (name, _) in features {
                direct.append(("Where do I allow \(setting) for \(name)?", .tab(.permissions)))
                direct.append(("For \(name), where can I find \(setting)?", .tab(.permissions)))
            }
        }
        direct += [
            ("Screen Recording for Screenshots", .tab(.permissions)),
            ("Where is Input Monitoring in case I need it?", .tab(.permissions)),
        ]
        var context: [(String, LilBroDestination)] = []
        for setting in settings {
            context += [
                ("How do I use Drop after enabling \(setting)?", .feature(.drop)),
                ("Where is Drop after enabling \(setting)?", .feature(.drop)),
                ("How do I use Drop once I enable \(setting)?", .feature(.drop)),
                ("How do I use Drop when I turn on \(setting)?", .feature(.drop)),
                ("Can I open Screenshots after allowing \(setting)?", .feature(.screenshots)),
            ]
        }
        context += [
            ("How do I dictate with my microphone?", .feature(.drop)),
            ("How do I translate system audio with Subtitles?", .feature(.translateSubtitles)),
            ("Can I enable Drop with my Microphone?", .feature(.drop)),
            ("Where can I find Drop after allowing Microphone?", .feature(.drop)),
            ("Where do I keep keys in Case?", .feature(.caseVault)),
        ]
        XCTAssertEqual(direct.count, 86)
        XCTAssertEqual(context.count, 40)
        for (question, expected) in direct + context {
            XCTAssertEqual(destination(question), expected, question)
        }
    }

    /// The builder's matrix for ticket 585: a setting qualified by where it
    /// lives or who gets it is still asked for directly, and a marker that
    /// introduces the feature ("With Drop …", "When using Screenshots …")
    /// does not make the setting context. The context cases stay context.
    func test_qualified_settings_and_feature_introductions_still_ask_for_the_setting() {
        let settings = ["Input Monitoring", "Accessibility", "Keyboard control",
                        "Screen Recording", "Microphone", "System audio", "Post Event"]
        let features: [(String, AppFeature)] = [
            ("Drop", .drop), ("Agent", .agent), ("Meeting Notes", .meetings),
            ("Screenshots", .screenshots), ("Subtitles", .translateSubtitles), ("Case", .caseVault),
        ]
        let permissions = LilBroDestination.tab(.permissions)
        typealias Template = (String, String, AppFeature) -> (String, LilBroDestination)
        let templates: [Template] = [
            { f, s, _ in ("For \(f), where can I open the macOS \(s) settings?", permissions) },
            { f, s, _ in ("For \(f), how can I grant Whytap \(s) access?", permissions) },
            { f, s, _ in ("For \(f), where do I allow Whytap to use \(s)?", permissions) },
            { f, s, _ in ("With \(f) can I enable \(s)?", permissions) },
            { f, s, _ in ("When using \(f) can I allow \(s)?", permissions) },
            { f, s, _ in ("For \(f), where can I open the \(s) settings?", permissions) },
            { f, s, _ in ("While using \(f), where do I give Whytap access to \(s)?", permissions) },
            { f, s, _ in ("With \(f), how do I turn on the System \(s) permission?", permissions) },
            { f, s, id in ("How do I use \(f) after I grant Whytap \(s) access?", .feature(id)) },
            { f, s, id in ("Can I use \(f) with my \(s) permission?", .feature(id)) },
            { f, s, id in ("Where is \(f) once I allow Whytap to use \(s)?", .feature(id)) },
            { f, s, id in ("Can I use \(f) with the macOS \(s) setting?", .feature(id)) },
        ]
        var checked = 0
        for template in templates {
            for (name, id) in features {
                for setting in settings {
                    let (question, expected) = template(name, setting, id)
                    XCTAssertEqual(destination(question), expected, question)
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 504)
    }

    /// The builder's matrices for tickets 590, 594 and 597: who turns, switches
    /// or gives the setting. "we", "please" and an instruction after a comma
    /// or a sentence ask for it; Drop doing it on its own does not, with or
    /// without commas inside the question.
    func test_the_person_turning_on_or_giving_a_setting_asks_for_it() {
        let settings = ["Input Monitoring", "Accessibility", "Keyboard control",
                        "Screen Recording", "Microphone", "System audio", "Post Event"]
        let features: [(String, AppFeature)] = [
            ("Drop", .drop), ("Agent", .agent), ("Meeting Notes", .meetings),
            ("Screenshots", .screenshots), ("Subtitles", .translateSubtitles), ("Case", .caseVault),
        ]
        let permissions = LilBroDestination.tab(.permissions)
        typealias Template = (String, String, AppFeature) -> (String, LilBroDestination)
        let templates: [Template] = [
            { f, s, _ in ("For \(f), can I turn on the \(s) permission?", permissions) },
            { f, s, _ in ("For \(f), can we turn on the \(s) permission?", permissions) },
            { f, s, _ in ("For \(f), how do we switch on \(s)?", permissions) },
            { f, s, _ in ("For \(f), please turn on \(s).", permissions) },
            { f, s, _ in ("For \(f), turn on \(s).", permissions) },
            { f, s, _ in ("For \(f), give \(s) access.", permissions) },
            { f, s, _ in ("For \(f), can we give \(s) access?", permissions) },
            { f, s, _ in ("I am using \(f). Switch on \(s).", permissions) },
            { f, s, _ in ("For \(f), please give \(s) access.", permissions) },
            { f, s, _ in ("For \(f), can I give \(s) access?", permissions) },
            { f, s, _ in ("For \(f), grant \(s) access.", permissions) },
            { f, s, _ in ("For \(f), can I switch \(s) off?", permissions) },
            { f, s, id in ("Does \(f) turn on \(s) automatically?", .feature(id)) },
            { f, s, _ in ("When using \(f) on this Mac, can I enable \(s)?", permissions) },
            { f, s, _ in ("To get started with \(f) on this Mac, enable \(s).", permissions) },
            { f, s, id in ("How do I use \(f) with the macOS \(s) setting?", .feature(id)) },
            { f, s, id in ("How can I use \(f) after macOS asks whether I can allow \(s)?", .feature(id)) },
            { f, s, id in ("Does \(f) switch \(s) on by itself?", .feature(id)) },
            { f, s, id in ("Will \(f) give \(s) access to other apps?", .feature(id)) },
            // Ticket 594: a comma inside a question about the feature's own behaviour.
            { f, s, _ in ("I use \(f). Switch on \(s).", permissions) },
            { f, s, id in ("Does \(f) turn on \(s) by default?", .feature(id)) },
            { f, s, id in ("Does \(f), by default, turn on \(s)?", .feature(id)) },
            { f, s, id in ("Does \(f), when it closes, switch \(s) off?", .feature(id)) },
            { f, s, id in ("Does \(f), without asking, give \(s) access to other apps?", .feature(id)) },
            { f, s, id in ("Does \(f) open at login, turn on \(s), and start automatically?", .feature(id)) },
            { f, s, id in ("At login, does \(f) turn on \(s) by default?", .feature(id)) },
            { f, s, id in ("On this Mac, does \(f) switch \(s) off when it closes?", .feature(id)) },
            { f, s, _ in ("How do I set up \(f), turn on \(s)?", permissions) },
            { f, s, _ in ("Can we, for \(f), turn on \(s)?", permissions) },
            // Ticket 597: the question has to open its own sentence.
            { f, s, _ in ("\(f) is installed; turn on \(s).", permissions) },
            { f, s, _ in ("\(f) is installed, turn on \(s).", permissions) },
            { f, s, _ in ("\(f) can start now; switch \(s) off.", permissions) },
            { f, s, _ in ("\(f) can start now, switch \(s) off.", permissions) },
            { f, s, _ in ("I know what \(f) can do, give \(f) \(s) access.", permissions) },
            { f, s, _ in ("\(f) is installed. Turn on \(s).", permissions) },
            { f, s, _ in ("\(f) is installed, can you turn on \(s)?", permissions) },
            { f, s, _ in ("\(f) is installed. Switch on \(s).", permissions) },
            { f, s, _ in ("Does \(f) work? Turn off \(s).", permissions) },
            { f, s, _ in ("Does \(f) work? Turn \(s) off.", permissions) },
            { f, s, _ in ("\(f) is ready! Switch off \(s).", permissions) },
            { f, s, _ in ("Does \(f) work? Give \(f) \(s) access.", permissions) },
            { f, s, _ in ("Does \(f) work? Give \(f) access to \(s).", permissions) },
            { f, s, _ in ("Does \(f) work? Grant \(f) \(s) access.", permissions) },
            { f, s, _ in ("Does \(f) work? Grant \(f) access to \(s).", permissions) },
            { f, s, _ in ("Does \(f) work? Enable \(s).", permissions) },
            { f, s, _ in ("The first step for \(f) is this: turn on \(s).", permissions) },
            { f, s, _ in ("Does \(f) work? Turn on \(s).", permissions) },
            { f, s, id in ("Doesn't \(f), by default, turn on \(s)?", .feature(id)) },
            { f, s, id in ("Can't \(f) start now, switch \(s) off, and stop cleanly?", .feature(id)) },
            { f, s, id in ("Won't \(f), by default, turn \(s) access off?", .feature(id)) },
            { f, s, id in ("Wouldn't \(f), without asking, give \(s) access to other apps?", .feature(id)) },
            { f, s, id in ("Does \(f), by default,\nturn on \(s)?", .feature(id)) },
            { f, s, id in ("Why does \(f), by default, turn on \(s)?", .feature(id)) },
            { f, s, id in ("Can I use \(f) without turning on \(s)?", .feature(id)) },
        ]
        var checked = 0
        for template in templates {
            for (name, id) in features {
                for setting in settings {
                    let (question, expected) = template(name, setting, id)
                    XCTAssertEqual(destination(question), expected, question)
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 2268)
    }

    /// An independent review of that fix: other everyday ways to ask for a
    /// setting or to mention one in passing.
    func test_other_ways_to_ask_for_a_setting_or_mention_it_in_passing() {
        let cases: [(String, LilBroDestination)] = [
            ("For Drop, how do I turn Microphone on?", .tab(.permissions)),
            ("How do I give Drop access to the Microphone?", .tab(.permissions)),
            ("Can I use Drop without having to enable Microphone?", .feature(.drop)),
            ("I tried using Drop with Microphone disabled. Where do I enable Microphone?", .tab(.permissions)),
            ("Can I use Drop after I go into System Settings and enable Microphone?", .feature(.drop)),
            ("For Drop, if prompted can I turn on Microphone?", .tab(.permissions)),
            ("Can I use Drop if Zoom says to enable Microphone?", .feature(.drop)),
            ("If I use Agent can I allow Accessibility?", .tab(.permissions)),
            ("While dictating with Drop can I turn on Microphone?", .tab(.permissions)),
            ("When I open Drop, where do I allow Microphone?", .tab(.permissions)),
            ("Does Agent work when Accessibility is off?", .feature(.agent)),
            ("How do I use Screenshots if Screen Recording is denied?", .feature(.screenshots)),
            ("After allowing Microphone, how do I use Drop?", .feature(.drop)),
            ("Can I use Subtitles with System audio?", .feature(.translateSubtitles)),
            ("Does Drop automatically turn the Microphone on?", .feature(.drop)),
            ("When using Drop is there a way to turn on Microphone access?", .tab(.permissions)),
            ("Does Drop give other apps access to my Microphone?", .feature(.drop)),
            ("Can I use Drop if I don't enable Microphone access? Microphone access is blocked on this Mac.",
             .feature(.drop)),
            ("Can I set up Drop before learning how to enable Microphone access?", .feature(.drop)),
            ("When using Drop where is Accessibility?", .tab(.permissions)),
            ("Can you help with Drop and show me where to enable Microphone access?", .tab(.permissions)),
            ("Does Drop automatically turn on my Mac microphone?", .feature(.drop)),
            ("Can I use Drop with Microphone off? I can't enable Microphone access.", .feature(.drop)),
            ("How do I give Drop Microphone access?", .tab(.permissions)),
            ("For Drop, how do I turn the Microphone off?", .tab(.permissions)),
            ("How do I turn on Microphone?", .tab(.permissions)),
            ("Where do I disable Screen Recording for Screenshots?", .tab(.permissions)),
        ]
        for (question, expected) in cases {
            XCTAssertEqual(destination(question), expected, question)
        }
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
