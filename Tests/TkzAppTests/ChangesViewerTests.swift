// ChangesViewerTests — the changes viewer (TKZ-58, design 2c.2): the model, the row builder, the
// status-bar chips that open it, and the window controller's open/close/focus round trip.

import AppKit
import GitStatus
import Testing
import TkzCore

@testable import TkzApp

// MARK: - Model

struct ChangesViewerModelTests {

    static let summary = DiffSummary(base: .head, files: [
        ChangedFile(path: "src/Service.cs", insertions: 41, deletions: 12),
        ChangedFile(path: "Controller.cs", insertions: 18, deletions: 2),
        ChangedFile(path: "new.txt", insertions: 3, deletions: 0, isUntracked: true),
    ])

    @Test func countsTextIsTheHeaderLine() {
        var model = ChangesViewerModel()
        #expect(model.countsText == "")
        model.setSummary(Self.summary)
        #expect(model.countsText == "3 files · +62 \u{2212}14")
        model.setSummary(DiffSummary(base: .head, files: [Self.summary.files[0]]))
        #expect(model.countsText == "1 file · +41 \u{2212}12")
    }

    @Test func firstSummarySelectsTheFirstFile() {
        var model = ChangesViewerModel()
        model.setSummary(Self.summary)
        #expect(model.selectedPath == "src/Service.cs")
        #expect(model.selectedIndex == 0)
        #expect(!model.failed)
    }

    @Test func refreshKeepsTheSelectionByPath() {
        var model = ChangesViewerModel()
        model.setSummary(Self.summary)
        model.select("new.txt")
        model.diff = FileDiff(path: "new.txt")
        // Reordered, still there: same file stays selected.
        model.setSummary(DiffSummary(base: .head, files: Self.summary.files.reversed()))
        #expect(model.selectedPath == "new.txt")
        #expect(model.selectedIndex == 0)
        // Gone: the first file takes over and the stale diff goes with the old selection.
        model.setSummary(DiffSummary(base: .head, files: Array(Self.summary.files.prefix(2))))
        #expect(model.selectedPath == "src/Service.cs")
        #expect(model.diff == nil)
    }

    @Test func failedSummaryIsFlagged() {
        var model = ChangesViewerModel()
        model.setSummary(nil)
        #expect(model.failed)
        #expect(model.files.isEmpty)
        #expect(ChangesViewerView.message(for: model) == "git could not read this repository")
    }

    @Test func arrowsClampAtTheEnds() {
        var model = ChangesViewerModel()
        model.moveSelection(by: 1)
        #expect(model.selectedPath == nil)
        model.setSummary(Self.summary)
        model.moveSelection(by: -1)
        #expect(model.selectedIndex == 0)
        model.moveSelection(by: 5)
        #expect(model.selectedIndex == 2)
        model.moveSelection(by: -1)
        #expect(model.selectedIndex == 1)
    }

    @Test func basesKeepTheChoiceWhileItIsOffered() {
        var model = ChangesViewerModel()
        model.setBases(upstream: "origin/develop")
        #expect(model.bases == [.head, .upstream("origin/develop")])
        model.base = .upstream("origin/develop")
        model.setBases(upstream: "origin/develop")
        #expect(model.base == .upstream("origin/develop"))
        model.setBases(upstream: nil)
        #expect(model.bases == [.head])
        #expect(model.base == .head)
    }

    @Test func theBaseBranchIsOfferedUnlessItIsTheUpstream() {
        var model = ChangesViewerModel()
        model.setBases(upstream: "origin/feature", base: "origin/main")
        #expect(model.bases == [.head, .upstream("origin/feature"), .base("origin/main")])
        model.base = .base("origin/main")
        model.setBases(upstream: nil, base: "origin/main")
        #expect(model.bases == [.head, .base("origin/main")])
        #expect(model.base == .base("origin/main"))
        // A main checkout tracking origin/main: one entry, not two.
        model.setBases(upstream: "origin/main", base: "origin/main")
        #expect(model.bases == [.head, .upstream("origin/main")])
        #expect(model.base == .head)
    }

