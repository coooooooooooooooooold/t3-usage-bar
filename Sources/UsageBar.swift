import Cocoa
import SwiftUI
import Charts
import UniformTypeIdentifiers

// 读 T3 Code 的缓存 ~/.t3/caches/*.json 里的 usageLimits，在菜单栏显示各家额度。
// 2026-11-25 改版：参考 Cindy 的托盘面板——顶上一句结论、能用余量（5 小时和 1 周取小）、
// 用完预测、打开时进度条依次涨起、管理页（拖动排序、菜单栏预览、快见底通知、隐藏个人信息、币种）。
// 不读任何账号凭证，不联网；只读 T3 Code 的本地缓存。

struct Win: Identifiable { var id: String { label }; var label: String; var kind: String; var used: Double; var resets: Date? }
struct Prov: Identifiable { var id: String { file }; var short: String; var name: String; var file: String; var wins: [Win] = []; var checked: Date?; var plan = ""; var email = "" }

let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
let iso2 = ISO8601DateFormatter()
func parseDate(_ s: String?) -> Date? { guard let s = s else { return nil }; return iso.date(from: s) ?? iso2.date(from: s) }

func loadProv(_ p: inout Prov) {
    let path = NSHomeDirectory() + "/.t3/caches/" + p.file
    p.wins = []; p.checked = nil
    guard let data = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    if let a = root["auth"] as? [String: Any] {
        p.plan = ((a["label"] as? String) ?? "").replacingOccurrences(of: " Subscription", with: "").replacingOccurrences(of: " account", with: " 账号")
        p.email = (a["email"] as? String) ?? ""
    }
    guard let ul = root["usageLimits"] as? [String: Any] else { return }
    p.checked = parseDate(ul["checkedAt"] as? String)
    for w in (ul["windows"] as? [[String: Any]]) ?? [] {
        guard let u = (w["usedPercent"] as? NSNumber)?.doubleValue else { continue }
        p.wins.append(Win(label: (w["label"] as? String) ?? "", kind: (w["kind"] as? String) ?? "", used: u, resets: parseDate(w["resetsAt"] as? String)))
    }
}
func left(_ w: Win?) -> Int? {
    guard let w = w else { return nil }
    if let r = w.resets, r < Date() { return nil } // 窗口已过期但缓存没刷新：真实额度未知，不假装 100%
    return max(0, min(100, Int((100 - w.used).rounded())))
}
func countdown(_ d: Date) -> String {
    let s = Int(d.timeIntervalSinceNow); if s <= 0 { return "已重置" }
    let m = s / 60, h = m / 60, day = h / 24
    if day >= 1 { return "\(day)天\(h % 24)小时" }
    if h >= 1 { return "\(h)小时\(m % 60)分" }
    return "\(max(1, m))分"
}
func shortCountdown(_ d: Date) -> String {
    let s = Int(d.timeIntervalSinceNow); if s <= 0 { return "已重置" }
    let m = s / 60, h = m / 60, day = h / 24
    if day >= 1 { return "\(day)天\(h % 24)时" }
    if h >= 1 { return "\(h)时\(m % 60)分" }
    return "\(max(1, m))分"
}
func resetText(_ d: Date?) -> String { guard let d = d else { return "" }; return d < Date() ? "已重置" : countdown(d) + "后重置" }
func niceLabel(_ l: String) -> String {
    var t = l.replacingOccurrences(of: "Claude & GPT (shared)", with: "Claude&GPT 共享")
    t = t.replacingOccurrences(of: " · ", with: " ").replacingOccurrences(of: "·", with: " ")
    t = t.replacingOccurrences(of: "Session", with: "5 小时").replacingOccurrences(of: "5-hour", with: "5 小时").replacingOccurrences(of: "Weekly", with: "1 周")
    return t.trimmingCharacters(in: .whitespaces)
}
let weekNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
func whenText(_ d: Date) -> String {
    let cal = Calendar.current, f = DateFormatter(); f.dateFormat = "HH:mm"
    if cal.isDateInToday(d) { return "今天 " + f.string(from: d) }
    if cal.isDateInTomorrow(d) { return "明天 " + f.string(from: d) }
    return weekNames[cal.component(.weekday, from: d) - 1] + " " + f.string(from: d)
}

func discoverProvs() -> [Prov] {
    let order = [("claudeAgent", "Cl", "Claude"), ("codex", "Cx", "Codex"), ("grok", "Gk", "Grok"), ("antigravity", "Ag", "Antigravity")]
    let dir = NSHomeDirectory() + "/.t3/caches"
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
    var found: [Prov] = []
    for (key, short, name) in order {
        let mine = files.filter { $0 == key + ".json" || $0.hasPrefix(key + "-") || $0.hasPrefix(key + "_") }
        for (i, f) in mine.enumerated() {
            let n = mine.count > 1 ? "\(i + 1)" : ""
            found.append(Prov(short: short + n, name: name + (n.isEmpty ? "" : " " + n), file: f))
        }
    }
    return found
}
func shown(_ p: Prov) -> String { p.name.hasPrefix("Antigravity") ? p.name.replacingOccurrences(of: "Antigravity", with: "Gemini") : p.name }
func pickWins(_ p: Prov) -> (Win?, Win?) {
    let ws = p.short.hasPrefix("Ag") ? p.wins.filter { $0.label.hasPrefix("Gemini") } : p.wins
    return (ws.first { $0.kind == "session" }, ws.first { $0.kind == "weekly" })
}
/// 能用的余量：5 小时和 1 周哪个先用完就卡在哪个，所以取小的
func effLeft(_ p: Prov) -> Int? { let (a, b) = pickWins(p); return [left(a), left(b)].compactMap { $0 }.min() }
/// 卡住这家的那个窗口（剩得少的那个）
func bindingWin(_ p: Prov) -> Win? {
    let (a, b) = pickWins(p)
    return [a, b].compactMap { $0 }.filter { left($0) != nil }.min { left($0)! < left($1)! }
}
func kindName(_ w: Win) -> String { w.kind == "weekly" ? "本周" : "5 小时" }
/// 照现在的速度，什么时候用完；在重置前用不完就返回 nil
func exhaustETA(_ w: Win?) -> Date? {
    guard let w = w, let r = w.resets, r > Date(), w.used >= 5, w.used < 100 else { return nil }
    let len: Double = w.kind == "weekly" ? 7 * 86400 : 5 * 3600
    let elapsed = len - r.timeIntervalSinceNow
    guard elapsed > len * 0.08 else { return nil } // 窗口刚开始，样本太少不判断
    let eta = Date().addingTimeInterval((100 - w.used) / (w.used / elapsed))
    return eta < r ? eta : nil
}
func maskEmail(_ e: String) -> String {
    guard let at = e.firstIndex(of: "@") else { return e.isEmpty ? "" : "•••" }
    return String(e.prefix(1)) + "•••" + String(e[at...])
}

// MARK: 开机自启
let agentLabel = Bundle.main.bundleIdentifier ?? "app.usagebar.t3"
let agentPath = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
var autostartOn: Bool { FileManager.default.fileExists(atPath: agentPath) }
func setAutostart(_ on: Bool) {
    if on {
        let exe = Bundle.main.executablePath ?? ""
        let plist: [String: Any] = ["Label": agentLabel, "ProgramArguments": [exe], "RunAtLoad": true, "ProcessType": "Interactive"]
        try? FileManager.default.createDirectory(atPath: (agentPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        (plist as NSDictionary).write(toFile: agentPath, atomically: true)
    } else { try? FileManager.default.removeItem(atPath: agentPath) }
}

// MARK: token 小图标（模板图，自动适配深浅色）
func tokenIcon(_ size: CGFloat = 14) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
        NSColor.black.setStroke(); NSColor.black.setFill()
        let k = r.width / 14
        let o = NSBezierPath(ovalIn: r.insetBy(dx: 1.2 * k, dy: 1.2 * k)); o.lineWidth = 1.4 * k; o.stroke()
        NSBezierPath(roundedRect: NSRect(x: 5.2 * k, y: 3.6 * k, width: 3.6 * k, height: 6.8 * k), xRadius: 1.8 * k, yRadius: 1.8 * k).fill()
        return true
    }
    img.isTemplate = true; return img
}

