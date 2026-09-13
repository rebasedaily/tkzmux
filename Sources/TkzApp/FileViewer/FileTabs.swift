// Read-only file tabs: a path ⌘-clicked in a pane opens here, next to the session's terminal tabs.
//
// Deliberately *not* part of `Session.tabs`. A terminal tab is durable layout that owns ptys and
// `.ghsnap` files, and every reducer in `PaneReducers` assumes a tab is a pane tree. A file tab
// owns nothing but a URL, so it lives beside the store as window state, is never persisted, and
// the strip simply lists it after the terminal tabs.

import Foundation
import TkzCore

/// One session's open files and which of them, if any, is on screen.
struct FileTabs: Hashable {
    private(set) var files: [URL] = []
    /// The file tab on screen, or nil when the session's active terminal tab is.
    private(set) var activeIndex: Int?

    var isEmpty: Bool { files.isEmpty }

    var activeFile: URL? { activeIndex.flatMap { files[safe: $0] } }

    /// Opens `url`, or brings its existing tab forward — ⌘-clicking the same path twice must not
    /// grow the strip.
    mutating func open(_ url: URL) {
        let url = url.standardizedFileURL
        if let index = files.firstIndex(of: url) {
            activeIndex = index
        } else {
            files.append(url)
            activeIndex = files.count - 1
        }
    }

    mutating func select(_ index: Int) {
        guard files.indices.contains(index) else { return }
        activeIndex = index
    }

    /// A terminal tab was chosen.
    mutating func deselect() { activeIndex = nil }

    /// Closes a tab. Closing the one on screen shows its neighbour, the way a browser does; closing
    /// the last file goes back to the terminal.
    mutating func close(_ index: Int) {
        guard files.indices.contains(index) else { return }
        files.remove(at: index)
        guard let active = activeIndex else { return }
        if active == index {
            activeIndex = files.isEmpty ? nil : min(index, files.count - 1)
        } else if active > index {
            activeIndex = active - 1
        }
    }
}

/// What a click on the strip at some index means.
enum TabStripTarget: Equatable {
    case terminal(Int)
    case file(Int)

    static func at(_ index: Int, terminalTabCount: Int) -> TabStripTarget {
        index < terminalTabCount ? .terminal(index) : .file(index - terminalTabCount)
    }
}

extension FileTabs {
    /// The strip for `session`: its terminal tabs, then its file tabs. A terminal tab reads as
    /// selected only while no file is on screen.
    func stripModel(for session: Session) -> TabStripModel {
        let terminals = session.tabs.enumerated().map { index, tab in
            TabStripItem(
                // A tab has no name of its own: the row's title belongs to the row, and a
                // shell's title is not a rename (the same rule `Session.displayTitle` follows).
                // Numbering is honest and stable; a real name is a later ticket's business.
                title: "Terminal \(index + 1)",
                isSelected: activeIndex == nil && tab.id == session.activeTab,
                terminalCount: tab.terminalCount)
        }
        let files = files.enumerated().map { index, url in
            TabStripItem(title: url.lastPathComponent, isSelected: index == activeIndex)
        }
        return TabStripModel(items: terminals + files)
    }
}
