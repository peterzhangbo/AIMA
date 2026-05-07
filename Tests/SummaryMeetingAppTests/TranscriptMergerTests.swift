import XCTest
@testable import SummaryMeetingApp

final class TranscriptMergerTests: XCTestCase {

    // MARK: - mergeRaw

    func testMergeRaw_assignsCorrectSpeaker() {
        let segments = [
            TranscriptSegment(id: 0, start: 0, end: 5, text: "Hello"),
            TranscriptSegment(id: 1, start: 6, end: 10, text: "World"),
        ]
        let diarization = [
            DiarizeSegment(start: 0, end: 5, speaker: "SPEAKER_00"),
            DiarizeSegment(start: 6, end: 10, speaker: "SPEAKER_01"),
        ]
        let transcript = Transcript(language: "zh", text: "Hello World", segments: segments)
        let raw = TranscriptMerger.mergeRaw(transcript: transcript, diarization: diarization)

        XCTAssertEqual(raw.count, 2)
        XCTAssertEqual(raw[0].speaker, "SPEAKER_00")
        XCTAssertEqual(raw[1].speaker, "SPEAKER_01")
    }

    func testMergeRaw_unknownWhenNoOverlap() {
        let segments = [TranscriptSegment(id: 0, start: 10, end: 15, text: "Gap")]
        let diarization = [DiarizeSegment(start: 0, end: 5, speaker: "SPEAKER_00")]
        let transcript = Transcript(language: nil, text: "Gap", segments: segments)
        let raw = TranscriptMerger.mergeRaw(transcript: transcript, diarization: diarization)

        XCTAssertEqual(raw[0].speaker, "SPEAKER_UNKNOWN")
    }

    func testMergeRaw_picksBestOverlap() {
        // Segment spans two diarize regions; the longer one should win
        let segments = [TranscriptSegment(id: 0, start: 0, end: 10, text: "Mixed")]
        let diarization = [
            DiarizeSegment(start: 0, end: 3, speaker: "SPEAKER_00"),   // 3 s overlap
            DiarizeSegment(start: 3, end: 10, speaker: "SPEAKER_01"),  // 7 s overlap
        ]
        let transcript = Transcript(language: nil, text: "Mixed", segments: segments)
        let raw = TranscriptMerger.mergeRaw(transcript: transcript, diarization: diarization)

        XCTAssertEqual(raw[0].speaker, "SPEAKER_01")
    }

    // MARK: - mergeClean

    func testMergeClean_mergesAdjacentSameSpeaker() {
        let raw = [
            SpeakerSegment(id: 0, start: 0,   end: 5,  speaker: "SPEAKER_00", text: "Hello"),
            SpeakerSegment(id: 1, start: 5.5, end: 10, speaker: "SPEAKER_00", text: "World"),
        ]
        let clean = TranscriptMerger.mergeClean(raw: raw)

        XCTAssertEqual(clean.count, 1)
        XCTAssertEqual(clean[0].text, "Hello World")
        XCTAssertEqual(clean[0].start, 0)
        XCTAssertEqual(clean[0].end, 10)
    }

    func testMergeClean_doesNotMergeDifferentSpeakers() {
        let raw = [
            SpeakerSegment(id: 0, start: 0, end: 5, speaker: "SPEAKER_00", text: "A"),
            SpeakerSegment(id: 1, start: 5, end: 10, speaker: "SPEAKER_01", text: "B"),
        ]
        let clean = TranscriptMerger.mergeClean(raw: raw)
        XCTAssertEqual(clean.count, 2)
    }

    func testMergeClean_doesNotMergeWhenGapExceeds2s() {
        let raw = [
            SpeakerSegment(id: 0, start: 0,   end: 5,  speaker: "SPEAKER_00", text: "A"),
            SpeakerSegment(id: 1, start: 8,   end: 12, speaker: "SPEAKER_00", text: "B"),
        ]
        let clean = TranscriptMerger.mergeClean(raw: raw)
        XCTAssertEqual(clean.count, 2)
    }

    // MARK: - save / load round-trip

    func testSaveLoad_roundTrip() throws {
        let segs = [
            SpeakerSegment(id: 0, start: 0, end: 5, speaker: "SPEAKER_00", text: "Test"),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_speaker_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try TranscriptMerger.save(segs, to: url)
        let loaded = try TranscriptMerger.load(from: url)

        XCTAssertEqual(loaded, segs)
    }
}
