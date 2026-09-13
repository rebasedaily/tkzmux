// TranscriptUsageReader — token usage and spend per session.
//
// Claude Code hands cost to the statusline command's stdin (see `StatuslineCommand.swift`), but
// only a single cumulative USD number for the *live* process, never a token breakdown, and never
// for a session that is not currently running one. The same data at real resolution — per-turn,
// per-model — already lives in the transcript `TranscriptReader` reads: every `"type":"assistant"`
// line carries a `message.usage` object (`input_tokens`, `output_tokens`,
// `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens_details.thinking_tokens`).
//
// This sums that, incrementally: transcripts are append-only, so each session gets a small cache
// file under `~/Library/Application Support/tkzmux/usage/<sessionId>.json` recording a byte offset
// and running per-model *token* totals — never a cost, so a `ModelPricing` edit changes what old
// totals cost without needing to re-read anything. A missing or corrupt cache file just means the
// next `refresh` starts from offset 0 and re-derives it: the cache is a recomputable convenience,
// not a source of truth, the same relationship `state.json`'s persisted fields have to `AppState`'s
// process-only ones.
//
// An actor, not a `DispatchQueue`-backed class like `StatuslineReader`/`ClaudeSessionWatcher`: there
// is no file to watch here, only a read-modify-write triggered by hook frames, so the actor's
// serialized-access guarantee is all the concurrency safety this needs.

import Foundation
import TkzCore

public actor TranscriptUsageReader {
    private let cacheDirectory: String

    public init(cacheDirectory: String) {
        self.cacheDirectory = cacheDirectory
    }

    /// `~/Library/Application Support/tkzmux/usage`.
    public static func standardDirectory(supportDirectory: URL) -> String {
        supportDirectory.appendingPathComponent("usage").path
    }

    /// Per-model *token* totals only — `sessionUsage` prices them on the way out, so a
    /// `ModelPricing` change is retroactive without touching this file.
    private struct RawModelUsage: Codable, Sendable {
        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var thinkingTokens = 0
    }

    private struct Cache: Codable, Sendable {
        var byteOffset: Int = 0
        var perModel: [String: RawModelUsage] = [:]
        var lastUpdatedAt: Date = Date()

        /// `nil` when nothing has ever been parsed for this session — distinct from "parsed, spent
        /// nothing", which cannot happen (an assistant line always carries some usage).
        var sessionUsage: SessionUsage? {
            guard !perModel.isEmpty else { return nil }
            let models = perModel.map { modelId, raw in
                ModelUsage(
                    modelId: modelId,
                    inputTokens: raw.inputTokens,
                    outputTokens: raw.outputTokens,
                    cacheCreationTokens: raw.cacheCreationTokens,
                    cacheReadTokens: raw.cacheReadTokens,
                    thinkingTokens: raw.thinkingTokens,
                    costUSD: ModelPricing.cost(
                        modelId: modelId,
                        inputTokens: raw.inputTokens,
                        outputTokens: raw.outputTokens,
                        cacheCreationTokens: raw.cacheCreationTokens,
                        cacheReadTokens: raw.cacheReadTokens))
            }.sorted { $0.modelId < $1.modelId }
            // A total only means something when every model in it has a price; a partial sum would
            // read as "this is what the session cost" while silently missing a model's share.
            let allPriced = models.allSatisfy { $0.costUSD != nil }
            let total = allPriced ? models.reduce(0.0) { $0 + ($1.costUSD ?? 0) } : nil
            return SessionUsage(perModel: models, totalCostUSD: total, lastUpdatedAt: lastUpdatedAt)
        }
    }

    /// Parses whatever of `transcriptPath` has been appended since the last call for `sessionId`,
    /// folds it into the persisted per-model totals, and returns the session's usage so far.
    /// `nil` when nothing has ever been parsed for this session (no transcript, unreadable file, or
    /// a transcript that so far carries no assistant turn) — the caller must not render that as
    /// "$0 spent".
    @discardableResult
    public func refresh(sessionId: String, transcriptPath: String?) -> SessionUsage? {
        var cache = readCache(sessionId: sessionId) ?? Cache()
        guard let transcriptPath, !transcriptPath.isEmpty,
              let handle = FileHandle(forReadingAtPath: transcriptPath)
        else {
            return cache.sessionUsage
        }
        defer { try? handle.close() }

        let size = Int((try? handle.seekToEnd()) ?? 0)
        // A transcript is append-only in normal operation; a stored offset past the current size
        // means the file was replaced (not observed in practice, but cheap to guard), so start over
        // rather than seek past the end.
        let startOffset = cache.byteOffset <= size ? cache.byteOffset : 0
        guard size > startOffset else { return cache.sessionUsage }

        try? handle.seek(toOffset: UInt64(startOffset))
        let unread = (try? handle.readToEnd()) ?? Data()
        // Only fully-written lines are safe to parse; a transcript can be mid-write to its last
        // line, and consuming a partial one would both misparse it and never see the rest of it
        // once the offset moves past it.
        guard let lastNewline = unread.lastIndex(of: 0x0A) else { return cache.sessionUsage }
        let complete = unread[unread.startIndex...lastNewline]

        for line in TranscriptReader.lines(of: complete) {
            guard let object = TranscriptReader.decode(line),
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            // Sidechain (subagent) turns are real API spend against the same account and are
            // folded into the session total rather than dropped.
            let modelId = (message["model"] as? String) ?? "unknown"
            var raw = cache.perModel[modelId] ?? RawModelUsage()
            raw.inputTokens += Self.intValue(usage["input_tokens"])
            raw.outputTokens += Self.intValue(usage["output_tokens"])
            raw.cacheCreationTokens += Self.intValue(usage["cache_creation_input_tokens"])
            raw.cacheReadTokens += Self.intValue(usage["cache_read_input_tokens"])
            if let details = usage["output_tokens_details"] as? [String: Any] {
                raw.thinkingTokens += Self.intValue(details["thinking_tokens"])
            }
            cache.perModel[modelId] = raw
        }
        cache.byteOffset = startOffset + complete.count
        cache.lastUpdatedAt = Date()
        writeCache(sessionId: sessionId, cache: cache)
        return cache.sessionUsage
    }

    private static func intValue(_ any: Any?) -> Int {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let n = any as? Double { return Int(n) }
        return 0
    }

    // MARK: - Cache file

    private func cachePath(sessionId: String) -> String {
        (cacheDirectory as NSString).appendingPathComponent("\(sessionId).json")
    }

    private func readCache(sessionId: String) -> Cache? {
        guard let data = FileManager.default.contents(atPath: cachePath(sessionId: sessionId)) else {
            return nil
        }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    /// Write-to-temp + rename via `Data.write(options: .atomic)`, so a read can never catch a
    /// half-written cache — the same guarantee `tkzmux-hook`'s `writeFileAtomically` gives the
    /// statusline sidecars, minus the hand-rolled POSIX calls that target needs to stay
    /// Foundation-free.
    private func writeCache(sessionId: String, cache: Cache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(
            atPath: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: cachePath(sessionId: sessionId)), options: .atomic)
    }
}
