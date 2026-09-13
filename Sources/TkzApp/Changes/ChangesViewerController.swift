// ChangesViewerController.swift — opens, feeds and closes the changes viewer (TKZ-58, design 2c.2).
//
// The viewer is a view *inside* the window, laid over the terminal container, not a panel like the
// first-prompt card: the card floats over a terminal that keeps drawing and must not lose the
// keyboard to it, whereas this view *replaces* the terminal on screen and takes the keyboard on
// purpose (Esc is how it gives it back). A subview also means the status bar stays where it is,
// with its `+142 −38` chip still visible — which is the artboard.
//
// Git is asked through two injected closures, defaulting to `GitDiffService`, so a test can feed
// the controller a summary and a diff without a repository. Answers arrive on the service's queue
// and are hopped onto the main actor; a generation counter drops any answer to a question the
// controller has stopped asking (the viewer closed, the row changed, the base changed).

import AppKit
import GitStatus
import TkzCore

@MainActor
final class ChangesViewerController {
    /// Called on the main actor; `done` may be called from any queue.
    typealias SummaryProvider = @MainActor (
        _ toplevel: String, _ base: DiffBase, _ done: @escaping @Sendable (DiffSummary?) -> Void
    ) -> Void
    typealias DiffProvider = @MainActor (
        _ file: ChangedFile, _ toplevel: String, _ base: DiffBase,
        _ done: @escaping @Sendable (FileDiff?) -> Void
    ) -> Void

    let view: ChangesViewerView
    /// The viewer went away — Esc, a selection change, the chord again. The window controller
    /// hands the keyboard back to the terminal.
    var onDismiss: (() -> Void)?

    var theme: Theme {
        didSet { if theme != oldValue { view.apply(theme: theme) } }
    }

    private(set) var model = ChangesViewerModel() {
        didSet { if model != oldValue { view.configure(model) } }
    }
    /// The row the viewer describes, while it is up.
    private(set) var sessionID: SessionID?
    private(set) var toplevel: String?
    /// The counts the viewer last saw for its row. A `GitSummary` that differs in them is the
    /// FSEvents signal, already debounced and coalesced by `GitStatusService`; one that differs
    /// only in its PR or timestamp is not a reason to re-run `git diff`.
    private var lastCounts: [Int]?
    private var generation = 0

    private let summaryProvider: SummaryProvider
    private let diffProvider: DiffProvider

    var isShown: Bool { !view.isHidden }

    init(
        theme: Theme,
        summaryProvider: SummaryProvider? = nil,
        diffProvider: DiffProvider? = nil
    ) {
        self.theme = theme
        self.view = ChangesViewerView(theme: theme)
        view.isHidden = true
        let service = (summaryProvider == nil || diffProvider == nil) ? GitDiffService() : nil
        self.summaryProvider = summaryProvider ?? { toplevel, base, done in
            service?.summary(toplevel: toplevel, base: base, completion: done)
        }
        self.diffProvider = diffProvider ?? { file, toplevel, base, done in
            service?.fileDiff(file, toplevel: toplevel, base: base, completion: done)
        }
        view.onEscape = { [weak self] in self?.dismiss() }
        view.onMoveSelection = { [weak self] offset in self?.moveSelection(by: offset) }
        view.onSelectPath = { [weak self] path in self?.select(path) }
        view.onBaseChanged = { [weak self] base in self?.setBase(base) }
        view.onModeChanged = { [weak self] mode in self?.setMode(mode) }
        view.configure(model)
    }

    // MARK: Presentation

    /// Shows the viewer for `id`'s repository at `toplevel` and starts the read. Re-presenting
    /// the same row keeps its selection and mode; another row starts over.
    func present(for id: SessionID, toplevel: String, git: GitSummary?) {
        if sessionID != id || self.toplevel != toplevel {
            model = ChangesViewerModel()
        }
        sessionID = id
        self.toplevel = toplevel
        lastCounts = Self.counts(of: git)
        model.setBases(upstream: git?.upstream, base: git?.baseBranch)
        view.isHidden = false
        view.takeKeyboard()
        loadSummary()
    }

    /// Esc, the chord again, a selection change, a row removed.
    func dismiss() {
        guard isShown else { return }
        generation &+= 1
        view.isHidden = true
        sessionID = nil
        toplevel = nil
        lastCounts = nil
        onDismiss?()
    }

    /// The row's `GitSummary` was re-posted. Re-reads only when the numbers moved.
    func gitSummaryChanged(_ git: GitSummary?) {
        guard isShown else { return }
        let counts = Self.counts(of: git)
        guard counts != lastCounts else { return }
        lastCounts = counts
        model.setBases(upstream: git?.upstream, base: git?.baseBranch)
        loadSummary()
    }

    static func counts(of git: GitSummary?) -> [Int]? {
        guard let git else { return nil }
        return [
            git.changedFiles, git.untrackedFiles, git.insertions, git.deletions, git.ahead, git.behind,
            git.aheadOfBase ?? -1, git.behindBase ?? -1,
        ]
    }

    // MARK: Reads

    private func loadSummary() {
        guard let toplevel else { return }
        generation &+= 1
        let generation = generation
        let base = model.base
        summaryProvider(toplevel, base) { [weak self] summary in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applySummary(summary, generation: generation) }
            }
        }
    }

    func applySummary(_ summary: DiffSummary?, generation: Int) {
        guard generation == self.generation else { return }
        let before = model.selectedPath
        model.setSummary(summary)
        if model.selectedPath != before { view.resetDiffScroll() }
        // The selected file's diff is re-read even when the file stayed selected: the refresh
        // came from the working tree changing, and this file may be what changed.
        loadDiff()
    }

    private func loadDiff() {
        guard let toplevel, let file = model.selectedFile else { return }
        let generation = generation
        let base = model.base
        diffProvider(file, toplevel, base) { [weak self] diff in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyDiff(diff, for: file.path, generation: generation) }
            }
        }
    }

    func applyDiff(_ diff: FileDiff?, for path: String, generation: Int) {
        guard generation == self.generation, model.selectedPath == path else { return }
        model.diff = diff ?? FileDiff(path: path)
    }

    // MARK: Interaction

    func select(_ path: String) {
        guard path != model.selectedPath else { return }
        model.select(path)
        view.resetDiffScroll()
        // A new question for git: an in-flight answer for the previous file must not land on
        // this one. `applyDiff` also checks the path, so this is belt and braces.
        generation &+= 1
        loadDiff()
    }

    func moveSelection(by offset: Int) {
        guard let current = model.selectedIndex else {
            if let first = model.files.first { select(first.path) }
            return
        }
        let next = min(max(0, current + offset), max(0, model.files.count - 1))
        guard next != current else { return }
        select(model.files[next].path)
    }

    func setBase(_ base: DiffBase) {
        guard base != model.base, model.bases.contains(base) else { return }
        model.base = base
        model.diff = nil
        view.resetDiffScroll()
        loadSummary()
    }

    func setMode(_ mode: DiffDisplayMode) {
        guard mode != model.mode else { return }
        model.mode = mode
    }
}
