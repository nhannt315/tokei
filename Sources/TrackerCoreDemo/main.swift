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

// MARK: - KeychainCredentialReader (pure exit-code / parse logic; no live Keychain)

print("KeychainCredentialReader")
// The stored blob is JSON; extract claudeAiOauth.accessToken.
check(KeychainCredentialReader.parseToken(
        from: Data(#"{"claudeAiOauth":{"accessToken":"abc"}}"#.utf8)) == "abc",
      "parses accessToken from the stored JSON blob")
check(KeychainCredentialReader.parseToken(
        from: Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)) == nil,
      "empty accessToken → nil (treated as not signed in)")
check(KeychainCredentialReader.parseToken(from: Data(#"{"other":1}"#.utf8)) == nil,
      "wrong shape → nil")
check(KeychainCredentialReader.parseToken(from: Data("not json".utf8)) == nil,
      "garbage blob → nil, not a crash")

// `security` exits with the low byte of the OSStatus (verified against the live
// tool): errSecItemNotFound -25300 & 0xFF = 44, errSecAuthFailed = 51,
// errSecUserCanceled = 128.
func isNotFound(_ r: KeychainCredentialReader.ReadResult) -> Bool {
    if case .notFound = r { return true }; return false
}
func isDenied(_ r: KeychainCredentialReader.ReadResult) -> Bool {
    if case .denied = r { return true }; return false
}
func failureStatus(_ r: KeychainCredentialReader.ReadResult) -> OSStatus? {
    if case .failure(let s) = r { return s }; return nil
}
check(isNotFound(KeychainCredentialReader.classify(exitCode: 44)), "exit 44 → notFound")
check(isDenied(KeychainCredentialReader.classify(exitCode: 51)), "exit 51 (auth failed) → denied")
check(isDenied(KeychainCredentialReader.classify(exitCode: 128)), "exit 128 (user cancel) → denied")
check(failureStatus(KeychainCredentialReader.classify(exitCode: 2)) == 2,
      "other non-zero exit → failure carrying that code")

// MARK: - UpdateChecker

print("UpdateChecker")
check(UpdateChecker.normalize("v0.1.2") == "0.1.2", "leading v stripped")
check(UpdateChecker.normalize("0.1.2-3-gabc123") == "0.1.2", "git describe suffix stripped")
check(UpdateChecker.isNewer("v0.1.3", than: "0.1.2"), "patch bump is newer")
check(UpdateChecker.isNewer("0.1.10", than: "0.1.9"), "0.1.10 > 0.1.9 (numeric, not string, compare)")
check(!UpdateChecker.isNewer("0.1.2", than: "0.1.2"), "same version is not newer")
check(!UpdateChecker.isNewer("0.1.2", than: "0.2.0"), "older release is not newer")
check(!UpdateChecker.isNewer("0.1.2", than: "0.1.2-5-gdeadbee"), "dev build of same tag: no update offered")
check(UpdateChecker.isNewer("1.0", than: "0.9.9"), "shorter version compares by component")
check(!UpdateChecker.isNewer("1.2", than: "1.2.0"), "missing components count as zero")
check(!UpdateChecker.isNewer("garbage", than: "0.1.2"), "unparseable tag never offers an update")

let releaseFixture = """
{"tag_name":"v0.2.0","draft":false,"prerelease":false,
 "html_url":"https://github.com/nhannt315/tokei/releases/tag/v0.2.0",
 "assets":[{"name":"Tokei-v0.2.0.dmg","browser_download_url":"https://example.com/a.dmg"},
           {"name":"Tokei-v0.2.0.zip","browser_download_url":"https://example.com/a.zip"}]}
"""
let release = UpdateChecker.decode(Data(releaseFixture.utf8))!
check(release.version == "0.2.0", "release tag normalized")
check(release.downloadURL.absoluteString == "https://example.com/a.zip", "picks the zip asset, not the dmg")

let prereleaseFixture = """
{"tag_name":"v0.3.0","prerelease":true,
 "assets":[{"name":"Tokei.zip","browser_download_url":"https://example.com/b.zip"}]}
"""
check(UpdateChecker.decode(Data(prereleaseFixture.utf8)) == nil, "prereleases ignored")
let dmgOnlyFixture = """
{"tag_name":"v0.2.0","assets":[{"name":"Tokei.dmg","browser_download_url":"https://example.com/a.dmg"}]}
"""
check(UpdateChecker.decode(Data(dmgOnlyFixture.utf8)) == nil, "no zip asset → no update")
check(UpdateChecker.decode(Data("{}".utf8)) == nil, "empty payload → nil, not a crash")
check(UpdateChecker.decode(Data("not json".utf8)) == nil, "garbage payload → nil")

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

// MARK: - End-to-end pipeline (temp dir → scan → aggregate → dollars)

print("End-to-end pipeline")
var e2eCal = Calendar(identifier: .gregorian)
e2eCal.timeZone = TimeZone(identifier: "UTC")!
let fakeNow = ISO8601DateFormatter().date(from: "2026-07-19T18:00:00Z")!

let tmpDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("tokei-e2e-\(ProcessInfo.processInfo.processIdentifier)")
let sessionDir = tmpDir.appendingPathComponent("project-a")
try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmpDir) }
let sessionFile = sessionDir.appendingPathComponent("session.jsonl")
try Data(parserFixture.utf8).write(to: sessionFile)

let e2eStore = UsageStore(projectsDir: tmpDir)
let e2eAgg = UsageAggregator(calendar: e2eCal)
@MainActor
func e2eRows() -> [ModelCostRow] {
    e2eStore.scan()
    var c = CostCalculator(catalog: catalog)
    return RowBuilder.rows(byModel: e2eAgg.today(e2eStore.events, now: fakeNow), calculator: &c)
}

// Goldens from the parser fixture through the pricing fixture:
//   opus msg_a final:  2×5e-6 + 602×2.5e-5 + 20314×5e-7 + 32177×1e-5 = 0.346987
//   sonnet msg_b:      100×2e-6 + 50×1e-5 + 5×2e-7 + 10×2.5e-6       = 0.000726
let firstScan = e2eRows()
check(firstScan.count == 2, "e2e scan yields 2 priced model rows")
check(firstScan[0].model == "claude-opus-4-8" && firstScan[0].cost == Decimal(string: "0.346987")!,
      "e2e opus golden dollars (dedupe kept final record)")
check(firstScan[1].cost == Decimal(string: "0.000726")!, "e2e sonnet golden dollars")

// Append a new event → incremental rescan picks up only the delta.
let appended = """
{"type":"assistant","timestamp":"2026-07-19T17:00:00.000Z","message":{"id":"msg_d","model":"claude-opus-4-8","usage":{"input_tokens":0,"output_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

"""
let handle = try FileHandle(forWritingTo: sessionFile)
try handle.seekToEnd()
try handle.write(contentsOf: Data(appended.utf8))
try handle.close()

let secondScan = e2eRows()
check(secondScan[0].cost == Decimal(string: "0.346987")! + Decimal(1000) * Decimal(string: "2.5e-05")!,
      "e2e appended line adds exactly 1000 output tokens of opus cost")

// MARK: - DirectoryWatcher (burst of writes → one debounced callback)

print("DirectoryWatcher")
let watchDir = tmpDir.appendingPathComponent("watched")
try FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
let counter = DispatchQueue(label: "e2e.counter")
nonisolated(unsafe) var fires = 0
let fired = DispatchSemaphore(value: 0)
let watcher = DirectoryWatcher(directory: watchDir, debounce: 0.5) {
    counter.sync { fires += 1 }
    fired.signal()
}
for i in 0..<3 {
    try Data("x".utf8).write(to: watchDir.appendingPathComponent("f\(i).jsonl"))
}
check(fired.wait(timeout: .now() + 10) == .success, "watcher fires within 10s of a write burst")
Thread.sleep(forTimeInterval: 1.5)   // any un-debounced extra callbacks would land here
check(counter.sync { fires } == 1, "burst of 3 writes debounced into exactly 1 callback")
_ = watcher

// MARK: - New aggregators (project / weekly / session window)

print("UsageAggregator extensions")

// Project slug decode.
check(UsageAggregator.projectSlug(from: "/x/.claude/projects/-Users-nhannt-code-tokei/s.jsonl")
        == "/Users/nhannt/code/tokei" || UsageAggregator.projectSlug(from: "/x/.claude/projects/-Users-nhannt-code-tokei/s.jsonl").hasSuffix("code/tokei"),
      "projectSlug decodes dash-encoded absolute path")
check(UsageAggregator.projectSlug(from: "/some/other/path.jsonl") == "unknown",
      "projectSlug returns 'unknown' when no project segment")

// Deterministic calendar/clock: UTC, week starts Monday.
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "UTC")!
cal.firstWeekday = 2
let agg = UsageAggregator(calendar: cal)
func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
func ev(_ model: String, _ ts: String, out: Int, path: String) -> UsageEvent {
    UsageEvent(dedupeKey: ts + path, model: model, timestamp: iso(ts),
               inputTokens: 0, outputTokens: out, cacheReadTokens: 0,
               cacheCreate5m: 0, cacheCreate1h: 0, sessionPath: path)
}
let now = iso("2026-08-13T12:00:00Z")   // a Thursday
let pA = "/h/.claude/projects/-proj-a/s.jsonl"
let pB = "/h/.claude/projects/-proj-b/s.jsonl"
let sample = [
    ev("claude-sonnet-5", "2026-08-13T09:00:00Z", out: 300, path: pA),  // today, proj-a
    ev("claude-sonnet-5", "2026-08-13T10:00:00Z", out: 200, path: pB),  // today, proj-b
    ev("claude-sonnet-5", "2026-08-11T10:00:00Z", out: 100, path: pA),  // Tue this week
    ev("claude-sonnet-5", "2026-08-04T10:00:00Z", out: 700, path: pA),  // last week
]

