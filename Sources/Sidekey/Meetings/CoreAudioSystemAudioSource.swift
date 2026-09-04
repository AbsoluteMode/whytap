import CoreAudio
import Foundation
import os.log

/// Audio-only capture of the system mix via CoreAudio Process Tap.
/// Recording meetings through this path lights audio privacy surfaces,
/// not the macOS screen-observation indicator.
final class CoreAudioSystemAudioSource: SystemAudioSourceStreaming, @unchecked Sendable {
    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "system-audio")

    private let stateLock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.sidekey.meetings.coreaudio.tap", qos: .userInitiated)
    private let defaultOutputListenerQueue = DispatchQueue(
        label: "com.sidekey.meetings.coreaudio.default-output",
        qos: .userInitiated
    )

    private var continuations: [UUID: AsyncStream<[Float]>.Continuation] = [:]
    private var isRunning = false
    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var ioProcID: AudioDeviceIOProcID?
    /// The tap describes the bytes/channels in each callback while the
    /// aggregate device owns the IO clock. Those rates can differ when a
    /// Bluetooth headset switches from A2DP to HFP without changing its UID.
    /// Keep them separate so a mono 48 kHz tap description never makes us
    /// resample an aggregate callback that is already arriving at 16 kHz.
    private var captureFormat: SystemAudioCaptureFormat?
    private var activeGeneration: UUID?
    private var callbackRateMonitor = SystemAudioCallbackRateMonitor()
    private var callbackRateMismatchWindows = 0
    private var defaultOutputListenerInstalled = false
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var outputPropertyListenerDeviceID = AudioObjectID(0)
    private var outputPropertyListeners: [InstalledAudioPropertyListener] = []

    /// Session counter for meeting-health telemetry (Task 7): every time the
    /// default output device listener fires, i.e. the user's audio output
    /// route changed. Monotonic within the process — `MeetingRecorder`
    /// snapshots start/stop deltas so always-on listener churn outside a
    /// meeting never leaks in. Guarded by `stateLock` like the rest of this
    /// type's mutable state. Privacy inv. #3: a count only, never a device
    /// name.
    private var outputRouteChangeCountStorage = 0

    private lazy var restartMonitor = AudioCaptureRestartMonitor { [weak self] in
        await self?.restartAfterDefaultOutputChange()
    }

    /// Current value of the output-route-change counter. Thread-safe read
    /// via `stateLock`.
    var outputRouteChangeCount: Int {
        stateLock.lock()
        let count = outputRouteChangeCountStorage
        stateLock.unlock()
        return count
    }

    func audioBufferStream() -> AsyncStream<[Float]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        stateLock.lock()
        continuations[id] = continuation
        stateLock.unlock()

        continuation.onTermination = { @Sendable [weak self] _ in
            self?.removeContinuation(id)
        }
        return stream
    }

    func start() async throws {
        guard !runningSnapshot() else { return }

        let excludedProcessIDs = Self.currentProcessObjectID().map { [$0] } ?? []
        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: excludedProcessIDs)
        tapDescription.name = "Whytap System Audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var createdTapID = AudioObjectID(0)
        try Self.check(AudioHardwareCreateProcessTap(tapDescription, &createdTapID), "AudioHardwareCreateProcessTap")

        let aggregateUID = "com.rootwise.sidekey.system-audio.\(UUID().uuidString)"
        let outputDeviceID = Self.defaultOutputDeviceID()
        let outputDeviceUID = outputDeviceID.flatMap(Self.deviceUID(for:))
        if outputDeviceUID == nil {
            os_log(
                "no default output device resolved; system-audio aggregate has no clock sub-device and may capture silence",
                log: Self.log, type: .error
            )
        }
        let aggregateDescription = Self.makeAggregateDescription(
            name: "Whytap System Audio",
            aggregateUID: aggregateUID,
            outputDeviceUID: outputDeviceUID,
            tapUID: tapDescription.uuid.uuidString
        )

        var createdAggregateID = AudioObjectID(0)
        var createdIOProcID: AudioDeviceIOProcID?
        do {
            try Self.check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdAggregateID),
                "AudioHardwareCreateAggregateDevice"
            )
            let aggregateFormat = try Self.streamFormat(for: createdAggregateID)
            // Decode using the TAP's own stream format, not the aggregate's.
            // With the output device bound as the aggregate's main sub-device
            // (required for the IO clock), the aggregate's input-scope format
            // can describe the output device's channel layout rather than the
            // mono tap. Decoding the mono tap buffer through that layout
            // averages in phantom/silent channels and craters the captured
            // level. The tap's own format is the source of truth (canonical
            // AudioCap pattern); fall back to the aggregate format only if the
            // tap format is unreadable.
            let tapFormat = (try? Self.tapStreamFormat(for: createdTapID)) ?? aggregateFormat
            let resolvedFormat = SystemAudioCaptureFormat(
                decodeFormat: tapFormat,
                clockSampleRate: aggregateFormat.mSampleRate
            )
            let generation = UUID()
            try Self.check(
                AudioDeviceCreateIOProcIDWithBlock(
                    &createdIOProcID,
                    createdAggregateID,
                    ioQueue
                ) { [weak self] _, inputData, _, _, _ in
                    self?.handleInput(
                        inputData,
                        generation: generation,
                        decodeFormat: resolvedFormat.decodeFormat
                    )
                },
                "AudioDeviceCreateIOProcIDWithBlock"
            )
            try Self.check(AudioDeviceStart(createdAggregateID, createdIOProcID), "AudioDeviceStart")

            markRunning(
                tapID: createdTapID,
                aggregateID: createdAggregateID,
                ioProcID: createdIOProcID,
                captureFormat: resolvedFormat,
                generation: generation
            )
            restartMonitor.setActive(true)
            installDefaultOutputDeviceListener()
            if let outputDeviceID {
                installOutputDevicePropertyListeners(deviceID: outputDeviceID)
            }

            os_log(
                "CoreAudio process tap started (output_uid: %{public}@, tap_sr: %{public}.0f, aggregate_sr: %{public}.0f, ch: %{public}d)",
                log: Self.log, type: .info,
                outputDeviceUID ?? "nil",
                tapFormat.mSampleRate,
                aggregateFormat.mSampleRate,
                Int(tapFormat.mChannelsPerFrame)
            )
        } catch {
            if let createdIOProcID {
                AudioDeviceDestroyIOProcID(createdAggregateID, createdIOProcID)
            }
            if createdAggregateID != 0 {
                AudioHardwareDestroyAggregateDevice(createdAggregateID)
            }
            if createdTapID != 0 {
                AudioHardwareDestroyProcessTap(createdTapID)
            }
            throw error
        }
    }

    func stop() async {
        restartMonitor.setActive(false)
        removeDefaultOutputDeviceListener()
        removeOutputDevicePropertyListeners()
        let resources = takeRunningResources()
        stopAndDestroy(resources: resources)
        os_log("CoreAudio process tap stopped", log: Self.log, type: .info)
    }

    deinit {
        restartMonitor.setActive(false)
        removeDefaultOutputDeviceListener()
        removeOutputDevicePropertyListeners()
        let resources = takeRunningResources()
        stopAndDestroy(resources: resources)
        for continuation in continuations.values {
            continuation.finish()
        }
    }

    private func runningSnapshot() -> Bool {
        stateLock.lock()
        let running = isRunning
        stateLock.unlock()
        return running
    }

    private func markRunning(
        tapID newTapID: AudioObjectID,
        aggregateID newAggregateID: AudioObjectID,
        ioProcID newIOProcID: AudioDeviceIOProcID?,
        captureFormat newCaptureFormat: SystemAudioCaptureFormat,
        generation newGeneration: UUID
    ) {
        stateLock.lock()
        tapID = newTapID
        aggregateID = newAggregateID
        ioProcID = newIOProcID
        captureFormat = newCaptureFormat
        activeGeneration = newGeneration
        callbackRateMonitor.reset()
        callbackRateMismatchWindows = 0
        isRunning = true
        stateLock.unlock()
    }

    private func takeRunningResources() -> (
        aggregateID: AudioObjectID,
        tapID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID?
    ) {
        stateLock.lock()
        let resources = (aggregateID: aggregateID, tapID: tapID, ioProcID: ioProcID)
        aggregateID = 0
        tapID = 0
        ioProcID = nil
        captureFormat = nil
        activeGeneration = nil
        callbackRateMonitor.reset()
        callbackRateMismatchWindows = 0
        isRunning = false
        stateLock.unlock()
        return resources
    }

    private func stopAndDestroy(resources: (
        aggregateID: AudioObjectID,
        tapID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID?
    )) {
        if let runningIOProcID = resources.ioProcID, resources.aggregateID != 0 {
            AudioDeviceStop(resources.aggregateID, runningIOProcID)
            AudioDeviceDestroyIOProcID(resources.aggregateID, runningIOProcID)
        }
        if resources.aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(resources.aggregateID)
        }
        if resources.tapID != 0 {
            AudioHardwareDestroyProcessTap(resources.tapID)
        }
    }

    private func restartAfterDefaultOutputChange() async {
        guard runningSnapshot() else { return }
        restartMonitor.setActive(false)
        os_log(
            "default output device changed; restarting CoreAudio process tap",
            log: Self.log,
            type: .info
        )

        removeOutputDevicePropertyListeners()
        let resources = takeRunningResources()
        stopAndDestroy(resources: resources)

        do {
            try await start()
            os_log(
                "CoreAudio process tap restarted after default output device change",
                log: Self.log,
                type: .info
            )
        } catch {
            restartMonitor.setActive(false)
            os_log(
                "CoreAudio process tap restart failed after default output device change %{public}@",
                log: Self.log,
                type: .error,
                String(describing: error)
            )
        }
    }

    private func installDefaultOutputDeviceListener() {
        stateLock.lock()
        if defaultOutputListenerInstalled {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        var address = Self.defaultOutputDeviceAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.recordOutputRouteChange()
            self?.restartMonitor.trigger()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultOutputListenerQueue,
            block
        )
        guard status == noErr else {
            os_log(
                "default output device listener install failed status=%{public}d",
                log: Self.log,
                type: .error,
                Int(status)
            )
            return
        }

        stateLock.lock()
        defaultOutputListenerInstalled = true
        defaultOutputListenerBlock = block
        stateLock.unlock()
    }

    private func removeDefaultOutputDeviceListener() {
        stateLock.lock()
        guard defaultOutputListenerInstalled, let block = defaultOutputListenerBlock else {
            stateLock.unlock()
            return
        }
        defaultOutputListenerInstalled = false
        defaultOutputListenerBlock = nil
        stateLock.unlock()

        var address = Self.defaultOutputDeviceAddress()
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultOutputListenerQueue,
            block
        )
        if status != noErr {
            os_log(
                "default output device listener removal failed status=%{public}d",
                log: Self.log,
                type: .error,
                Int(status)
            )
        }
    }

    /// The default-output UID is not enough to identify a stable route.
    /// Bluetooth headsets keep the same UID while their nominal rate and
    /// stream format change as the microphone enters/leaves HFP. Listen on
    /// the active physical device as well and funnel the event through the
    /// same debounced full tap rebuild as a UID change.
    private func installOutputDevicePropertyListeners(deviceID: AudioObjectID) {
        removeOutputDevicePropertyListeners()

        let addresses = [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        ]

        var installed: [InstalledAudioPropertyListener] = []
        for originalAddress in addresses {
            var address = originalAddress
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.recordOutputRouteChange()
                self?.restartMonitor.trigger()
            }
            let status = AudioObjectAddPropertyListenerBlock(
                deviceID,
                &address,
                defaultOutputListenerQueue,
                block
            )
            if status == noErr {
                installed.append(InstalledAudioPropertyListener(address: address, block: block))
            } else {
                os_log(
                    "output property listener install failed selector=%{public}u status=%{public}d",
                    log: Self.log, type: .error,
                    address.mSelector, Int(status)
                )
            }
        }

        stateLock.lock()
        outputPropertyListenerDeviceID = deviceID
        outputPropertyListeners = installed
        stateLock.unlock()
    }

    private func removeOutputDevicePropertyListeners() {
        stateLock.lock()
        let deviceID = outputPropertyListenerDeviceID
        let listeners = outputPropertyListeners
        outputPropertyListenerDeviceID = 0
        outputPropertyListeners = []
        stateLock.unlock()

        guard deviceID != 0 else { return }
        for listener in listeners {
            var address = listener.address
            let status = AudioObjectRemovePropertyListenerBlock(
                deviceID,
                &address,
                defaultOutputListenerQueue,
                listener.block
            )
            if status != noErr {
                os_log(
                    "output property listener removal failed selector=%{public}u status=%{public}d",
                    log: Self.log, type: .error,
                    address.mSelector, Int(status)
                )
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        stateLock.lock()
        continuations[id] = nil
        stateLock.unlock()
    }

    /// Increments the output-route-change counter. Called from the default
    /// output device listener block, which fires on
    /// `defaultOutputListenerQueue` — `stateLock` synchronizes against reads
    /// on any thread, matching the rest of this type's mutable state.
    private func recordOutputRouteChange() {
        stateLock.lock()
        outputRouteChangeCountStorage += 1
        stateLock.unlock()
    }

    private func handleInput(
        _ inputData: UnsafePointer<AudioBufferList>,
        generation: UUID,
        decodeFormat: AudioStreamBasicDescription
    ) {
        stateLock.lock()
        let isCurrentGeneration = activeGeneration == generation
        stateLock.unlock()
        guard isCurrentGeneration else { return }

        let inputSamples = Self.monoFloatSamples(from: inputData, format: decodeFormat)
        guard !inputSamples.isEmpty else { return }

        let observedRate: Double?
        let sourceSampleRate: Double
        var correctedClock = false
        stateLock.lock()
        observedRate = callbackRateMonitor.observe(
            frameCount: inputSamples.count,
            nowNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        if let observedRate,
           var current = captureFormat,
           current.clockSampleRate > 0 {
            let relativeDelta = abs(observedRate - current.clockSampleRate) / current.clockSampleRate
            if relativeDelta >= 0.20 {
                // A 48 kHz metadata rate with ~16 kHz worth of callback
                // frames is the exact Bluetooth-HFP failure we saw in prod.
                // Correct immediately; waiting for a route event would keep
                // shrinking the system track to one third forever.
                current.clockSampleRate = observedRate
                captureFormat = current
                callbackRateMismatchWindows = 0
                correctedClock = true
            } else if relativeDelta >= 0.05 {
                callbackRateMismatchWindows += 1
                if callbackRateMismatchWindows >= 2 {
                    current.clockSampleRate = observedRate
                    captureFormat = current
                    callbackRateMismatchWindows = 0
                    correctedClock = true
                }
            } else {
                callbackRateMismatchWindows = 0
            }
        }
        sourceSampleRate = captureFormat?.clockSampleRate ?? decodeFormat.mSampleRate
        stateLock.unlock()

        if correctedClock, let observedRate {
            recordOutputRouteChange()
            os_log(
                "system audio callback clock corrected from observed cadence (observed_sr: %{public}.0f, tap_sr: %{public}.0f)",
                log: Self.log, type: .error,
                observedRate, decodeFormat.mSampleRate
            )
        }

        let outputSamples = Self.resample(
            inputSamples,
            sourceSampleRate: sourceSampleRate,
            targetSampleRate: 16_000
        )
        guard !outputSamples.isEmpty else { return }

        stateLock.lock()
        let sinks = Array(continuations.values)
        stateLock.unlock()
        for sink in sinks {
            sink.yield(outputSamples)
        }
    }

    private static func monoFloatSamples(
        from inputData: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription
    ) -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard !buffers.isEmpty else { return [] }

        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(format.mBitsPerChannel)
        let bytesPerSample = max(bitsPerChannel / 8, 1)

        if isNonInterleaved || buffers.count > 1 {
            let decodedChannels = buffers.compactMap { buffer -> [Float]? in
                guard let data = buffer.mData else { return nil }
                let frameCount = Int(buffer.mDataByteSize) / bytesPerSample
                return decodeChannel(
                    data: data,
                    frameCount: frameCount,
                    isFloat: isFloat,
                    bitsPerChannel: bitsPerChannel
                )
            }
            guard !decodedChannels.isEmpty else { return [] }
            return averageChannels(decodedChannels)
        }

        guard let buffer = buffers.first,
              let data = buffer.mData else {
            return []
        }
        let channels = max(Int(buffer.mNumberChannels), Int(format.mChannelsPerFrame), 1)
        let frameCount = Int(buffer.mDataByteSize) / (bytesPerSample * channels)
        var out = [Float](repeating: 0, count: frameCount)
        let raw = UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize))
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channels {
                let offset = (frame * channels + channel) * bytesPerSample
                sum += readSample(
                    raw,
                    offset: offset,
                    isFloat: isFloat,
                    bitsPerChannel: bitsPerChannel
                )
            }
            out[frame] = sum / Float(channels)
        }
        return out
    }

    private static func decodeChannel(
        data: UnsafeMutableRawPointer,
        frameCount: Int,
        isFloat: Bool,
        bitsPerChannel: Int
    ) -> [Float] {
        let bytesPerSample = max(bitsPerChannel / 8, 1)
        let raw = UnsafeRawBufferPointer(start: data, count: frameCount * bytesPerSample)
        var out = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            out[frame] = readSample(
                raw,
                offset: frame * bytesPerSample,
                isFloat: isFloat,
                bitsPerChannel: bitsPerChannel
            )
        }
        return out
    }

    private static func averageChannels(_ channels: [[Float]]) -> [Float] {
        let frameCount = channels.map(\.count).min() ?? 0
        guard frameCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: frameCount)
        for channel in channels {
            for i in 0..<frameCount {
                out[i] += channel[i]
            }
        }
        let scale = 1 / Float(channels.count)
        for i in 0..<frameCount {
            out[i] *= scale
        }
        return out
    }

    private static func readSample(
        _ raw: UnsafeRawBufferPointer,
        offset: Int,
        isFloat: Bool,
        bitsPerChannel: Int
    ) -> Float {
        if isFloat {
            switch bitsPerChannel {
            case 32:
                return raw.load(fromByteOffset: offset, as: Float.self)
            case 64:
                return Float(raw.load(fromByteOffset: offset, as: Double.self))
            default:
                return 0
            }
        }

        switch bitsPerChannel {
        case 16:
            return Float(raw.load(fromByteOffset: offset, as: Int16.self)) / Float(Int16.max)
        case 32:
            return Float(raw.load(fromByteOffset: offset, as: Int32.self)) / Float(Int32.max)
        default:
            return 0
        }
    }

    private static func resample(
        _ samples: [Float],
        sourceSampleRate: Double,
        targetSampleRate: Double
    ) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard sourceSampleRate > 0, targetSampleRate > 0 else { return samples }
        guard abs(sourceSampleRate - targetSampleRate) > 0.5 else { return samples }

        let ratio = sourceSampleRate / targetSampleRate
        let outputCount = max(1, Int(Double(samples.count) / ratio))
        var out = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let sourcePosition = Double(i) * ratio
            let lower = Int(sourcePosition)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            let a = samples[min(lower, samples.count - 1)]
            let b = samples[upper]
            out[i] = a + (b - a) * fraction
        }
        return out
    }

    /// Builds the aggregate-device description that wraps the process tap.
    ///
    /// The aggregate needs a real hardware sub-device to drive its IO clock;
    /// without one the IOProc never pulls the tapped mix and system audio is
    /// captured as silence. We bind the current default output device as the
    /// aggregate's *main* sub-device (canonical Apple / AudioCap pattern) and
    /// drift-compensate the tap against that clock. When no output device can
    /// be resolved (headless / no audio hardware) we fall back to a tap-only
    /// aggregate — best-effort, but capture is moot with no output anyway.
    static func makeAggregateDescription(
        name: String,
        aggregateUID: String,
        outputDeviceUID: String?,
        tapUID: String
    ) -> [String: Any] {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID
                ]
            ]
        ]
        if let outputDeviceUID {
            description[kAudioAggregateDeviceMainSubDeviceKey] = outputDeviceUID
            description[kAudioAggregateDeviceIsStackedKey] = false
            description[kAudioAggregateDeviceSubDeviceListKey] = [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ]
        }
        return description
    }

    private static func streamFormat(for deviceID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &format)
        try check(status, "AudioObjectGetPropertyData(kAudioDevicePropertyStreamFormat)")
        return format
    }

    /// The process tap's own stream format, read directly off the tap object.
    /// This is the authoritative layout of the tapped mix — unlike the
    /// aggregate's input-scope format, it is not skewed by the output
    /// sub-device bound for the IO clock.
    private static func tapStreamFormat(for tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        try check(status, "AudioObjectGetPropertyData(kAudioTapPropertyFormat)")
        return format
    }


    private static func defaultOutputDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// UID of the current default output device — bound into the aggregate as
    /// its clock-driving main sub-device. Uses the same property the route-
    /// change listener watches, so a switch fires a restart that rebinds to
    /// the new device. Returns `nil` when no output device exists.
    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var deviceAddress = defaultOutputDeviceAddress()
        var deviceID = AudioObjectID(0)
        var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress, 0, nil, &deviceSize, &deviceID
        )
        return deviceStatus == noErr && deviceID != 0 ? deviceID : nil
    }

    private static func deviceUID(for deviceID: AudioObjectID) -> String? {
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let uidStatus = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
        }
        guard uidStatus == noErr else { return nil }
        let resolved = uid as String
        return resolved.isEmpty ? nil : resolved
    }

    private static func currentProcessObjectID() -> AudioObjectID? {
        var pid = pid_t(getpid())
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var objectID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPtr,
                &size,
                &objectID
            )
        }
        return status == noErr ? objectID : nil
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw CoreAudioSystemAudioSourceError(operation: operation, status: status)
        }
    }
}

