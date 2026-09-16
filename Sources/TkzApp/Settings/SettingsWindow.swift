// SettingsWindow.swift — the ⌘, window's own key handling.
//
// ⌘W belongs to `closeTerminal` in the main menu, and AppKit offers a key-down to the key window's
// `performKeyEquivalent` before it offers it to the menu bar — so this window takes ⌘W and Esc
// there and closes, and the pane behind it is never asked. `keyDown` and `cancelOperation` catch
// the same two keys on the paths that skip `performKeyEquivalent` (a text-editing first responder
// forwards Esc as `cancelOperation:`), so one `close()` serves every way out.

import AppKit

final class SettingsWindow: NSWindow {

    /// Every close, whichever key or button asked for it. `windowWillClose` is not delivered for a
    /// window that was never on screen (a headless test), so the controller's `isShown` hangs off
    /// this rather than the delegate.
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func close() {
        onClose?()
        super.close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.closes(event) {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if Self.closes(event) {
            close()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { close() }

    /// ⌘W, or a bare Escape. Caps Lock is a lock, not a chord (the rule `handleCommandKey` uses).
    static func closes(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" { return true }
        if flags.isEmpty, event.keyCode == 53 { return true }
        return false
    }
}
