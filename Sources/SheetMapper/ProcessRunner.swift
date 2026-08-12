import Foundation
import ZIPFoundation

enum ProcessRunner {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], directory: URL? = nil) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw MapperError.message(text.isEmpty ? L10n.text("error.fileProcessingFailed") : text) }
        return text
    }

    static func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func unzip(_ source: URL, to destination: URL) throws {
        try FileManager.default.unzipItem(at: source, to: destination)
    }

    static func zipContents(of directory: URL, to output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.zipItem(at: directory, to: output, shouldKeepParent: false, compressionMethod: .deflate)
    }
}
