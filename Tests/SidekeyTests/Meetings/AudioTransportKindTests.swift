import CoreAudio
import XCTest
@testable import Sidekey

/// Mapping-only coverage for `AudioTransportKind.from(transportType:)`.
/// `defaultDevice(isInput:)` touches live CoreAudio hardware state and is
/// exercised manually rather than in a unit test (see Task 7 brief).
final class AudioTransportKindTests: XCTestCase {
    func test_from_bluetooth_mapsToBluetooth() {
        XCTAssertEqual(
            AudioTransportKind.from(transportType: kAudioDeviceTransportTypeBluetooth),
            .bluetooth
        )
    }

    func test_from_bluetoothLE_mapsToBluetooth() {
        XCTAssertEqual(
            AudioTransportKind.from(transportType: kAudioDeviceTransportTypeBluetoothLE),
            .bluetooth
        )
    }

    func test_from_builtIn_mapsToBuiltin() {
        XCTAssertEqual(
            AudioTransportKind.from(transportType: kAudioDeviceTransportTypeBuiltIn),
            .builtin
        )
    }

    func test_from_usb_mapsToUsb() {
        XCTAssertEqual(
            AudioTransportKind.from(transportType: kAudioDeviceTransportTypeUSB),
            .usb
        )
    }

    func test_from_unknownTransport_mapsToOther() {
        XCTAssertEqual(
            AudioTransportKind.from(transportType: kAudioDeviceTransportTypeAggregate),
            .other
        )
    }
}