// MARK: 动效（曲线照 Cindy：平滑 .22,1,.36,1；回弹 .3,1.5,.5,1；系统「减少动态效果」时全关）
let isSnapshot = CommandLine.arguments.contains("--snapshot")
let isDemo = CommandLine.arguments.contains("--demo") // 演示数据：截 README 图用，不读真实缓存
func demoProvs() -> [Prov] {
    func w(_ kind: String, _ used: Double, _ h: Double) -> Win { Win(label: kind == "weekly" ? "Weekly" : "Session", kind: kind, used: used, resets: Date().addingTimeInterval(h * 3600)) }
    let now = Date().addingTimeInterval(-90)
    return [
        Prov(short: "Cl", name: "Claude", file: "demo-claude", wins: [w("session", 38, 2.4), w("weekly", 22, 130)], checked: now, plan: "Claude Max", email: "you@example.com"),
        Prov(short: "Cx", name: "Codex", file: "demo-codex", wins: [w("session", 6, 3.9), w("weekly", 9, 140)], checked: now, plan: "ChatGPT Plus", email: "you@example.com"),
        Prov(short: "Gk", name: "Grok", file: "demo-grok", wins: [w("weekly", 41, 70)], checked: now, plan: "Grok 账号", email: "you@example.com"),
        Prov(short: "Ag1", name: "Antigravity 1", file: "demo-gemini1", wins: [Win(label: "Gemini Session", kind: "session", used: 12, resets: Date().addingTimeInterval(4 * 3600)), Win(label: "Gemini Weekly", kind: "weekly", used: 83, resets: Date().addingTimeInterval(100 * 3600))], checked: now, plan: "Google 账号"),
        Prov(short: "Ag2", name: "Antigravity 2", file: "demo-gemini2", wins: [Win(label: "Gemini Session", kind: "session", used: 30, resets: Date().addingTimeInterval(1.5 * 3600)), Win(label: "Gemini Weekly", kind: "weekly", used: 15, resets: Date().addingTimeInterval(150 * 3600))], checked: now, plan: "Google 账号"),
    ]
}
var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
extension Animation {
    static let qRise = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.9)
    static let qPage = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)
    static let qSpring = Animation.timingCurve(0.3, 1.5, 0.5, 1, duration: 0.35)
    static let qSpin = Animation.timingCurve(0.4, 0.1, 0.3, 1, duration: 0.9)
    static let qMode = Animation.timingCurve(0.45, 0, 0.25, 1, duration: 0.42) // 简/常切换：两头都慢，不回弹，不晃眼
}
func motion(_ a: Animation) -> Animation? { reduceMotion ? nil : a }

// MARK: 币种（花费都是 T3 按 API 价估的美元）
let usdToCny = 7.1
var useCny: Bool { ud.integer(forKey: "currency") == 1 }
var curSym: String { useCny ? "¥" : "US$" }

// MARK: 数据与设置
let ud = UserDefaults.standard
struct CostSum { var today = 0.0; var week = 0.0; var daily = [Double](repeating: 0, count: 14); var ok = false
    var todayTok = 0.0; var weekTok = 0.0; var dailyTok = [Double](repeating: 0, count: 14) }

final class Store: ObservableObject {
    @Published var provs: [Prov] = []
    @Published var updated = Date()
    @Published var openTick = 0
    @Published var rise = isSnapshot // 打开面板时进度条从 0 涨上来；放在 Store 里，由弹出面板之后统一触发
    @Published var cost = CostSum()
    @Published var showUsed: Bool { didSet { ud.set(showUsed, forKey: "showUsed"); onChange?() } }
    @Published var barMode: Int { didSet { ud.set(barMode, forKey: "barMode"); onChange?() } } // 0 仅图标 1 最低余量 2 每家 3 今日花费
    @Published var interval: Double { didSet { ud.set(interval, forKey: "interval"); onChange?() } }
    @Published var hidden: [String] { didSet { ud.set(hidden, forKey: "hidden"); onChange?() } }
    @Published var order: [String] { didSet { ud.set(order, forKey: "order") } }
    @Published var notifyLow: Bool { didSet { ud.set(notifyLow, forKey: "notifyLow") } }
    @Published var hidePrivate: Bool { didSet { ud.set(hidePrivate, forKey: "hidePrivate"); onChange?() } }
    @Published var currency: Int { didSet { ud.set(currency, forKey: "currency"); onChange?() } }
    @Published var compact: Bool { didSet { ud.set(compact, forKey: "compact") } } // 极简模式
    var onChange: (() -> Void)?
    var openDetail: (() -> Void)?
    private var costAt = Date.distantPast
    init() {
        showUsed = ud.bool(forKey: "showUsed")
        barMode = ud.object(forKey: "barMode") as? Int ?? (ud.bool(forKey: "iconOnly") ? 0 : 2)
        let v = ud.double(forKey: "interval"); interval = v > 0 ? v : 30
        hidden = ud.stringArray(forKey: "hidden") ?? []
        order = ud.stringArray(forKey: "order") ?? []
        notifyLow = ud.object(forKey: "notifyLow") as? Bool ?? true
        hidePrivate = ud.bool(forKey: "hidePrivate")
        currency = ud.integer(forKey: "currency")
        compact = ud.object(forKey: "compact") as? Bool ?? true
    }
    var visible: [Prov] { provs.filter { !hidden.contains($0.file) } }
    func sorted(_ ps: [Prov]) -> [Prov] {
        ps.enumerated().sorted { a, b in
            let ia = order.firstIndex(of: a.element.file) ?? 1000 + a.offset, ib = order.firstIndex(of: b.element.file) ?? 1000 + b.offset
            return ia < ib
        }.map { $0.element }
    }
    func reload() {
        var ps = discoverProvs(); for i in ps.indices { loadProv(&ps[i]) }
        if isDemo { ps = demoProvs() }
        provs = sorted(ps); updated = Date()
        checkLow()
    }
    func move(_ d: String, onto t: String) {
        var arr = provs.map { $0.file }
        guard let from = arr.firstIndex(of: d), let to = arr.firstIndex(of: t), from != to else { return }
        arr.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        order = arr; provs = sorted(provs)
    }
    /// 数据最旧的那家是几分钟前的
    var staleMin: Int { (visible.compactMap { $0.checked }.map { Int(Date().timeIntervalSince($0) / 60) }.max()) ?? 0 }
    /// 花费显示成 Token：currency == 2
    var tokenMode: Bool { currency == 2 }
    /// 按设置显示成美元 / 人民币 / token
    func spend(_ usd: Double, _ tok: Double, compact: Bool = false) -> String {
        if tokenMode { return hidePrivate ? "•••" : fmtTok(tok) + (compact ? "" : " token") }
        return money(usd, compact: compact)
    }
    func money(_ usd: Double, compact: Bool = false) -> String {
        if hidePrivate { return curSym + "•••" }
        let v = useCny ? usd * usdToCny : usd
        if compact { return (useCny ? "¥" : "$") + (v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)) }
        return fmtCost(usd)
    }
    func loadCost(force: Bool = false) {
        if !force && Date().timeIntervalSince(costAt) < 120 { return }
        costAt = Date()
        if isDemo { let d = [6, 9, 7, 14, 11, 8, 12, 15, 10, 13, 19, 12, 16, 18.42]; cost = CostSum(today: 18.42, week: 96.30, daily: d, ok: true, todayTok: 24.6e6, weekTok: 131e6, dailyTok: d.map { $0 * 1.34e6 }); return }
        DispatchQueue.global(qos: .utility).async {
            let cal = Calendar.current, start = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: Date()))!
            guard let reqs = loadT3Requests(since: start) else { return }
            var days = [Double](repeating: 0, count: 14), toks = [Double](repeating: 0, count: 14)
            for q in reqs { let d = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: q.date)).day ?? -1; if d >= 0 && d < 14 { days[d] += q.cost; toks[d] += q.tokens } }
            DispatchQueue.main.async {
                self.cost = CostSum(today: days[13], week: days[7...].reduce(0, +), daily: days, ok: true, todayTok: toks[13], weekTok: toks[7...].reduce(0, +), dailyTok: toks)
                if self.barMode == 3 { self.onChange?() }
            }
        }
    }
    // 快见底通知：每个窗口每个重置周期只提醒一次
    func checkLow() {
        guard notifyLow, !isDemo else { return }
        var done = ud.stringArray(forKey: "notified") ?? []
        var changed = false
        for p in visible {
            let (a, b) = pickWins(p)
            for w in [a, b].compactMap({ $0 }) {
                guard let l = left(w), l < 20 else { continue }
                let key = "\(p.file)|\(w.kind)|\(Int(w.resets?.timeIntervalSince1970 ?? 0))"
                if done.contains(key) { continue }
                done.append(key); changed = true
                let tail = w.resets.map { "，" + whenText($0) + " 重置" } ?? ""
                notify("用量快见底", "\(shown(p)) \(kindName(w))只剩 \(l)%\(tail)")
            }
        }
        if changed { ud.set(Array(done.suffix(60)), forKey: "notified") }
    }
    /// 菜单栏上的文字，管理页的预览也用它
    func barTitle() -> NSAttributedString {
        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        func add(_ s: String, _ color: NSColor = .labelColor) { title.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])) }
        func num(_ l: Int) -> String { "\(showUsed ? 100 - l : l)" }
        switch barMode {
        case 1:
            let ks = visible.compactMap { p in effLeft(p).map { (p, $0) } }
            if let m = ks.min(by: { $0.1 < $1.1 }) { add(m.0.short + " "); add(num(m.1) + "%", m.1 < 20 ? .systemRed : .labelColor) } else { add("–", .secondaryLabelColor) }
        case 2:
            for (i, p) in visible.enumerated() {
                let (s, w) = pickWins(p)
                if i > 0 { add("  ") }
                add(p.short + " ")
                for (j, win) in [s, w].enumerated() {
                    if j == 1 { add("/") }
                    if let l = left(win) { add(num(l), l < 20 ? .systemRed : .labelColor) } else { add("–", .secondaryLabelColor) }
                }
            }
        case 3: add(cost.ok ? spend(cost.today, cost.todayTok, compact: true) : "–")
        default: break
        }
        return title
    }
}