// byProject over today only.
let dayStart = cal.startOfDay(for: now)
let byProj = agg.byProject(sample, since: dayStart, now: now)
check(byProj.count == 2, "byProject splits today's two projects")
check(byProj["/proj/a"]?["claude-sonnet-5"]?.total == 300, "byProject sums proj-a today = 300")

// lastDays: current week has activity Tue(11) + Thu(13).
let days = agg.lastDays(sample, count: 4, now: now)   // Mon..Thu
check(days.count == 4, "lastDays returns requested count incl. empty days")
check(days.last?.totals.total == 500, "lastDays: Thursday total = 300+200")
check(days[1].totals.total == 100, "lastDays: Tuesday total = 100")
check(days[0].totals.total == 0 && days[2].totals.total == 0, "lastDays fills empty days with zero")

// lastWeeks: this week = 600 (300+200+100), previous = 700.
let weeks = agg.lastWeeks(sample, count: 2, now: now)
check(weeks.count == 2, "lastWeeks returns 2 weeks")
check(weeks.last?.totals.total == 600, "lastWeeks: current week = 600")
check(weeks.first?.totals.total == 700, "lastWeeks: previous week = 700")

// Session window: only events within the last 5h before now.
let windowStart = now.addingTimeInterval(-5 * 3600)   // 07:00Z
check(agg.sinceWindow(sample, windowStart: windowStart, now: now).total == 500,
      "sinceWindow counts only in-window tokens (09:00 + 10:00) = 500")

