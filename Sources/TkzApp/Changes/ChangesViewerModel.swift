// ChangesViewerModel.swift — the value behind the changes viewer (TKZ-58, design 2c.2).
//
// Everything the viewer draws is a pure function of this struct and a `Theme`: the header's
// `12 files · +142 −38`, the base menu, which file is selected, and — through `DiffRowBuilder` —
// the rows of the diff pane in either display mode. `ChangesViewerController` mutates it as git
// answers arrive; the views never hold state of their own, so "what does the viewer show after a
// refresh that dropped the selected file?" is a test over this file, not a screenshot.

import Foundation
import GitStatus
import TkzCore

/// The header's `Inline | Split` toggle.
enum DiffDisplayMode: Hashable, Sendable, CaseIterable {
    case inline
    case split

    var title: String {
        switch self {
        case .inline: "Inline"
        case .split: "Split"
        }
    }
}

struct ChangesViewerModel: Equatable {
    /// `nil` until the first `--numstat` has landed (the header then says `Loading…`).
    var summary: DiffSummary?
    /// The file whose diff the right-hand pane shows. Kept by *path* rather than index so a
    /// refresh that reorders the list keeps the same file selected.
    var selectedPath: String?
    var mode: DiffDisplayMode = .inline
    /// What the base menu offers: `HEAD`, then the upstream when the branch has one.
    var bases: [DiffBase] = [.head]
    var base: DiffBase = .head
    /// The selected file's diff, or `nil` while it is being read (or when there is no file).
    var diff: FileDiff?
    /// The one thing git could not answer: the numstat itself failed. The pane says so rather
    /// than showing an empty list that reads as "nothing changed".
    var failed = false

    var files: [ChangedFile] { summary?.files ?? [] }

    var selectedIndex: Int? {
        guard let selectedPath else { return nil }
        return files.firstIndex { $0.path == selectedPath }
    }

    var selectedFile: ChangedFile? { selectedIndex.map { files[$0] } }

    /// `12 files · +142 −38` — the header's counts. Empty until the summary is known, so the
    /// header can show its own placeholder instead of `0 files · +0 −0` for a list still loading.
    var countsText: String {
        guard let summary else { return "" }
        let n = summary.files.count
        return "\(n) file\(n == 1 ? "" : "s") · +\(summary.insertions) \u{2212}\(summary.deletions)"
    }

    /// A fresh answer from git. The selection survives when its file is still listed; otherwise
    /// the first file is selected, so the pane is never blank while there is something to show.
    mutating func setSummary(_ new: DiffSummary?) {
        summary = new
        failed = new == nil
        if selectedIndex == nil {
            let previous = selectedPath
            selectedPath = files.first?.path
            // The selected file went away: whatever diff was showing is that file's, not the new
            // selection's.
            if previous != selectedPath { diff = nil }
        }
    }

    /// The bases the branch offers: `HEAD`, the upstream when there is one, and the repo's base
    /// branch when it is known and is not the upstream already (a main checkout tracking
    /// `origin/main` must not list it twice). Keeps the current choice when it is still on the
    /// menu — a refresh must not silently flip `vs origin/develop` back to `vs HEAD`.
    mutating func setBases(upstream: String?, base baseBranch: String? = nil) {
        bases = [.head] + (upstream.map { [DiffBase.upstream($0)] } ?? [])
        if let baseBranch, baseBranch != upstream { bases.append(.base(baseBranch)) }
        if !bases.contains(base) { base = .head }
    }

    mutating func select(_ path: String) {
        guard files.contains(where: { $0.path == path }), path != selectedPath else { return }
        selectedPath = path
        diff = nil
    }

    /// ↑ / ↓ in the file list: clamped, no wrap — an arrow at the end does nothing, like the
    /// search overlay's.
    mutating func moveSelection(by offset: Int) {
        guard !files.isEmpty else { return }
        let current = selectedIndex ?? 0
        let next = min(max(0, current + offset), files.count - 1)
        select(files[next].path)
    }
}

// MARK: - Rows

/// One drawn row of the diff pane, in either mode.
enum DiffRow: Equatable {
    /// `@@ -87,9 +87,24 @@ …`, spanning the full width.
    case hunk(String)
    /// Inline: one line with both numbers.
    case line(DiffLine)
    /// Split: the old side and the new side. A removed line has no right half, an added line no
    /// left half, and a context line is the same text on both.
    case pair(left: DiffLine?, right: DiffLine?)
}

enum DiffRowBuilder {
    static func rows(for diff: FileDiff, mode: DiffDisplayMode) -> [DiffRow] {
        var out: [DiffRow] = []
        for hunk in diff.hunks {
            out.append(.hunk(hunk.header))
            switch mode {
            case .inline: out.append(contentsOf: hunk.lines.map(DiffRow.line))
            case .split: out.append(contentsOf: pairs(hunk.lines))
            }
        }
        return out
    }

    /// Pairs a run of removed lines with the run of added lines that follows it, index by index,
    /// the way every side-by-side viewer does; the longer run's tail sits alone. Context lines
    /// stand on both sides. A `\ No newline` marker attaches to whichever side it follows — both
    /// when it follows context — so it never opens a pairing run of its own.
    static func pairs(_ lines: [DiffLine]) -> [DiffRow] {
        var out: [DiffRow] = []
        var removed: [DiffLine] = []
        var added: [DiffLine] = []

        func flush() {
            let count = max(removed.count, added.count)
            for i in 0..<count {
                out.append(.pair(
                    left: i < removed.count ? removed[i] : nil,
                    right: i < added.count ? added[i] : nil))
            }
            removed.removeAll()
            added.removeAll()
        }

        var lastKind: DiffLineKind = .context
        for line in lines {
            switch line.kind {
            case .removed:
                // A removed line after added ones is a new run: `- + -` is two changes, not one.
                if !added.isEmpty { flush() }
                removed.append(line)
            case .added:
                added.append(line)
            case .context:
                flush()
                out.append(.pair(left: line, right: line))
            case .noNewline:
                switch lastKind {
                case .removed: removed.append(line)
                case .added: added.append(line)
                default:
                    flush()
                    out.append(.pair(left: line, right: line))
                }
            }
            if line.kind != .noNewline { lastKind = line.kind }
        }
        flush()
        return out
    }
}
