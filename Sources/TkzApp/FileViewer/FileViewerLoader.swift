// Reading a file for the read-only viewer.

import Foundation

enum FileViewerContent: Equatable {
    case markdown(String)
    case text(String)
    /// Nothing to render: binary, too large, or unreadable. The string says which.
    case notice(String)
}

enum FileViewerLoader {
    /// Past this the viewer declines. `NSTextView` copes with more, but a multi-megabyte log is not
    /// what ⌘-click on a path is for, and the read happens on the main thread.
    static let maxBytes = 5 * 1024 * 1024

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]

    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    static func load(_ url: URL) -> FileViewerContent {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else {
            let megabytes = Double(size) / 1_048_576
            return .notice(String(format: "This file is too large to preview (%.1f MB).", megabytes))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .notice("This file could not be read.")
        }
        // A NUL in the first few KB is the usual test git and `file` use for "binary".
        guard !data.prefix(8192).contains(0) else {
            return .notice("This looks like a binary file, so there is nothing to show.")
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return isMarkdown(url) ? .markdown(text) : .text(text)
    }
}