func notify(_ title: String, _ body: String) {
    let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
    try? p.run()
}
/// 在后台打开 T3 Code，让它刷新额度缓存（不抢焦点）
func nudgeT3() {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "-a", "T3 Code (Beta)"]; try? p.run()
}

// MARK: 颜色与小部件
func provColor(_ p: Prov) -> Color {
    switch p.short.prefix(2) {
    case "Cl": return Color(red: 0.88, green: 0.52, blue: 0.42)
    case "Cx": return Color(red: 0.30, green: 0.64, blue: 0.54)
    case "Gk": return Color(white: 0.5)
    default: return Color(red: 0.55, green: 0.50, blue: 0.86)
    }
}
func barTint(_ l: Int, _ p: Prov) -> Color { l < 20 ? .red : (l < 40 ? .orange : provColor(p)) }
func levelColor(_ l: Int?) -> Color { guard let l = l else { return .secondary }; return l < 20 ? .red : (l < 40 ? .orange : .primary) }
func dyn(_ light: NSColor, _ dark: NSColor) -> Color { Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }) }
let panelBase = dyn(NSColor(white: 0.962, alpha: 1), NSColor(white: 0.125, alpha: 1))
let tileFill = dyn(NSColor(white: 1, alpha: 0.78), NSColor(white: 1, alpha: 0.06))
let inkStrong = dyn(NSColor(white: 0.13, alpha: 1), NSColor(white: 0.95, alpha: 1))

struct Card<C: View>: View {
    let content: C
    init(@ViewBuilder _ c: () -> C) { content = c() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}
/// 面板里的白色圆角块
struct Tile<C: View>: View {
    let content: C
    init(@ViewBuilder _ c: () -> C) { content = c() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }.frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(tileFill))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}
struct Bar: View {
    var pct: Int; var color: Color; var h: CGFloat = 10; var glow = false
    @State private var phase: CGFloat = 0
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: pct <= 0 ? 0 : max(h, g.size.width * CGFloat(pct) / 100))
                    .overlay(alignment: .leading) {
                        if glow && !reduceMotion { // 余量最足那家：一道光慢慢扫过
                            LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 26).offset(x: phase * (g.size.width + 26) - 26)
                        }
                    }.clipShape(Capsule())
            }
        }.frame(height: h)
        .onAppear { if glow && !reduceMotion { withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false).delay(1)) { phase = 1 } } }
    }
}
struct WinRow: View {
    let w: Win; let p: Prov
    var body: some View {
        let l = left(w) ?? 0, stale = left(w) == nil
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(niceLabel(w.label)).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text(stale ? "–" : "\(l)%").font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundColor(stale ? .secondary : (l < 20 ? .red : .primary))
                    Text("剩余").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }.frame(width: 118, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                Bar(pct: l, color: stale ? .clear : barTint(l, p))
                Text(stale ? "数据较旧，等 T3 Code 刷新" : (exhaustETA(w).map { "照这速度 " + whenText($0) + " 用完 · " } ?? "") + resetText(w.resets))
                    .font(.system(size: 11)).foregroundColor(exhaustETA(w) != nil ? .orange : .secondary).frame(height: 13)
            }
        }
    }
}
struct Seg: View {
    let items: [String]; @Binding var sel: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                Text(items[i]).font(.system(size: 13, weight: sel == i ? .semibold : .regular))
                    .foregroundColor(sel == i ? .primary : .secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(sel == i ? Color(nsColor: .controlBackgroundColor) : .clear)
                        .shadow(color: .black.opacity(sel == i ? 0.1 : 0), radius: 2, y: 1))
                    .contentShape(Rectangle()).onTapGesture { sel = i }
            }
        }.padding(3).background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }
}
/// 管理页的小分段：选中的是蓝底白字（照 Cindy）
struct PillSeg: View {
    let items: [String]; @Binding var sel: Int; var small = false
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                Text(items[i]).font(.system(size: small ? 11 : 12, weight: sel == i ? .semibold : .regular))
                    .foregroundColor(sel == i ? .white : .primary.opacity(0.75))
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, small ? 8 : 10).padding(.vertical, small ? 3 : 5)
                    .background { if sel == i { RoundedRectangle(cornerRadius: 7).fill(Color.accentColor).matchedGeometryEffect(id: "sel", in: ns) } } // 选中块滑过去，不是一闪
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(motion(.qMode)) { sel = i } }
            }
        }.padding(2).background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
    }
}
struct IconBtn: View {
    let name: String; let action: () -> Void
    var body: some View { Button(action: action) { Image(systemName: name).font(.system(size: 14)).foregroundColor(.secondary) }.buttonStyle(.plain) }
}
/// 按下缩一点、松开回弹
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? scale : 1)
            .animation(motion(configuration.isPressed ? .easeOut(duration: 0.1) : .qSpring), value: configuration.isPressed)
    }
}
/// 悬停时往上浮一点
struct Lift: ViewModifier {
    var by: CGFloat = 2
    @State private var on = false
    func body(content: Content) -> some View {
        content.offset(y: on ? -by : 0).onHover { h in withAnimation(motion(.timingCurve(0.22, 1, 0.36, 1, duration: 0.25))) { on = h } }
    }
}

