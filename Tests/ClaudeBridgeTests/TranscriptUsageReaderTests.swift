// TranscriptUsageReaderTests — summing `message.usage` off a synthetic transcript, and the
// incremental-cursor rule that makes repeated calls cheap: bytes already parsed are never re-read,
// so an in-place edit to an already-consumed line must not change the answer, only newly appended
// lines may.

import Foundation
import Testing

@testable import ClaudeBridge

@Suite struct TranscriptUsageReaderTests {
    /// A minimal `"type":"assistant"` transcript line carrying exactly the fields the reader looks
    /// at.
    private func assistantLine(
        model: String, input: Int, output: Int = 0,
        cacheCreate: Int = 0, cacheRead: Int = 0, thinking: Int = 0, sidechain: Bool = false
    ) -> String {
        """
        {"type":"assistant","isSidechain":\(sidechain),"message":{"model":"\(model)",\
        "usage":{"input_tokens":\(input),"output_tokens":\(output),\
        "cache_creation_input_tokens":\(cacheCreate),"cache_read_input_tokens":\(cacheRead),\
        "output_tokens_details":{"thinking_tokens":\(thinking)}}}}
        """
    }

    private func tempTranscript() throws -> URL {
        let dir = try StatuslineTestSupport.tempDirectory("usage-reader")
        return dir.appendingPathComponent("session.jsonl")
    }

    @Test("Sums input/output/cache tokens across assistant lines, folding in a sidechain turn")
    func sumsAcrossAssistantLines() async throws {
        let lines = [
            assistantLine(model: "claude-sonnet-5", input: 10, output: 20, cacheCreate: 5, cacheRead: 100),
            #"{"type":"user","message":{"content":"hi"}}"#,  // ignored: not an assistant line
            assistantLine(model: "claude-sonnet-5", input: 4, output: 6, sidechain: true),  // subagent spend counts
        ]
        let path = try tempTranscript()
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: path)

        let reader = TranscriptUsageReader(cacheDirectory: try StatuslineTestSupport.tempDirectory("usage-cache").path)
        let usage = try #require(await reader.refresh(sessionId: "s1", transcriptPath: path.path))
        #expect(usage.perModel.count == 1)
        let model = try #require(usage.perModel.first)
        #expect(model.modelId == "claude-sonnet-5")
        #expect(model.inputTokens == 14)
        #expect(model.outputTokens == 26)
        #expect(model.cacheCreationTokens == 5)
        #expect(model.cacheReadTokens == 100)
    }

    @Test("A total only appears once every model used is priced; an unpriced model still shows tokens")
    func totalRequiresEveryModelPriced() async throws {
        let lines = [
            assistantLine(model: "claude-sonnet-5", input: 1_000_000, output: 1_000_000),
            assistantLine(model: "claude-not-a-real-model", input: 10, output: 10),
        ]
        let path = try tempTranscript()
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: path)

        let reader = TranscriptUsageReader(cacheDirectory: try StatuslineTestSupport.tempDirectory("usage-cache").path)
        let usage = try #require(await reader.refresh(sessionId: "s2", transcriptPath: path.path))
        #expect(usage.perModel.count == 2)
        #expect(usage.totalCostUSD == nil)
        let priced = usage.perModel.first { $0.modelId == "claude-sonnet-5" }
        let unpriced = usage.perModel.first { $0.modelId == "claude-not-a-real-model" }
        #expect(priced?.costUSD != nil)
        #expect(unpriced?.costUSD == nil)
    }

    @Test("Bytes already parsed are never re-read: an in-place edit is invisible, only appended lines count")
    func incrementalReparseSkipsConsumedBytes() async throws {
        let path = try tempTranscript()
        let first = assistantLine(model: "claude-sonnet-5", input: 100)
        try Data((first + "\n").utf8).write(to: path)

        let cacheDir = try StatuslineTestSupport.tempDirectory("usage-cache")
        let reader = TranscriptUsageReader(cacheDirectory: cacheDir.path)
        let afterFirst = try #require(await reader.refresh(sessionId: "s3", transcriptPath: path.path))
        #expect(afterFirst.perModel.first?.inputTokens == 100)

        // Overwrite the already-consumed line's input_tokens in place — same byte length (both
        // 3-digit), so the file size (and therefore the stored cursor) does not move.
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        let editedFirst = assistantLine(model: "claude-sonnet-5", input: 999)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(editedFirst.utf8))

        let afterEdit = try #require(await reader.refresh(sessionId: "s3", transcriptPath: path.path))
        #expect(afterEdit.perModel.first?.inputTokens == 100, "an edit inside already-parsed bytes must not change the total")

        // Now append a genuinely new line — this is the only thing that should move the total.
        try handle.seekToEnd()
        let second = assistantLine(model: "claude-sonnet-5", input: 50)
        try handle.write(contentsOf: Data(("\n" + second + "\n").utf8))

        let afterAppend = try #require(await reader.refresh(sessionId: "s3", transcriptPath: path.path))
        #expect(afterAppend.perModel.first?.inputTokens == 150)
    }

    @Test("No transcript and no prior cache means no data, not a zeroed usage")
    func noDataYetIsNilNotZero() async throws {
        let reader = TranscriptUsageReader(cacheDirectory: try StatuslineTestSupport.tempDirectory("usage-cache").path)
        let usage = await reader.refresh(sessionId: "never-seen", transcriptPath: nil)
        #expect(usage == nil)
    }

    @Test("A partial trailing line (mid-write) is not parsed until it is completed by a later call")
    func partialTrailingLineIsDeferred() async throws {
        let path = try tempTranscript()
        let partial = String(assistantLine(model: "claude-sonnet-5", input: 100).dropLast(10))
        try Data(partial.utf8).write(to: path)  // no trailing newline: this line is still "being written"

        let cacheDir = try StatuslineTestSupport.tempDirectory("usage-cache")
        let reader = TranscriptUsageReader(cacheDirectory: cacheDir.path)
        let whilePartial = await reader.refresh(sessionId: "s4", transcriptPath: path.path)
        #expect(whilePartial == nil)

        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(assistantLine(model: "claude-sonnet-5", input: 100).suffix(10).utf8))
        try handle.write(contentsOf: Data("\n".utf8))

        let complete = try #require(await reader.refresh(sessionId: "s4", transcriptPath: path.path))
        #expect(complete.perModel.first?.inputTokens == 100)
    }
}
