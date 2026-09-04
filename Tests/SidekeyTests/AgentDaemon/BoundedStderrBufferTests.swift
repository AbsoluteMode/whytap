import XCTest
@testable import Sidekey

final class BoundedStderrBufferTests: XCTestCase {
    func testKeepsLastBytesWhenOverCap() {
        var buf = BoundedStderrBuffer(maxBytes: 8)
        buf.append(Data("ABCDE".utf8))
        buf.append(Data("FGHIJ".utf8))   // total 10 > cap 8
        XCTAssertEqual(buf.tail, "CDEFGHIJ")  // last 8 bytes
    }

    func testUnderCapKeepsAll() {
        var buf = BoundedStderrBuffer(maxBytes: 1024)
        buf.append(Data("hello".utf8))
        XCTAssertEqual(buf.tail, "hello")
    }

    func testEmptyTail() {
        XCTAssertEqual(BoundedStderrBuffer(maxBytes: 16).tail, "")
    }

    func testSingleChunkLargerThanCap() {
        var buf = BoundedStderrBuffer(maxBytes: 4)
        buf.append(Data("ABCDEFGH".utf8))   // 8 bytes > cap 4
        XCTAssertEqual(buf.tail, "EFGH")     // last 4
    }
}
