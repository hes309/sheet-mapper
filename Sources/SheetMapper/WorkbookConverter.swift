import Foundation

enum WorkbookConverter {
    static let acceptedExtensions = ["xlsx", "xls", "et", "ett"]

    static func prepare(_ source: URL) throws -> URL {
        let ext = source.pathExtension.lowercased()
        if ext == "xlsx" { return source }
        if isZipContainer(source) {
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("wps-\(UUID().uuidString).xlsx")
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }
        guard let converter = findLibreOffice() else {
            throw MapperError.message(L10n.text("error.legacyConversionRequired"))
        }
        let outputFolder = try ProcessRunner.temporaryDirectory(prefix: "workbook-convert")
        try ProcessRunner.run(converter.path, ["--headless", "--convert-to", "xlsx", "--outdir", outputFolder.path, source.path])
        let expected = outputFolder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".xlsx")
        guard FileManager.default.fileExists(atPath: expected.path) else { throw MapperError.message(L10n.text("error.legacyConversionFailed")) }
        return expected
    }

    private static func isZipContainer(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return handle.readData(ofLength: 4).starts(with: [0x50, 0x4B, 0x03, 0x04])
    }

    private static func findLibreOffice() -> URL? {
        ["/Applications/LibreOffice.app/Contents/MacOS/soffice", "/opt/homebrew/bin/soffice", "/usr/local/bin/soffice", "/usr/bin/soffice"]
            .map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
