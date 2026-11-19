import XCTest
@testable import Sidekey

/// Meeting audio stays on disk only while it can still become a note.
///
/// Each test is a launch (or full wake) of the app over a staging directory
/// left in a given state: a recent failure, an old failure, leftovers without
/// a manifest, a Reconnect part. Real `MeetingsStore` and real files in a
/// temp directory with backdated modification times; only the processor is a
/// spy that never touches the staging directory.
@MainActor
final class MeetingsStagedAudioRetentionTests: XCTestCase {
    private var tempRoot: URL!
    private var testDefaults: UserDefaults!
    private var defaultsSuiteName: String!

    private var meetingsRoot: URL { tempRoot.appendingPathComponent("Meetings") }
    private var stagingRoot: URL { tempRoot.appendingPathComponent("meetings-staging") }

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "com.sidekey.meetings.retention.tests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("staged-audio-retention-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        testDefaults.removePersistentDomain(forName: defaultsSuiteName)
        testDefaults = nil
        defaultsSuiteName = nil
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - Failed processing

    /// Break caught: the retention sweep deletes a recording the next launch
    /// could still turn into a note.
    func test_failed_meeting_from_today_keeps_its_audio_and_is_retried_on_launch() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.upsertProgress(meta: meta(id: id, status: .failed), status: .failed, failureReason: "Soniox file API HTTP 503.")
        let dir = try stageRecording(id: id, lastChunkHoursAgo: 23)
        let processor = SpyDirectProcessor()
        let coordinator = makeCoordinator(store: store, processor: processor)

        await coordinator.recoverFinalizeManifestsOnLaunch()

