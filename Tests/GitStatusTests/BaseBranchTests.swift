// The base-branch half of the status service (design 5a/5b, 2026-09-13): resolution, the
// `rev-list` drift counts, and what happens when the base is missing, appears later, or goes away.
// Real repos through `TKZ26Fixture`; a bare repo plus `git clone` stands in for GitHub so
// `origin/HEAD` is set the way a real clone has it.

import Foundation
import Testing
import TkzCore

@testable import GitStatus

extension TKZ26Fixture {
    /// A bare "origin" seeded with one commit on `main`, a `seed` checkout that can push more to
    /// it, and a `clone` of it — the checkout under test. `git clone` sets `origin/HEAD`.
    func makeClone(_ name: String = "clone") -> (bare: String, seed: String, clone: String) {
        let bare = path("\(name)-origin.git")
        try? FileManager.default.createDirectory(atPath: bare, withIntermediateDirectories: true)
        git(["init", "--bare", "-b", "main"], in: bare)
        let seed = makeCheckout("\(name)-seed")
        write("a\n", to: (seed as NSString).appendingPathComponent("shared.txt"))
        git(["add", "."], in: seed)
        git(["commit", "-m", "shared"], in: seed)
        git(["remote", "add", "origin", bare], in: seed)
        git(["push", "-u", "origin", "main"], in: seed)
        let clone = path(name)
        git(["clone", bare, clone], in: root)
        return (bare, seed, clone)
    }

    /// One commit touching `file` with `text`, in `directory`.
    func commit(_ text: String, to file: String, in directory: String, message: String = "change") {
        write(text, to: (directory as NSString).appendingPathComponent(file))
        git(["add", "-A"], in: directory)
        git(["commit", "-m", message], in: directory)
    }

    /// `n` empty commits in `directory`. The message carries a fresh UUID: two checkouts making
    /// "the same" empty commit on the same parent in the same second would otherwise produce the
    /// *same commit hash*, and the two branches would silently become one line of history.
    func commits(_ n: Int, in directory: String) {
        for i in 0..<n {
            git(["commit", "--allow-empty", "-m", "c\(i) \(UUID().uuidString)"], in: directory)
        }
    }
}

private func makeService(_ recorder: TKZ26Recorder, baseRetryInterval: TimeInterval = 60) -> GitStatusService {
    GitStatusService(
        debounce: .seconds(60), minimumInterval: .seconds(60), baseRetryInterval: baseRetryInterval
    ) { id, summary in
        recorder.record(id, summary)
    }
}

@Suite(.serialized) struct BaseBranchTests {

    // MARK: Parsing

    @Test func leftRightCountParses() {
        #expect(GitStatusParsing.parseLeftRightCount("3\t2\n")?.left == 3)
        #expect(GitStatusParsing.parseLeftRightCount("3\t2\n")?.right == 2)
        #expect(GitStatusParsing.parseLeftRightCount("0\t0")?.left == 0)
        #expect(GitStatusParsing.parseLeftRightCount("") == nil)
        #expect(GitStatusParsing.parseLeftRightCount("fatal: bad revision") == nil)
        #expect(GitStatusParsing.parseLeftRightCount("1\t2\t3") == nil)
    }

    @Test func symbolicRefParses() {
        #expect(BaseBranch.parseSymbolicRef("refs/remotes/origin/main") == BaseBranch(remote: "origin", name: "main"))
        #expect(BaseBranch.parseSymbolicRef("refs/remotes/upstream/feature/x") == BaseBranch(remote: "upstream", name: "feature/x"))
        #expect(BaseBranch.parseSymbolicRef("refs/heads/main") == nil)
        #expect(BaseBranch.parseSymbolicRef("") == nil)
        #expect(BaseBranch(remote: "origin", name: "main").ref == "origin/main")
        #expect(BaseBranch(remote: nil, name: "main").ref == "main")
    }