// MARK: 主面板
struct Root: View {
    @ObservedObject var s: Store
    @State var page: Int
    init(s: Store, page: Int = CommandLine.arguments.contains("--tab1") ? 1 : 0) { self.s = s; _page = State(initialValue: page) }
    var body: some View {
        ZStack(alignment: .top) {
            if page == 0 {
                MainPage(s: s, page: $page).transition(.asymmetric(insertion: .offset(x: -110).combined(with: .opacity), removal: .offset(x: -110).combined(with: .opacity)))
            } else {
                ManagePage(s: s, page: $page).transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: 360).clipped() // 两种样式同宽，切换时只变高度，不左右跳
        .background(PanelBG(color: bestColor))
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in s.reload() }
    }
    var bestColor: Color {
        let ks = s.visible.compactMap { p in effLeft(p).map { (p, $0) } }
        return ks.max { $0.1 < $1.1 }.map { provColor($0.0) } ?? .gray
    }
}
/// 底色：中性灰白，左上角一点点最足那家的颜色
struct PanelBG: View {
    var color: Color
    var body: some View {
        ZStack {
            panelBase
            RadialGradient(colors: [color.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 340)
            LinearGradient(colors: [.clear, Color.primary.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }.animation(motion(.easeInOut(duration: 0.8)), value: color)
    }
}

struct Headline { var main: String; var sub: String?; var warn = false }
func makeHeadline(_ ps: [Prov]) -> Headline {
    let withData = ps.filter { !$0.wins.isEmpty }
    if withData.isEmpty { return Headline(main: "还没读到余量。", sub: "打开一次 T3 Code，这里就会有数。") }
    let known = withData.compactMap { p in effLeft(p).map { (p, $0) } }
    if known.isEmpty { return Headline(main: "余量数据都过期了。", sub: "点右上角刷新，会在后台打开 T3 Code 更新。", warn: true) }
    let back = known.filter { $0.1 == 0 }.compactMap { k in bindingWin(k.0)?.resets.map { (k.0, $0) } }.sorted { $0.1 < $1.1 }
    if known.allSatisfy({ $0.1 == 0 }) {
        return Headline(main: "余量都用完了。", sub: back.first.map { "\(shown($0.0)) \(countdown($0.1))后回来" }, warn: true)
    }
    let best = known.max { $0.1 < $1.1 }!
    var subs: [String] = []
    for k in known where k.1 > 0 && k.1 < 20 { subs.append("\(shown(k.0)) 快见底，剩 \(k.1)%") }
    let etas = known.filter { $0.1 >= 20 }.compactMap { k in exhaustETA(bindingWin(k.0)).map { "\(shown(k.0)) \(whenText($0))" } }
    if !etas.isEmpty { subs.append("照这速度会提前用完：" + etas.prefix(2).joined(separator: "，")) }
    let warn = !subs.isEmpty
    for b in back { subs.append("\(shown(b.0)) \(countdown(b.1))后回来") }
    return Headline(main: "\(shown(best.0)) 余量最足。", sub: subs.isEmpty ? nil : subs.prefix(2).joined(separator: " · "), warn: warn)
}

struct MainPage: View {
    @ObservedObject var s: Store; @Binding var page: Int
    @State var spins = 0.0
    @State var dragging: String?
    @State var reveal = 1.0      // 下面内容的显隐：1 = 拉下来，0 = 收起
    @State var switching = false
    @State var modeSel = -1      // 顶栏「简丨常」的选中块，点下去先滑过去，内容随后再换
    var rise: Bool { s.rise }
    var body: some View {
        let h = makeHeadline(s.visible)
        let best = s.visible.compactMap { p in effLeft(p).map { (p, $0) } }.max { $0.1 < $1.1 }?.0.file
        VStack(alignment: .leading, spacing: 0) {
            // 顶栏：简、常两种样式一模一样，切换时完全不动
            HStack(spacing: 8) {
                // 点左上角图标切换样式：极简是线框图标，正常是立体图标
                Button {
                    let toFull = s.compact
                    withAnimation(motion(.qSpring)) { modeSel = toFull ? 1 : 0 }
                    switchMode()
                } label: { ModeIcon(raised: modeSel < 0 ? !s.compact : modeSel == 1).contentShape(Circle()) }
                .buttonStyle(PressStyle(scale: 0.86)).modifier(Lift(by: 1))
                .help(s.compact ? "点一下：展开成正常样式" : "点一下：收成极简样式")
                Spacer()
                if s.staleMin > 30 { Text(freshText).font(.system(size: 12)).foregroundColor(.orange) } // 数据旧了才露出
                Button {
                    withAnimation(motion(.qSpin)) { spins += 1 }
                    s.reload(); s.loadCost(force: true)
                    if s.staleMin > 5 { nudgeT3() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .medium)).foregroundColor(.secondary)
                        .rotationEffect(.degrees(spins * 360)).frame(width: 26, height: 26).contentShape(Rectangle())
                }.buttonStyle(PressStyle(scale: 0.85)).help(s.staleMin > 5 ? "重新读取，并在后台打开 T3 Code 刷新额度" : "重新读取")
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)

            // 下面的内容：切换样式时先收上去，换好再拉下来
            VStack(alignment: .leading, spacing: 0) {
                if !s.compact {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(h.main).font(.system(size: 18, weight: .semibold)).foregroundColor(inkStrong)
                        if let sub = h.sub { Text(sub).font(.system(size: 11.5)).foregroundColor(h.warn ? .orange : .secondary).lineLimit(2) }
                    }.padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 12)
                }

                Tile {
                    if s.visible.isEmpty { Text("在「管理」里打开要显示的几家").font(.system(size: 12)).foregroundColor(.secondary).padding(16) }
                    ForEach(Array(s.visible.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { Divider().padding(.leading, 16) }
                        // 每一行都能拖动换位置，松手后顺序记住（和管理页是同一份顺序）
                        Group {
                            if s.compact { SlimRow(p: p, i: i, rise: rise, best: p.file == best, showUsed: s.showUsed) }
                            else { ProvRow(p: p, i: i, rise: rise, best: p.file == best, showUsed: s.showUsed) }
                        }
                        .modifier(Reorderable(file: p.file, dragging: $dragging, s: s, dim: 0.35))
                    }
                }
                .padding(.horizontal, 14)

                if s.compact { SlimCost(s: s).padding(.horizontal, 14).padding(.top, 10) }
                else { CostTile(s: s).padding(.horizontal, 14).padding(.top, 10) }

                HStack(spacing: 10) {
                    Button { s.openDetail?() } label: {
                        HStack(spacing: 6) { Image(systemName: "chart.bar.xaxis").font(.system(size: 12, weight: .semibold)); Text("用量详情").font(.system(size: 13, weight: .semibold)) }
                            .foregroundColor(Color(nsColor: .windowBackgroundColor)).padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Capsule().fill(inkStrong))
                    }.buttonStyle(PressStyle(scale: 0.97))
                    Spacer()
                    Button { withAnimation(motion(.qPage)) { page = 1 } } label: {
                        Image(systemName: "gearshape").font(.system(size: 15)).foregroundColor(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
                    }.buttonStyle(PressStyle(scale: 0.88)).help("管理")
                }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 14)
            }
            .opacity(reveal)
            .offset(y: -16 * (1 - reveal))
            .scaleEffect(x: 1, y: 0.97 + 0.03 * reveal, anchor: .top)
        }
    }
    /// 换样式：先把下面收上去（0.16 秒），趁看不见时换内容、面板改高度，再慢慢拉下来（0.5 秒）
    func switchMode() {
        if switching { return }
        if reduceMotion { s.compact.toggle(); modeSel = -1; return }
        switching = true
        withAnimation(.easeIn(duration: 0.16)) { reveal = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { s.compact.toggle() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)) { reveal = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { switching = false; modeSel = -1 }
            }
        }
    }
    var freshText: String {
        let m = s.staleMin
        if s.visible.allSatisfy({ $0.checked == nil }) { return "" }
        if m < 1 { return "刚刚更新" }; if m < 60 { return "\(m) 分钟前" }
        return "\(m / 60) 小时前"
    }
}

struct ProvRow: View {
    let p: Prov; let i: Int; let rise: Bool; let best: Bool; let showUsed: Bool
    @State var hover = false
    var body: some View {
        let (a, b) = pickWins(p), eff = effLeft(p)
        let shownEff = rise ? (eff ?? 0) : 0
        let delay = Double(i) * 0.06
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(provColor(p)).frame(width: 8, height: 8)
                    Text(shown(p)).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                    if best { Text("最足").fixedSize().font(.system(size: 9.5, weight: .semibold)).foregroundColor(provColor(p)).padding(.horizontal, 5).padding(.vertical, 1.5).background(Capsule().fill(provColor(p).opacity(0.15))) }
                }
                Text(subline.0).font(.system(size: 11)).foregroundColor(subline.1).lineLimit(1).fixedSize()
            }.layoutPriority(1)
            Spacer(minLength: 4)
            if p.wins.isEmpty { Text("没读到").font(.system(size: 12)).foregroundColor(.secondary) }
            else {
                VStack(alignment: .leading, spacing: 6) { mini("5h", a, delay); mini("周", b, delay + 0.03) }
            }
            Text(eff == nil ? "–" : "\(showUsed ? 100 - shownEff : shownEff)%")
                .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundColor(levelColor(eff)).contentTransition(.numericText(value: Double(shownEff)))
                .animation(motion(Animation.qRise.delay(rise ? delay : 0)), value: rise)
                .animation(motion(.qRise), value: eff)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.primary.opacity(hover ? 0.035 : 0))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(motion(.easeOut(duration: 0.2))) { hover = h } }
    }
    var subline: (String, Color) {
        if p.wins.isEmpty { return ("T3 Code 没开或没登录", .secondary) }
        guard let w = bindingWin(p) else { return ("数据较旧，点刷新", .orange) }
        if let e = exhaustETA(w) { return ("\(whenText(e)) 会用完", .orange) }
        if let l = left(w), l < 20, let r = w.resets { return ("\(kindName(w))快见底，\(shortCountdown(r))后重置", .red) }
        return (p.plan.isEmpty ? "卡在\(kindName(w))" : p.plan, .secondary)
    }
    @ViewBuilder func mini(_ label: String, _ w: Win?, _ delay: Double) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary).frame(width: 16, alignment: .leading)
            if let w = w, let l = left(w) {
                Bar(pct: rise ? l : 0, color: barTint(l, p), h: 5, glow: best && l == effLeft(p))
                    .animation(motion(Animation.qRise.delay(rise ? delay : 0)), value: rise)
                    .animation(motion(.qRise), value: l)
                    .frame(width: 50)
                Text(w.resets.map { shortCountdown($0) } ?? "未计时").font(.system(size: 10)).monospacedDigit().foregroundColor(.secondary).frame(width: 44, alignment: .leading)
            } else if w != nil {
                Bar(pct: 0, color: .clear, h: 5).frame(width: 50)
                Text("较旧").font(.system(size: 10)).foregroundColor(.orange).frame(width: 44, alignment: .leading)
            } else {
                Text("无此限制").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7)).frame(width: 100, alignment: .leading)
            }
        }.help(w.map { niceLabel($0.label) + "：" + (left($0).map { "剩 \($0)%，" } ?? "") + resetText($0.resets) } ?? "")
    }
}