    @Test func paneMessagesCoverEveryEmptyState() {
        var model = ChangesViewerModel()
        #expect(ChangesViewerView.message(for: model) == "Loading\u{2026}")
        model.setSummary(DiffSummary(base: .head, files: []))
        #expect(ChangesViewerView.message(for: model) == "No changes")
        model.setSummary(Self.summary)
        #expect(ChangesViewerView.message(for: model) == "Loading\u{2026}")
        model.diff = FileDiff(path: "src/Service.cs", isBinary: true)
        #expect(ChangesViewerView.message(for: model) == "Binary file")
        model.diff = FileDiff(path: "src/Service.cs", hunks: [
            DiffHunk(header: "@@ -1 +1 @@", oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
                     lines: [DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "x")]),
        ])
        #expect(ChangesViewerView.message(for: model) == nil)
        model.select("new.txt")
        model.diff = FileDiff(path: "new.txt")
        #expect(ChangesViewerView.message(for: model) == "Empty file")
    }
}

// MARK: - Rows

struct DiffRowBuilderTests {

    static func line(_ kind: DiffLineKind, _ text: String, old: Int? = nil, new: Int? = nil) -> DiffLine {
        DiffLine(kind: kind, oldNumber: old, newNumber: new, text: text)
    }

    static let hunk = DiffHunk(
        header: "@@ -1,4 +1,5 @@", oldStart: 1, oldCount: 4, newStart: 1, newCount: 5,
        lines: [
            line(.context, "a", old: 1, new: 1),
            line(.removed, "b", old: 2),
            line(.removed, "c", old: 3),
            line(.added, "B", new: 2),
            line(.added, "C", new: 3),
            line(.added, "D", new: 4),
            line(.context, "e", old: 4, new: 5),
        ])

    @Test func inlineRowsAreTheHunkThenItsLines() {
        let rows = DiffRowBuilder.rows(for: FileDiff(path: "x", hunks: [Self.hunk]), mode: .inline)
        #expect(rows.count == 8)
        #expect(rows[0] == .hunk("@@ -1,4 +1,5 @@"))
        #expect(rows[2] == .line(Self.hunk.lines[1]))
    }

    @Test func splitPairsRemovedWithAddedIndexByIndex() {
        let rows = DiffRowBuilder.rows(for: FileDiff(path: "x", hunks: [Self.hunk]), mode: .split)
        let lines = Self.hunk.lines
        let expected: [DiffRow] = [
            .hunk("@@ -1,4 +1,5 @@"),
            .pair(left: lines[0], right: lines[0]),
            .pair(left: lines[1], right: lines[3]),
            .pair(left: lines[2], right: lines[4]),
            .pair(left: nil, right: lines[5]),
            .pair(left: lines[6], right: lines[6]),
        ]
        #expect(rows == expected)
    }

    @Test func aRemovedLineAfterAddedOnesStartsANewRun() {
        let lines = [
            Self.line(.removed, "a", old: 1), Self.line(.added, "A", new: 1),
            Self.line(.removed, "b", old: 2),
        ]
        let rows = DiffRowBuilder.pairs(lines)
        let expected: [DiffRow] = [.pair(left: lines[0], right: lines[1]), .pair(left: lines[2], right: nil)]
        #expect(rows == expected)
    }

    @Test func noNewlineMarkerFollowsItsSide() {
        let marker = Self.line(.noNewline, "No newline at end of file")
        let afterAdded = [Self.line(.added, "x", new: 1), marker]
        let expectedAdded: [DiffRow] = [
            .pair(left: nil, right: afterAdded[0]), .pair(left: nil, right: marker),
        ]
        #expect(DiffRowBuilder.pairs(afterAdded) == expectedAdded)
        let afterContext = [Self.line(.context, "x", old: 1, new: 1), marker]
        let expectedContext: [DiffRow] = [
            .pair(left: afterContext[0], right: afterContext[0]), .pair(left: marker, right: marker),
        ]
        #expect(DiffRowBuilder.pairs(afterContext) == expectedContext)
    }

