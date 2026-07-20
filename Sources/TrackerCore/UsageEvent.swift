import Foundation

/// One deduped assistant message from a Claude Code JSONL transcript.
public struct UsageEvent: Sendable {
    public let dedupeKey: String      // message.id, else requestId, else line uuid
    public let model: String
    public let timestamp: Date
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreate5m: Int
    public let cacheCreate1h: Int
    public let sessionPath: String    // source jsonl file → session/project attribution

    public init(dedupeKey: String, model: String, timestamp: Date,
                inputTokens: Int, outputTokens: Int, cacheReadTokens: Int,
                cacheCreate5m: Int, cacheCreate1h: Int, sessionPath: String) {
        self.dedupeKey = dedupeKey
        self.model = model
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreate5m = cacheCreate5m
        self.cacheCreate1h = cacheCreate1h
        self.sessionPath = sessionPath
    }
}