        XCTAssertEqual(processor.processedIds, [id], "a recent failure is retried")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("chunk-000.wav").path))
    }

    /// Break caught: a meeting that never gets a note keeps its audio forever
    /// and is retried on every launch, even though every retry rewrote its
    /// manifest and Soniox checkpoint a moment ago.
    func test_failed_meeting_older_than_a_day_loses_its_audio_and_is_not_retried() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.upsertProgress(meta: meta(id: id, status: .failed), status: .failed, failureReason: "Soniox file API HTTP 503.")
        let dir = try stageRecording(id: id, lastChunkHoursAgo: 25, manifestAndCheckpointHoursAgo: 0)
        let processor = SpyDirectProcessor()
        let coordinator = makeCoordinator(store: store, processor: processor)

        await coordinator.recoverFinalizeManifestsOnLaunch()
        await coordinator.recoverFinalizeManifestsOnLaunch()

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "no audio is kept after the retry window")
        XCTAssertTrue(processor.processedIds.isEmpty, "an expired recording is never processed again")
        let state = try await store.progressState(id: id)
        XCTAssertEqual(state?.status, .failed, "the meeting stays listed so the user sees what happened")
        XCTAssertEqual(state?.failureReason, MeetingsCoordinator.recordingExpiredMessage)
    }

    /// Break caught: expiry of the extra part of a reconnected meeting leaves
    /// the meeting failed or updating for good, although its first part has a
    /// stored note, or touches that note.
    func test_expired_reconnect_part_leaves_its_meeting_ready_with_the_stored_note() async throws {
        for parentState in ["ready", "updating", "failed"] {
            let store = try MeetingsStore(rootDirectory: tempRoot.appendingPathComponent("Meetings-\(parentState)"))
            let meetingId = UUID()
            try await store.insert(meta: meta(id: meetingId, status: .ready), markdown: "# Planning\n\nFirst part.")
            if parentState != "ready" {
                // Processing of the added part began (and possibly failed).
                try await store.beginContinuationUpdate(id: meetingId)
            }
            if parentState == "failed" {
                try await store.updateProgress(id: meetingId, status: .failed, failureReason: "Soniox file API HTTP 503.")
            }
            let partDir = try stageRecording(id: UUID(), lastChunkHoursAgo: 30, continuation: continuation(of: meetingId))
            let processor = SpyDirectProcessor()
            let coordinator = makeCoordinator(store: store, processor: processor)

            await coordinator.recoverFinalizeManifestsOnLaunch()

            XCTAssertFalse(FileManager.default.fileExists(atPath: partDir.path), parentState)
            XCTAssertTrue(processor.processedIds.isEmpty, parentState)
            let note = try await store.markdown(id: meetingId)
            XCTAssertEqual(note, "# Planning\n\nFirst part.", parentState)
            let state = try await store.progressState(id: meetingId)
            XCTAssertEqual(state?.status, .ready, "\(parentState): the stored note is the meeting's result")
            XCTAssertNil(state?.failureReason, parentState)
        }
    }

    /// Break caught: an expired part settles the meeting's status while a
    /// later part of the same meeting is still waiting for its retry.
    func test_expired_reconnect_part_leaves_the_status_to_a_newer_staged_part() async throws {
        let store = try makeStore()
        let meetingId = UUID()
        try await store.insert(meta: meta(id: meetingId, status: .ready), markdown: "# Planning")
        try await store.beginContinuationUpdate(id: meetingId)
        try await store.updateProgress(id: meetingId, status: .failed, failureReason: "boom")
        let oldPart = try stageRecording(id: UUID(), lastChunkHoursAgo: 30, continuation: continuation(of: meetingId))
        let newPart = try stageRecording(id: UUID(), lastChunkHoursAgo: 2, continuation: continuation(of: meetingId, part: 3))
        // Meeting Notes off: the newer part waits, so the status after launch
        // is what the expiry of the old part left.
        let coordinator = makeCoordinator(store: store, processor: SpyDirectProcessor(), enabled: false)

        await coordinator.recoverFinalizeManifestsOnLaunch()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPart.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPart.path))
        let status = try await store.progressStatus(id: meetingId)
        XCTAssertEqual(status, .failed, "the newer part still owns the meeting's status")
    }

    /// Break caught: an expired recording whose meeting never got a note is
    /// set ready, so a meeting without a result looks finished.
    func test_expired_first_recording_without_a_note_stays_failed() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.upsertProgress(meta: meta(id: id, status: .transcribing), status: .transcribing)
        let dir = try stageRecording(id: id, lastChunkHoursAgo: 26)
        let coordinator = makeCoordinator(store: store, processor: SpyDirectProcessor())

        await coordinator.recoverFinalizeManifestsOnLaunch()

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        let state = try await store.progressState(id: id)
        XCTAssertEqual(state?.status, .failed, "an interrupted run that expired is a failure")
        XCTAssertEqual(state?.failureReason, MeetingsCoordinator.recordingExpiredMessage)
    }

    // MARK: - Transcript kept without a note

    private let keptSegments = [TranscriptSegment(speaker: "Speaker 1", start: 0, end: 4, text: "We ship on Friday.")]

    /// Break caught: the user paid for a transcription, the notes model was
    /// out of credit for a day, and the transcript went away with the audio.
    func test_expired_recording_keeps_its_transcript_and_says_so() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.upsertProgress(meta: meta(id: id, status: .failed), status: .failed, failureReason: "out of credit")
        try await store.savePendingTranscript(recordingId: id, meetingId: id, segments: keptSegments)
        let dir = try stageRecording(id: id, lastChunkHoursAgo: 25)
        let coordinator = makeCoordinator(store: store, processor: SpyDirectProcessor())

        await coordinator.recoverFinalizeManifestsOnLaunch()

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "the audio still goes after a day")
        let state = try await store.progressState(id: id)
        XCTAssertEqual(state?.status, .failed)
        XCTAssertEqual(state?.failureReason, MeetingsCoordinator.recordingExpiredTranscriptKeptMessage)
        let kept = try await store.transcriptAwaitingNote(meetingId: id)
        XCTAssertEqual(kept, keptSegments, "the transcript outlives the audio")
    }

    func test_retry_notes_writes_the_note_after_the_recording_is_gone() async throws {
        let store = try makeStore()
        let id = UUID()
        let row = meta(id: id, status: .failed)
        try await store.upsertProgress(meta: row, status: .failed, failureReason: "out of credit")
        try await store.savePendingTranscript(recordingId: id, meetingId: id, segments: keptSegments)
        let processor = SpyDirectProcessor()
        let segments = keptSegments
        processor.writeNotes = { retry, store in
            _ = try await store?.storeProcessedRecording(
                recordingId: retry.meetingId, startedAt: retry.startedAt, endedAt: retry.endedAt,
                duration: retry.durationSeconds, title: "Release plan", markdown: "# Release plan",
                transcript: segments, continuation: nil)
            return true
        }
        let coordinator = makeCoordinator(store: store, processor: processor)

        let wrote = await coordinator.retryNotes(meetingId: id)

        XCTAssertTrue(wrote)
        XCTAssertEqual(processor.notesRetries.map(\.meetingId), [id])
        XCTAssertEqual(processor.notesRetries.first.map { Int($0.startedAt.timeIntervalSince1970) },
                       Int(row.startedAt.timeIntervalSince1970), "the note keeps the meeting's own time")
        XCTAssertTrue(processor.processedIds.isEmpty, "there is no recording to process")
        let state = try await store.progressState(id: id)
        XCTAssertEqual(state?.status, .ready)
        let markdown = try await store.markdown(id: id)
        XCTAssertEqual(markdown, "# Release plan")
        let stillKept = try await store.pendingTranscript(recordingId: id)
        XCTAssertNil(stillKept, "the note carries the transcript now")
    }

    /// Break caught: the button wrote the note beside the queue, so launch
    /// recovery could run the same recording at the same time and the
    /// language and reconnect markers captured at Stop were dropped.
    func test_retry_notes_with_the_recording_still_staged_goes_through_the_ordinary_queue() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.upsertProgress(meta: meta(id: id, status: .failed), status: .failed, failureReason: "out of credit")
        try await store.savePendingTranscript(recordingId: id, meetingId: id, segments: keptSegments)
        _ = try stageRecording(id: id, lastChunkHoursAgo: 2)
        let processor = SpyDirectProcessor()
        let coordinator = makeCoordinator(store: store, processor: processor)

        let wrote = await coordinator.retryNotes(meetingId: id)

        XCTAssertTrue(wrote)
        XCTAssertEqual(processor.processedIds, [id], "the staged recording is processed by the queue")
        XCTAssertTrue(processor.notesRetries.isEmpty, "no second path beside it")
        let state = try await store.progressState(id: id)
        XCTAssertEqual(state?.status, .ready)
    }

    /// Break caught: the retry was claimed only after the row had been read,
    /// so clicks that arrived during that read all went on to the notes
    /// model, and each one is a paid request for the same note.
    func test_parallel_retries_of_one_meeting_ask_the_notes_model_once() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.upsertProgress(meta: meta(id: id, status: .failed), status: .failed, failureReason: "out of credit")
        try await store.savePendingTranscript(recordingId: id, meetingId: id, segments: keptSegments)
        let processor = SpyDirectProcessor()
        let segments = keptSegments
        processor.writeNotes = { retry, store in
            // The notes model takes its time.
            try await Task.sleep(for: .milliseconds(50))
            _ = try await store?.storeProcessedRecording(
                recordingId: retry.meetingId, startedAt: retry.startedAt, endedAt: retry.endedAt,
                duration: retry.durationSeconds, title: "Release plan", markdown: "# Release plan",
                transcript: segments, continuation: nil)
            return true
        }
        let coordinator = makeCoordinator(store: store, processor: processor)

        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask { @MainActor in await coordinator.retryNotes(meetingId: id) }
            }
            var all: [Bool] = []
            for await outcome in group { all.append(outcome) }
            return all
        }

        XCTAssertEqual(processor.notesRetries.count, 1, "one paid request, whatever the number of clicks")
        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
        let state = try await store.progressState(id: id)
        XCTAssertEqual(state?.status, .ready)
    }

    func test_parallel_retries_with_the_recording_staged_process_it_once() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.upsertProgress(meta: meta(id: id, status: .failed), status: .failed, failureReason: "out of credit")
        try await store.savePendingTranscript(recordingId: id, meetingId: id, segments: keptSegments)
        _ = try stageRecording(id: id, lastChunkHoursAgo: 2)
        let processor = SpyDirectProcessor()
        let coordinator = makeCoordinator(store: store, processor: processor)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { @MainActor in _ = await coordinator.retryNotes(meetingId: id) }
            }
        }

        XCTAssertEqual(processor.processedIds, [id], "the staged recording is processed once")
    }

    func test_meeting_cannot_be_deleted_while_its_notes_are_being_written() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.upsertProgress(meta: meta(id: id, status: .failed), status: .failed, failureReason: "x")
        try await store.savePendingTranscript(recordingId: id, meetingId: id, segments: keptSegments)
        let processor = SpyDirectProcessor()
        let coordinator = makeCoordinator(store: store, processor: processor)
        var deletedMidway: Bool?
        processor.writeNotes = { _, _ in
            deletedMidway = await coordinator.deleteMeeting(id: id)
            return false
        }

        _ = await coordinator.retryNotes(meetingId: id)

        XCTAssertEqual(deletedMidway, false, "a note stored after Delete would bring the meeting back")
        let stillListed = try await store.list().contains { $0.id == id }
        XCTAssertTrue(stillListed)
    }

    func test_notes_retry_cut_short_by_quitting_goes_back_to_failed_with_its_transcript() async throws {
        let store = try makeStore()
        let id = UUID()
        // What a quit in the middle of Retry notes leaves: no recording, no
        // note, the row still "preparing the note".
        try await store.upsertProgress(meta: meta(id: id, status: .generatingProtocol), status: .generatingProtocol)
        try await store.savePendingTranscript(recordingId: id, meetingId: id, segments: keptSegments)
        let coordinator = makeCoordinator(store: store, processor: SpyDirectProcessor())

        await coordinator.recoverFinalizeManifestsOnLaunch()

        let state = try await store.progressState(id: id)
        XCTAssertEqual(state?.status, .failed, "it can be retried and deleted again")
        XCTAssertEqual(state?.failureReason, MeetingsCoordinator.notesInterruptedMessage)
    }

    func test_expired_reconnect_part_drops_its_unreachable_kept_transcript() async throws {
        let store = try makeStore()
        let meetingId = UUID()
        let partId = UUID()
        let started = Date().addingTimeInterval(-3 * 86_400)
        _ = try await store.storeProcessedRecording(
            recordingId: meetingId, startedAt: started, endedAt: started.addingTimeInterval(60), duration: 60,
            title: "Call", markdown: "# Call", transcript: keptSegments, continuation: nil)
        let continuation = MeetingContinuation(
            meetingId: meetingId, precedingRecordingId: meetingId, startedAt: started,
            audioOffsetSeconds: 60, gapSeconds: 30, partNumber: 2)
        try await store.savePendingTranscript(recordingId: partId, meetingId: meetingId, segments: keptSegments)
        _ = try stageRecording(id: partId, lastChunkHoursAgo: 25, continuation: continuation)
        let coordinator = makeCoordinator(store: store, processor: SpyDirectProcessor())

        await coordinator.recoverFinalizeManifestsOnLaunch()

        let kept = try await store.pendingTranscript(recordingId: partId)
        XCTAssertNil(kept, "nothing can show or retry it once the audio is gone")
        let state = try await store.progressState(id: meetingId)
        XCTAssertEqual(state?.status, .ready, "the meeting keeps its earlier note")
    }

    func test_retry_notes_that_fails_again_keeps_the_meeting_failed_with_the_new_reason() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.upsertProgress(meta: meta(id: id, status: .failed), status: .failed, failureReason: "old reason")
        try await store.savePendingTranscript(recordingId: id, meetingId: id, segments: keptSegments)
        let processor = SpyDirectProcessor()
        processor.writeNotes = { _, _ in throw MeetingNotesFailure(OpenRouterLLMError.unexpectedStatus(402, "provider text")) }
        let coordinator = makeCoordinator(store: store, processor: processor)

        let wrote = await coordinator.retryNotes(meetingId: id)

        XCTAssertFalse(wrote)
        let state = try await store.progressState(id: id)
        XCTAssertEqual(state?.status, .failed)
        XCTAssertEqual(state?.failureReason,
                       "The Meeting notes provider is out of credit. " + MeetingNotesFailure.transcriptKept)
        let kept = try await store.pendingTranscript(recordingId: id)
        XCTAssertEqual(kept, keptSegments, "still there for the next retry")
    }

    func test_retry_notes_is_refused_for_a_meeting_that_is_not_failed() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.upsertProgress(meta: meta(id: id, status: .transcribing), status: .transcribing)
        let processor = SpyDirectProcessor()
        let coordinator = makeCoordinator(store: store, processor: processor)

        let wrote = await coordinator.retryNotes(meetingId: id)

        XCTAssertFalse(wrote)
        XCTAssertTrue(processor.notesRetries.isEmpty)
    }

    /// Break caught: with Meeting Notes switched off nothing runs at launch,
    /// so old audio stays on disk although nothing can process it.
    func test_old_audio_is_released_while_meeting_notes_are_switched_off() async throws {
        let store = try makeStore()
        let failedId = UUID()
        try await store.upsertProgress(meta: meta(id: failedId, status: .failed), status: .failed, failureReason: "boom")
        let expired = try stageRecording(id: failedId, lastChunkHoursAgo: 48)
        let leftover = try stageLeftover(id: UUID(), hoursAgo: 48)
        let recent = try stageRecording(id: UUID(), lastChunkHoursAgo: 1)
        let processor = SpyDirectProcessor()
        let coordinator = makeCoordinator(store: store, processor: processor, enabled: false)

        await coordinator.recoverFinalizeManifestsOnLaunch()

        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), "a recent failure waits for Meeting Notes")
        XCTAssertTrue(processor.processedIds.isEmpty, "switched off means nothing is processed")
    }

    // MARK: - Directories without a manifest

    /// Break caught: leftovers of older builds and manual repairs (a mixed
    /// track, `orig-mixed-*`, held manifests, old checkpoints) stay on disk
    /// for good because launch recovery only looks at manifests.
    func test_directory_without_a_manifest_is_removed_an_hour_after_its_last_write() async throws {
        let store = try makeStore()
        let leftover = try stageLeftover(id: UUID(), hoursAgo: 2)
        let coordinator = makeCoordinator(store: store, processor: SpyDirectProcessor())

        await coordinator.recoverFinalizeManifestsOnLaunch()

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }

    /// Break caught: the sweep removes the directory of a recording that is
    /// still being written or has only just stopped.
    func test_freshly_written_directory_without_a_manifest_stays() async throws {
        let store = try makeStore()
        let fresh = try stageLeftover(id: UUID(), hoursAgo: 0)
        let coordinator = makeCoordinator(store: store, processor: SpyDirectProcessor())

        await coordinator.recoverFinalizeManifestsOnLaunch()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.appendingPathComponent("chunk-000.wav").path))
    }

    /// Break caught: a manifest that cannot be decoded today is treated like
    /// no manifest at all, so its audio is gone before a fixed build could
    /// still recover it the next day.
    func test_unreadable_manifest_keeps_its_audio_for_a_day() async throws {
        let store = try makeStore()
        let recent = try stageLeftover(id: UUID(), hoursAgo: 2, manifest: Data("{".utf8))
        let old = try stageLeftover(id: UUID(), hoursAgo: 25, manifest: Data("{".utf8))
        let coordinator = makeCoordinator(store: store, processor: SpyDirectProcessor())

        await coordinator.recoverFinalizeManifestsOnLaunch()

        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    /// Break caught: the sweep empties whatever sits in the staging root,
    /// not only directories named by a recording id.
    func test_entries_not_named_by_a_recording_id_are_left_alone() async throws {
        let store = try makeStore()
        let foreign = stagingRoot.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data([0x01]).write(to: foreign.appendingPathComponent("chunk-000.wav"))
        let looseFile = stagingRoot.appendingPathComponent(UUID().uuidString)
        try Data([0x02]).write(to: looseFile)
        try backdate([foreign.appendingPathComponent("chunk-000.wav"), foreign, looseFile], hoursAgo: 72)
        let coordinator = makeCoordinator(store: store, processor: SpyDirectProcessor())

        await coordinator.recoverFinalizeManifestsOnLaunch()

        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: looseFile.path))
    }

    // MARK: - Fixtures

    private func makeStore() throws -> MeetingsStore {
        try MeetingsStore(rootDirectory: meetingsRoot)
    }

    private func makeCoordinator(
        store: MeetingsStore,
        processor: SpyDirectProcessor,
        enabled: Bool = true
    ) -> MeetingsCoordinator {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = enabled
        let staging = stagingRoot
        return MeetingsCoordinator(
            config: config,
            detector: StubbedMeetingDetector(),
            stagingRoot: { staging },
            meetingsStore: store,
            directProcessor: processor,
            meetingsEnabled: { true }
        )
    }

    private func meta(id: UUID, status: MeetingProgressStatus) -> MeetingMetaWithLocalState {
        let started = Date().addingTimeInterval(-3 * 86_400)
        return MeetingMetaWithLocalState(
            id: id,
            startedAt: started,
            endedAt: started.addingTimeInterval(120),
            durationSeconds: 120,
            title: "Meeting",
            syncStatus: .new,
            serverVersion: 1,
            createdAt: started.addingTimeInterval(121),
            progressStatus: status
        )
    }

    /// A finalized recording as a failed run leaves it: two chunks, a Soniox
    /// checkpoint and the manifest. The chunks are dated by when the
    /// recording ended; retries rewrite only the manifest and the checkpoint.
    @discardableResult
    private func stageRecording(
        id: UUID,
        lastChunkHoursAgo: Double,
        manifestAndCheckpointHoursAgo: Double? = nil,
        continuation: MeetingContinuation? = nil
    ) throws -> URL {
        let dir = stagingRoot.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let chunks = ["chunk-000.wav", "chunk-001.wav"].map { dir.appendingPathComponent($0) }
        for chunk in chunks { try Data([0x01]).write(to: chunk) }
        let checkpoint = dir.appendingPathComponent("soniox-transcription.json")
        try Data("{}".utf8).write(to: checkpoint)
        let ended = Date().addingTimeInterval(-lastChunkHoursAgo * 3600)
        var manifest = MeetingFinalizeManifest(
            recorderMeetingId: id,
            startedAt: ended.addingTimeInterval(-120),
            endedAt: ended,
            durationSeconds: 120,
            language: nil,
            chunkFileNames: chunks.map(\.lastPathComponent),
            isFinal: true
        )
        manifest.continuation = continuation
        try MeetingFinalizeManifestStore().write(manifest, to: dir)
        try backdate(chunks, hoursAgo: lastChunkHoursAgo)
        try backdate(
            [checkpoint, dir.appendingPathComponent(MeetingFinalizeManifest.fileName), dir],
            hoursAgo: manifestAndCheckpointHoursAgo ?? lastChunkHoursAgo
        )
        return dir
    }

    /// A directory nothing will process: chunks and repair leftovers without
    /// `manifest.json`, or with an undecodable one when `manifest` is given.
    @discardableResult
    private func stageLeftover(id: UUID, hoursAgo: Double, manifest: Data? = nil) throws -> URL {
        let dir = stagingRoot.appendingPathComponent(id.uuidString)
        let original = dir.appendingPathComponent("orig-mixed-20261007-143143", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        var files = [
            dir.appendingPathComponent("chunk-000.wav"),
            dir.appendingPathComponent("chunk-000.sha256"),
            dir.appendingPathComponent("manifest.json.held-20261007-115433"),
            dir.appendingPathComponent("soniox-transcription.json.pre-realign-20261007-143143"),
            original.appendingPathComponent("chunk-000.wav"),
        ]
        if let manifest {
            let url = dir.appendingPathComponent(MeetingFinalizeManifest.fileName)
            try manifest.write(to: url)
            files.append(url)
        }
        for file in files where !FileManager.default.fileExists(atPath: file.path) {
            try Data([0x01]).write(to: file)
        }
        try backdate(files + [original, dir], hoursAgo: hoursAgo)
        return dir
    }

    /// A metadata read failure must not turn an unknown recording age into
    /// an expired recording. No real recording or user directory is used.
    func testUnreadableDirectoryIsKeptUntilItsDatesCanBeRead() throws {
        let dir = try stageLeftover(id: UUID(), hoursAgo: 2)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        XCTAssertNil(MeetingsCoordinator.lastWrite(in: dir))
        XCTAssertNil(MeetingsCoordinator.lastRecordedWrite(in: dir))
        let found = MeetingsCoordinator.releasableStagedRecordings(
            in: stagingRoot, at: Date(), manifestStore: MeetingFinalizeManifestStore()
        )
        XCTAssertFalse(found.unmanaged.contains(dir))
        XCTAssertTrue(found.expired.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertNotNil(MeetingsCoordinator.lastWrite(in: dir))
    }

    private func continuation(of meetingId: UUID, part: Int = 2) -> MeetingContinuation {
        MeetingContinuation(
            meetingId: meetingId, precedingRecordingId: meetingId,
            startedAt: Date().addingTimeInterval(-31 * 3600), audioOffsetSeconds: 120,
            gapSeconds: 60, partNumber: part
        )
    }

    private func backdate(_ urls: [URL], hoursAgo: Double) throws {
        let date = Date().addingTimeInterval(-hoursAgo * 3600)
        for url in urls {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }
}

/// Processor spy: records which meetings were handed to it and never touches
/// the staging dir, so what the sweep leaves on disk stays visible.
@MainActor
private final class SpyDirectProcessor: MeetingDirectProcessing {
    private(set) var processedIds: [UUID] = []

    func shouldProcessDirectly() -> Bool { true }

    func process(
        event: MeetingRecorder.FinalizedEvent,
        startedAt: Date,
        language: String?,
        meetingsStore: MeetingsStore?, continuation: MeetingContinuation?, endedAt: Date?
    ) async throws -> UUID {
        processedIds.append(event.meetingId)
        return event.meetingId
    }

    var writeNotes: ((MeetingNotesRetry, MeetingsStore?) async throws -> Bool)?
    private(set) var notesRetries: [MeetingNotesRetry] = []

    func writeNotesFromKeptTranscript(
        _ retry: MeetingNotesRetry, language: String?, meetingsStore: MeetingsStore?
    ) async throws -> Bool {
        notesRetries.append(retry)
        return try await writeNotes?(retry, meetingsStore) ?? false
    }
}
