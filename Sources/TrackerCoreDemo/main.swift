import Foundation
import TrackerCore

// Assert-based check runner, stands in for `swift test` (no XCTest in the CLT
// toolchain). Fixtures are embedded string literals — no resource plumbing.

#if !DEBUG
#error("TrackerCoreDemo must run in debug; asserts are stripped in release builds.")
#endif

var checksRun = 0
@MainActor
func check(_ condition: Bool, _ label: String) {
    checksRun += 1
    precondition(condition, "FAILED: \(label)")
    print("  ok \(label)")
}

// MARK: - JSONLParser

print("JSONLParser")
let parserFixture = """
{"type":"user","timestamp":"2026-07-19T14:00:00.000Z","message":{"role":"user","content":"hi"}}
{"type":"assistant","timestamp":"2026-07-19T14:00:01.000Z","requestId":"req_1","message":{"id":"msg_a","model":"claude-opus-4-8","usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"type":"assistant","timestamp":"2026-07-19T14:00:05.000Z","requestId":"req_1","message":{"id":"msg_a","model":"claude-opus-4-8","usage":{"input_tokens":2,"output_tokens":602,"cache_creation_input_tokens":32177,"cache_read_input_tokens":20314,"cache_creation":{"ephemeral_1h_input_tokens":32177,"ephemeral_5m_input_tokens":0}}}}
{"type":"assistant","timestamp":"2026-07-19T15:30:00.000Z","message":{"id":"msg_b","model":"claude-sonnet-5-20260203","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":10,"cache_read_input_tokens":5}}}
this line is not json at all {"type":"assistant"
{"type":"assistant","timestamp":"2026-07-19T16:00:00.000Z","message":{"id":"msg_c","model":"claude-haiku-4-5","usage":null}}
{"type":"summary","summary":"irrelevant"}

"""
let parsed = JSONLParser().parse(data: Data(parserFixture.utf8), sessionPath: "/fake/session.jsonl")
check(parsed.events.count == 3, "parses 3 assistant events (placeholder + final + one more)")
check(parsed.skippedLines == 2, "counts 2 skipped lines (malformed json, null usage), got \(parsed.skippedLines)")

var dedupe: [String: UsageEvent] = [:]
for e in parsed.events { dedupe[e.dedupeKey] = e }
check(dedupe.count == 2, "dedupe by message id keeps 2 events")
let final = dedupe["msg_a"]!
check(final.inputTokens == 2 && final.outputTokens == 602, "final record replaces placeholder")
check(final.cacheCreate1h == 32177 && final.cacheCreate5m == 0, "1h/5m cache split preserved")
let noSplit = dedupe["msg_b"]!
check(noSplit.cacheCreate5m == 10 && noSplit.cacheCreate1h == 0, "no cache_creation split → all cache writes 5m tier")

// MARK: - UsageAggregator day bucketing (UTC event vs local day)

print("UsageAggregator")
// 2026-07-19T15:30:00Z = 2026-07-20 00:30 in Asia/Tokyo → next local day.
var tokyoCal = Calendar(identifier: .gregorian)
tokyoCal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
var utcCal = Calendar(identifier: .gregorian)
utcCal.timeZone = TimeZone(identifier: "UTC")!

let events = Array(dedupe.values)
let tokyoDays = UsageAggregator(calendar: tokyoCal).byDayModel(events)
let utcDays = UsageAggregator(calendar: utcCal).byDayModel(events)
check(tokyoDays.count == 2, "Tokyo calendar splits the two events across midnight (19th/20th)")
check(utcDays.count == 1, "UTC calendar keeps both events on the 19th")

let df = ISO8601DateFormatter()
let noon19thUTC = df.date(from: "2026-07-19T12:00:00Z")!
let sums = UsageAggregator(calendar: utcCal).today(events, now: noon19thUTC)
check(sums["claude-opus-4-8"]!.output == 602, "today() sums the deduped final record")
check(sums["claude-sonnet-5-20260203"]!.input == 100, "today() includes second model")

