// ActivityIntegrationTests — what `ClaudeIntegration` does to a feed entry's read flag when the
// hook lands on the row the user is looking at.

import Foundation
import Testing
import ClaudeBridge
import TkzCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct ActivityIntegrationTests {
    typealias H = ClaudeIntegrationTests

    @Test("a Stop on the row the user is looking at lands read; elsewhere it stays unread")
    func stopReadWhenAttended() {
        let h = H.makeHarness()
        h.integration.handle(H.launch(h.session, pid: 4242))
        h.integration.isSessionAttended = { _ in true }
        let stop = HookEvent(kind: .stop, sessionID: h.session, lastAssistantMessage: "seen")
        h.integration.handle(HookFrame.hook(stop, ppid: 4242, fullMessage: "seen", cwd: nil, transcriptPath: nil))
        h.store.flush()
        #expect(h.store.state.activity.map(\.unread) == [false])

        h.integration.isSessionAttended = { _ in false }
        let later = HookEvent(kind: .stop, sessionID: h.session, lastAssistantMessage: "unseen")
        h.integration.handle(HookFrame.hook(later, ppid: 4242, fullMessage: "unseen", cwd: nil, transcriptPath: nil))
        h.store.flush()
        #expect(h.store.state.activity.map(\.unread) == [false, true])
    }

    @Test("a permission prompt on the attended row is read on arrival, without resetting attendance")
    func promptReadWhenAttended() {
        let h = H.makeHarness()
        h.integration.handle(H.launch(h.session, pid: 4242))
        h.integration.isSessionAttended = { _ in true }
        let attendedBefore = h.store.state.sessions[h.session]?.live?.attendedAt
        let prompt = HookEvent(kind: .notification, sessionID: h.session, notificationType: .permissionPrompt)
        h.integration.handle(HookFrame.hook(prompt, ppid: 4242, fullMessage: nil, cwd: nil, transcriptPath: nil))
        h.store.flush()
        #expect(h.store.state.activity.map(\.kind) == [.needsYou(reason: .permission, message: nil)])
        #expect(h.store.state.activity.map(\.unread) == [false])
        // Not `markAttended`: the prompt is still pending and the badge stays up.
        #expect(h.store.state.sessions[h.session]?.needsAttention == true)
        #expect(h.store.state.sessions[h.session]?.live?.attendedAt == attendedBefore)
    }
}
