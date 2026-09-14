// GitDiffService — the process half of the changes viewer (TKZ-58, design 2c.2).
//
// `GitStatusService` answers "how much changed?" with two cheap calls it repeats on every
// filesystem event. This one answers "what changed, exactly?" and is only asked while the viewer
// is open: a `--numstat` for the file list, then one `git diff -- <path>` per file the user looks
// at. Both go through `GitProcess`, so they take no lock and cannot prompt — the user's own git
// (and Claude's) keeps working underneath.
//
// Every call runs in the repo **toplevel**, never in the session's cwd: `--numstat` prints paths
// relative to the toplevel whatever the cwd, but a pathspec (`-- <path>`) is resolved against the
// cwd, and the two must agree or a file in a subdirectory session lists fine and then diffs as
// "no changes". For a worktree the toplevel is the worktree's own root, which is what the ticket
// asks for.
//
// Threading: one serial queue, results delivered on it; the caller hops to the main actor. A
// generation counter is the caller's business (`ChangesViewerController` drops answers to a
// question it has stopped asking); the service itself is stateless between calls.

import Dispatch
import Foundation

public final class GitDiffService: Sendable {
    private let gitPath: String
    private let queue = DispatchQueue(label: "se.tkz.tkzmux.GitDiffService")

    /// Files past this many bytes are not read for an untracked line count; the row shows no
    /// numbers and the diff pane says the file is too large. A build artefact that slipped past
    /// `.gitignore` must not cost a 200 MB read on every refresh.
    public static let untrackedReadLimit = 4 * 1024 * 1024

    public init(gitPath: String = GitProcess.gitPath) {
        self.gitPath = gitPath
    }

    // MARK: - Asynchronous API

    /// The file list for `toplevel` against `base`, tracked changes first (git's order) then
    /// untracked files (`ls-files` order). `nil` when git itself failed — not for an empty diff.
    public func summary(
        toplevel: String, base: DiffBase,
        completion: @escaping @Sendable (DiffSummary?) -> Void
    ) {
        queue.async { [gitPath] in
            completion(Self.computeSummary(toplevel: toplevel, base: base, gitPath: gitPath))
        }
    }

    /// One file's hunks. An untracked file is read from disk and shown as all-added.
    public func fileDiff(
        _ file: ChangedFile, toplevel: String, base: DiffBase,
        completion: @escaping @Sendable (FileDiff?) -> Void
    ) {
        queue.async { [gitPath] in
            completion(Self.computeFileDiff(file, toplevel: toplevel, base: base, gitPath: gitPath))
        }
    }

    // MARK: - Synchronous core (also the test seam)

    public static func computeSummary(
        toplevel: String, base: DiffBase, gitPath: String = GitProcess.gitPath
    ) -> DiffSummary? {
        var files: [ChangedFile] = []
        if let ref = resolve(base, toplevel: toplevel, gitPath: gitPath) {
            guard
                let output = try? GitProcess.git(
                    ["diff", ref, "--numstat", "-z"], in: toplevel, gitPath: gitPath)
            else { return nil }
            // `diff HEAD` on an unborn branch fails; that repo has only untracked files, which
            // the second call still lists. Any other failure is a measurement not made.
            if output.succeeded {
                files = DiffParsing.parseNumstat(output.standardOutput)
            } else if !isUnborn(toplevel: toplevel, gitPath: gitPath) {
                return nil
            }
        }
        guard
            let untracked = try? GitProcess.git(
                ["ls-files", "--others", "--exclude-standard", "-z"], in: toplevel, gitPath: gitPath),
            untracked.succeeded
        else { return nil }
        for path in untracked.standardOutput.split(separator: "\0").map(String.init) where !path.isEmpty {
            files.append(untrackedFile(path, toplevel: toplevel))
        }
        return DiffSummary(base: base, files: files)
    }

    public static func computeFileDiff(
        _ file: ChangedFile, toplevel: String, base: DiffBase, gitPath: String = GitProcess.gitPath
    ) -> FileDiff? {
        if file.isUntracked {
            let url = URL(fileURLWithPath: toplevel).appendingPathComponent(file.path)
            guard let data = readCapped(url) else { return FileDiff(path: file.path) }
            if data.prefix(8_000).contains(0) { return FileDiff(path: file.path, isBinary: true) }
            return DiffParsing.wholeFileAdded(
                path: file.path, contents: String(decoding: data, as: UTF8.self))
        }
        guard let ref = resolve(base, toplevel: toplevel, gitPath: gitPath) else { return nil }
        // `--no-color` because a `color.ui = always` in the user's config would otherwise paint
        // escape codes into the text; `--no-ext-diff` because an external diff tool is not a
        // unified diff at all. A rename names both paths, or git — seeing only the new one —
        // would print the whole file as added and disagree with the numstat's counts.
        let paths = [file.oldPath, file.path].compactMap { $0 }
        guard
            let output = try? GitProcess.git(
                ["diff", ref, "--no-color", "--no-ext-diff", "--"] + paths,
                in: toplevel, gitPath: gitPath, timeout: 10),
            output.succeeded
        else { return nil }
        return DiffParsing.parseUnifiedDiff(output.standardOutput, path: file.path)
    }

    /// `HEAD`, or the merge base of the upstream and `HEAD`. A merge base that cannot be found
    /// (the upstream ref is gone) falls back to the upstream itself rather than to nothing — a
    /// backwards-looking diff beats an empty viewer with no explanation.
    static func resolve(_ base: DiffBase, toplevel: String, gitPath: String) -> String? {
        switch base {
        case .head:
            return "HEAD"
        case .upstream(let name), .base(let name):
            guard
                let output = try? GitProcess.git(
                    ["merge-base", name, "HEAD"], in: toplevel, gitPath: gitPath),
                output.succeeded, !output.trimmedOutput.isEmpty
            else { return name }
            return output.trimmedOutput
        }
    }

    private static func isUnborn(toplevel: String, gitPath: String) -> Bool {
        guard
            let output = try? GitProcess.git(
                ["rev-parse", "--verify", "-q", "HEAD"], in: toplevel, gitPath: gitPath)
        else { return false }
        return !output.succeeded
    }

    static func untrackedFile(_ path: String, toplevel: String) -> ChangedFile {
        var file = ChangedFile(path: path, isUntracked: true)
        let url = URL(fileURLWithPath: toplevel).appendingPathComponent(path)
        if let data = readCapped(url) {
            let counts = DiffParsing.untrackedCounts(of: data)
            file.insertions = counts.insertions
            file.deletions = counts.deletions
        }
        return file
    }

    /// The file's bytes, or `nil` when it is unreadable or past `untrackedReadLimit`.
    private static func readCapped(_ url: URL) -> Data? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
            size <= untrackedReadLimit
        else { return nil }
        return try? Data(contentsOf: url)
    }
}
