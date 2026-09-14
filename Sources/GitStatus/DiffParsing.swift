// DiffParsing — the text half of the changes viewer (TKZ-58, design 2c.2). Pure functions, no
// processes, in the same spirit as `GitStatusParsing`: `GitDiffService` supplies the text, and
// everything that can go wrong in reading it is a parsing bug tested against literal fixtures.
//
// Two formats are read here:
//
//   * `git diff <base> --numstat -z` — one record per changed file: `<ins>\t<del>\t<path>NUL`,
//     or for a rename/copy `<ins>\t<del>\tNUL<old>NUL<new>NUL` (the path field is empty and the
//     two names follow as their own NUL-separated fields — the same trap as `status -z`). A
//     binary file prints `-\t-`.
//   * `git diff <base> -- <path>` — one unified diff: a `diff --git` preamble, then `@@` hunks
//     whose lines start with ` `, `+`, `-` or `\` (the "No newline at end of file" marker).
//     "Binary files … differ" is the whole body for a binary.

import Foundation

/// What the working tree is compared against. `HEAD` is what the status bar's `+142 −38` chip
/// counts, so it is the default; the upstream (through its merge base with `HEAD`, so commits the
/// remote has and the branch lacks do not show up backwards) is the design's `vs origin/develop`.
public enum DiffBase: Hashable, Sendable {
    case head
    case upstream(String)
    /// The repo's base branch (`GitSummary.baseBranch`, e.g. `origin/main`) — what a worktree
    /// branch's PR will be diffed against. Same merge-base treatment as `upstream`.
    case base(String)

    /// The header's menu title.
    public var label: String {
        switch self {
        case .head: "vs HEAD"
        case .upstream(let name): "vs \(name)"
        case .base(let name): "vs \(name)"
        }
    }
}

/// One file of a `DiffSummary`: the numbers behind its row in the file list.
public struct ChangedFile: Hashable, Sendable, Identifiable {
    /// Toplevel-relative, exactly as git printed it. For a rename this is the **new** name.
    public var path: String
    /// The old name of a rename or copy; `nil` otherwise.
    public var oldPath: String?
    /// `nil` when git printed `-`: a binary file has no line counts.
    public var insertions: Int?
    public var deletions: Int?
    /// Not in the index at all. Git's diff does not know these files, so their counts and their
    /// diff are made up by `DiffParsing.wholeFileAdded` from the file's own contents.
    public var isUntracked: Bool

    public var id: String { path }

    public init(
        path: String, oldPath: String? = nil, insertions: Int? = nil, deletions: Int? = nil,
        isUntracked: Bool = false
    ) {
        self.path = path
        self.oldPath = oldPath
        self.insertions = insertions
        self.deletions = deletions
        self.isUntracked = isUntracked
    }

    public var isBinary: Bool { insertions == nil && deletions == nil }

    /// `PositionAuditService.cs` of `src/CoreInvest.Api/Services/PositionAuditService.cs`.
    public var name: String {
        path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
    }

    /// `src/CoreInvest.Api/Services/` of the same — with its trailing slash, or empty for a file
    /// at the toplevel, so the header can draw `directory + name` with nothing in between.
    public var directory: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }
}

/// Everything the viewer's header and file list need: the base, the files, the totals.
public struct DiffSummary: Hashable, Sendable {
    public var base: DiffBase
    public var files: [ChangedFile]

    public init(base: DiffBase, files: [ChangedFile]) {
        self.base = base
        self.files = files
    }

    public var insertions: Int { files.reduce(0) { $0 + ($1.insertions ?? 0) } }
    public var deletions: Int { files.reduce(0) { $0 + ($1.deletions ?? 0) } }
}

public enum DiffLineKind: Hashable, Sendable {
    case context
    case added
    case removed
    /// `\ No newline at end of file` — drawn dimmed, numbered like neither side.
    case noNewline
}

/// One line of a hunk. `text` has the leading marker stripped; the kind carries what it said.
public struct DiffLine: Hashable, Sendable {
    public var kind: DiffLineKind
    public var oldNumber: Int?
    public var newNumber: Int?
    public var text: String

    public init(kind: DiffLineKind, oldNumber: Int? = nil, newNumber: Int? = nil, text: String) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
    }
}

public struct DiffHunk: Hashable, Sendable {
    /// The whole `@@ -87,9 +87,24 @@ public async Task…` line, drawn as the hunk's header row.
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]

    public init(
        header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
        lines: [DiffLine] = []
    ) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

/// One file's diff, as the right-hand pane draws it.
public struct FileDiff: Hashable, Sendable {
    public var path: String
    public var hunks: [DiffHunk]
    /// `Binary files a/x and b/x differ` — no hunks, and the pane says so instead of "no changes".
    public var isBinary: Bool

    public init(path: String, hunks: [DiffHunk] = [], isBinary: Bool = false) {
        self.path = path
        self.hunks = hunks
        self.isBinary = isBinary
    }
}