private struct InstalledAudioPropertyListener {
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
}

/// Explicitly separates the process tap's memory layout from the aggregate
/// device's IO clock. They usually share a rate, but Bluetooth HFP is a
/// production-proven counterexample (tap metadata 48 kHz, aggregate callbacks
/// clocked at 16 kHz).
struct SystemAudioCaptureFormat {
    var decodeFormat: AudioStreamBasicDescription
    var clockSampleRate: Double
}

/// Measures actual callback cadence independently of CoreAudio metadata.
/// This is the last line of defence for same-UID profile changes that fail to
/// publish a nominal-rate or stream-format property notification.
struct SystemAudioCallbackRateMonitor {
    private static let observationWindowNanoseconds: UInt64 = 2_000_000_000
    private static let commonRates: [Double] = [
        8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000,
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000
    ]

    private var windowStartNanoseconds: UInt64?
    private var framesSinceWindowStart = 0

    mutating func reset() {
        windowStartNanoseconds = nil
        framesSinceWindowStart = 0
    }

    mutating func observe(frameCount: Int, nowNanoseconds: UInt64) -> Double? {
        guard frameCount > 0 else { return nil }
        guard let start = windowStartNanoseconds else {
            windowStartNanoseconds = nowNanoseconds
            return nil
        }
        guard nowNanoseconds >= start else {
            reset()
            windowStartNanoseconds = nowNanoseconds
            return nil
        }

        framesSinceWindowStart += frameCount
        let elapsed = nowNanoseconds - start
        guard elapsed >= Self.observationWindowNanoseconds else { return nil }

        let rawRate = Double(framesSinceWindowStart) * 1_000_000_000 / Double(elapsed)
        windowStartNanoseconds = nowNanoseconds
        framesSinceWindowStart = 0
        return Self.normalizedCommonRate(rawRate)
    }

    static func normalizedCommonRate(_ observedRate: Double) -> Double? {
        guard observedRate.isFinite, observedRate > 0 else { return nil }
        guard let nearest = commonRates.min(by: {
            abs($0 - observedRate) < abs($1 - observedRate)
        }) else { return nil }
        let relativeDelta = abs(nearest - observedRate) / nearest
        return relativeDelta <= 0.12 ? nearest : nil
    }
}

struct CoreAudioSystemAudioSourceError: Error, Equatable {
    let operation: String
    let status: OSStatus
}