/// 左上角的样式图标：极简 = 线框（和菜单栏图标一样），正常 = 立体（蓝色渐变、高光、投影）
struct ModeIcon: View {
    let raised: Bool
    var body: some View {
        let blue = Color(red: 0.18, green: 0.45, blue: 0.84)
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.40, green: 0.66, blue: 0.97), blue], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.5), .clear], startPoint: .top, endPoint: .center)).padding(1.2))
                .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                .overlay(Capsule().fill(.white).frame(width: 5.5, height: 10.5).shadow(color: .black.opacity(0.22), radius: 0.6, y: 0.6))
                .shadow(color: blue.opacity(0.45), radius: 3, y: 2)
                .opacity(raised ? 1 : 0).scaleEffect(raised ? 1 : 0.55)
            Image(nsImage: tokenIcon(18)).resizable().renderingMode(.template).frame(width: 18, height: 18)
                .opacity(raised ? 0 : 1).scaleEffect(raised ? 1.25 : 1)
        }.frame(width: 22, height: 22)
    }
}

/// 极简模式的一行：名字、一条能用余量、百分比；有事才在名字后面挂个小橙点
struct SlimRow: View {
    let p: Prov; let i: Int; let rise: Bool; let best: Bool; let showUsed: Bool
    @State var hover = false
    var body: some View {
        let eff = effLeft(p), shownEff = rise ? (eff ?? 0) : 0, delay = Double(i) * 0.06
        let w = bindingWin(p), eta = exhaustETA(w)
        HStack(spacing: 10) {
            Circle().fill(provColor(p)).frame(width: 7, height: 7)
            Text(shown(p)).font(.system(size: 13, weight: best ? .semibold : .regular)).lineLimit(1)
            if eta != nil { Circle().fill(Color.orange).frame(width: 5, height: 5) }
            Spacer(minLength: 8)
            Bar(pct: shownEff, color: eff.map { barTint($0, p) } ?? .clear, h: 4, glow: best)
                .animation(motion(Animation.qRise.delay(rise ? delay : 0)), value: rise)
                .animation(motion(.qRise), value: eff)
                .frame(width: 96)
            Text(eff == nil ? "–" : "\(showUsed ? 100 - shownEff : shownEff)%")
                .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundColor(levelColor(eff)).contentTransition(.numericText(value: Double(shownEff)))
                .animation(motion(Animation.qRise.delay(rise ? delay : 0)), value: rise)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 14).frame(height: 38)
        .background(Color.primary.opacity(hover ? 0.035 : 0))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(motion(.easeOut(duration: 0.2))) { hover = h } }
        .help(tip(eta, w))
    }
    func tip(_ eta: Date?, _ w: Win?) -> String {
        var out = [String]()
        let (a, b) = pickWins(p)
        for x in [a, b].compactMap({ $0 }) { out.append(kindName(x) + "：" + (left(x).map { "剩 \($0)%，" } ?? "数据较旧，") + resetText(x.resets)) }
        if let e = eta { out.append("照这速度 " + whenText(e) + " 会用完") }
        return out.joined(separator: "\n")
    }
}
/// 极简模式的花费：一行字
struct SlimCost: View {
    @ObservedObject var s: Store
    var body: some View {
        Button { s.openDetail?() } label: {
            HStack(spacing: 6) {
                Text("今天").foregroundColor(.secondary)
                Text(s.cost.ok ? s.spend(s.cost.today, s.cost.todayTok) : "–").fontWeight(.semibold).monospacedDigit()
                Text("· 近 7 天 " + (s.cost.ok ? s.spend(s.cost.week, s.cost.weekTok) : "–")).foregroundColor(.secondary).monospacedDigit()
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(tileFill))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
            .contentShape(Rectangle())
        }.buttonStyle(PressStyle(scale: 0.98)).modifier(Lift(by: 1))
    }
}