public enum DiffParsing {
    /// Parses `git diff --numstat -z`.
    ///
    /// Tolerant by design, like `parsePorcelainV2`: a record with fewer than three tab-separated
    /// fields is skipped, a count that is not a number (or `-`) reads as binary, and an empty
    /// path field means "the two names follow" — consumed explicitly so a rename is one file, not
    /// three.
    public static func parseNumstat(_ text: String) -> [ChangedFile] {
        let fields = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var out: [ChangedFile] = []
        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            guard !record.isEmpty else { continue }
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let insertions = Int(parts[0])
            let deletions = Int(parts[1])
            var path = String(parts[2])
            var oldPath: String?
            if path.isEmpty {
                // THE `-z` TRAP, numstat edition: `<ins>\t<del>\t` then the old and new names as
                // two more fields.
                guard index + 1 < fields.count else { break }
                oldPath = fields[index]
                path = fields[index + 1]
                index += 2
            }
            guard !path.isEmpty else { continue }
            out.append(ChangedFile(
                path: path, oldPath: oldPath, insertions: insertions, deletions: deletions))
        }
        return out
    }

    /// Parses one file's `git diff` output into hunks with both line numbers on every line.
    ///
    /// Everything before the first `@@` is the preamble (`diff --git`, `index`, `---`, `+++`,
    /// mode lines) and is skipped, except that a `Binary files … differ` line anywhere marks
    /// the result binary. Inside a hunk, a line that starts with none of ` `, `+`, `-`, `\` ends
    /// the hunk — git does not print such lines, but a truncated read must not be mis-numbered.
    public static func parseUnifiedDiff(_ text: String, path: String) -> FileDiff {
        var result = FileDiff(path: path)
        var current: DiffHunk?
        var oldLine = 0
        var newLine = 0

        func finish() {
            if let hunk = current { result.hunks.append(hunk) }
            current = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("@@") {
                finish()
                guard let header = parseHunkHeader(line) else { continue }
                current = header
                oldLine = header.oldStart
                newLine = header.newStart
                continue
            }
            guard current != nil else {
                if line.hasPrefix("Binary files ") && line.hasSuffix(" differ") {
                    result.isBinary = true
                }
                continue
            }
            guard let marker = line.first else {
                // An empty line inside a hunk can only be the trailing split artefact; git prints
                // context lines with their leading space even when the content is empty.
                continue
            }
            let text = String(line.dropFirst())
            switch marker {
            case " ":
                current?.lines.append(DiffLine(
                    kind: .context, oldNumber: oldLine, newNumber: newLine, text: text))
                oldLine += 1
                newLine += 1
            case "+":
                current?.lines.append(DiffLine(kind: .added, newNumber: newLine, text: text))
                newLine += 1
            case "-":
                current?.lines.append(DiffLine(kind: .removed, oldNumber: oldLine, text: text))
                oldLine += 1
            case "\\":
                current?.lines.append(DiffLine(
                    kind: .noNewline, text: text.trimmingCharacters(in: .whitespaces)))
            default:
                finish()
            }
        }
        finish()
        return result
    }

    /// `@@ -87,9 +87,24 @@ public async…` → the hunk with no lines yet. A missing `,count` means 1,
    /// as git defines it (`@@ -0,0 +1 @@` for a one-line new file).
    static func parseHunkHeader(_ line: String) -> DiffHunk? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "@@",
            let old = parseRange(parts[1], sign: "-"), let new = parseRange(parts[2], sign: "+")
        else { return nil }
        return DiffHunk(
            header: line, oldStart: old.start, oldCount: old.count,
            newStart: new.start, newCount: new.count)
    }

    private static func parseRange(_ field: Substring, sign: Character) -> (start: Int, count: Int)? {
        guard field.first == sign else { return nil }
        let body = field.dropFirst()
        let pieces = body.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let start = Int(pieces[0]) else { return nil }
        let count = pieces.count > 1 ? Int(pieces[1]) ?? 1 : 1
        return (start, count)
    }

    /// The diff git cannot give us: an untracked file, shown as one hunk of added lines. The
    /// numbers agree with ``untrackedCounts(of:)`` by construction — both split the same way.
    public static func wholeFileAdded(path: String, contents: String) -> FileDiff {
        let lines = splitLines(contents)
        var hunk = DiffHunk(
            header: "@@ -0,0 +1,\(lines.count) @@", oldStart: 0, oldCount: 0, newStart: 1,
            newCount: lines.count)
        for (offset, text) in lines.enumerated() {
            hunk.lines.append(DiffLine(kind: .added, newNumber: offset + 1, text: text))
        }
        if !contents.isEmpty, !contents.hasSuffix("\n") {
            hunk.lines.append(DiffLine(kind: .noNewline, text: "No newline at end of file"))
        }
        return FileDiff(path: path, hunks: lines.isEmpty ? [] : [hunk])
    }

    /// The `+N` for an untracked file's row: its line count, or `nil` when it looks binary — a
    /// NUL in the first 8 KiB, git's own heuristic.
    public static func untrackedCounts(of data: Data) -> (insertions: Int?, deletions: Int?) {
        if data.prefix(8_000).contains(0) { return (nil, nil) }
        let text = String(decoding: data, as: UTF8.self)
        return (splitLines(text).count, 0)
    }

    /// Lines the way `git diff` counts them: a trailing newline does not start an empty last line.
    static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }
}
