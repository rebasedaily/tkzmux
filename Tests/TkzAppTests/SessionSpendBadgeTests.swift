// SessionSpendBadgeTests — the sidebar badge for a session's estimated spend so far.
//
// Unlike the other sidebar badges (the memory badge, `WT`, the account chip), this one is gated by
// a user preference on two levels (design: enable/disable, all sessions and per session):
// `AppState.showSessionSpend` (global) and `Session.spendTrackingDisabled` (this one session's own
// opt-out). Both default to "tracked" and either one hides the badge.

import Foundation
import Testing
import TkzCore

@testable import TkzApp

@Suite("Session spend badge")
struct SessionSpendBadgeTests {

    private static func session(totalCostUSD: Double?, spendTrackingDisabled: Bool? = nil) -> Session {
        var state = AppState()
        let group = state.addGroup(name: "G", repoRoot: "/tmp")
        var session = state.createSession(groupID: group.id, cwd: "/tmp")
        var live = LiveSessionState()
        if let totalCostUSD {
            live.usage = SessionUsage(
                perModel: [ModelUsage(modelId: "claude-sonnet-5", costUSD: totalCostUSD)],
                totalCostUSD: totalCostUSD,
                lastUpdatedAt: Date())
        }
        session.live = live
        session.spendTrackingDisabled = spendTrackingDisabled
        return session
    }

    @Test("no usage yet means no badge")
    func noUsageHasNoBadge() {
        #expect(SidebarRowAdapter.spendBadge(for: Self.session(totalCostUSD: nil), in: AppState()) == nil)
        var bare = Self.session(totalCostUSD: nil)
        bare.live = nil
        #expect(SidebarRowAdapter.spendBadge(for: bare, in: AppState()) == nil)
    }

    @Test("below one cent shows no badge, so a $0.00 pill never claims nothing was spent")
    func belowOneCentHasNoBadge() {
        #expect(SidebarRowAdapter.spendBadge(for: Self.session(totalCostUSD: 0.004), in: AppState()) == nil)
    }

    @Test("a real spend is formatted the same way the status bar formats it")
    func realSpendIsFormatted() {
        #expect(SidebarRowAdapter.spendBadge(for: Self.session(totalCostUSD: 1.23), in: AppState()) == "$1.23")
        // `.rounded()` is away-from-zero, so exactly half a cent clears the one-cent floor.
        #expect(SidebarRowAdapter.spendBadge(for: Self.session(totalCostUSD: 0.005), in: AppState()) == "$0.01")
    }

    @Test("the global switch off hides a real spend")
    func globalSwitchOffHidesBadge() {
        var state = AppState()
        state.showSessionSpend = false
        #expect(SidebarRowAdapter.spendBadge(for: Self.session(totalCostUSD: 1.23), in: state) == nil)
    }

    @Test("a session's own opt-out hides it even while the global switch is on")
    func perSessionOptOutHidesBadge() {
        let session = Self.session(totalCostUSD: 1.23, spendTrackingDisabled: true)
        #expect(SidebarRowAdapter.spendBadge(for: session, in: AppState()) == nil)
    }

    @Test("the badge reaches the row model")
    func badgeReachesRowModel() {
        var state = AppState()
        let group = state.addGroup(name: "G", repoRoot: "/tmp")
        var session = state.createSession(groupID: group.id, cwd: "/tmp")
        var live = LiveSessionState()
        live.usage = SessionUsage(
            perModel: [ModelUsage(modelId: "claude-sonnet-5", costUSD: 4.2)],
            totalCostUSD: 4.2,
            lastUpdatedAt: Date())
        session.live = live
        state.sessions[session.id] = session

        let model = SidebarRowAdapter.sessionModel(session, in: state)
        #expect(model.spendBadge == "$4.20")
    }
}
