import XCTest
@testable import Sidekey

@MainActor
final class IslandOutputLanguageControlTests: XCTestCase {
    func test_smart_opens_picker_fast_shows_notice() {
        XCTAssertEqual(IslandOutputLanguageControl.tap(for: .smart), .openPicker)
        XCTAssertEqual(IslandOutputLanguageControl.tap(for: .fast), .showSmartOnlyNotice)
    }

    func test_input_control_renamed_to_input_language() {
        XCTAssertEqual(IslandLanguageControl.title, "Input Language")
    }

    func test_off_option_is_neutral_with_nil_language() {
        let off = IslandLanguageControl.offOption()
        XCTAssertNil(off.language)
        XCTAssertEqual(off.label, "Off")
    }

    func test_output_picker_options_lead_with_off() {
        let options = IslandLanguageControl.pickerOptions(leading: IslandLanguageControl.offOption())
        XCTAssertEqual(options.first?.label, "Off")
        XCTAssertNil(options.first?.language)
    }
}
