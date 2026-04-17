import Foundation

public struct SessionPaths {
    public let root: URL
    public let meetingID: MeetingID

    public var directory: URL { root.appendingPathComponent(meetingID.raw, isDirectory: true) }
    public var micWav: URL { directory.appendingPathComponent("mic.wav") }
    public var systemAudio: URL { directory.appendingPathComponent("system.m4a") }
    public var mixedWav: URL { directory.appendingPathComponent("mixed.wav") }
    public var transcriptDir: URL { directory.appendingPathComponent("transcript", isDirectory: true) }
    public var transcriptJSON: URL { transcriptDir.appendingPathComponent("mixed.json") }
    public var summaryDir: URL { directory.appendingPathComponent("summary", isDirectory: true) }
    public var logFile: URL { directory.appendingPathComponent("run.log") }

    public init(root: URL, meetingID: MeetingID) {
        self.root = root
        self.meetingID = meetingID
    }

    public func ensureCreated() throws {
        let fm = FileManager.default
        for dir in [directory, transcriptDir, summaryDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public static func defaultRoot() -> URL {
        let docs = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = (docs ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents"))
            .appendingPathComponent("SummaryMeetingApp/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
