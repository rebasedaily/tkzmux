// GitRebase — "rebase this branch onto main" (design 5a/5b, 2026-09-13).
//
// The one place in the app that runs git commands which *write* to a repo: a fetch of the base
// branch and a `rebase --autostash` onto it. Everything else in this module is read-only by
// construction (`GitProcess.git` even passes `--no-optional-locks`), and `docs/privacy.md` lists
// these commands separately for that reason.
//
// Stateless and synchronous — `run` blocks for as long as git does (a fetch can take a while on a
// slow link, hence its own timeout) — so it must be called off the main actor. `GitIntegration`
// owns the "one rebase per worktree at a time" rule and turns the outcome into a status bar
// notice; this type only knows how to do the rebase and how to leave the tree the way it found
// it when the rebase cannot finish.
//
// Guarantees:
//   * A conflict never leaves the tree mid-rebase: `rebase --abort` runs, which also puts the
//     autostash back. The outcome says how many files conflicted so the user knows what they are
//     in for when they run it by hand.
//   * Nothing prompts. The fetch runs under `GitProcess.environment` (no terminal prompt, empty
//     askpass), so a missing credential fails at once with a message rather than hanging a
//     background thread or popping a keychain sheet with no window behind it. Credential helpers
//     configured in git (`osxkeychain`, `gh auth git-credential`) still run — `GIT_ASKPASS` is
//     only the interactive fallback — and ssh keys reach the agent through the inherited
//     `SSH_AUTH_SOCK`.

import Foundation
import TkzCore

public enum GitRebase {

    /// Everything one rebase needs, captured on the main actor and handed to a background queue.
    public struct Request: Hashable, Sendable {
        /// `RepoInfo.toplevel` — the worktree's own root, where the rebase runs.
        public var toplevel: String
        /// `RepoInfo.gitDir` — `<main>/.git/worktrees/<name>` for a worktree; where `rebase-merge`
        /// and `MERGE_HEAD` would be.
        public var gitDir: String
        public var base: BaseBranch
        /// The sheet already fetched a moment ago: go straight to the rebase.
        public var skipFetch: Bool
        public var gitPath: String

        public init(
            toplevel: String, gitDir: String, base: BaseBranch, skipFetch: Bool = false,
            gitPath: String = GitProcess.gitPath
        ) {
            self.toplevel = toplevel
            self.gitDir = gitDir
            self.base = base
            self.skipFetch = skipFetch
            self.gitPath = gitPath
        }
    }

    /// Why a rebase was not even attempted. Decided from the last `GitSummary` and two
    /// `fileExists` checks, so `preflight` is cheap enough for a menu validation.
    public enum Refusal: Hashable, Sendable {
        case noBase
        case onBase
        case detachedHead
        case rebaseInProgress
        case mergeInProgress
    }

    public enum Outcome: Hashable, Sendable {
        /// `commits` replayed on top of the base; `stashReapplied` when local changes were
        /// stashed for the rebase and put back afterwards.
        case rebased(commits: Int, stashReapplied: Bool)
        /// The rebase finished but the stashed local changes did not apply cleanly on top of it;
        /// git keeps them in `git stash` and the tree holds the conflict markers.
        case rebasedStashConflict(commits: Int)
        /// Nothing on the base that the branch lacks (after the fetch): no rebase was run.
        case upToDate
        /// Aborted; the tree is back where it was. `files` had conflict markers.
        case conflicts(files: Int)
        /// `git fetch` failed — the last line git printed.
        case fetchFailed(String)
        /// The rebase failed for a reason other than conflicts; aborted, tree restored.
        case failed(String)
        /// `step` is `"fetch"` or `"rebase"`. A rebase that timed out was aborted.
        case timedOut(step: String)
    }

    public static let fetchTimeout: Double = 60
    public static let rebaseTimeout: Double = 120

    // MARK: - Preflight

    /// The reasons not to start, in the order they are reported. `nil` = go ahead. A dirty tree
    /// is deliberately *not* one of them: the rebase stashes and reapplies local changes (5a).
    public static func preflight(summary: GitSummary?, gitDir: String) -> Refusal? {
        guard let summary, summary.baseBranch != nil else { return .noBase }
        guard summary.branch != nil else { return .detachedHead }
        guard summary.isOffBase else { return .onBase }
        let fm = FileManager.default
        for marker in ["rebase-merge", "rebase-apply"]
        where fm.fileExists(atPath: (gitDir as NSString).appendingPathComponent(marker)) {
            return .rebaseInProgress
        }
        if fm.fileExists(atPath: (gitDir as NSString).appendingPathComponent("MERGE_HEAD")) {
            return .mergeInProgress
        }
        return nil
    }

    // MARK: - Steps