    @Test func markedTextCarriesTheSign() {
        #expect(DiffPaneView.marked(Self.line(.added, "x")) == "+ x")
        #expect(DiffPaneView.marked(Self.line(.removed, "x")) == "\u{2212} x")
        #expect(DiffPaneView.marked(Self.line(.context, "x")) == "  x")
        #expect(DiffPaneView.marked(Self.line(.context, "\ta")) == "      a")
    }
}

// MARK: - Status bar chips

@MainActor
struct ChangesStatusBarTests {

    @Test func bothDiffChipsOpenTheViewer() throws {
        let items = StatusBarView.items(
            for: StatusBarModel(branch: "develop", diffAdded: 142, diffRemoved: 38, diffFiles: 12),
            theme: .default)
        let counts = try #require(items.first { $0.segment.plainText == "+142 \u{2212}38" })
        let files = try #require(items.first { $0.segment.plainText == "12 files" })
        #expect(counts.action == .showChanges)
        #expect(files.action == .showChanges)
        #expect(counts.url == nil)
        #expect(counts.tooltip == "142 inserted, 38 deleted since HEAD\nClick to browse the changes")
        #expect(files.tooltip == "12 files changed in the working tree\nClick to browse the changes")
        // The branch is still inert.
        #expect(items[0].action == nil)
    }

    @Test func clickingAChipFiresTheCallbackNotABrowser() throws {
        let view = StatusBarInteractionTests.laidOut(
            StatusBarModel(branch: "develop", diffAdded: 1, diffRemoved: 0, diffFiles: 1))
        final class Box { var shown = 0; var url: URL? }
        let box = Box()
        view.onShowChanges = { box.shown += 1 }
        view.openURL = { box.url = $0 }
        let chip = try #require(view.placement().first { $0.item.action == .showChanges })
        let point = NSPoint(x: chip.frame.midX, y: chip.frame.midY)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 0))
        view.mouseUp(with: event)
        #expect(box.shown == 1)
        #expect(box.url == nil)
    }

    @Test func theTooltipNamesTheChordWhenKnown() throws {
        let model = StatusBarModel(diffAdded: 1, diffRemoved: 0, diffFiles: 1, changesShortcut: "\u{21E7}\u{2318}G")
        let items = Self.items(model: model)
        #expect(items[0].tooltip == "1 inserted, 0 deleted since HEAD\nClick or \u{21E7}\u{2318}G to browse the changes")
        #expect(items[1].tooltip == "1 file changed in the working tree\nClick or \u{21E7}\u{2318}G to browse the changes")
        #expect(StatusBarView.showChangesHint(shortcut: "") == "Click to browse the changes")
    }

    static func items(model: StatusBarModel) -> [StatusItem] {
        StatusBarView.items(for: model, theme: .default)
    }

    @Test func hoveringAClickableChipHighlightsItAndInertTextDoesNot() throws {
        let view = StatusBarInteractionTests.laidOut(
            StatusBarModel(branch: "develop", diffAdded: 1, diffRemoved: 0, diffFiles: 1))
        let chip = try #require(view.placement().first { $0.item.action == .showChanges })
        let branch = try #require(view.placement().first { $0.item.action == nil })
        func move(to point: NSPoint) throws {
            let event = try #require(NSEvent.mouseEvent(
                with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: 0, pressure: 0))
            view.mouseMoved(with: event)
        }
        try move(to: NSPoint(x: chip.frame.midX, y: chip.frame.midY))
        #expect(view.hoveredItemForTesting?.action == .showChanges)
        try move(to: NSPoint(x: branch.frame.midX, y: branch.frame.midY))
        #expect(view.hoveredItemForTesting == nil)
        try move(to: NSPoint(x: chip.frame.midX, y: chip.frame.midY))
        #expect(view.hoveredItemForTesting != nil)
        view.mouseExited(with: try #require(NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        #expect(view.hoveredItemForTesting == nil)
        // The wash is wider than the text and vertically centred on the band.
        let wash = StatusBarView.hoverRect(for: chip.frame, in: view.bounds)
        #expect(wash.minX == chip.frame.minX - 4 && wash.maxX == chip.frame.maxX + 4)
        #expect(abs(wash.midY - view.bounds.midY) <= 1)
    }

    @Test func theChordIsShiftCommandG() {
        #expect(ShortcutsTable.defaults[.showChanges] == Shortcut("g", [.shift, .command]))
        #expect(ShortcutsTable.title(for: .showChanges) == "Show Changes")
        #expect(ShortcutsTable.allActions.contains(.showChanges))
    }
}

