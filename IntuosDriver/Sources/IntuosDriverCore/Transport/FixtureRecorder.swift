import Foundation

/// Appends raw HID reports as JSONL for Phase 0 capture / regression fixtures.
public final class FixtureRecorder: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.intuos.fixture-recorder")
    private var fileHandle: FileHandle?

    public init(directory: URL, filename: String = "capture.jsonl") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.fileHandle = try FileHandle(forWritingTo: url)
        try self.fileHandle?.seekToEnd()
    }

    public func record(reportID: UInt8, bytes: [UInt8], note: String = "") {
        queue.async { [weak self] in
            guard let self else { return }
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            let ts = Int(Date().timeIntervalSince1970 * 1000)
            var line = "{\"ts\":\(ts),\"reportID\":\(reportID),\"hex\":\"\(hex)\",\"len\":\(bytes.count)"
            if !note.isEmpty {
                let escaped = note.replacingOccurrences(of: "\"", with: "\\\"")
                line += ",\"note\":\"\(escaped)\""
            }
            line += "}\n"
            if let data = line.data(using: .utf8) {
                self.fileHandle?.write(data)
            }
        }
    }

    public func close() {
        queue.sync {
            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    deinit {
        close()
    }

    public var path: String { url.path }
}
