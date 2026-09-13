// Plain-text file paths under the pointer: which cells ⌘-click treats as a path.

import Testing

@testable import TkzTerminalView

struct FileLinkDetectorTests {
    /// One cell per character, the way `RowTextLookup` returns an ASCII row.
    private static func cells(_ row: String) -> [String] { row.map { String($0) } }

    private static func candidate(_ row: String, at marker: String) -> FileLinkCandidate? {
        let column = row.distance(from: row.startIndex, to: row.range(of: marker)!.lowerBound)
        return FileLinkDetector.candidate(in: cells(row), column: column)
    }

    @Test func findsARelativePathAroundThePointer() {
        let found = Self.candidate("  modified: Sources/TkzApp/Foo.swift", at: "TkzApp")
        #expect(found?.path == "Sources/TkzApp/Foo.swift")
        #expect(found?.columns == 12...35)
    }

    @Test func stripsBracketsQuotesAndSentencePunctuation() {
        #expect(Self.candidate("⏺ Update(docs/design.md)", at: "design")?.path == "docs/design.md")
        #expect(Self.candidate("see `README.md`.", at: "READ")?.path == "README.md")
        #expect(Self.candidate("open docs/perf.md.", at: "perf")?.path == "docs/perf.md")
    }

    @Test func separatesALineNumberSuffix() {
        let found = Self.candidate("Sources/A.swift:42:7: error", at: "A.swift")
        #expect(found?.path == "Sources/A.swift")
        #expect(found?.line == 42)
    }

    @Test func refusesWordsURLsAndBlankCells() {
        #expect(Self.candidate("just some prose", at: "some") == nil)
        #expect(Self.candidate("go to https://example.com/a.md", at: "example") == nil)
        #expect(FileLinkDetector.candidate(in: ["", "a"], column: 0) == nil)
        #expect(FileLinkDetector.candidate(in: [], column: 3) == nil)
    }

    @Test func thePointerOnTrimmedPunctuationIsNotALink() {
        #expect(Self.candidate("docs/perf.md, then", at: ", then") == nil)
    }
}