// MARK: - Controller

@MainActor
struct ChangesViewerControllerTests {

    /// A controller whose git is two recorded closures. Answers are delivered synchronously so
    /// the test needs no run loop; the controller still hops them through the main queue, which
    /// `drain` flushes.
    @MainActor final class Fake {
        var summaries: [DiffSummary?] = []
        var diffs: [String: FileDiff] = [:]
        var summaryCalls: [(String, DiffBase)] = []
        var diffCalls: [String] = []
        let controller: ChangesViewerController

        init() {
            let box = Box()
            controller = ChangesViewerController(
                theme: .default,
                summaryProvider: { toplevel, base, done in
                    box.fake?.summaryCalls.append((toplevel, base))
                    done(box.fake?.summaries.first ?? nil)
                },
                diffProvider: { file, _, _, done in
                    box.fake?.diffCalls.append(file.path)
                    done(box.fake?.diffs[file.path] ?? FileDiff(path: file.path))
                })
            box.fake = self
        }

        @MainActor final class Box { weak var fake: Fake? }
    }

    /// Yields the main actor until `condition` holds, so the main-queue hops the controller makes
    /// can land — the same shape as `MainWindowControllerTests.settle`. The deadline is generous
    /// because every `@MainActor` suite in the target shares the actor: under the full parallel
    /// run a yield can hand it to a test that holds it for seconds. The happy path returns in
    /// milliseconds either way.
    @discardableResult
    static func settle(until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// For the negative assertions ("git was not asked again"): a fixed pause.
    static func pause() async {
        try? await Task.sleep(for: .milliseconds(80))
    }

    static let summary = ChangesViewerModelTests.summary

    @Test func presentLoadsTheListThenTheFirstFile() async {
        let fake = Fake()
        fake.summaries = [Self.summary]
        fake.diffs["src/Service.cs"] = FileDiff(path: "src/Service.cs", hunks: [DiffRowBuilderTests.hunk])
        let id = SessionID(uuid: UUID())

        #expect(!fake.controller.isShown)
        fake.controller.present(for: id, toplevel: "/repo", git: GitSummary(upstream: "origin/main"))
        #expect(fake.controller.isShown)
        #expect(fake.controller.sessionID == id)
        await Self.settle { fake.controller.model.diff != nil }

        #expect(fake.summaryCalls.map(\.0) == ["/repo"])
        #expect(fake.controller.model.bases == [.head, .upstream("origin/main")])
        #expect(fake.controller.model.selectedPath == "src/Service.cs")
        #expect(fake.diffCalls == ["src/Service.cs"])
        #expect(fake.controller.model.diff?.hunks.count == 1)
        #expect(fake.controller.view.header.countsForTesting == "3 files · +62 \u{2212}14")
        #expect(fake.controller.view.diffPane.rows.count == 8)
        #expect(fake.controller.view.pathHeaderForTesting.stringValue == "src/Service.cs")
    }

    @Test func selectionChangesReadThatFileOnly() async {
        let fake = Fake()
        fake.summaries = [Self.summary]
        fake.controller.present(for: SessionID(uuid: UUID()), toplevel: "/repo", git: nil)
        await Self.settle { fake.controller.model.diff != nil }
        fake.diffCalls.removeAll()

        fake.controller.moveSelection(by: 1)
        await Self.settle { fake.diffCalls.count == 1 }
        #expect(fake.controller.model.selectedPath == "Controller.cs")
        #expect(fake.diffCalls == ["Controller.cs"])
        #expect(fake.summaryCalls.count == 1)

        fake.controller.select("new.txt")
        await Self.settle { fake.diffCalls.count == 2 }
        #expect(fake.controller.view.fileList.selectedPath == "new.txt")
        #expect(fake.diffCalls == ["Controller.cs", "new.txt"])
    }

    @Test func gitNumbersMovingReReadsTheListButThePrDoesNot() async {
        let fake = Fake()
        fake.summaries = [Self.summary]
        var git = GitSummary(changedFiles: 2, insertions: 59, deletions: 14)
        fake.controller.present(for: SessionID(uuid: UUID()), toplevel: "/repo", git: git)
        await Self.settle { fake.controller.model.diff != nil }
        #expect(fake.summaryCalls.count == 1)

        git.pr = PRInfo(number: 7)
        fake.controller.gitSummaryChanged(git)
        await Self.pause()
        #expect(fake.summaryCalls.count == 1)

        git.insertions = 60
        fake.controller.gitSummaryChanged(git)
        await Self.settle { fake.summaryCalls.count == 2 && fake.controller.model.diff != nil }
        #expect(fake.summaryCalls.count == 2)
        #expect(fake.controller.model.selectedPath == "src/Service.cs")
    }

    @Test func changingTheBaseReReadsAgainstIt() async {
        let fake = Fake()
        fake.summaries = [Self.summary]
        fake.controller.present(
            for: SessionID(uuid: UUID()), toplevel: "/repo", git: GitSummary(upstream: "origin/main"))
        await Self.settle { fake.controller.model.diff != nil }

        fake.controller.setBase(.upstream("origin/main"))
        await Self.settle { fake.summaryCalls.count == 2 && fake.controller.model.diff != nil }
        #expect(fake.summaryCalls.last?.1 == .upstream("origin/main"))
        #expect(fake.controller.view.header.basePopupForTesting.indexOfSelectedItem == 1)
        // Not on the menu: ignored.
        fake.controller.setBase(.upstream("origin/other"))
        #expect(fake.controller.model.base == .upstream("origin/main"))
    }

    @Test func modeSwitchRebuildsRowsWithoutAskingGit() async {
        let fake = Fake()
        fake.summaries = [Self.summary]
        fake.diffs["src/Service.cs"] = FileDiff(path: "src/Service.cs", hunks: [DiffRowBuilderTests.hunk])
        fake.controller.present(for: SessionID(uuid: UUID()), toplevel: "/repo", git: nil)
        await Self.settle { fake.controller.model.diff != nil }
        let calls = fake.diffCalls.count

        fake.controller.setMode(.split)
        #expect(fake.controller.view.diffPane.rows.count == 6)
        #expect(fake.controller.view.header.modeControlForTesting.selectedSegment == 1)
        #expect(fake.diffCalls.count == calls)
    }

    @Test func staleAnswersAreDropped() async {
        let fake = Fake()
        fake.summaries = [Self.summary]
        fake.controller.present(for: SessionID(uuid: UUID()), toplevel: "/repo", git: nil)
        await Self.settle { fake.controller.model.diff != nil }
        let generation = 0  // anything but the current one
        fake.controller.applySummary(DiffSummary(base: .head, files: []), generation: generation)
        #expect(fake.controller.model.files.count == 3)
        fake.controller.applyDiff(FileDiff(path: "Controller.cs"), for: "Controller.cs", generation: generation)
        #expect(fake.controller.model.selectedPath == "src/Service.cs")
    }

    @Test func keysWalkTheFilesAndEscapeCloses() async throws {
        let fake = Fake()
        fake.summaries = [Self.summary]
        fake.controller.present(for: SessionID(uuid: UUID()), toplevel: "/repo", git: nil)
        await Self.settle { fake.controller.model.diff != nil }
        let view = fake.controller.view

        func press(_ keyCode: UInt16) throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                keyCode: keyCode))
            view.keyDown(with: event)
        }

        try press(125)  // ↓
        await Self.settle { fake.controller.model.selectedPath == "Controller.cs" }
        #expect(fake.controller.model.selectedPath == "Controller.cs")
        try press(126)  // ↑
        await Self.settle { fake.controller.model.selectedPath == "src/Service.cs" }
        #expect(fake.controller.model.selectedPath == "src/Service.cs")
        try press(0)  // `a`: swallowed, nothing changes
        #expect(fake.controller.model.selectedPath == "src/Service.cs")
        #expect(ChangesViewerView.Key(keyCode: 0) == nil)
        try press(53)  // esc
        #expect(!fake.controller.isShown)
    }

    @Test func themeChangeRedrawsThePathHeader() async {
        let fake = Fake()
        fake.summaries = [Self.summary]
        fake.controller.present(for: SessionID(uuid: UUID()), toplevel: "/repo", git: nil)
        await Self.settle { fake.controller.model.diff != nil }
        let header = fake.controller.view.pathHeaderForTesting
        let before = header.attributedStringValue
        fake.controller.theme = .light
        let after = header.attributedStringValue
        #expect(after.string == before.string)
        #expect(after.string == "src/Service.cs")
        let color = { (text: NSAttributedString) -> NSColor? in
            text.attribute(.foregroundColor, at: text.length - 1, effectiveRange: nil) as? NSColor
        }
        #expect(color(before) == Theme.midnightIndigo.terminalForeground.nsColor)
        #expect(color(after) == Theme.light.terminalForeground.nsColor)
    }

    @Test func theCloseButtonDismissesLikeEscape() {
        let fake = Fake()
        fake.summaries = [Self.summary]
        fake.controller.present(for: SessionID(uuid: UUID()), toplevel: "/repo", git: nil)
        #expect(fake.controller.isShown)
        fake.controller.view.header.closeButtonForTesting.performClick(nil)
        #expect(!fake.controller.isShown)
    }

    @Test func dismissHidesAndForgetsTheRow() {
        let fake = Fake()
        fake.summaries = [Self.summary]
        final class Box { var dismissed = 0 }
        let box = Box()
        fake.controller.onDismiss = { box.dismissed += 1 }
        fake.controller.present(for: SessionID(uuid: UUID()), toplevel: "/repo", git: nil)
        fake.controller.dismiss()
        #expect(!fake.controller.isShown)
        #expect(fake.controller.sessionID == nil)
        #expect(box.dismissed == 1)
        // Not shown: a second dismiss is a no-op, not a second callback.
        fake.controller.dismiss()
        #expect(box.dismissed == 1)
    }
}

