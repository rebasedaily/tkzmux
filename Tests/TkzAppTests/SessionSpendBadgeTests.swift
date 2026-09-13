// SessionSpendBadgeTests — the sidebar badge for a session's estimated spend so far.
//
// Deliberately data-driven, like every other sidebar badge (the memory badge, `WT`, the account
// chip): none of them are behind a user preference, and this one follows suit rather than
// introducing the sidebar's first per-row visibility toggle.

import Foundation
import Testing
import TkzCore

@testable import TkzApp

@Suite("Session spend badge")
struct SessionSpendBadgeTests {

    private static func session(totalCostUSD: Double?) -> Session {
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
        return session
    }

    @Test("no usage yet means no badge")
    func noUsageHasNoBadge() {
        #expect(SidebarRowAdapter.spendBadge(for: Self.session(totalCostUSD: nil)) == nil)
        var bare = Self.session(totalCostUSD: nil)
        bare.live = nil
        #expect(SidebarRowAdapter.spendBadge(for: bare) == nil)
    }

    @Test("below one cent shows no badge, so a $0.00 pill never claims nothing was spent")
    func belowOneCentHasNoBadge() {
        #expect(SidebarRowAdapter.spendBadge(for: Self.session(totalCostUSD: 0.004)) == nil)
    }

    @Test("a real spend is formatted the same way the status bar formats it")
    func realSpendIsFormatted() {
        #expect(SidebarRowAdapter.spendBadge(for: Self.session(totalCostUSD: 1.23)) == "$1.23")
        // `.rounded()` is away-from-zero, so exactly half a cent clears the one-cent floor.
        #expect(SidebarRowAdapter.spendBadge(for: Self.session(totalCostUSD: 0.005)) == "$0.01")
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
