// GitDiffServiceTests — the process half of the changes viewer (TKZ-58), over a real temp repo.
// Reuses `TKZ26Fixture` from the status service tests: same git knobs, same cleanup.

import Foundation
import Testing

@testable import GitStatus

struct GitDiffServiceTests {

    /// A checkout with one committed file, one modified, one untracked — and a worktree of it.
    private static func populated(_ fixture: TKZ26Fixture) -> String {
        let checkout = fixture.makeCheckout()
        fixture.write("one\ntwo\nthree\n", to: checkout + "/tracked.txt")
        try? FileManager.default.createDirectory(atPath: checkout + "/sub", withIntermediateDirectories: true)
        fixture.write("x\n", to: checkout + "/sub/nested.txt")
        fixture.git(["add", "."], in: checkout)
        fixture.git(["commit", "-m", "base"], in: checkout)
        fixture.write("one\n2\nthree\nfour\n", to: checkout + "/tracked.txt")
        fixture.write("new\nfile", to: checkout + "/sub/untracked.txt")
        return checkout
    }

    @Test func summaryListsTrackedChangesThenUntrackedFiles() throws {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = Self.populated(fixture)

        let summary = try #require(GitDiffService.computeSummary(toplevel: checkout, base: .head))
        #expect(summary.base == .head)
        #expect(summary.files.map(\.path) == ["tracked.txt", "sub/untracked.txt"])
        let tracked = summary.files[0]
        #expect(tracked.insertions == 2 && tracked.deletions == 1 && !tracked.isUntracked)
        let untracked = summary.files[1]
        #expect(untracked.isUntracked)
        #expect(untracked.insertions == 2 && untracked.deletions == 0)
        #expect(summary.insertions == 4 && summary.deletions == 1)
    }

    @Test func fileDiffOfATrackedFileHasNumberedHunks() throws {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = Self.populated(fixture)
        let file = ChangedFile(path: "tracked.txt", insertions: 2, deletions: 1)

        let diff = try #require(GitDiffService.computeFileDiff(file, toplevel: checkout, base: .head))
        #expect(diff.hunks.count == 1)
        let kinds = diff.hunks[0].lines.map(\.kind)
        #expect(kinds == [.context, .removed, .added, .context, .added])
        #expect(diff.hunks[0].lines[1].text == "two")
        #expect(diff.hunks[0].lines[4].newNumber == 4)
    }

    @Test func fileDiffOfAnUntrackedFileIsAllAdded() throws {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = Self.populated(fixture)
        let file = ChangedFile(path: "sub/untracked.txt", isUntracked: true)

        let diff = try #require(GitDiffService.computeFileDiff(file, toplevel: checkout, base: .head))
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].lines.map(\.kind) == [.added, .added, .noNewline])
        #expect(diff.hunks[0].lines.map(\.text).prefix(2) == ["new", "file"])
    }

    @Test func pathsAreToplevelRelativeInAWorktree() throws {
        // Acceptance: works for worktrees, paths relative to the worktree root — and a file in a
        // subdirectory lists *and* diffs, which is what running in the toplevel guarantees.
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = Self.populated(fixture)
        let worktree = fixture.addWorktree("wt", of: checkout, branch: "feature")
        fixture.write("changed\n", to: worktree + "/sub/nested.txt")

        let summary = try #require(GitDiffService.computeSummary(toplevel: worktree, base: .head))
        #expect(summary.files.map(\.path) == ["sub/nested.txt"])
        let diff = try #require(
            GitDiffService.computeFileDiff(summary.files[0], toplevel: worktree, base: .head))
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].lines.map(\.kind) == [.removed, .added])
    }

    @Test func upstreamBaseDiffsAgainstTheMergeBase() throws {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = Self.populated(fixture)
        // Commit the working tree on a branch, then move `main` on: against `main` the diff
        // must show the branch's own commit only, not main's later change backwards.
        fixture.git(["checkout", "-b", "feature"], in: checkout)
        fixture.git(["add", "tracked.txt"], in: checkout)
        fixture.git(["commit", "-m", "feature work"], in: checkout)
        fixture.git(["checkout", "main"], in: checkout)
        fixture.write("moved on\n", to: checkout + "/sub/nested.txt")
        fixture.git(["commit", "-am", "main moves"], in: checkout)
        fixture.git(["checkout", "feature"], in: checkout)

        let head = try #require(GitDiffService.computeSummary(toplevel: checkout, base: .head))
        #expect(head.files.map(\.path) == ["sub/untracked.txt"])

        let upstream = try #require(
            GitDiffService.computeSummary(toplevel: checkout, base: .upstream("main")))
        #expect(upstream.files.map(\.path) == ["tracked.txt", "sub/untracked.txt"])
        #expect(upstream.files[0].insertions == 2 && upstream.files[0].deletions == 1)
    }

    @Test func unbornRepoStillListsUntrackedFiles() throws {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let directory = fixture.makePlainDirectory("fresh")
        fixture.git(["init", "-b", "main"], in: directory)
        fixture.write("hello\n", to: directory + "/a.txt")

        let summary = try #require(GitDiffService.computeSummary(toplevel: directory, base: .head))
        #expect(summary.files.map(\.path) == ["a.txt"])
        #expect(summary.files[0].isUntracked)
    }

    @Test func notARepoIsNil() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let directory = fixture.makePlainDirectory("plain")
        #expect(GitDiffService.computeSummary(toplevel: directory, base: .head) == nil)
    }

    @Test func asynchronousCallsDeliverTheSameAnswer() throws {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = Self.populated(fixture)
        let service = GitDiffService()
        let recorder = TKZ58Recorder()

        service.summary(toplevel: checkout, base: .head) { recorder.set(summary: $0) }
        #expect(TKZ26Fixture.waitUntil { recorder.summary != nil })
        let file = try #require(recorder.summary?.files.first)
        service.fileDiff(file, toplevel: checkout, base: .head) { recorder.set(diff: $0) }
        #expect(TKZ26Fixture.waitUntil { recorder.diff != nil })
        #expect(recorder.diff?.hunks.count == 1)
    }
}

import Synchronization

final class TKZ58Recorder: Sendable {
    private let storage = Mutex<(summary: DiffSummary?, diff: FileDiff?)>((nil, nil))
    func set(summary: DiffSummary?) { storage.withLock { $0.summary = summary } }
    func set(diff: FileDiff?) { storage.withLock { $0.diff = diff } }
    var summary: DiffSummary? { storage.withLock { $0.summary } }
    var diff: FileDiff? { storage.withLock { $0.diff } }
}
