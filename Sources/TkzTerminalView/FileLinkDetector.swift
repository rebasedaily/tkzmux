// FileLinkDetector — finding a file path printed as plain text under the pointer.
//
// OSC 8 links are announced by the program; a path in `git status`, a compiler error or Claude
// Code's `⏺ Update(Sources/Foo.swift)` is just text. This file only decides *which characters*
// around the pointer look like a path. Whether that path names a real file is the app's call
// (`MouseController.resolveFilePath`), because only the app knows the pane's directory.
//
// Pure and total over one row of cells, so it is table-tested without a terminal.

/// A path-shaped run of cells on one row.
public struct FileLinkCandidate: Sendable, Equatable {
    /// The path as printed, with any `:line[:column]` suffix removed.
    public var path: String
    /// The `:line` suffix, when there was one.
    public var line: Int?
    /// The cells the whole token covers (suffix included), for the hover underline.
    public var columns: ClosedRange<UInt16>

    public init(path: String, line: Int? = nil, columns: ClosedRange<UInt16>) {
        self.path = path
        self.line = line
        self.columns = columns
    }
}

public enum FileLinkDetector {
    /// Punctuation that ends a sentence around a path rather than belonging to it:
    /// `see Sources/Foo.swift.` or `Sources/Foo.swift:12:`.
    private static let trailingTrim: Set<String> = [".", ",", ":", ";"]
    private static let leadingTrim: Set<String> = [":", ","]

    /// Whether one cell can be part of a path. Brackets, quotes and backticks deliberately cannot,
    /// so `(Sources/Foo.swift)` and `` `README.md` `` resolve to what is inside them.
    static func isPathCell(_ cell: String) -> Bool {
        guard cell.count == 1, let character = cell.first else { return false }
        if character.isLetter || character.isNumber { return true }
        return "._-/~+@#%=:,".contains(character)
    }

    /// The path-shaped token containing `column`, or nil when the pointer is not on one.
    ///
    /// A token must contain a `/` or a `.` to count: a bare word such as `hello` is far more often
    /// prose than a file, and every candidate costs the resolver a `stat`.
    public static func candidate(in cells: [String], column: Int) -> FileLinkCandidate? {
        guard cells.indices.contains(column), isPathCell(cells[column]) else { return nil }
        var start = column
        var end = column
        while start > 0, isPathCell(cells[start - 1]) { start -= 1 }
        while end + 1 < cells.count, isPathCell(cells[end + 1]) { end += 1 }
        while end > start, trailingTrim.contains(cells[end]) { end -= 1 }
        while start < end, leadingTrim.contains(cells[start]) { start += 1 }
        guard (start...end).contains(column) else { return nil }

        let token = cells[start...end].joined()
        guard !token.contains("://") else { return nil }

        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        let path = String(parts[0])
        guard !path.isEmpty, path.contains("/") || path.contains(".") else { return nil }
        guard path != "." && path != ".." else { return nil }
        let line = parts.count > 1 ? Int(parts[1]) : nil
        // `foo:bar` with a non-numeric suffix is not `path:line`; refuse rather than guess.
        if parts.count > 1, line == nil { return nil }

        return FileLinkCandidate(
            path: path, line: line, columns: UInt16(start)...UInt16(end))
    }
}