    @Test func pickFollowsPriorityNotSortOrder() {
        // `for-each-ref` sorts by name, so `master` would come before `main` for the local pair.
        #expect(BaseBranch.pick(from: ["refs/heads/main", "refs/heads/master"]) == BaseBranch(remote: nil, name: "main"))
        #expect(BaseBranch.pick(from: ["refs/heads/master"]) == BaseBranch(remote: nil, name: "master"))
        #expect(BaseBranch.pick(from: ["refs/heads/main", "refs/remotes/origin/master"])
                == BaseBranch(remote: "origin", name: "master"))
        #expect(BaseBranch.pick(from: ["refs/heads/main", "refs/remotes/origin/main"])
                == BaseBranch(remote: "origin", name: "main"))
        #expect(BaseBranch.pick(from: []) == nil)
        #expect(BaseBranch.pick(from: ["refs/heads/develop"]) == nil)
    }

    // MARK: Resolution and counts

    @Test func cloneOnMainHasABaseButNoCounts() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let (_, _, clone) = fixture.makeClone()
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)
        let id = SessionID.generate()

        service.track(id, directory: clone)
        service.refreshAllForTesting()

        #expect(recorder.lastSummary?.baseBranch == "origin/main")
        #expect(recorder.lastSummary?.aheadOfBase == nil)
        #expect(recorder.lastSummary?.behindBase == nil)
        #expect(recorder.lastSummary?.isOffBase == false)
        #expect(service.baseBranch(for: id) == BaseBranch(remote: "origin", name: "main"))
    }

    @Test func featureBranchMeasuresDriftAgainstOriginMain() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let (_, seed, clone) = fixture.makeClone()
        fixture.git(["switch", "-c", "feature"], in: clone)
        fixture.commits(2, in: clone)
        fixture.commits(3, in: seed)
        fixture.git(["push", "origin", "main"], in: seed)
        fixture.git(["fetch", "origin"], in: clone)
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)

        service.track(SessionID.generate(), directory: clone)
        service.refreshAllForTesting()

        #expect(recorder.lastSummary?.branch == "feature")
        #expect(recorder.lastSummary?.baseBranch == "origin/main")
        #expect(recorder.lastSummary?.aheadOfBase == 2)
        #expect(recorder.lastSummary?.behindBase == 3)
        #expect(recorder.lastSummary?.isOffBase == true)
    }

    @Test func aWorktreeOfTheCloneMeasuresAgainstTheSameBase() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let (_, seed, clone) = fixture.makeClone()
        let worktree = fixture.addWorktree("wt", of: clone, branch: "wt-feature")
        fixture.commits(1, in: worktree)
        fixture.commits(1, in: seed)
        fixture.git(["push", "origin", "main"], in: seed)
        fixture.git(["fetch", "origin"], in: clone)
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)
        let id = SessionID.generate()

        service.track(id, directory: worktree)
        service.refreshAllForTesting()

        #expect(recorder.lastSummary?.isWorktree == true)
        #expect(recorder.lastSummary?.baseBranch == "origin/main")
        #expect(recorder.lastSummary?.aheadOfBase == 1)
        #expect(recorder.lastSummary?.behindBase == 1)
        #expect(service.baseBranch(for: id)?.remote == "origin")
    }

    @Test func originHeadUnsetFallsBackToOriginMain() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let (_, _, clone) = fixture.makeClone()
        fixture.git(["remote", "set-head", "origin", "-d"], in: clone)
        fixture.git(["switch", "-c", "feature"], in: clone)
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)

        service.track(SessionID.generate(), directory: clone)
        service.refreshAllForTesting()

        #expect(recorder.lastSummary?.baseBranch == "origin/main")
        #expect(recorder.lastSummary?.aheadOfBase == 0)
        #expect(recorder.lastSummary?.behindBase == 0)
    }

    /// `origin/HEAD` pointing at a remote-tracking ref that no longer exists — the remote's default
    /// branch was renamed or removed after the symref was set, and a later `fetch --prune` took the
    /// tracking ref with it but left the dangling symref in place. `symbolic-ref` still answers with
    /// that gone target, so resolution must fall through to `origin/main` rather than returning it.
    @Test func originHeadDanglingFallsBackToOriginMain() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let (_, seed, clone) = fixture.makeClone()
        fixture.git(["switch", "-c", "develop"], in: seed)
        fixture.git(["push", "-u", "origin", "develop"], in: seed)
        fixture.git(["fetch"], in: clone)
        fixture.git(["remote", "set-head", "origin", "develop"], in: clone)
        fixture.git(["update-ref", "-d", "refs/remotes/origin/develop"], in: clone)
        fixture.git(["switch", "-c", "feature"], in: clone)
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)

        service.track(SessionID.generate(), directory: clone)
        service.refreshAllForTesting()

        #expect(recorder.lastSummary?.baseBranch == "origin/main")
        #expect(recorder.lastSummary?.aheadOfBase == 0)
        #expect(recorder.lastSummary?.behindBase == 0)
    }

    @Test func noRemoteFallsBackToTheLocalMain() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let checkout = fixture.makeCheckout()
        let worktree = fixture.addWorktree("feature-wt", of: checkout, branch: "feature")
        fixture.commits(1, in: checkout)
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)
        let id = SessionID.generate()

        service.track(id, directory: worktree)
        service.refreshAllForTesting()

        #expect(recorder.lastSummary?.baseBranch == "main")
        #expect(recorder.lastSummary?.aheadOfBase == 0)
        #expect(recorder.lastSummary?.behindBase == 1)
        #expect(service.baseBranch(for: id) == BaseBranch(remote: nil, name: "main"))
    }

    @Test func anUnresolvedBaseIsRetriedAfterTheInterval() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let directory = fixture.makePlainDirectory("trunk-repo")
        fixture.git(["init", "-b", "trunk"], in: directory)
        fixture.git(["commit", "--allow-empty", "-m", "root"], in: directory)

        // Interval 0: every refresh may resolve again, so `main` appearing is seen at once.
        let eager = TKZ26Recorder()
        let eagerService = makeService(eager, baseRetryInterval: 0)
        eagerService.track(SessionID.generate(), directory: directory)
        eagerService.refreshAllForTesting()
        #expect(eager.lastSummary?.branch == "trunk")
        #expect(eager.lastSummary?.baseBranch == nil)

        fixture.git(["branch", "main"], in: directory)
        eagerService.refreshAllForTesting()
        #expect(eager.lastSummary?.baseBranch == "main")
        #expect(eager.lastSummary?.aheadOfBase == 0)
        #expect(eager.lastSummary?.behindBase == 0)

        // The default interval: the second refresh is inside it, so the new branch is not seen
        // yet — no extra git launches for a repo that has no trunk.
        fixture.git(["branch", "-D", "main"], in: directory)
        let lazy = TKZ26Recorder()
        let lazyService = makeService(lazy)
        lazyService.track(SessionID.generate(), directory: directory)
        lazyService.refreshAllForTesting()
        #expect(lazy.lastSummary?.baseBranch == nil)
        fixture.git(["branch", "main"], in: directory)
        lazyService.refreshAllForTesting()
        #expect(lazy.lastSummary?.baseBranch == nil)
    }

    @Test func aBaseWhoseRefIsGoneIsForgotten() {
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let (_, _, clone) = fixture.makeClone()
        fixture.git(["switch", "-c", "feature"], in: clone)
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)
        let id = SessionID.generate()

        service.track(id, directory: clone)
        service.refreshAllForTesting()
        #expect(recorder.lastSummary?.baseBranch == "origin/main")

        // `origin/main` is gone with the remote; the next refresh posts the base as unresolved
        // and the service forgets it (the local `main` would be found once the retry interval
        // has passed — not within it).
        fixture.git(["remote", "remove", "origin"], in: clone)
        service.refreshAllForTesting()
        #expect(recorder.lastSummary?.baseBranch == nil)
        #expect(recorder.lastSummary?.behindBase == nil)
        #expect(recorder.lastSummary?.branch == "feature")
        #expect(service.baseBranch(for: id) == nil)
    }

    @Test func onlyTheBaseFieldsDifferBetweenRefreshes() {
        // The Equatable rule still holds with the new fields: two refreshes over an unchanged
        // clone post once.
        let fixture = TKZ26Fixture()
        defer { fixture.destroy() }
        let (_, _, clone) = fixture.makeClone()
        fixture.git(["switch", "-c", "feature"], in: clone)
        let recorder = TKZ26Recorder()
        let service = makeService(recorder)
        service.track(SessionID.generate(), directory: clone)
        service.refreshAllForTesting()
        service.refreshAllForTesting()
        #expect(recorder.count == 1)
    }
}
