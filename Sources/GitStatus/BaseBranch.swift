// BaseBranch — "which branch is this repo's trunk?" (design 5a/5b, 2026-09-13).
//
// The status bar's `↑n ↓m` is the branch against its *upstream*, which for a per-session worktree
// branch says whether it was pushed — not how far it lags `main`. This type answers the second
// question's first half: what "main" is. Resolution order, all local (no network):
//
//   1. `refs/remotes/origin/HEAD` — set by `git clone`, and what `git remote set-head` maintains.
//   2. `refs/remotes/origin/main`, then `origin/master` — clones made by `init` + `remote add`
//      have no `origin/HEAD`.
//   3. Local `main`, then `master` — a repo with no remote at all still has a trunk its worktree
//      branches diverge from.
//
// A repo whose default is `develop` and has no `origin/HEAD` resolves to nothing; the chip stays
// hidden until `git remote set-head origin -a` names it. Resolution is one or two git launches, so
// `GitStatusService` caches the answer per repo and retries an unresolved one every minute.

import Foundation

/// The base branch a session's branch is measured against.
public struct BaseBranch: Hashable, Sendable {
    /// `"origin"`, or `nil` for the local fallback.
    public var remote: String?
    /// `"main"` — the short branch name on either side.
    public var name: String

    public init(remote: String?, name: String) {
        self.remote = remote
        self.name = name
    }

    /// What `rev-list`, `rebase` and the chip's tooltip name: `origin/main`, or a bare `main`.
    public var ref: String { remote.map { "\($0)/\(name)" } ?? name }

    /// Synchronous — it launches git — so call it from a background queue. `nil` when nothing in
    /// the list above exists, or when git could not be launched.
    public static func resolve(in directory: String, gitPath: String = GitProcess.gitPath) -> BaseBranch? {
        if let output = try? GitProcess.git(
            ["symbolic-ref", "-q", "refs/remotes/origin/HEAD"], in: directory, gitPath: gitPath),
            output.succeeded, let base = parseSymbolicRef(output.trimmedOutput)
        {
            return base
        }
        guard
            let output = try? GitProcess.git(
                ["for-each-ref", "--format=%(refname)"] + candidates, in: directory, gitPath: gitPath),
            output.succeeded
        else { return nil }
        return pick(from: output.standardOutput.split(separator: "\n").map(String.init))
    }

    /// The fallback refs, in priority order. `for-each-ref` prints whichever exist sorted by
    /// name — which would put `master` before `main` for the local pair — so `pick` re-applies
    /// this order rather than taking the first line.
    static let candidates = [
        "refs/remotes/origin/main", "refs/remotes/origin/master",
        "refs/heads/main", "refs/heads/master",
    ]

    /// `refs/remotes/origin/main` → `origin/main`. Anything else (an empty line, a ref outside
    /// `refs/remotes/`) is `nil`.
    static func parseSymbolicRef(_ line: String) -> BaseBranch? {
        let prefix = "refs/remotes/"
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let remote = String(rest[..<slash])
        let name = String(rest[rest.index(after: slash)...])
        guard !remote.isEmpty, !name.isEmpty else { return nil }
        return BaseBranch(remote: remote, name: name)
    }

    /// The first of `candidates` that appears in `refnames`, in candidate order.
    static func pick(from refnames: [String]) -> BaseBranch? {
        let present = Set(refnames.map { $0.trimmingCharacters(in: .whitespaces) })
        for candidate in candidates where present.contains(candidate) {
            if let base = parseSymbolicRef(candidate) { return base }
            let headsPrefix = "refs/heads/"
            if candidate.hasPrefix(headsPrefix) {
                return BaseBranch(remote: nil, name: String(candidate.dropFirst(headsPrefix.count)))
            }
        }
        return nil
    }
}
