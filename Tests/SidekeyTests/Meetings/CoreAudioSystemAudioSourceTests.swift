import CoreAudio
import XCTest
@testable import Sidekey

/// Aggregate-device description contract for the CoreAudio system-audio
/// process tap. The tap is wrapped in a private aggregate device; for the
/// aggregate's IOProc to actually pull the captured mix it needs a real
/// hardware sub-device to drive the IO clock. The canonical pattern (Apple
/// "Capturing system audio with Core Audio taps" / insidegui AudioCap) uses
/// the current default output device as the aggregate's *main* sub-device.
///
/// Regression guard: a previous shape created the aggregate with the tap
/// only (no sub-device). That aggregate has no clock-driving device, so the
/// IOProc never delivered the system mix — system audio was silent in
/// recordings and the system waveform stayed flat while the mic path
/// (separate AVAudioEngine) kept working.
final class CoreAudioSystemAudioSourceTests: XCTestCase {

    private let deviceName = "Whytap System Audio"
    private let aggregateUID = "com.rootwise.sidekey.system-audio.TEST-UID"
    private let tapUID = "TAP-UUID-1234"

    func test_aggregateDescription_bindsOutputDeviceAsMainSubDevice() {
        let outputUID = "BuiltInSpeakerDevice-UID"
        let description = CoreAudioSystemAudioSource.makeAggregateDescription(
            name: deviceName,
            aggregateUID: aggregateUID,
            outputDeviceUID: outputUID,
            tapUID: tapUID
        )

        XCTAssertEqual(
            description[kAudioAggregateDeviceMainSubDeviceKey] as? String,
            outputUID,
            "Aggregate must bind the default output device as its main sub-device so the IOProc has a clock to pull the tapped mix."
        )

        let subDeviceList = description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
        XCTAssertEqual(
            subDeviceList?.first?[kAudioSubDeviceUIDKey] as? String,
            outputUID,
            "Aggregate sub-device list must contain the output device UID."
        )

        XCTAssertEqual(
            description[kAudioAggregateDeviceIsStackedKey] as? Bool,
            false,
            "Aggregate must be non-stacked (multi-output) so the tap + output run as one clocked device."
        )
    }

    func test_aggregateDescription_alwaysContainsTapWithDriftCompensation() {
        let description = CoreAudioSystemAudioSource.makeAggregateDescription(
            name: deviceName,
            aggregateUID: aggregateUID,
            outputDeviceUID: "AnyOutput-UID",
            tapUID: tapUID
        )

        let tapList = description[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        XCTAssertEqual(
            tapList?.first?[kAudioSubTapUIDKey] as? String,
            tapUID,
            "Tap list must reference the created process tap by UID."
        )
        XCTAssertEqual(
            tapList?.first?[kAudioSubTapDriftCompensationKey] as? Bool,
            true,
            "Tap must drift-compensate against the output sub-device clock."
        )
        XCTAssertEqual(description[kAudioAggregateDeviceUIDKey] as? String, aggregateUID)
        XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertEqual(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool, true)
    }

    func test_aggregateDescription_withoutOutputDevice_omitsSubDeviceBinding() {
        let description = CoreAudioSystemAudioSource.makeAggregateDescription(
            name: deviceName,
            aggregateUID: aggregateUID,
            outputDeviceUID: nil,
            tapUID: tapUID
        )

        XCTAssertNil(
            description[kAudioAggregateDeviceMainSubDeviceKey],
            "With no resolvable output device there is nothing to bind; fall back to a tap-only aggregate rather than inventing a sub-device."
        )
        XCTAssertNil(description[kAudioAggregateDeviceSubDeviceListKey])
        // The tap itself must still be present so the best-effort fallback
        // at least attempts capture.
        XCTAssertNotNil(description[kAudioAggregateDeviceTapListKey])
    }

    func test_captureFormat_keepsTapLayoutAndAggregateClockSeparate() {
        let tapFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let format = SystemAudioCaptureFormat(
            decodeFormat: tapFormat,
            clockSampleRate: 16_000
        )

        XCTAssertEqual(format.decodeFormat.mSampleRate, 48_000)
        XCTAssertEqual(format.decodeFormat.mChannelsPerFrame, 1)
        XCTAssertEqual(format.clockSampleRate, 16_000)
    }

    func test_callbackRateMonitor_detectsBluetoothHFPClock() {
        var monitor = SystemAudioCallbackRateMonitor()
        let interval: UInt64 = 100_000_000

        var observed: Double?
        for callback in 0...20 {
            observed = monitor.observe(
                frameCount: 1_600,
                nowNanoseconds: UInt64(callback) * interval
            ) ?? observed
        }

        XCTAssertEqual(observed, 16_000)
    }

    func test_callbackRateMonitor_preservesFortyEightKilohertzClock() {
        var monitor = SystemAudioCallbackRateMonitor()
        let interval: UInt64 = 100_000_000

        var observed: Double?
        for callback in 0...20 {
            observed = monitor.observe(
                frameCount: 4_800,
                nowNanoseconds: UInt64(callback) * interval
            ) ?? observed
        }

        XCTAssertEqual(observed, 48_000)
    }

    func test_callbackRateMonitor_rejectsImplausibleCadence() {
        XCTAssertNil(SystemAudioCallbackRateMonitor.normalizedCommonRate(37_000))
        XCTAssertNil(SystemAudioCallbackRateMonitor.normalizedCommonRate(.nan))
        XCTAssertNil(SystemAudioCallbackRateMonitor.normalizedCommonRate(0))
    }
}
