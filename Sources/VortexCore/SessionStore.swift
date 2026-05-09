import Foundation

/// Append-only markdown-файл одной сессии созвона.
/// Путь: ~/Documents/Froggy/Meetings/YYYY-MM-DD_HH-mm-ss.md
/// Каждый финальный сегмент транскрипта флашится немедленно через FileHandle.write —
/// файл читаемый даже если демон упадёт посреди созвона.
public actor SessionStore {
    public let url: URL
    private let handle: FileHandle
    private let timeFormatter: DateFormatter

    public init(at url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        self.url = url

        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"
        self.timeFormatter = tf

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let header = "# Meeting — \(iso.string(from: Date()))\n\n"
        handle.write(Data(header.utf8))
    }

    /// Добавляет финальный сегмент транскрипта.
    public func append(speaker: String, text: String) {
        let ts = timeFormatter.string(from: Date())
        write("**[\(ts)] \(speaker):** \(text)\n\n")
    }

    /// Добавляет именованную секцию (например ## Summary).
    public func appendSection(title: String, content: String) {
        write("\n## \(title)\n\n\(content)\n")
    }

    public func close() {
        try? handle.close()
    }

    private func write(_ s: String) {
        handle.write(Data(s.utf8))
    }

    /// Стандартный путь для новой сессии.
    public static func makeURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Froggy/Meetings", isDirectory: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return dir.appendingPathComponent("\(df.string(from: Date())).md")
    }
}
