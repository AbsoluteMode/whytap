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
        let rows = try XCTUnwrap(body.range(of: "AIUsageFeatureCostRow(row: row, hover: modelsHover)"))
        XCTAssertLessThan(total.lowerBound, header.lowerBound)
        XCTAssertLessThan(header.lowerBound, rows.lowerBound)
        XCTAssertEqual(body.components(separatedBy: #"Text("Total")"#).count - 1, 1, "one total, not a second one below")
    }

    /// Break caught: the hover lived on the name's button, so the row's empty
    /// middle and its price did nothing.
    func test_the_whole_row_opens_the_model_detail() throws {
        let text = try source()
        let row = try XCTUnwrap(text.range(of: "private struct AIUsageFeatureCostRow: View"))
        let end = try XCTUnwrap(text.range(of: "struct AIUsagePriceLabel: View"))
        let body = String(text[row.upperBound..<end.lowerBound])
        let price = try XCTUnwrap(body.range(of: "AIUsagePriceLabel(events: row.events)"))
        let frame = try XCTUnwrap(body.range(of: ".onGeometryChange(for: CGRect.self)"))
        XCTAssertLessThan(price.lowerBound, frame.lowerBound, "the reported frame is the row that contains the price")
        XCTAssertTrue(body.contains(".onTapGesture { if isEnabled { hover.send(.clicked(row.id)) } }"), "a click anywhere opens it")
        XCTAssertFalse(body.contains("pointerEnteredRow"), "no per-row hover flag decides where the pointer is")
        XCTAssertFalse(text.contains("AIUsageHoverProbeView"),
                       "NSViews inside the ScrollView report the whole window; rows use SwiftUI frames (AIUsageModelsHoverHostingTests)")
        XCTAssertFalse(body.contains("@State private var shown"),
                       "no row owns its own open state; the table's one controller decides (AIUsageModelsHoverTests)")
        XCTAssertTrue(body.contains("hover.isPresented(row.id)"), "each popover shows only its own row")
        let table = try XCTUnwrap(text.range(of: "private var table: some View"))
        let observer = try XCTUnwrap(text.range(of: ".onChange(of: visibleRowIDs, initial: true)"))
        XCTAssertLessThan(observer.lowerBound, table.lowerBound,
                          "rows are retired from outside the conditionally shown table (loading, empty, error)")
    }
}