// projectedLimit: 50% used halfway through window → limit at window end.
let ws = iso("2026-08-13T10:00:00Z")
let midNow = iso("2026-08-13T11:00:00Z")   // 1h elapsed of a 2h-equivalent projection
let bucket = QuotaBucket(key: "five_hour", utilization: 0.5, resetsAt: nil)
if let projected = bucket.projectedLimit(windowStart: ws, now: midNow) {
    check(abs(projected.timeIntervalSince(iso("2026-08-13T12:00:00Z"))) < 1,
          "projectedLimit: 50% in 1h → 100% at 2h")
} else {
    check(false, "projectedLimit should be non-nil at 50%")
}
check(QuotaBucket(key: "x", utilization: 0, resetsAt: nil).projectedLimit(windowStart: ws, now: midNow) == nil,
      "projectedLimit nil when idle")

// MARK: - AlertLatch

print("AlertLatch")
// Quota: fires below threshold when not latched; not while latched; off at 0.
check(AlertLatch.shouldFireQuota(remainingPct: 15, thresholdPct: 20, alreadyFired: false),
      "quota fires below threshold when not latched")
check(!AlertLatch.shouldFireQuota(remainingPct: 15, thresholdPct: 20, alreadyFired: true),
      "quota does not refire while latched")
check(!AlertLatch.shouldFireQuota(remainingPct: 25, thresholdPct: 20, alreadyFired: false),
      "quota does not fire above threshold")
check(!AlertLatch.shouldFireQuota(remainingPct: 5, thresholdPct: 0, alreadyFired: false),
      "quota disabled at threshold 0")
// Reset clears the latch → can fire again (simulated by alreadyFired flipping to false).
check(AlertLatch.shouldFireQuota(remainingPct: 15, thresholdPct: 20, alreadyFired: false),
      "quota re-arms after reset clears the latch")
// Cost: fires at/above threshold when not latched; not while latched; off at 0.
check(AlertLatch.shouldFireCost(todayDollars: 10, thresholdDollars: 10, alreadyFired: false),
      "cost fires at threshold when not latched")
check(!AlertLatch.shouldFireCost(todayDollars: 12, thresholdDollars: 10, alreadyFired: true),
      "cost does not refire while latched")
check(!AlertLatch.shouldFireCost(todayDollars: 3, thresholdDollars: 10, alreadyFired: false),
      "cost does not fire below threshold")
check(!AlertLatch.shouldFireCost(todayDollars: 99, thresholdDollars: 0, alreadyFired: false),
      "cost disabled at threshold 0")

print("\nall \(checksRun) checks passed")