/// 底部花费小块：今天 + 近 7 天 + 14 天走势
struct CostTile: View {
    @ObservedObject var s: Store
    @State var hover = false
    var body: some View {
        Button { s.openDetail?() } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.tokenMode ? "今天用的 token" : "今天 · API 估算").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).fixedSize()
                    Text(s.cost.ok ? s.spend(s.cost.today, s.cost.todayTok, compact: s.tokenMode) : "–").font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit().foregroundColor(inkStrong).lineLimit(1).fixedSize()
                        .contentTransition(.numericText(value: s.cost.today)).animation(motion(.qRise), value: s.cost.today)
                    Text(s.cost.ok ? "近 7 天 " + s.spend(s.cost.week, s.cost.weekTok) : "读取中…").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 6)
                Spark(vals: s.tokenMode ? s.cost.dailyTok : s.cost.daily).frame(width: 92, height: 34).opacity(s.hidePrivate ? 0.25 : 1)
                HStack(spacing: 2) { Text("展开").font(.system(size: 12, weight: .medium)); Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).offset(x: hover ? 2 : 0) }
                    .foregroundColor(.secondary)
            }.padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(tileFill))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
            .offset(y: hover ? -1 : 0)
            .contentShape(Rectangle())
        }.buttonStyle(PressStyle(scale: 0.98))
        .onHover { h in withAnimation(motion(.qSpring)) { hover = h } }
    }
}
struct Spark: View {
    let vals: [Double]
    var body: some View {
        Chart(Array(vals.enumerated()), id: \.offset) { i, v in
            AreaMark(x: .value("d", i), y: .value("v", v)).foregroundStyle(LinearGradient(colors: [Color.primary.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom)).interpolationMethod(.monotone)
            LineMark(x: .value("d", i), y: .value("v", v)).foregroundStyle(Color.primary.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1.4)).interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .chartYScale(domain: 0...max(0.01, (vals.max() ?? 0) * 1.1)).clipped()
    }
}

// MARK: 管理页（照 Cindy 的「管理」：余量来源 / 菜单栏图标 / 其他）
struct ManagePage: View {
    @ObservedObject var s: Store; @Binding var page: Int
    @State var dragging: String?
    @State var auto = autostartOn
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { back() } label: { Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)).foregroundColor(.secondary).frame(width: 24, height: 26).contentShape(Rectangle()) }.buttonStyle(PressStyle(scale: 0.85))
                Text("管理").font(.system(size: 16, weight: .bold))
                Spacer()
                Button { back() } label: { Text("完成").font(.system(size: 13, weight: .semibold)).foregroundColor(Color(nsColor: .windowBackgroundColor)).padding(.horizontal, 14).padding(.vertical, 6).background(Capsule().fill(inkStrong)) }.buttonStyle(PressStyle())
            }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            if isSnapshot { content } else { ScrollView(.vertical, showsIndicators: false) { content }.frame(height: 560) }
        }
    }
    var content: some View {
                VStack(alignment: .leading, spacing: 0) {
                    section("余量来源", trailing: "已显示 \(s.visible.count)/\(s.provs.count)")
                    Tile {
                        ForEach(Array(s.provs.enumerated()), id: \.element.id) { i, p in
                            if i > 0 { Divider().padding(.leading, 56) }
                            sourceRow(p)
                                .modifier(Reorderable(file: p.file, dragging: $dragging, s: s, dim: 0.4))
                        }
                    }
                    Text("拖动左边的三道杠调顺序，面板和菜单栏都按这个顺序。").font(.system(size: 11)).foregroundColor(.secondary).padding(.horizontal, 6).padding(.top, 6)

                    section("菜单栏图标")
                    BarPreview(s: s)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                        ForEach(Array(["仅图标", "最低余量", "每家都显示", "今日花费"].enumerated()), id: \.offset) { i, t in
                            Button { withAnimation(motion(.qSpring)) { s.barMode = i } } label: {
                                Text(t).font(.system(size: 13, weight: s.barMode == i ? .semibold : .regular))
                                    .foregroundColor(s.barMode == i ? Color(nsColor: .windowBackgroundColor) : .primary.opacity(0.7))
                                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                                    .background(Capsule().fill(s.barMode == i ? inkStrong : tileFill))
                                    .overlay(Capsule().stroke(Color.primary.opacity(s.barMode == i ? 0 : 0.07), lineWidth: 0.5))
                                    .contentShape(Capsule())
                            }.buttonStyle(PressStyle(scale: 0.97))
                        }
                    }.padding(.top, 10)

                    section("其他")
                    Tile {
                        row("面板样式", s.compact ? "每家一行，只看能用多少" : "两个窗口、倒计时、用完预测都显示") { PillSeg(items: ["极简", "正常"], sel: Binding(get: { s.compact ? 0 : 1 }, set: { s.compact = $0 == 0 })) }
                        Divider().padding(.leading, 16)
                        row("快用完时通知", "低于 20% 提醒一次") { Toggle("", isOn: $s.notifyLow).toggleStyle(.switch).labelsHidden() }
                        Divider().padding(.leading, 16)
                        row("隐藏个人信息", "截图前打开：邮箱打码、金额变 •••") { Toggle("", isOn: $s.hidePrivate).toggleStyle(.switch).labelsHidden() }
                        Divider().padding(.leading, 16)
                        row("数字含义") { PillSeg(items: ["剩余", "已用"], sel: Binding(get: { s.showUsed ? 1 : 0 }, set: { s.showUsed = $0 == 1 })) }
                        Divider().padding(.leading, 16)
                        row("花费显示", s.currency == 1 ? "按 1 美元 ≈ \(String(format: "%.1f", usdToCny)) 元估" : (s.tokenMode ? "用了多少 token（含缓存读写）" : nil)) { PillSeg(items: ["USD", "CNY", "Token"], sel: $s.currency) }
                        Divider().padding(.leading, 16)
                        row("刷新间隔") { PillSeg(items: ["15秒", "30秒", "1分", "5分"], sel: Binding(get: { [15.0, 30, 60, 300].firstIndex(of: s.interval) ?? 1 }, set: { s.interval = [15.0, 30, 60, 300][$0] })) }
                        Divider().padding(.leading, 16)
                        row("开机自动启动") { Toggle("", isOn: Binding(get: { auto }, set: { auto = $0; setAutostart($0) })).toggleStyle(.switch).labelsHidden() }
                    }
                    HStack {
                        Button("打开用量详情") { s.openDetail?() }.buttonStyle(.plain).foregroundColor(.secondary)
                        Spacer()
                        Button("退出用量菜单栏") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundColor(.secondary)
                    }.font(.system(size: 12)).padding(.horizontal, 6).padding(.top, 12)
                    Text("额度和花费都来自 T3 Code 的本地缓存；不读账号凭证，不联网。").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.8)).padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 14)
                }.padding(.horizontal, 14)
    }
    func back() { withAnimation(motion(.qPage)) { page = 0 } }
    func section(_ t: String, trailing: String? = nil) -> some View {
        HStack { Text(t).font(.system(size: 13, weight: .bold)); Spacer(); if let tr = trailing { Text(tr).font(.system(size: 12)).foregroundColor(.secondary) } }
            .padding(.horizontal, 6).padding(.top, 16).padding(.bottom, 8)
    }
    func row<V: View>(_ t: String, _ sub: String? = nil, @ViewBuilder _ c: () -> V) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) { Text(t).font(.system(size: 13)); if let sub = sub { Text(sub).font(.system(size: 11)).foregroundColor(.secondary) } }
            Spacer(); c()
        }.padding(.horizontal, 16).frame(minHeight: 44)
    }
    func sourceRow(_ p: Prov) -> some View {
        let on = !s.hidden.contains(p.file), eff = effLeft(p)
        let acct = [p.plan, s.hidePrivate ? maskEmail(p.email) : p.email].filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary.opacity(0.7)).frame(width: 14)
            Text(String(shown(p).prefix(1))).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(provColor(p))
                .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(provColor(p).opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(shown(p)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(acct.isEmpty ? "–" : acct).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Text(eff.map { "\($0)%" } ?? "–").font(.system(size: 13)).monospacedDigit().foregroundColor(.secondary)
            Toggle("", isOn: Binding(get: { on }, set: { v in
                withAnimation(motion(.qSpring)) { if v { s.hidden.removeAll { $0 == p.file } } else if !s.hidden.contains(p.file) { s.hidden.append(p.file) } } }))
                .toggleStyle(.switch).labelsHidden()
        }.padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
    }
}
/// 拖动换位置：主面板和管理页共用；离屏截图时不挂拖动（渲染器画不出来）
struct Reorderable: ViewModifier {
    let file: String; @Binding var dragging: String?; let s: Store; var dim = 0.4
    func body(content: Content) -> some View {
        if isSnapshot { content } else {
            content.opacity(dragging == file ? dim : 1)
                .onDrag { dragging = file; return NSItemProvider(object: file as NSString) }
                .onDrop(of: [UTType.text], delegate: ReorderDrop(target: file, dragging: $dragging, s: s))
        }
    }
}
struct ReorderDrop: DropDelegate {
    let target: String; @Binding var dragging: String?; let s: Store
    func dropEntered(info: DropInfo) { guard let d = dragging, d != target else { return }; withAnimation(motion(.qSpring)) { s.move(d, onto: target) } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
/// 菜单栏长什么样：一小块模拟桌面，上面一条菜单栏
struct BarPreview: View {
    @ObservedObject var s: Store
    var body: some View {
        let now = whenText(Date()).replacingOccurrences(of: "今天", with: weekNames[Calendar.current.component(.weekday, from: Date()) - 1])
        ZStack {
            LinearGradient(colors: [Color(red: 0.93, green: 0.90, blue: 0.84), Color(red: 0.80, green: 0.86, blue: 0.84), Color(red: 0.74, green: 0.82, blue: 0.86)], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 12) {
                Spacer()
                Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    Image(nsImage: tokenIcon(15)).resizable().renderingMode(.template).frame(width: 15, height: 15)
                    if s.barMode != 0 { Text((try? AttributedString(s.barTitle(), including: \.appKit)) ?? AttributedString(s.barTitle().string)).font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1) }
                }.padding(.horizontal, 8).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.09)))
                .animation(motion(.qSpring), value: s.barMode)
                Text(now).font(.system(size: 13, weight: .medium))
            }.foregroundColor(Color(white: 0.12)).padding(.horizontal, 14).frame(height: 32)
            .background(Rectangle().fill(.white.opacity(0.35)))
        }
        .frame(height: 92).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .environment(\.colorScheme, .light)
    }
}

// MARK: 用量详情（token / 费用），数据来自 T3 Code 的用量缓存
struct Req { var date: Date; var prov: String; var model: String; var inp: Double; var out: Double; var cw: Double; var cr: Double; var cost: Double; var session: String
    var tokens: Double { inp + out + cw + cr } }
