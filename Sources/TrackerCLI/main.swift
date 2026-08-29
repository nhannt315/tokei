import Foundation
import TrackerCore

// CLI over the same TrackerCore functions the menu bar app uses.
// Subcommands: today | month | daily [n] | quota [--raw] | scan

func fmtTokens(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

func fmtCost(_ d: Decimal) -> String {
    "$" + String(format: "%.4f", NSDecimalNumber(decimal: d).doubleValue)
}

func lpad(_ s: String, _ w: Int) -> String { String(repeating: " ", count: max(0, w - s.count)) + s }
func rpad(_ s: String, _ w: Int) -> String { s + String(repeating: " ", count: max(0, w - s.count)) }

func row(_ model: String, _ c1: String, _ c2: String, _ c3: String, _ c4: String, _ c5: String) -> String {
    rpad(model, 34) + lpad(c1, 12) + lpad(c2, 12) + lpad(c3, 14) + lpad(c4, 14) + lpad(c5, 11)
}

func loadCalculator() -> CostCalculator {
    let service = PricingService()
    let catalog = (try? service.load()) ?? PricingCatalog(models: [:])
    if catalog.models.isEmpty {
        FileHandle.standardError.write(Data("warning: pricing catalog empty — costs will be $0\n".utf8))
    }
    return CostCalculator(catalog: catalog)
}

func printModelTable(_ byModel: [String: TokenTotals], calc: inout CostCalculator) {
    print(row("MODEL", "INPUT", "OUTPUT", "CACHE RD", "CACHE WR", "COST"))
    var totalCost: Decimal = 0
    var sum = TokenTotals()
    for (model, t) in byModel.sorted(by: { $0.key < $1.key }) {
        let cost = calc.cost(model: model, totals: t)
        totalCost += cost
        sum.input += t.input; sum.output += t.output; sum.cacheRead += t.cacheRead
        sum.cacheCreate5m += t.cacheCreate5m; sum.cacheCreate1h += t.cacheCreate1h
        print(row(model, fmtTokens(t.input), fmtTokens(t.output), fmtTokens(t.cacheRead),
                  fmtTokens(t.cacheCreate5m + t.cacheCreate1h), fmtCost(cost)))
    }
    print(row("TOTAL", fmtTokens(sum.input), fmtTokens(sum.output), fmtTokens(sum.cacheRead),
              fmtTokens(sum.cacheCreate5m + sum.cacheCreate1h), fmtCost(totalCost)))
    if !calc.unpricedModels.isEmpty {
        print("unpriced models (cost $0): \(calc.unpricedModels.sorted().joined(separator: ", "))")
    }
}

func scannedEvents() -> [UsageEvent] {
    let store = UsageStore()
    store.scan()
    return store.events
}

// MARK: - JSON output (--json)

// Lossless Decimal → string; do NOT bridge through Double.
func decimalString(_ d: Decimal) -> String { NSDecimalNumber(decimal: d).description }

struct ModelJSON: Encodable {
    let model: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheCreate5m: Int
    let cacheCreate1h: Int
    let tokens: Int
    let cost: String
}

struct ScopeJSON: Encodable {
    let scope: String
    let date: String
    let models: [ModelJSON]
    let totalCost: String
    let unpricedModels: [String]
}

struct QuotaBucketJSON: Encodable {
    let key: String
    let utilizationPct: Double
    let resetsAt: String?
}

func emitJSON<T: Encodable>(_ v: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(v), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

// Build a JSON scope document from raw byModel totals. Drops synthetic models,
// matching the table path.
func scopeJSON(_ scope: String, date: String, byModel: [String: TokenTotals],
               calc: inout CostCalculator) -> ScopeJSON {
    var models: [ModelJSON] = []
    var total: Decimal = 0
    for (model, t) in byModel.sorted(by: { $0.key < $1.key }) where !CostCalculator.isSynthetic(model) {
        let cost = calc.cost(model: model, totals: t)
        total += cost
        models.append(ModelJSON(
            model: model, input: t.input, output: t.output, cacheRead: t.cacheRead,
            cacheCreate5m: t.cacheCreate5m, cacheCreate1h: t.cacheCreate1h,
            tokens: t.total, cost: decimalString(cost)))
    }
    return ScopeJSON(scope: scope, date: date, models: models,
                     totalCost: decimalString(total),
                     unpricedModels: calc.unpricedModels.sorted())
}

let isoDay: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    return df
}()

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "today"
let json = args.contains("--json")

switch command {
case "today":
    var calc = loadCalculator()
    let byModel = UsageAggregator().today(scannedEvents())
    if json {
        emitJSON(scopeJSON("today", date: isoDay.string(from: Date()), byModel: byModel, calc: &calc))
    } else {
        print("Today (\(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)), local time)")
        printModelTable(byModel, calc: &calc)
    }

case "month":
    var calc = loadCalculator()
    let byModel = UsageAggregator().thisMonth(scannedEvents())
    if json {
        emitJSON(scopeJSON("month", date: isoDay.string(from: Date()), byModel: byModel, calc: &calc))
    } else {
        print("This month (local time)")
        printModelTable(byModel, calc: &calc)
    }

case "daily":
    let days = Int(args.dropFirst().first(where: { !$0.hasPrefix("--") }) ?? "7") ?? 7
    var calc = loadCalculator()
    let byDay = UsageAggregator().byDayModel(scannedEvents())
    let cutoff = Calendar.current.date(byAdding: .day, value: -(days - 1),
                                       to: Calendar.current.startOfDay(for: Date()))!
    let sortedDays = byDay.sorted(by: { $0.key < $1.key }).filter { $0.key >= cutoff }
    if json {
        emitJSON(sortedDays.map { scopeJSON("daily", date: isoDay.string(from: $0.key), byModel: $0.value, calc: &calc) })
    } else {
        for (day, models) in sortedDays {
            print("\n=== \(isoDay.string(from: day)) ===")
            printModelTable(models, calc: &calc)
        }
    }

case "quota":
    let raw = args.contains("--raw")
    switch KeychainCredentialReader().readAccessToken() {
    case .notFound:
        print("No credentials found in Keychain (service: Claude Code-credentials). Sign in to Claude Code.")
        exit(2)
    case .denied:
        print("Keychain access denied. Approve the prompt to allow reading the Claude Code token.")
        exit(2)
    case .failure(let status):
        print("Keychain error (OSStatus \(status)).")
        exit(2)
    case .token(let token):
        if raw {
            // Probe mode: print the raw endpoint response (contains no secrets).
            var request = URLRequest(url: QuotaClient.endpoint)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            let (data, response) = try await URLSession.shared.data(for: request)
            print("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            print(String(data: data, encoding: .utf8) ?? "<non-utf8 body>")
        } else {
            switch await QuotaClient().fetch(token: token) {
            case .success(let snapshot):
                if json {
                    let iso = ISO8601DateFormatter()
                    emitJSON(snapshot.buckets.map {
                        QuotaBucketJSON(key: $0.key, utilizationPct: $0.utilization * 100,
                                        resetsAt: $0.resetsAt.map { iso.string(from: $0) })
                    })
                    break
                }
                let df = DateFormatter()
                df.dateStyle = .medium
                df.timeStyle = .short
                for b in snapshot.buckets {
                    let reset = b.resetsAt.map { "  resets \(df.string(from: $0))" } ?? ""
                    print(rpad(b.key, 28) + lpad(String(format: "%.1f%% used", b.utilization * 100), 12) + reset)
                }
            case .failure(.tokenExpired):
                print("Token expired (401). Open Claude Code to refresh your session.")
                exit(2)
            case .failure(let err):
                print("Quota fetch failed: \(err)")
                exit(2)
            }
        }
    }

case "scan":
    let store = UsageStore()
    let cold = store.scan()
    print("cold scan: \(cold.filesSeen) files seen, \(cold.filesParsed) parsed, "
        + "\(ByteCountFormatter.string(fromByteCount: Int64(cold.bytesParsed), countStyle: .file)), "
        + "\(store.events.count) events, \(cold.skippedLines) skipped lines, "
        + String(format: "%.2fs", cold.elapsed))
    let warm = store.scan()
    print("warm rescan: \(warm.filesParsed) files re-parsed, "
        + String(format: "%.3fs", warm.elapsed))

default:
    print("usage: TrackerCLI <today|month|daily [n]|quota|scan> [--json]  (quota also: --raw)")
    exit(64)
}