// MARK: - Window controller

@MainActor
struct ChangesViewerWindowTests {

    @Test func chordOpensOverTheTerminalAndEscReturnsFocus() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        let id = try #require(harness.store.state.orderedSessions.first?.id)
        _ = try harness.host.openRow(id)
        harness.mutate {
            $0.setLive(LiveSessionState(shellPid: 1, status: .idle), for: id)
            $0.select(id)
        }
        controller.focusTerminalIfSessionShown()
        #expect(controller.dispatcher.canPerform(.showChanges))

        // Installed over the terminal container, hidden until asked for.
        let view = controller.changes.view
        #expect(view.superview === controller.detail.view)
        #expect(view.isHidden)

        _ = controller.dispatcher.perform(.showChanges)
        harness.layout()
        #expect(controller.changes.isShown)
        #expect(controller.changes.sessionID == id)
        #expect(view.frame == controller.detail.terminalContainer.frame)
        #expect(harness.window.firstResponder === view)

        view.cancelOperation(nil)
        #expect(!controller.changes.isShown)
        #expect(harness.window.firstResponder === harness.terminalView)

        // The chord toggles.
        _ = controller.dispatcher.perform(.showChanges)
        #expect(controller.changes.isShown)
        _ = controller.dispatcher.perform(.showChanges)
        #expect(!controller.changes.isShown)
    }

    @Test func selectingAnotherRowClosesIt() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        let ids = harness.store.state.orderedSessions.map(\.id)
        let first = try #require(ids.first)
        let second = try #require(ids.dropFirst().first)
        _ = try harness.host.openRow(first)
        harness.mutate {
            $0.setLive(LiveSessionState(shellPid: 1, status: .idle), for: first)
            $0.select(first)
        }
        controller.toggleChangesViewer()
        #expect(controller.changes.isShown)
        harness.mutate { $0.select(second) }
        #expect(!controller.changes.isShown)
    }

    @Test func noSelectionOpensNothing() {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        harness.mutate { $0.select(nil) }
        harness.controller.toggleChangesViewer()
        #expect(!harness.controller.changes.isShown)
    }
}