let provNames = ["Claude", "Codex", "Grok", "Antigravity", "其他"]
func groupName(_ agent: String) -> String {
    let a = agent.lowercased()
    if a.contains("claude") { return "Claude" }; if a.contains("codex") { return "Codex" }
    if a.contains("grok") { return "Grok" }; if a == "agy" || a.contains("antigravity") || a.contains("gemini") { return "Antigravity" }
    return "其他"
}
func gColor(_ n: String) -> Color {
    switch n { case "Claude": return Color(red: 0.88, green: 0.45, blue: 0.34); case "Codex": return Color(red: 0.36, green: 0.68, blue: 0.58)
    case "Grok": return Color(white: 0.5); case "Antigravity": return Color(red: 0.55, green: 0.47, blue: 0.86); default: return Color(white: 0.75) }
}
func parseCSV(_ d: Data) -> [[String]] {
    var rows = [[String]](), row = [String](), f = [UInt8](), q = false
    let b = [UInt8](d); var i = 0
    func endField() { row.append(String(decoding: f, as: UTF8.self)); f.removeAll(keepingCapacity: true) }
    while i < b.count {
        let c = b[i]
        if q { if c == 34 { if i + 1 < b.count && b[i + 1] == 34 { f.append(34); i += 1 } else { q = false } } else { f.append(c) } }
        else if c == 34 { q = true } else if c == 44 { endField() }
        else if c == 10 { endField(); rows.append(row); row = [] } else if c != 13 { f.append(c) }
        i += 1
    }
    if !f.isEmpty || !row.isEmpty { endField(); rows.append(row) }
    return rows
}
// MARK: 直接读 T3 Code 自己的用量缓存和价格表（不依赖 magpie）
struct Rt { var i: Double; var o: Double; var cr: Double; var cc: Double; var c1: Double }
struct Rate { var std: Rt; var fast: Rt?; var ultra: Rt?; var tiers: [(th: Double, r: Rate)] = [] }
private func num(_ v: Any?) -> Double? { if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { let d = n.doubleValue; return d.isFinite ? d : nil }; return nil }
private func readRt(_ e: [String: Any], _ suf: String, _ std: Rt?, _ outFB: Double?) -> Rt? {
    guard let i = num(e["input_cost_per_token" + suf]), let o = num(e["output_cost_per_token" + suf]) ?? outFB else { return nil }
    func c(_ name: String, _ f: (Rt) -> Double, _ fb: Double) -> Double {
        if let v = num(e[name + suf]) { return v }
        if let s = std, s.i > 0 { return f(s) / s.i * i }
        return fb
    }
    let cc = c("cache_creation_input_token_cost", { $0.cc }, i)
    return Rt(i: i, o: o, cr: c("cache_read_input_token_cost", { $0.cr }, i), cc: cc, c1: c("cache_creation_input_token_cost_above_1hr", { $0.c1 }, cc))
}
private func scaled(_ r: Rt, _ m: Double) -> Rt { Rt(i: r.i * m, o: r.o * m, cr: r.cr * m, cc: r.cc * m, c1: r.c1 * m) }
private func readSpeeds(_ e: [String: Any], _ std: Rt, _ suf: String) -> (Rt?, Rt?) {
    var mult: Double? = nil
    if let sp = e["provider_specific_entry"] as? [String: Any], let f = num(sp["fast"]), f > 0 { mult = f }
    return (mult.map { scaled(std, $0) } ?? readRt(e, suf + "_priority", std, nil), readRt(e, suf + "_ultrafast", std, nil))
}
func loadT3Rates(_ doc: [String: Any]) -> [String: Rate] {
    var table = [String: Rate]()
    let tierRe = try! NSRegularExpression(pattern: "^input_cost_per_token_above_(\\d+)k_tokens$")
    for (name, raw) in doc {
        guard let e = raw as? [String: Any], let std = readRt(e, "", nil, nil) else { continue }
        let sp = readSpeeds(e, std, "")
        var rate = Rate(std: std, fast: sp.0, ultra: sp.1)
        for k in e.keys {
            guard let m = tierRe.firstMatch(in: k, range: NSRange(k.startIndex..., in: k)), let rg = Range(m.range(at: 1), in: k), let th = Double(k[rg]) else { continue }
            let suf = "_above_\(k[rg])k_tokens"
            let ts = readRt(e, suf, std, std.o) ?? std
            let tsp = readSpeeds(e, ts, suf)
            rate.tiers.append((th * 1000, Rate(std: ts, fast: tsp.0, ultra: tsp.1)))
        }
        rate.tiers.sort { $0.th > $1.th }
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if !key.isEmpty { table[key] = rate }
    }
    for (k, v) in table {
        let b: String = k.contains("/") ? String(k[k.index(after: k.lastIndex(of: "/")!)...]) : (k.hasPrefix("anthropic.") ? String(k.dropFirst(10)) : k)
        if b != k && !b.isEmpty && table[b] == nil { table[b] = v }
    }
    return table
}
/// 返回 nil 表示 T3 的缓存不存在或读不懂
func loadT3Requests(since: Date) -> [Req]? {
    let dir = NSHomeDirectory() + "/.t3/userdata/"
    guard let sd = FileManager.default.contents(atPath: dir + "usage-scan-cache-v17.json"),
          let sc = (try? JSONSerialization.jsonObject(with: sd)) as? [String: Any],
          let files = sc["files"] as? [String: Any], let models = sc["models"] as? [String], let sessions = sc["sessions"] as? [String] else { return nil }
    var table = [String: Rate]()
    if let rd = FileManager.default.contents(atPath: dir + "usage-model-rates.json"),
       let rj = (try? JSONSerialization.jsonObject(with: rd)) as? [String: Any], let doc = rj["document"] as? [String: Any] { table = loadT3Rates(doc) }
    func look(_ m: String?) -> Rate? { guard let m = m else { return nil }; var k = m.trimmingCharacters(in: .whitespaces).lowercased(); if let b = k.firstIndex(of: "[") { k = String(k[..<b]) }; return table[k] }
    let cut = since.timeIntervalSince1970 * 1000
    var seen = Set<String>(); var out = [Req]()
    for (_, fv) in files {
        guard let fe = fv as? [String: Any], let prov = fe["p"] as? String else { continue }
        let recs = ((fe["r"] as? [[Any]]) ?? []) + ((fe["t"] as? [[Any]]) ?? [])
        for r in recs where r.count >= 11 {
            guard let ts = num(r[0]), ts >= cut, let mi = num(r[1]).map({ Int($0) }), mi < models.count else { continue }
            if let dk = r[8] as? String { let k = prov + "\u{0}" + dk; if seen.contains(k) { continue }; seen.insert(k) }
            let u = num(r[3]) ?? 0, c = num(r[4]) ?? 0, cw = num(r[5]) ?? 0, o = num(r[6]) ?? 0
            let model = models[mi]
            let rm: String? = (r.count > 11 ? num(r[11]).map { Int($0) } : nil).flatMap { $0 < models.count ? models[$0] : nil }
            var cost = 0.0
            if let rate = look(rm) ?? look(model) {
                let sp = num(r[10]).map { Int($0) } ?? 0
                let prompt = u + c + cw
                let tier = rate.tiers.first { prompt > $0.th }?.r
                let rr: Rt
                if sp == 0 { rr = (tier ?? rate).std }
                else { let pick: (Rate) -> Rt? = { sp == 1 ? $0.fast : $0.ultra }; rr = (tier.flatMap(pick)) ?? pick(rate) ?? (tier ?? rate).std }
                let one = min(r.count > 13 ? (num(r[13]) ?? 0) : 0, cw)
                cost = u * rr.i + c * rr.cr + (cw - one) * rr.cc + one * rr.c1 + o * rr.o
            } else if let rc = num(r[9]) { cost = rc }
            let si = num(r[2]).map { Int($0) } ?? -1
            out.append(Req(date: Date(timeIntervalSince1970: ts / 1000), prov: groupName(prov), model: model, inp: u, out: o, cw: cw, cr: c, cost: cost, session: si >= 0 && si < sessions.count ? sessions[si] : ""))
        }
    }
    return out
}
func fmtTok(_ v: Double) -> String {
    if v >= 1e9 { return String(format: "%.2fB", v / 1e9) }; if v >= 1e6 { return String(format: "%.1fM", v / 1e6) }
    if v >= 1e3 { return String(format: "%.1fK", v / 1e3) }; return String(format: "%.0f", v)
}
func fmtCost(_ v: Double) -> String { let n = NumberFormatter(); n.numberStyle = .decimal; n.minimumFractionDigits = 2; n.maximumFractionDigits = 2; return curSym + (n.string(from: NSNumber(value: useCny ? v * usdToCny : v)) ?? "0") }

struct Agg: Identifiable { var id: String { name }; var name: String; var tokens = 0.0; var cost = 0.0; var sessions = Set<String>() }
struct DayPt: Identifiable { var id: String { "\(date.timeIntervalSince1970)\(prov)" }; var date: Date; var prov: String; var cost: Double; var tokens: Double }
struct ModelRow: Identifiable { var id: String { model }; var model: String; var prov: String; var cost = 0.0; var tokens = 0.0 }

final class DetailModel: ObservableObject {
    @Published var range = 2 { didSet { load() } }
    @Published var metric = 0
    @Published var loading = false
    @Published var error: String?
    @Published var byProv: [Agg] = []; @Published var daily: [DayPt] = []; @Published var models: [ModelRow] = []
    @Published var tot = (inp: 0.0, out: 0.0, cw: 0.0, cr: 0.0, cost: 0.0, sessions: 0)
    let ranges: [(String, String, String)] = [("过去 24 小时", "--last", "24h"), ("7 天", "--days", "7"), ("30 天", "--days", "30"), ("90 天", "--days", "90")]
    func load() {
        loading = true; error = nil
        let r = ranges[range]
        let secs: Double = r.1 == "--last" ? 86400 : (Double(r.2) ?? 30) * 86400
        DispatchQueue.global().async {
            let reqs = loadT3Requests(since: Date().addingTimeInterval(-secs))
            DispatchQueue.main.async {
                if let reqs = reqs { self.compute(reqs) } else { self.error = "读不到 T3 Code 的用量数据：请先打开一次 T3 Code 的「用量」页。" }
                self.loading = false
            }
        }
    }
    func compute(_ reqs: [Req]) {
        var agg = [String: Agg](), mod = [String: ModelRow](), day = [String: DayPt]()
        var t = (inp: 0.0, out: 0.0, cw: 0.0, cr: 0.0, cost: 0.0, sessions: Set<String>())
        let cal = Calendar.current, hourly = range == 0
        for q in reqs {
            var a = agg[q.prov] ?? Agg(name: q.prov); a.tokens += q.tokens; a.cost += q.cost; a.sessions.insert(q.session); agg[q.prov] = a
            var m = mod[q.model] ?? ModelRow(model: q.model, prov: q.prov); m.tokens += q.tokens; m.cost += q.cost; mod[q.model] = m
            let d = hourly ? cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: q.date))! : cal.startOfDay(for: q.date)
            let k = "\(d.timeIntervalSince1970)|\(q.prov)"
            var x = day[k] ?? DayPt(date: d, prov: q.prov, cost: 0, tokens: 0); x.cost += q.cost; x.tokens += q.tokens; day[k] = x
            t.inp += q.inp; t.out += q.out; t.cw += q.cw; t.cr += q.cr; t.cost += q.cost; t.sessions.insert(q.session)
        }
        byProv = provNames.compactMap { agg[$0] }.filter { $0.tokens > 0 || $0.cost > 0 }
        models = Array(mod.values); daily = Array(day.values).sorted { $0.date < $1.date }
        tot = (t.inp, t.out, t.cw, t.cr, t.cost, t.sessions.count)
    }
}