    /// `git fetch <remote> <name>`. `nil` when it succeeded, or when the base is local and there
    /// is nothing to fetch. Blocking.
    public static func fetch(_ request: Request) -> Outcome? {
        guard let remote = request.base.remote else { return nil }
        do {
            let output = try GitProcess.run(
                request.gitPath, ["-C", request.toplevel, "fetch", "--quiet", remote, request.base.name],
                environment: fetchEnvironment(), timeout: fetchTimeout)
            guard output.succeeded else { return .fetchFailed(lastLine(of: output)) }
            return nil
        } catch GitProcess.Failure.timedOut {
            return .timedOut(step: "fetch")
        } catch {
            return .fetchFailed(String(describing: error))
        }
    }

    /// `rev-list --left-right --count <base>...HEAD` as (behind, ahead). `nil` when the base ref
    /// does not exist or git failed. Blocking.
    public static func counts(_ request: Request) -> (behind: Int, ahead: Int)? {
        guard
            let output = try? GitProcess.git(
                ["rev-list", "--left-right", "--count", "\(request.base.ref)...HEAD"],
                in: request.toplevel, gitPath: request.gitPath),
            output.succeeded,
            let parsed = GitStatusParsing.parseLeftRightCount(output.standardOutput)
        else { return nil }
        return (parsed.left, parsed.right)
    }

    /// The sheet's "Pulls in N commits". Blocking.
    public static func behindCount(_ request: Request) -> Int? { counts(request)?.behind }

    /// Fetch (unless skipped), measure, rebase. Blocking — never on the main actor.
    public static func run(_ request: Request) -> Outcome {
        if !request.skipFetch, let failure = fetch(request) { return failure }

        guard let before = counts(request) else {
            return .failed("\(request.base.ref) is not a branch here")
        }
        guard before.behind > 0 else { return .upToDate }

        // Tracked changes only: `--autostash` stashes what `git stash` would, and untracked
        // files are left alone (and survive a rebase untouched).
        let dirty = hasTrackedChanges(request)

        let output: GitProcess.Output
        do {
            output = try GitProcess.run(
                request.gitPath,
                ["-C", request.toplevel, "rebase", "--autostash", request.base.ref],
                environment: ["GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true"],
                timeout: rebaseTimeout)
        } catch GitProcess.Failure.timedOut {
            abort(request)
            return .timedOut(step: "rebase")
        } catch {
            abort(request)
            return .failed(String(describing: error))
        }

        // The rebase itself went through; only putting the stash back did not. Checked before
        // the exit status: git has reported this both ways, and an abort here would find no
        // rebase to abort while the conflict markers in the tree are the stash's, not ours.
        if output.standardError.contains(autostashConflictMarker)
            || output.standardOutput.contains(autostashConflictMarker)
        {
            return .rebasedStashConflict(commits: before.ahead)
        }
        if output.succeeded {
            return .rebased(commits: before.ahead, stashReapplied: dirty)
        }

        let conflicted = conflictedFileCount(request)
        abort(request)
        if conflicted > 0 { return .conflicts(files: conflicted) }
        return .failed(lastLine(of: output))
    }

    /// What git prints (exit 0) when the rebase went through but the stash did not apply.
    static let autostashConflictMarker = "Applying autostash resulted in conflicts"

    // MARK: - Helpers

    /// The environment overrides for the fetch: the default no-prompt environment plus a `PATH`
    /// a Finder-launched app lacks — a `credential.helper = !gh auth git-credential` or an
    /// `osxkeychain` from Homebrew's git would otherwise not resolve. Pure so it can be tested.
    static func fetchEnvironment(
        path: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> [String: String] {
        let prefixes = ["/opt/homebrew/bin", "/usr/local/bin"]
        var parts = prefixes
        if let path, !path.isEmpty {
            parts += path.split(separator: ":").map(String.init).filter { !prefixes.contains($0) }
        }
        return ["PATH": parts.joined(separator: ":")]
    }

    private static func hasTrackedChanges(_ request: Request) -> Bool {
        guard
            let output = try? GitProcess.git(
                ["status", "--porcelain=v2", "-z"], in: request.toplevel, gitPath: request.gitPath),
            output.succeeded
        else { return false }
        return GitStatusParsing.parsePorcelainV2(output.standardOutput).changedFiles > 0
    }

    private static func conflictedFileCount(_ request: Request) -> Int {
        guard
            let output = try? GitProcess.git(
                ["diff", "--name-only", "--diff-filter=U"], in: request.toplevel, gitPath: request.gitPath),
            output.succeeded
        else { return 0 }
        return output.standardOutput.split(separator: "\n").filter { !$0.isEmpty }.count
    }

    /// `rebase --abort`, outcome ignored: there is nothing more to do if even that fails, and the
    /// tree state is reported by the next status refresh either way.
    private static func abort(_ request: Request) {
        _ = try? GitProcess.run(
            request.gitPath, ["-C", request.toplevel, "rebase", "--abort"], timeout: 30)
    }

    /// The last non-empty line git printed, stderr first — where git puts its reasons.
    static func lastLine(of output: GitProcess.Output) -> String {
        for text in [output.standardError, output.standardOutput] {
            if let line = text.split(separator: "\n").last(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }) {
                return String(line).trimmingCharacters(in: .whitespaces)
            }
        }
        return "exit status \(output.status)"
    }
}
