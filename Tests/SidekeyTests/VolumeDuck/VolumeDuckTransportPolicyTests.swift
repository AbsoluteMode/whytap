import CoreAudio
import XCTest
@testable import Sidekey

final class VolumeDuckTransportPolicyTests: XCTestCase {
    func test_allowsDucking_builtInAndBluetooth() {
        // Built-in speakers/jack: the codec does not click on volume writes —
        // duck has always been safe here.
        XCTAssertTrue(
            VolumeDuckTransportPolicy.allowsDucking(
                transportType: kAudioDeviceTransportTypeBuiltIn
            ),
            "Built-in output stays duckable."
        )
        // Bluetooth (headphones/speakers): volume is handled digitally on
        // this transport (e.g. AVRCP absolute volume) rather than as the
        // analog hardware-gain step that made wired DACs click, and ducking
        // worked on Bluetooth for the feature's whole life before the #516
        // transport gate cut it off on the wrong premise that Bluetooth
        // volume was never settable. Headphone users rely on ducking to hear
        // themselves dictate over music.
        XCTAssertTrue(
            VolumeDuckTransportPolicy.allowsDucking(
                transportType: kAudioDeviceTransportTypeBluetooth
            ),
            "Bluetooth output must be duckable."
        )
        XCTAssertTrue(
            VolumeDuckTransportPolicy.allowsDucking(
                transportType: kAudioDeviceTransportTypeBluetoothLE
            ),
            "Bluetooth LE output must be duckable."
        )
    }

    func test_refusesDucking_wiredExternalAndUnknown() {
        // Wired external DACs are the confirmed "pop" source (#516): they
        // click on hardware-gain writes and must never be touched.
        for transport in [
            kAudioDeviceTransportTypeUnknown,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeFireWire,
            kAudioDeviceTransportTypePCI,
            kAudioDeviceTransportTypeAirPlay,
            kAudioDeviceTransportTypeAVB,
            kAudioDeviceTransportTypeVirtual,
            kAudioDeviceTransportTypeAggregate,
            kAudioDeviceTransportTypeAutoAggregate,
            kAudioDeviceTransportTypeContinuityCaptureWired,
            kAudioDeviceTransportTypeContinuityCaptureWireless,
        ] {
            XCTAssertFalse(
                VolumeDuckTransportPolicy.allowsDucking(transportType: transport),
                "External transport \(transport) must not be duckable."
            )
        }
        // Missing/unreadable transport counts as external (fail-safe: never
        // touch hardware we can't identify).
        XCTAssertFalse(
            VolumeDuckTransportPolicy.allowsDucking(transportType: nil),
            "Unknown transport must not be duckable."
        )
    }
}
