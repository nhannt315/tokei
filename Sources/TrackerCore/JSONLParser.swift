import Foundation

/// Decodes Claude Code transcript lines into `UsageEvent`s.
/// Tolerant by design: lines that aren't assistant messages, lack usage, or
/// fail to decode are skipped (and counted), never fatal.
public struct JSONLParser {
    // Only the fields we need; everything else in the line is ignored.
    private struct RawLine: Decodable {
        let type: String?
        let timestamp: String?
        let requestId: String?
        let uuid: String?
        let message: RawMessage?

        struct RawMessage: Decodable {
            let id: String?
            let model: String?
            let usage: RawUsage?
        }

        struct RawUsage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreation: CacheCreation?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreation = "cache_creation"
            }

            struct CacheCreation: Decodable {
                let ephemeral1h: Int?
                let ephemeral5m: Int?
                enum CodingKeys: String, CodingKey {
                    case ephemeral1h = "ephemeral_1h_input_tokens"
                    case ephemeral5m = "ephemeral_5m_input_tokens"
                }
            }
        }
    }

    private let decoder = JSONDecoder()
    private let isoFractional: ISO8601DateFormatter
    private let isoPlain: ISO8601DateFormatter

    public init() {
        isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
    }

    public struct Result {
        public var events: [UsageEvent] = []
        public var skippedLines = 0     // lines that looked relevant but failed to decode
    }

    /// Parse a chunk of JSONL data (complete lines only) from one session file.
    public func parse(data: Data, sessionPath: String) -> Result {
        var result = Result()
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            defer { start = end < data.endIndex ? data.index(after: end) : data.endIndex }
            let line = data[start..<end]
            if line.isEmpty { continue }
            // Cheap prefilter: skip user/tool/summary lines without JSON decoding.
            guard line.range(of: Data(#""type":"assistant""#.utf8)) != nil else { continue }
            guard let raw = try? decoder.decode(RawLine.self, from: line),
                  raw.type == "assistant" else {
                result.skippedLines += 1
                continue
            }
            guard let usage = raw.message?.usage, let model = raw.message?.model,
                  let ts = raw.timestamp, let date = parseDate(ts) else {
                result.skippedLines += 1
                continue
            }
            let totalCreate = usage.cacheCreationInputTokens ?? 0
            let create1h = usage.cacheCreation?.ephemeral1h
            let create5m = usage.cacheCreation?.ephemeral5m
            result.events.append(UsageEvent(
                dedupeKey: raw.message?.id ?? raw.requestId ?? raw.uuid ?? UUID().uuidString,
                model: model,
                timestamp: date,
                inputTokens: usage.inputTokens ?? 0,
                outputTokens: usage.outputTokens ?? 0,
                cacheReadTokens: usage.cacheReadInputTokens ?? 0,
                // No 1h/5m split (older format) → treat all cache writes as 5m tier.
                cacheCreate5m: create5m ?? (create1h == nil ? totalCreate : 0),
                cacheCreate1h: create1h ?? 0,
                sessionPath: sessionPath
            ))
        }
        return result
    }

    private func parseDate(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}
