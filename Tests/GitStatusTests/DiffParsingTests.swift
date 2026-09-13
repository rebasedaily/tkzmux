// DiffParsingTests — the text half of the changes viewer (TKZ-58), against literal fixtures.

import Foundation
import Testing

@testable import GitStatus

struct DiffParsingTests {

    // MARK: numstat

    @Test func numstatReadsCountsAndPaths() {
        let text = "41\t12\tsrc/Services/PositionAuditService.cs\0" + "9\t0\tAuditDtos.cs\0"
        let files = DiffParsing.parseNumstat(text)
        #expect(files.map(\.path) == ["src/Services/PositionAuditService.cs", "AuditDtos.cs"])
        #expect(files[0].insertions == 41)
        #expect(files[0].deletions == 12)
        #expect(files[1].deletions == 0)
        #expect(files.allSatisfy { !$0.isUntracked && $0.oldPath == nil })
    }

    @Test func numstatBinaryHasNoCounts() {
        let files = DiffParsing.parseNumstat("-\t-\tAssets/icon.png\0")
        #expect(files.count == 1)
        #expect(files[0].isBinary)
        #expect(files[0].insertions == nil)
    }

    @Test func numstatRenameIsOneFileWithBothNames() {
        // THE `-z` TRAP, numstat edition: an empty path field, then old and new as two fields.
        let text = "3\t1\t\0old/Name.swift\0new/Name.swift\0" + "1\t1\tother.swift\0"
        let files = DiffParsing.parseNumstat(text)
        #expect(files.count == 2)
        #expect(files[0].path == "new/Name.swift")
        #expect(files[0].oldPath == "old/Name.swift")
        #expect(files[0].insertions == 3)
        #expect(files[1].path == "other.swift")
    }

    @Test func numstatSkipsGarbage() {
        #expect(DiffParsing.parseNumstat("").isEmpty)
        #expect(DiffParsing.parseNumstat("not a record\0\0").isEmpty)
    }

    // MARK: unified diff

    static let sample = """
        diff --git a/Service.cs b/Service.cs
        index 1111111..2222222 100644
        --- a/Service.cs
        +++ b/Service.cs
        @@ -87,3 +87,4 @@ public async Task GetHistory()
          var entries = await _repo.GetAuditTrail(positionId);
        - return entries.Select(MapToDto).ToArray();
        + var tracked = BuildTrackedFieldMap(entries);
        + return entries.Select(e => MapToDto(e, tracked)).ToArray();
          }
        @@ -131,2 +132,3 @@ private AuditEntryDto MapToDto(AuditEntry entry)
          var dto = new AuditEntryDto(entry.Id);
        + dto.TrackedFields = tracked.GetValueOrDefault(entry.Field);
          return dto;
        \\ No newline at end of file

        """

    @Test func unifiedDiffNumbersBothSides() throws {
        let diff = DiffParsing.parseUnifiedDiff(Self.sample, path: "Service.cs")
        #expect(!diff.isBinary)
        #expect(diff.hunks.count == 2)

        let first = diff.hunks[0]
        #expect(first.header == "@@ -87,3 +87,4 @@ public async Task GetHistory()")
        #expect(first.oldStart == 87 && first.oldCount == 3 && first.newStart == 87 && first.newCount == 4)
        #expect(first.lines.map(\.kind) == [.context, .removed, .added, .added, .context])
        #expect(first.lines.map(\.oldNumber) == [87, 88, nil, nil, 89])
        #expect(first.lines.map(\.newNumber) == [87, nil, 88, 89, 90])
        #expect(first.lines[1].text == " return entries.Select(MapToDto).ToArray();")

        let second = diff.hunks[1]
        #expect(second.lines.map(\.kind) == [.context, .added, .context, .noNewline])
        #expect(second.lines.map(\.oldNumber) == [131, nil, 132, nil])
        #expect(second.lines.map(\.newNumber) == [132, 133, 134, nil])
        #expect(second.lines[3].text == "No newline at end of file")
    }

    @Test func hunkHeaderWithoutCountsMeansOne() throws {
        let hunk = try #require(DiffParsing.parseHunkHeader("@@ -0,0 +1 @@"))
        #expect(hunk.oldStart == 0 && hunk.oldCount == 0)
        #expect(hunk.newStart == 1 && hunk.newCount == 1)
        #expect(DiffParsing.parseHunkHeader("@@ garbage @@") == nil)
    }

    @Test func binaryDiffIsFlagged() {
        let text = "diff --git a/x.png b/x.png\nBinary files a/x.png and b/x.png differ\n"
        let diff = DiffParsing.parseUnifiedDiff(text, path: "x.png")
        #expect(diff.isBinary)
        #expect(diff.hunks.isEmpty)
    }

    @Test func emptyOutputIsNoHunks() {
        let diff = DiffParsing.parseUnifiedDiff("", path: "x")
        #expect(diff.hunks.isEmpty && !diff.isBinary)
    }

    // MARK: untracked files

    @Test func wholeFileAddedNumbersFromOne() {
        let diff = DiffParsing.wholeFileAdded(path: "new.txt", contents: "a\nb\n")
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].header == "@@ -0,0 +1,2 @@")
        #expect(diff.hunks[0].lines.map(\.newNumber) == [1, 2])
        #expect(diff.hunks[0].lines.allSatisfy { $0.kind == .added })
    }

    @Test func wholeFileAddedMarksMissingTrailingNewline() {
        let diff = DiffParsing.wholeFileAdded(path: "new.txt", contents: "a\nb")
        #expect(diff.hunks[0].lines.map(\.kind) == [.added, .added, .noNewline])
        #expect(DiffParsing.wholeFileAdded(path: "empty", contents: "").hunks.isEmpty)
    }

    @Test func untrackedCountsAgreeWithTheDiff() {
        #expect(DiffParsing.untrackedCounts(of: Data("a\nb\n".utf8)).insertions == 2)
        #expect(DiffParsing.untrackedCounts(of: Data("a\nb".utf8)).insertions == 2)
        #expect(DiffParsing.untrackedCounts(of: Data()).insertions == 0)
        let binary = DiffParsing.untrackedCounts(of: Data([0x89, 0x50, 0x00, 0x47]))
        #expect(binary.insertions == nil && binary.deletions == nil)
    }

    // MARK: value helpers

    @Test func changedFileSplitsDirectoryAndName() {
        let nested = ChangedFile(path: "src/CoreInvest.Api/Services/PositionAuditService.cs")
        #expect(nested.directory == "src/CoreInvest.Api/Services/")
        #expect(nested.name == "PositionAuditService.cs")
        let top = ChangedFile(path: "README.md")
        #expect(top.directory == "" && top.name == "README.md")
    }

    @Test func summaryTotalsSkipBinaries() {
        let summary = DiffSummary(base: .head, files: [
            ChangedFile(path: "a", insertions: 41, deletions: 12),
            ChangedFile(path: "b.png"),
            ChangedFile(path: "c", insertions: 9, deletions: 0, isUntracked: true),
        ])
        #expect(summary.insertions == 50)
        #expect(summary.deletions == 12)
        #expect(DiffBase.head.label == "vs HEAD")
        #expect(DiffBase.upstream("origin/develop").label == "vs origin/develop")
        #expect(DiffBase.base("origin/main").label == "vs origin/main")
    }
}