let monthSums = UsageAggregator(calendar: utcCal).thisMonth(events, now: df.date(from: "2026-07-31T00:00:00Z")!)
check(monthSums["claude-opus-4-8"]!.total == 2 + 602 + 20314 + 32177, "thisMonth totals all token classes")

// MARK: - PricingCatalog + CostCalculator

print("PricingCatalog / CostCalculator")
let pricingFixture = """
{"claude-opus-4-8":{"input_cost_per_token":5e-06,"output_cost_per_token":2.5e-05,
 "cache_read_input_token_cost":5e-07,"cache_creation_input_token_cost":6.25e-06,
 "cache_creation_input_token_cost_above_1hr":1e-05},
 "claude-sonnet-5":{"input_cost_per_token":2e-06,"output_cost_per_token":1e-05,
 "cache_read_input_token_cost":2e-07,"cache_creation_input_token_cost":2.5e-06,
 "cache_creation_input_token_cost_above_1hr":4e-06},
 "claude-no-cache-rates":{"input_cost_per_token":1e-06,"output_cost_per_token":5e-06},
 "broken-entry":{"output_cost_per_token":1e-06}}
"""
let catalog = try PricingCatalog(litellmJSON: Data(pricingFixture.utf8))
check(catalog.models.count == 3, "tolerant decode skips broken entry")
check(catalog.pricing(for: "claude-sonnet-5-20260203") != nil, "prefix match resolves dated model id")
check(catalog.pricing(for: "claude-sonnet-5-20260203")!.output == Decimal(string: "1e-05")!,
      "prefix match picks claude-sonnet-5 rates")
check(catalog.pricing(for: "gpt-4o") == nil, "unknown model → nil")
let fallback = catalog.pricing(for: "claude-no-cache-rates")!
check(fallback.cacheWrite5m == Decimal(string: "1e-06")! * Decimal(1.25), "missing 5m rate → 1.25 × input")
check(fallback.cacheWrite1h == Decimal(string: "1e-06")! * 2, "missing 1h rate → 2 × input")

// Golden cost: the real sampled opus-4-8 event (all cache writes 1h-tier).
// 2×5e-6 + 602×2.5e-5 + 20314×5e-7 + 32177×1e-5 = 0.346987
var calc = CostCalculator(catalog: catalog)
var golden = TokenTotals()
golden.input = 2; golden.output = 602; golden.cacheRead = 20314; golden.cacheCreate1h = 32177
check(calc.cost(model: "claude-opus-4-8", totals: golden) == Decimal(string: "0.346987")!,
      "golden cost exact in Decimal (0.346987)")
check(calc.cost(model: "unknown-model-x", totals: golden) == 0, "unknown model costs 0")
check(calc.unpricedModels == ["unknown-model-x"], "unknown model surfaced in unpricedModels")
check(calc.cost(model: "<synthetic>", totals: golden) == 0 && !calc.unpricedModels.contains("<synthetic>"),
      "synthetic model costs 0 and is not flagged unpriced")

// MARK: - Bundled pricing snapshot

print("PricingService")
let bundled = try PricingService().loadBundled()
check(bundled.models["claude-opus-4-8"] != nil, "bundled DefaultPricing.json contains claude-opus-4-8")
check(bundled.models["claude-opus-4-8"]!.input == Decimal(string: "5e-06")!, "bundled opus input rate = $5/MTok")

// MARK: - Quota decode (fixture = sanitized live response captured 2026-07-20)

print("QuotaClient")
let quotaFixture = """
{"five_hour":{"utilization":29.0,"resets_at":"2026-07-20T09:49:59.995225+00:00","limit_dollars":null},
 "seven_day":{"utilization":4.0,"resets_at":"2026-07-26T19:59:59.995249+00:00"},
 "seven_day_opus":null,
 "extra_usage":{"is_enabled":false,"utilization":null},
 "limits":[
  {"kind":"session","group":"session","percent":29,"severity":"normal","resets_at":"2026-07-20T09:49:59.995225+00:00","scope":null,"is_active":true},
  {"kind":"weekly_all","group":"weekly","percent":4,"severity":"normal","resets_at":"2026-07-26T19:59:59.995249+00:00","scope":null,"is_active":false},
  {"kind":"weekly_scoped","group":"weekly","percent":4,"severity":"normal","resets_at":"2026-07-26T19:59:59.995488+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}],
 "spend":{"percent":0,"enabled":false}}
"""
let snapshot = QuotaClient.decode(Data(quotaFixture.utf8), fetchedAt: Date())!
check(snapshot.buckets.map(\.key) == ["session", "weekly_all", "weekly_scoped:Fable"],
      "limits array decoded: session, weekly_all, model-scoped weekly (spend has no kind → skipped)")
