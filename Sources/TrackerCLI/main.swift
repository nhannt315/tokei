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

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "today"

switch command {
case "today":
    var calc = loadCalculator()
    print("Today (\(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)), local time)")
    printModelTable(UsageAggregator().today(scannedEvents()), calc: &calc)

case "month":
    var calc = loadCalculator()
    print("This month (local time)")
    printModelTable(UsageAggregator().thisMonth(scannedEvents()), calc: &calc)

case "daily":
    let days = Int(args.dropFirst().first ?? "7") ?? 7
    var calc = loadCalculator()
    let byDay = UsageAggregator().byDayModel(scannedEvents())
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    let cutoff = Calendar.current.date(byAdding: .day, value: -(days - 1),
                                       to: Calendar.current.startOfDay(for: Date()))!
    for (day, models) in byDay.sorted(by: { $0.key < $1.key }) where day >= cutoff {
        print("\n=== \(df.string(from: day)) ===")
        printModelTable(models, calc: &calc)
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
    print("usage: TrackerCLI <today|month|daily [n]|quota [--raw]|scan>")
    exit(64)
}