struct DetailView: View {
    @ObservedObject var m: DetailModel; @ObservedObject var s: Store
    var useCost: Bool { m.metric == 0 }
    func val(_ a: Agg) -> Double { useCost ? a.cost : a.tokens }
    var total: Double { useCost ? m.tot.cost : m.tot.inp + m.tot.out + m.tot.cw + m.tot.cr }
    func fmt(_ v: Double) -> String { useCost ? fmtCost(v) : fmtTok(v) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("用量").font(.system(size: 15, weight: .semibold))
                Spacer()
                if m.metric != 2 { Seg(items: m.ranges.map { $0.0 }, sel: Binding(get: { m.range }, set: { m.range = $0 })).frame(width: 330) }
                Seg(items: ["费用", "token", "限制"], sel: Binding(get: { m.metric }, set: { m.metric = $0 })).frame(width: 170)
                IconBtn(name: "arrow.clockwise") { m.load(); s.reload() }
            }.padding(.horizontal, 22).padding(.vertical, 12)
            Divider()
            ScrollView { if m.metric == 2 { limits } else { usage }  }
        }.frame(minWidth: 900, minHeight: 640).background(Color(nsColor: .windowBackgroundColor))
    }
    var limits: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(s.provs) { p in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) { Circle().fill(provColor(p)).frame(width: 8, height: 8); Text(p.name).font(.system(size: 13, weight: .semibold)) }
                    Card { if p.wins.isEmpty { Text("没读到（T3 Code 没开或没登录）").font(.system(size: 12)).foregroundColor(.secondary) }
                        ForEach(p.wins) { w in WinRow(w: w, p: p) } }
                }
            }
        }.padding(.vertical, 22).frame(maxWidth: 700).frame(maxWidth: .infinity)
    }
    var usage: some View {
        VStack(alignment: .leading, spacing: 26) {
            if let e = m.error { Text(e).foregroundColor(.secondary) }
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(fmt(total)).font(.system(size: 40, weight: .bold)).monospacedDigit()
                    Text("\(m.tot.sessions) 个会话" + (useCost ? " · API 估算" : "") + (m.loading ? " · 读取中…" : "")).font(.system(size: 12)).foregroundColor(.secondary)
                    ForEach(m.byProv) { a in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Circle().fill(gColor(a.name)).frame(width: 8, height: 8); Text(a.name).font(.system(size: 14, weight: .medium))
                                Text("\(a.sessions.count) 个会话").font(.system(size: 11)).foregroundColor(.secondary); Spacer()
                                Text(fmt(val(a))).font(.system(size: 14, weight: .semibold)).monospacedDigit() }
                            Text(String(format: "占%@的 %.1f%% · ", useCost ? "费用" : " token", total > 0 ? val(a) / total * 100 : 0) + (useCost ? fmtTok(a.tokens) + " token" : fmtCost(a.cost)))
                                .font(.system(size: 11)).foregroundColor(.secondary).padding(.leading, 14)
                        }
                    }
                }.frame(width: 330, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text(useCost ? "每天费用" : "每天处理的 token").font(.system(size: 13, weight: .semibold))
                    chart
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("总计").font(.system(size: 14, weight: .semibold))
                HStack { stat("处理的 token", fmtTok(m.tot.inp + m.tot.out + m.tot.cw + m.tot.cr)); stat("缓存读取", fmtTok(m.tot.cr)); stat("未缓存输入", fmtTok(m.tot.inp)); stat("缓存写入", fmtTok(m.tot.cw)); stat("输出", fmtTok(m.tot.out)) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("明细（按模型）").font(.system(size: 14, weight: .semibold))
                HStack { Text("#").frame(width: 24, alignment: .leading); Text("模型"); Spacer(); Text("费用").frame(width: 100, alignment: .trailing); Text("占比").frame(width: 60, alignment: .trailing); Text("token").frame(width: 80, alignment: .trailing) }
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Divider()
                let rows = m.models.sorted { (useCost ? $0.cost > $1.cost : $0.tokens > $1.tokens) }.prefix(12)
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    HStack { Text("\(i + 1)").frame(width: 24, alignment: .leading).foregroundColor(.secondary)
                        Circle().fill(gColor(r.prov)).frame(width: 7, height: 7); Text(r.model).lineLimit(1); Spacer()
                        Text(r.cost > 0 ? fmtCost(r.cost) : "–").frame(width: 100, alignment: .trailing)
                        Text(String(format: "%.1f%%", (useCost ? (m.tot.cost > 0 ? r.cost / m.tot.cost : 0) : (total > 0 ? r.tokens / total : 0)) * 100)).frame(width: 60, alignment: .trailing).foregroundColor(.secondary)
                        Text(fmtTok(r.tokens)).frame(width: 80, alignment: .trailing) }.font(.system(size: 12)).monospacedDigit()
                }
            }
        }.padding(.horizontal, 36).padding(.vertical, 24)
    }
    func stat(_ t: String, _ v: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(t).font(.system(size: 11)).foregroundColor(.secondary); Text(v).font(.system(size: 18, weight: .semibold)).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading) }
    var chart: some View {
        let names = provNames.filter { n in m.daily.contains { $0.prov == n } }
        return Chart(m.daily) { p in
            BarMark(x: .value("时间", p.date, unit: m.range == 0 ? .hour : .day), y: .value("值", useCost ? p.cost : p.tokens)).foregroundStyle(by: .value("来源", p.prov))
        }
        .chartForegroundStyleScale(domain: names, range: names.map { gColor($0) })
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(useCost ? (useCny ? "¥" : "$") + String(format: "%.0f", useCny ? d * usdToCny : d) : fmtTok(d)).font(.system(size: 10)) } } } }
        .chartLegend(position: .bottom, alignment: .leading).frame(height: 250)
    }
}

// MARK: 菜单栏
class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let store = Store()
    let popover = NSPopover()
    var timer: Timer?
    let detail = DetailModel()
    var detailWin: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        popover.behavior = .transient; popover.animates = !reduceMotion
        let hc = NSHostingController(rootView: Root(s: store)); hc.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hc
        item.autosaveName = "usagebar"; item.button?.target = self; item.button?.action = #selector(toggle)
        store.openDetail = { [weak self] in self?.openDetail() }
        if let i = CommandLine.arguments.firstIndex(of: "--metric"), i + 1 < CommandLine.arguments.count { detail.metric = Int(CommandLine.arguments[i + 1]) ?? 0 }
        store.onChange = { [weak self] in self?.updateTitle(); self?.restartTimer() }
        store.reload(); store.loadCost(); updateTitle(); restartTimer()
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { // 等花费读完
                for (pg, pn, cm) in [(0, "main_min", true), (0, "main_full", false), (1, "manage", true)] { for (ap, an) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                    self.store.compact = cm
                    NSAppearance(named: ap)!.performAsCurrentDrawingAppearance {
                        let r = ImageRenderer(content: Root(s: self.store, page: pg).environment(\.colorScheme, ap == .darkAqua ? .dark : .light)); r.scale = 2
                        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: dir + "/\(pn)_\(an).png"))
                        }
                    }
                } }
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--detail") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openDetail() } }
        if CommandLine.arguments.contains("--popover") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.toggle() } }
    }
    func openDetail() {
        popover.performClose(nil)
        if detailWin == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "用量"; w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: DetailView(m: detail, s: store))
            w.setContentSize(NSSize(width: 960, height: 720)); w.center(); detailWin = w
        }
        detail.load(); store.reload()
        detailWin?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func toggle() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil) } else {
            store.reload(); store.loadCost(); updateTitle(); store.openTick += 1
            if !reduceMotion { store.rise = false } // 先归零，面板弹出后再涨上去
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY); NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in self?.store.rise = true }
            // 保险：万一这一步没生效，1 秒后直接显示真实数字，绝不停在 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in if self?.store.rise == false { self?.store.rise = true } }
        }
    }
    func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: store.interval, repeats: true) { [weak self] _ in
            self?.store.reload(); if self?.store.barMode == 3 { self?.store.loadCost() }; self?.updateTitle()
        }
    }
    func updateTitle() {
        guard let b = item.button else { return }
        let t = store.barTitle()
        b.image = tokenIcon(); b.imagePosition = t.length == 0 ? .imageOnly : .imageLeft
        b.attributedTitle = t; b.imageHugsTitle = true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let d = App(); app.delegate = d
app.run()