check(abs(snapshot.bucket("session")!.utilization - 0.29) < 1e-9, "percent normalized to 0…1")
check(snapshot.bucket("session")!.resetsAt != nil, "6-digit fractional-seconds resets_at parsed")
check(abs(snapshot.bucket("weekly_scoped:Fable")!.utilization - 0.04) < 1e-9, "scoped bucket keeps its percent")

// Fallback path: no limits array → top-level utilization objects.
let fallbackFixture = """
{"five_hour":{"utilization":23.5,"resets_at":"2026-07-20T12:00:00.000Z"},
 "seven_day":{"utilization":61.0,"resets_at":"2026-07-24T00:00:00Z"},
 "seven_day_opus":null,
 "extra_usage":{"utilization":null}}
"""
let fb = QuotaClient.decode(Data(fallbackFixture.utf8), fetchedAt: Date())!
check(fb.buckets.map(\.key) == ["five_hour", "seven_day"], "fallback decodes top-level buckets, skips nulls")
check(abs(fb.bucket("five_hour")!.utilization - 0.235) < 1e-9, "fallback percent normalized")
check(fb.bucket("seven_day")!.resetsAt != nil, "plain ISO8601 resets_at parsed")
check(QuotaClient.decode(Data("{}".utf8), fetchedAt: Date()) == nil, "empty response → nil, not a crash")
check(QuotaClient.decode(Data("not json".utf8), fetchedAt: Date()) == nil, "garbage response → nil")

// MARK: - RowBuilder

print("RowBuilder")
var rowCalc = CostCalculator(catalog: catalog)
var big = TokenTotals(); big.output = 1_000_000        // opus: $25
var small = TokenTotals(); small.output = 1_000        // sonnet-5: $0.01
var zero = TokenTotals()
var synth = TokenTotals(); synth.output = 5
let rows = RowBuilder.rows(byModel: [
    "claude-sonnet-5-20260203": small,
    "claude-opus-4-8": big,
    "<synthetic>": synth,
    "claude-haiku-4-5": zero,
], calculator: &rowCalc)
check(rows.map(\.model) == ["claude-opus-4-8", "claude-sonnet-5-20260203"],
      "rows sorted by cost desc; synthetic and zero-token rows dropped")
check(rows[0].cost == 25, "row cost computed via calculator")

var manyModels: [String: TokenTotals] = [:]
for i in 1...7 {
    var t = TokenTotals(); t.output = i * 1000
    manyModels["claude-opus-4-8-v\(i)"] = t   // prefix-priced via claude-opus-4-8
}
let capped = RowBuilder.rows(byModel: manyModels, calculator: &rowCalc, top: 5)
check(capped.count == 6 && capped[5].model == "other (2 models)",
      "beyond top 5 collapses into an 'other' row")
check(capped[5].cost == Decimal(1000 + 2000) * Decimal(string: "2.5e-05")!,
      "'other' row sums the collapsed costs")
check(RowBuilder.rows(byModel: [:], calculator: &rowCalc).isEmpty, "zero data → empty rows")
check(RowBuilder.displayName("claude-opus-4-8") == "opus-4-8", "display name strips claude- prefix")
check(RowBuilder.displayName("claude-sonnet-5-20260203") == "sonnet-5", "display name strips date suffix")
check(RowBuilder.displayName("gpt-4o") == "gpt-4o", "non-claude display name unchanged")

print("\nall \(checksRun) checks passed")
