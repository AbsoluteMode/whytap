import XCTest

/// Costs: the total leads the page, and a feature's model detail opens from
/// anywhere on its row, not only from the name at its left edge.
final class AIUsageCostsLayoutTests: XCTestCase {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Sidekey/Settings/APIAndModels/AIUsageCostsView.swift"),
            encoding: .utf8)
    }

    func test_total_comes_before_the_feature_rows() throws {
        let text = try source()
        let table = try XCTUnwrap(text.range(of: "private var table: some View"))
        let body = text[table.upperBound...]
        let total = try XCTUnwrap(body.range(of: #"Text("Total")"#))
        let header = try XCTUnwrap(body.range(of: #"Text("Feature")"#))
        let rows = try XCTUnwrap(body.range(of: "AIUsageFeatureCostRow(row: row)"))
        XCTAssertLessThan(total.lowerBound, header.lowerBound)
        XCTAssertLessThan(header.lowerBound, rows.lowerBound)
        XCTAssertEqual(body.components(separatedBy: #"Text("Total")"#).count - 1, 1, "one total, not a second one below")
    }

    /// Break caught: the hover lived on the name's button, so the row's empty
    /// middle and its price did nothing.
    func test_the_whole_row_opens_the_model_detail() throws {
        let text = try source()
        let row = try XCTUnwrap(text.range(of: "private struct AIUsageFeatureCostRow: View"))
        let end = try XCTUnwrap(text.range(of: "private func scheduleClose()"))
        let body = String(text[row.upperBound..<end.lowerBound])
        let price = try XCTUnwrap(body.range(of: "AIUsagePriceLabel(events: row.events)"))
        let shape = try XCTUnwrap(body.range(of: ".contentShape(Rectangle())\n        .onHover"))
        XCTAssertLessThan(price.lowerBound, shape.lowerBound, "the hover is on the row that contains the price")
        XCTAssertTrue(body.contains(".onTapGesture { if isEnabled { togglePinned() } }"), "a click anywhere pins it")
        XCTAssertEqual(body.components(separatedBy: ".onHover").count - 1, 2, "the row and the open detail, nothing on the name alone")
        XCTAssertTrue(text.contains("!hovered, !overPopover, !focused, !pinned"),
                      "the detail stays while the pointer is over it, even where it covers the row")
    }
}
