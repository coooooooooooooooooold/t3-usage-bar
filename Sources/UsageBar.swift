import Cocoa
import SwiftUI
import Charts
import UniformTypeIdentifiers

// 读 T3 Code 的缓存 ~/.t3/caches/*.json 里的 usageLimits，在菜单栏显示各家额度。
// 2026-11-25 改版：参考 Cindy 的托盘面板——顶上一句结论、能用余量（5 小时和 1 周取小）、
// 用完预测、打开时进度条依次涨起、管理页（拖动排序、菜单栏预览、快见底通知、隐藏个人信息、币种）。
// 不读任何账号凭证，不联网；只读 T3 Code 的本地缓存。

struct Win: Identifiable { var id: String { label }; var label: String; var kind: String; var used: Double; var resets: Date? }
struct Prov: Identifiable { var id: String { file }; var short: String; var name: String; var file: String; var wins: [Win] = []; var checked: Date?; var plan = ""; var email = ""; var display = "" }

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
    p.display = (root["displayName"] as? String) ?? ""
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
/// 同一家有好几个账号时靠名字区分：先用你在管理页改的名字，没有就用 T3 里的账号名（比如「Claude · cc5」「Gemini · C1」）
func familyName(_ p: Prov) -> String {
    switch p.short.prefix(2) { case "Cl": return "Claude"; case "Cx": return "Codex"; case "Gk": return "Grok"; case "Ag": return "Gemini"; default: return p.name }
}
func autoName(_ p: Prov) -> String {
    let fam = familyName(p)
    var suf = p.display
    for w in [fam, "Antigravity", "Claude", "Codex", "Grok", "Gemini"] { suf = suf.replacingOccurrences(of: w, with: "", options: .caseInsensitive) }
    suf = suf.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "·-_")))
    if !suf.isEmpty { return fam + " · " + suf }
    let n = p.name.filter(\.isNumber)
    return n.isEmpty ? fam : fam + " " + n
}
func shown(_ p: Prov) -> String {
    let a = ((ud.dictionary(forKey: "aliases") as? [String: String]) ?? [:])[p.file]?.trimmingCharacters(in: .whitespaces) ?? ""
    return a.isEmpty ? autoName(p) : a
}

// MARK: 各家 logo（取自 T3 Code 的开源素材，MIT 许可）
func logoKey(_ group: String) -> String {
    switch group { case "Claude": return "claude"; case "Codex": return "openai"; case "Grok": return "grok"; default: return "gemini" }
}
var logoCache: [String: NSImage] = [:]
func logoImage(_ key: String) -> NSImage? {
    if let c = logoCache[key] { return c }
    var dirs: [URL] = []
    if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("logos")) }
    dirs.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("logos"))
    for d in dirs { for ext in ["svg", "png"] {
        if let im = NSImage(contentsOf: d.appendingPathComponent(key + "." + ext)), im.isValid {
            im.isTemplate = key == "openai" || key == "grok" // 黑色单色 logo 跟着深浅色变
            logoCache[key] = im; return im
        }
    } }
    return nil
}
struct BrandLogo: View {
    let group: String; var size: CGFloat = 14
    var body: some View {
        if let im = logoImage(logoKey(group)) {
            Image(nsImage: im).resizable().renderingMode(im.isTemplate ? .template : .original).interpolation(.high)
                .aspectRatio(contentMode: .fit).foregroundColor(.primary).frame(width: size, height: size)
        } else {
            Image(systemName: "circle.fill").font(.system(size: size * 0.6)).foregroundColor(gColor(group)).frame(width: size, height: size)
        }
    }
}
extension View {
    /// 面板里统一的白色圆角块
    func tileBG(_ r: CGFloat = 14) -> some View {
        background(RoundedRectangle(cornerRadius: r).fill(tileFill)).overlay(RoundedRectangle(cornerRadius: r).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}
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
    var todayTok = 0.0; var weekTok = 0.0; var dailyTok = [Double](repeating: 0, count: 14)
    var byGroup: [String: [Double]] = [:] } // 每家：[今天花费, 7 天花费, 今天 token, 7 天 token]

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
    /// 主面板三大块的顺序：list 各家列表 / summary 结论卡 / cost 花费卡，可拖动，记住
    @Published var sections: [String] { didSet { ud.set(sections, forKey: "sections") } }
    @Published var aliases: [String: String] { didSet { ud.set(aliases, forKey: "aliases"); onChange?() } } // 你给每个账号起的名字
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
        aliases = (ud.dictionary(forKey: "aliases") as? [String: String]) ?? [:]
        let sec = ud.stringArray(forKey: "sections") ?? []
        sections = Set(sec) == Set(["list", "summary", "cost"]) && sec.count == 3 ? sec : ["list", "summary", "cost"]
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
    func moveSection(_ d: String, onto t: String) {
        var arr = sections
        guard let from = arr.firstIndex(of: d), let to = arr.firstIndex(of: t), from != to else { return }
        arr.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        sections = arr
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
        if isDemo { let d = [6, 9, 7, 14, 11, 8, 12, 15, 10, 13, 19, 12, 16, 18.42]; cost = CostSum(today: 18.42, week: 96.30, daily: d, ok: true, todayTok: 24.6e6, weekTok: 131e6, dailyTok: d.map { $0 * 1.34e6 }, byGroup: ["Claude": [8.1, 41.2, 9.8e6, 52e6], "Codex": [6.3, 30.5, 8.1e6, 44e6], "Grok": [0.4, 2.2, 0.6e6, 3e6], "Antigravity": [3.6, 22.4, 6.1e6, 32e6]]); return }
        DispatchQueue.global(qos: .utility).async {
            let cal = Calendar.current, start = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: Date()))!
            guard let reqs = loadT3Summary(since: start, hourly: false) ?? loadT3Requests(since: start) else { return }
            var days = [Double](repeating: 0, count: 14), toks = [Double](repeating: 0, count: 14), groups = [String: [Double]]()
            for q in reqs {
                let d = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: q.date)).day ?? -1
                guard d >= 0 && d < 14 else { continue }
                days[d] += q.cost; toks[d] += q.tokens
                if d >= 7 { var g = groups[q.prov] ?? [0, 0, 0, 0]; g[1] += q.cost; g[3] += q.tokens; if d == 13 { g[0] += q.cost; g[2] += q.tokens }; groups[q.prov] = g }
            }
            DispatchQueue.main.async {
                self.cost = CostSum(today: days[13], week: days[7...].reduce(0, +), daily: days, ok: true, todayTok: toks[13], weekTok: toks[7...].reduce(0, +), dailyTok: toks, byGroup: groups)
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
    // T3 已经开着就不碰它：再发「打开」会把 T3 窗口顶到前面，菜单栏面板跟着收起
    if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.t3tools.t3code").isEmpty { return }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "-a", "T3 Code (Beta)"]; try? p.run()
}

// MARK: 让 T3 立刻重查额度
// T3 只在自己界面在前台时才每 5 分钟查一次。这里走 T3 官方的会话令牌：
// 用 T3 自带的 `t3 auth session issue` 发一个只读令牌（orchestration:read，30 天），存在本机（只有自己能读），
// 再用它换一次性连接票，连 T3 本机服务调 server.refreshProviders。全程只连本机，不读任何 AI 账号的凭证。
final class Box<T> { var v: T; init(_ v: T) { self.v = v } }
enum T3Refresh {
    static let bundleId = "com.t3tools.t3code"
    static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty }
    static var tokenURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(agentLabel, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("t3-session")
    }
    static func cli() -> String? {
        ["~/.t3/bin/t3", "~/.local/bin/t3", "/opt/homebrew/bin/t3", "/usr/local/bin/t3"].map { ($0 as NSString).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    /// 发一个新的只读令牌并存起来
    static func issue() -> String? {
        guard let c = cli() else { return nil }
        let p = Process(); p.executableURL = URL(fileURLWithPath: c)
        p.arguments = ["auth", "session", "issue", "--scope", "orchestration:read", "--scope", "diagnostics:read", "--label", "用量菜单栏（只读：刷新额度、读用量）", "--ttl", "30d", "--token-only"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let tok = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, !tok.isEmpty, !tok.contains(" "), !tok.contains("\n") else { return nil }
        try? FileManager.default.removeItem(at: tokenURL)
        FileManager.default.createFile(atPath: tokenURL.path, contents: Data(tok.utf8), attributes: [.posixPermissions: 0o600])
        return tok
    }
    static func saved() -> String? {
        let s = (try? String(contentsOf: tokenURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }
    /// T3 本机服务的地址（server-runtime.json 里的 origin 或 host+port）
    static func base() -> URL? {
        guard let d = FileManager.default.contents(atPath: NSHomeDirectory() + "/.t3/userdata/server-runtime.json"),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        if let o = j["origin"] as? String, let u = URL(string: o) { return u }
        if let port = (j["port"] as? NSNumber)?.intValue { return URL(string: "http://\((j["host"] as? String) ?? "127.0.0.1"):\(port)") }
        return nil
    }
    static func ticket(_ base: URL, _ tok: String) -> (String?, Int) {
        var req = URLRequest(url: base.appendingPathComponent("api/auth/websocket-ticket/rpc"), timeoutInterval: 8)
        req.httpMethod = "POST"; req.setValue("Bearer " + tok, forHTTPHeaderField: "Authorization")
        let sem = DispatchSemaphore(value: 0); let res = Box<(String?, Int)>((nil, 0))
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let t = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["ticket"] as? String
            res.v = (code == 200 ? t : nil, code); sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        return res.v
    }
    /// 同步调一次 T3 的本机接口（在后台线程用）。返回 (成功时的结果, 失败时给人看的一句话)
    /// 令牌过期或权限不够会自动换新令牌再试一次。
    static func call(_ tag: String, _ payload: [String: Any], timeout: Double = 60) -> (Any?, String?) {
        guard let b = base() else { return (nil, "T3 没开") }
        guard var tok = saved() ?? issue() else { return (nil, "没找到 t3 命令") }
        for attempt in 0..<2 {
            var (tk, code) = ticket(b, tok)
            if tk == nil, code == 401 || code == 403, let fresh = issue() { tok = fresh; (tk, code) = ticket(b, tok) }
            guard let tkt = tk else { return (nil, code == 0 ? "连不上 T3" : "T3 拒绝了请求（\(code)）") }
            guard var comps = URLComponents(url: b.appendingPathComponent("ws"), resolvingAgainstBaseURL: false) else { return (nil, "T3 地址不对") }
            comps.scheme = comps.scheme == "https" ? "wss" : "ws"
            comps.queryItems = [URLQueryItem(name: "wsTicket", value: tkt), URLQueryItem(name: "orchestrationProtocol", value: "2")]
            guard let url = comps.url,
                  let body = try? JSONSerialization.data(withJSONObject: ["_tag": "Request", "id": "1", "tag": tag, "payload": payload, "headers": [Any]()]) else { return (nil, "请求没拼好") }
            let task = URLSession.shared.webSocketTask(with: url); task.maximumMessageSize = 64 << 20; task.resume()
            let sem = DispatchSemaphore(value: 0), exitObj = Box<[String: Any]?>(nil), fail = Box<String?>(nil)
            task.send(.string(String(decoding: body, as: UTF8.self))) { err in if err != nil { fail.v = "连不上 T3"; sem.signal() } }
            func listen() {
                task.receive { r in
                    switch r {
                    case .failure: if fail.v == nil { fail.v = "T3 连接断了" }; sem.signal()
                    case .success(let m):
                        var d = Data()
                        if case .string(let x) = m { d = Data(x.utf8) } else if case .data(let x) = m { d = x }
                        let any = try? JSONSerialization.jsonObject(with: d)
                        let items = (any as? [[String: Any]]) ?? ((any as? [String: Any]).map { [$0] } ?? [])
                        if let e = items.first(where: { ($0["_tag"] as? String) == "Exit" }) { exitObj.v = e; sem.signal() } else { listen() }
                    @unknown default: sem.signal()
                    }
                }
            }
            listen()
            let timedOut = sem.wait(timeout: .now() + timeout) == .timedOut
            task.cancel(with: .normalClosure, reason: nil)
            if timedOut { return (nil, "T3 没回应，稍后再试") }
            if let f = fail.v { return (nil, f) }
            guard let ex = exitObj.v?["exit"] as? [String: Any] else { return (nil, "T3 回的东西看不懂") }
            if (ex["_tag"] as? String) == "Success" { return (ex["value"] ?? [String: Any](), nil) }
            let why = String(describing: ex["cause"] ?? "")
            if attempt == 0, why.localizedCaseInsensitiveContains("scope") || why.contains("Authorization"), let fresh = issue() { tok = fresh; continue } // 旧令牌权限不够：换一个再试
            return (nil, "T3 回复失败")
        }
        return (nil, "T3 回复失败")
    }
    /// 在后台让 T3 重查额度，结果回到主线程：(成功没有, 失败时给人看的一句话)
    static func run(_ done: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (v, err) = call("server.refreshProviders", [:], timeout: 30)
            DispatchQueue.main.async { done(v != nil, err) }
        }
    }
}

/// 问 T3 要用量汇总（和 T3 自己的「用量」页同一份数据，含 Gemini）。T3 没开或失败时返回 nil
func loadT3Summary(since: Date, hourly: Bool) -> [Req]? {
    guard T3Refresh.running else { return nil }
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
    let isoF = ISO8601DateFormatter()
    var payload: [String: Any] = ["sinceDay": df.string(from: since), "untilDay": df.string(from: Date()), "timeZone": TimeZone.current.identifier]
    if hourly { payload["resolution"] = "hour"; payload["sinceTime"] = isoF.string(from: since); payload["untilTime"] = isoF.string(from: Date()) }
    guard let v = T3Refresh.call("server.getUsageSummary", payload, timeout: 90).0 as? [String: Any],
          let buckets = v["buckets"] as? [[String: Any]] else { return nil }
    var out = [Req]()
    for b in buckets {
        let date: Date? = (b["hourStart"] as? String).flatMap { parseDate($0) } ?? (b["day"] as? String).flatMap { df.date(from: $0) }
        guard let d = date, let t = b["totals"] as? [String: Any] else { continue }
        func n(_ k: String) -> Double { (t[k] as? NSNumber)?.doubleValue ?? 0 }
        var q = Req(date: d, prov: groupName((b["provider"] as? String) ?? ""), model: (b["model"] as? String) ?? "?",
                    inp: n("uncachedInputTokens"), out: n("outputTokens"), cw: n("cacheCreationTokens"), cr: n("cachedInputTokens"),
                    cost: (b["costUsd"] as? NSNumber)?.doubleValue ?? 0, session: "")
        q.nSess = (b["sessions"] as? NSNumber)?.intValue ?? 0
        out.append(q)
    }
    return out
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
    var mark: Double? = nil          // 时间竖线：窗口时间过了多少（0~1）；条比它短就是用太快
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
                if let m = mark {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.7)).frame(width: 2, height: h + 6)
                        .offset(x: max(0, min(g.size.width - 2, g.size.width * CGFloat(m) - 1)))
                }
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
                Text(stale ? "已重置，等 T3 重新查" : (exhaustETA(w).map { "照这速度 " + whenText($0) + " 用完 · " } ?? "") + resetText(w.resets))
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

// MARK: 主面板（圆环改版）
// 顶栏：左上角样式图标（线框 = 极简，立体 = 正常）+ 刷新。
// 极简：一排五家圆环 + 底部一行花费。正常：圆环最前面多一个「总览」，下面是总览列表或某一家的详情。
func provGroup(_ p: Prov) -> String {
    switch p.short.prefix(2) { case "Cl": return "Claude"; case "Cx": return "Codex"; case "Gk": return "Grok"; default: return "Antigravity" }
}
func provGlyph(_ p: Prov) -> String {
    switch p.short.prefix(2) { case "Cl": return "asterisk"; case "Cx": return "hexagon"; case "Gk": return "xmark"; default: return "sparkle" }
}
/// 这个窗口的时间已经过去多少（0~1）：圆环外圈的「窗口时钟」和进度条上的时间竖线都用它
func elapsedFrac(_ w: Win?) -> Double? {
    guard let w = w, let r = w.resets, r > Date() else { return nil }
    let len: Double = w.kind == "weekly" ? 7 * 86400 : 5 * 3600
    return max(0, min(1, 1 - r.timeIntervalSinceNow / len))
}
/// 重置时刻的短写法：今天的写「23:10 重置」，别的天写「周一 10:03」
func resetShort(_ d: Date?) -> String {
    guard let d = d else { return "" }
    let s = whenText(d)
    return s.hasPrefix("今天 ") ? String(s.dropFirst(3)) + " 重置" : s
}

struct Ring: View {
    let pct: Int?; let color: Color; let group: String; let clock: Double?; let rise: Bool; let delay: Double
    var body: some View {
        let v = rise ? Double(pct ?? 0) / 100 : 0
        ZStack {
            if let c = clock { // 外圈细线：窗口时间过了多少
                Circle().trim(from: 0, to: rise ? c : 0).stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 40, height: 40)
            }
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 3.5).frame(width: 32, height: 32)
            Circle().trim(from: 0, to: v).stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 32, height: 32)
            BrandLogo(group: group, size: 14)
        }
        .frame(width: 42, height: 42)
        .animation(motion(Animation.qRise.delay(rise ? delay : 0)), value: rise)
        .animation(motion(.qRise), value: pct)
    }
}

struct RingStrip: View {
    @ObservedObject var s: Store; let showOverview: Bool; let focus: String?; let rise: Bool; let pick: (String?) -> Void
    var body: some View {
        HStack(spacing: 0) {
            if showOverview {
                cell(selected: focus == nil, help: "总览：每家一行") {
                    ZStack {
                        Circle().stroke(focus == nil ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.1), lineWidth: 3.5).frame(width: 32, height: 32)
                        Image(systemName: "square.grid.2x2").font(.system(size: 11.5, weight: .semibold)).foregroundColor(focus == nil ? .accentColor : .secondary)
                    }.frame(width: 42, height: 42)
                } label: { Text("总览").foregroundColor(focus == nil ? .accentColor : .secondary) } action: { pick(nil) }
            }
            ForEach(Array(s.visible.enumerated()), id: \.element.id) { i, p in
                let eff = effLeft(p), w = bindingWin(p)
                cell(selected: showOverview && focus == p.file, help: shown(p) + (eff.map { "：能用 \($0)%" } ?? "：没读到")) {
                    Ring(pct: eff, color: eff.map { barTint($0, p) } ?? .clear, group: provGroup(p), clock: elapsedFrac(w), rise: rise, delay: Double(i) * 0.06)
                } label: {
                    Text(eff == nil ? "–" : "\(s.showUsed ? 100 - (eff ?? 0) : (eff ?? 0))%").foregroundColor(levelColor(eff)).monospacedDigit()
                } action: { pick(p.file) }
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 6).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(tileFill))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
    func cell<R: View, L: View>(selected: Bool, help: String, @ViewBuilder ring: () -> R, @ViewBuilder label: () -> L, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) { ring(); label().font(.system(size: 11, weight: .semibold)) }
                .padding(.vertical, 4).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }.buttonStyle(PressStyle(scale: 0.92)).help(help)
    }
}

/// 总览里的一行：图标、名字、重置时刻、能用多少，下面一条带时间竖线的进度条
struct OverviewRow: View {
    let p: Prov; let i: Int; let rise: Bool; let best: Bool; let showUsed: Bool
    @State private var hover = false
    var body: some View {
        let eff = effLeft(p), w = bindingWin(p), shownEff = rise ? (eff ?? 0) : 0
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                BrandLogo(group: provGroup(p), size: 14).frame(width: 16)
                Text(shown(p)).font(.system(size: 13, weight: best ? .semibold : .medium)).lineLimit(1).fixedSize()
                StaleClock(p: p)
                if exhaustETA(w) != nil { Image(systemName: "hourglass").font(.system(size: 9.5, weight: .semibold)).foregroundColor(.orange).help("照这速度会在重置前用完") }
                Spacer(minLength: 6)
                Text(p.wins.isEmpty ? "没读到" : (w == nil ? "已重置" : resetShort(w?.resets))).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                Text(eff == nil ? "–" : "\(showUsed ? 100 - shownEff : shownEff)%")
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit().foregroundColor(levelColor(eff))
                    .contentTransition(.numericText(value: Double(shownEff)))
                    .animation(motion(Animation.qRise.delay(rise ? Double(i) * 0.06 : 0)), value: rise)
                    .frame(width: 42, alignment: .trailing)
            }
            Bar(pct: shownEff, color: eff.map { barTint($0, p) } ?? .clear, h: 5, glow: best, mark: elapsedFrac(w))
                .animation(motion(Animation.qRise.delay(rise ? Double(i) * 0.06 : 0)), value: rise)
                .animation(motion(.qRise), value: eff)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.primary.opacity(hover ? 0.035 : 0))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(motion(.easeOut(duration: 0.2))) { hover = h } }
    }
}

/// 单家详情：两个窗口分开写、用完预测、这家自己的花费
struct ProvDetail: View {
    @ObservedObject var s: Store; let p: Prov
    var body: some View {
        let (a, b) = pickWins(p), w = bindingWin(p)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                BrandLogo(group: provGroup(p), size: 16)
                Text(shown(p)).font(.system(size: 15, weight: .semibold))
                StaleClock(p: p)
                Spacer(minLength: 6)
                Text([p.plan, p.checked.map { agoText($0) + "查的" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            if p.wins.isEmpty { Text("没读到这家的额度：T3 Code 没开，或没登录这个账号").font(.system(size: 12)).foregroundColor(.secondary) }
            ForEach(Array([a, b].compactMap { $0 }.enumerated()), id: \.offset) { _, x in block(x) }
            if let e = exhaustETA(w) {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass").font(.system(size: 10.5, weight: .semibold))
                    Text("照这速度，\(whenText(e)) 会用完\(kindName(w!))额度")
                }.font(.system(size: 11.5)).foregroundColor(.orange)
                .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
            Divider()
            HStack(spacing: 6) {
                let g = provGroup(p), c = s.cost.byGroup[g]
                if !(c == nil && g == "Antigravity") { Text((g == "Antigravity" ? "Gemini 合计" : g) + " 今天").foregroundColor(.secondary) }
                if c == nil && g == "Antigravity" { Text("T3 没有记录 Gemini 的花费").foregroundColor(.secondary) }
                else {
                    Text(c.map { s.spend($0[0], $0[2]) } ?? "–").fontWeight(.semibold).monospacedDigit()
                    Text("· 7 天 " + (c.map { s.spend($0[1], $0[3]) } ?? "–")).foregroundColor(.secondary).monospacedDigit()
                }
                Spacer()
            }.font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(tileFill))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
    @ViewBuilder func block(_ x: Win) -> some View {
        let l = left(x)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(kindName(x)).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(l.map { "剩 \(s.showUsed ? 100 - $0 : $0)%".replacingOccurrences(of: "剩", with: s.showUsed ? "用了" : "剩") } ?? "已重置").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundColor(levelColor(l))
            }
            Bar(pct: l ?? 0, color: l.map { barTint($0, p) } ?? .clear, h: 6, mark: elapsedFrac(x))
            Text(l == nil ? "\(resetShort(x.resets)) 已过，等 T3 重新查" : (x.resets.map { whenText($0) + " 重置 · 还有 " + countdown($0) } ?? "还没开始计时"))
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
}

struct MainPage: View {
    @ObservedObject var s: Store; @Binding var page: Int
    @State var spins = 0.0
    @State var busy = false          // 正在让 T3 重查
    @State var note: String?         // 刷新结果的一句话，几秒后消失
    @State var dragging: String?
    @State var reveal = 1.0          // 下面内容的显隐：1 = 拉下来，0 = 收起
    @State var switching = false
    @State var modeSel = -1          // 点图标后，图标先变，内容随后再换
    @State var focus: String? = CommandLine.arguments.firstIndex(of: "--focus").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } // nil = 总览
    var rise: Bool { s.rise }
    var body: some View {
        let best = s.visible.compactMap { p in effLeft(p).map { (p, $0) } }.max { $0.1 < $1.1 }?.0.file
        VStack(alignment: .leading, spacing: 0) {
            // 顶栏：两种样式一模一样，切换时完全不动
            HStack(spacing: 8) {
                Button {
                    withAnimation(motion(.qSpring)) { modeSel = s.compact ? 1 : 0 }
                    switchMode()
                } label: { ModeIcon(raised: modeSel < 0 ? !s.compact : modeSel == 1).contentShape(Circle()) }
                .buttonStyle(PressStyle(scale: 0.86)).modifier(Lift(by: 1))
                .help(s.compact ? "点一下：展开成正常样式" : "点一下：收成极简样式")
                Spacer()
                Button { refresh() } label: {
                    TimelineView(.animation(paused: !busy || reduceMotion)) { ctx in
                        let a = busy && !reduceMotion ? ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360 : 0
                        Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .medium)).foregroundColor(busy ? .primary : .secondary)
                            .rotationEffect(.degrees(spins * 360 + a))
                    }.frame(width: 26, height: 26).contentShape(Rectangle())
                }.buttonStyle(PressStyle(scale: 0.85)).disabled(busy)
                .help(T3Refresh.running ? "让 T3 马上重新查一遍各家额度" : "T3 没开：在后台打开它")
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)

            // 下面的内容：切换样式时先收上去，换好再拉下来
            VStack(alignment: .leading, spacing: 0) {
                RingStrip(s: s, showOverview: !s.compact, focus: focus, rise: rise) { f in pick(f) }
                    .padding(.horizontal, 14)
                if !s.compact {
                    ZStack(alignment: .top) {
                        if let f = focus, let p = s.visible.first(where: { $0.file == f }) {
                            ProvDetail(s: s, p: p).id(f).transition(.opacity.combined(with: .offset(y: 6)))
                        } else {
                            Tile {
                                if s.visible.isEmpty { Text("在「管理」里打开要显示的几家").font(.system(size: 12)).foregroundColor(.secondary).padding(16) }
                                ForEach(Array(s.visible.enumerated()), id: \.element.id) { i, p in
                                    if i > 0 { Divider().padding(.leading, 38) }
                                    OverviewRow(p: p, i: i, rise: rise, best: p.file == best, showUsed: s.showUsed)
                                        .onTapGesture { pick(p.file) }
                                        .modifier(Reorderable(file: p.file, dragging: $dragging, s: s, dim: 0.35))
                                }
                            }.transition(.opacity.combined(with: .offset(y: 6)))
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, 10)
                }
                footer
            }
            .opacity(reveal)
            .offset(y: -16 * (1 - reveal))
            .scaleEffect(x: 1, y: 0.97 + 0.03 * reveal, anchor: .top)
            .onChange(of: s.openTick) { _, _ in dragging = nil; focus = nil } // 每次点开都回到总览
        }
    }
    /// 底部一行：今天和近 7 天的花费（点开详情）、刷新结果、详情和管理两个小按钮
    var footer: some View {
        HStack(spacing: 10) {
            Button { s.openDetail?() } label: {
                HStack(spacing: 5) {
                    if let n = note { Text(n).foregroundColor(.secondary).lineLimit(1) }
                    else if busy { Text("正在让 T3 重查…").foregroundColor(.secondary) }
                    else {
                        Text("今天").foregroundColor(.secondary)
                        Text(s.cost.ok ? s.spend(s.cost.today, s.cost.todayTok) : "–").fontWeight(.semibold).monospacedDigit()
                        Text("· 7 天 " + (s.cost.ok ? s.spend(s.cost.week, s.cost.weekTok) : "–")).foregroundColor(.secondary).monospacedDigit().lineLimit(1)
                    }
                }.font(.system(size: 12)).contentShape(Rectangle())
            }.buttonStyle(.plain).help("打开用量详情")
            Spacer(minLength: 4)
            Button { s.openDetail?() } label: {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 14)).foregroundColor(.secondary).frame(width: 26, height: 26).contentShape(Rectangle())
            }.buttonStyle(PressStyle(scale: 0.88)).help("用量详情")
            Button { withAnimation(motion(.qPage)) { page = 1 } } label: {
                Image(systemName: "gearshape").font(.system(size: 14)).foregroundColor(.secondary).frame(width: 26, height: 26).contentShape(Rectangle())
            }.buttonStyle(PressStyle(scale: 0.88)).help("管理")
        }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 14)
    }
    /// 点圆环或列表行：极简样式下先展开成正常样式再打开那一家；正常样式下直接切换
    func pick(_ f: String?) {
        if s.compact {
            focus = f
            withAnimation(motion(.qSpring)) { modeSel = 1 }
            switchMode()
        } else {
            withAnimation(motion(.qMode)) { focus = (f != nil && focus == f) ? nil : f }
        }
    }
    func refresh() {
        withAnimation(motion(.qSpin)) { spins += 1 }
        s.reload(); s.loadCost(force: true)
        if !T3Refresh.running { nudgeT3(); say("已在后台打开 T3，稍等一会儿"); return }
        withAnimation(.easeOut(duration: 0.2)) { busy = true; note = nil }
        T3Refresh.run { ok, msg in
            withAnimation(.easeOut(duration: 0.2)) { busy = false }
            s.reload(); DispatchQueue.main.asyncAfter(deadline: .now() + 2) { s.reload() }
            say(ok ? "已刷新" : (msg ?? "刷新失败"))
        }
    }
    func say(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { note = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if note == text { withAnimation(.easeOut(duration: 0.3)) { note = nil } } }
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
    /// 数据旧了时顶上那句：写明是哪家旧，比如「Claude 1 小时前查的」
    var freshText: String {
        let olds = s.visible.compactMap { p in p.checked.map { (p, Int(Date().timeIntervalSince($0) / 60)) } }
        guard let o = olds.max(by: { $0.1 < $1.1 }) else { return "" }
        let n = olds.filter { $0.1 > 30 }.count
        let when = o.1 < 1 ? "刚刚" : (o.1 < 60 ? "\(o.1) 分钟前" : "\(o.1 / 60) 小时前")
        return shown(o.0) + (n > 1 ? " 等" : "") + " · " + when
    }
    /// 鼠标停在那句上：每家各是几点查的
    var freshDetail: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return s.visible.map { p in shown(p) + "：" + (p.checked.map { f.string(from: $0) + " 查的" } ?? "没读到") }.joined(separator: "\n")
            + "\n点右边刷新，T3 会马上重查（Claude 只在你用它时才更新）"
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
                    StaleClock(p: p)
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
        guard let w = bindingWin(p) else { return ("已重置，等 T3 重查", .secondary) }
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
                Text("已重置").font(.system(size: 10)).foregroundColor(.secondary).frame(width: 44, alignment: .leading)
            } else {
                Text("无此限制").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7)).frame(width: 100, alignment: .leading)
            }
        }.help(w.map { x in
            if left(x) == nil, let r = x.resets { let f = DateFormatter(); f.dateFormat = "HH:mm"; return "\(kindName(x))额度 \(f.string(from: r)) 已经重置，T3 还没重新查，现在多半是满的" }
            return niceLabel(x.label) + "：" + (left(x).map { "剩 \($0)%，" } ?? "") + resetText(x.resets)
        } ?? "")
    }
}

/// 结论卡片：第一行谁最足，下面每条提醒一行、带小图标（最多 3 条）
struct SummaryTile: View {
    let ps: [Prov]; let main: String
    var body: some View {
        let known = ps.compactMap { p in effLeft(p).map { (p, $0) } }
        let best = known.max { $0.1 < $1.1 }?.0
        var lines: [(String, String, Color)] = []
        for k in known where k.1 > 0 && k.1 < 20 { lines.append(("exclamationmark.circle.fill", "\(shown(k.0)) 快见底，剩 \(k.1)%", .red)) }
        for k in known where k.1 >= 20 { if let e = exhaustETA(bindingWin(k.0)) { lines.append(("hourglass", "\(shown(k.0)) 照这速度 \(whenText(e)) 用完", .orange)) } }
        for k in known where k.1 == 0 { if let r = bindingWin(k.0)?.resets { lines.append(("arrow.clockwise", "\(shown(k.0)) \(countdown(r))后回来", .secondary)) } }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).foregroundColor(best.map { provColor($0) } ?? .secondary).frame(width: 14)
                Text(main.replacingOccurrences(of: "。", with: "")).font(.system(size: 13, weight: .semibold)).foregroundColor(inkStrong)
            }
            ForEach(Array(lines.prefix(3).enumerated()), id: \.offset) { _, l in
                HStack(spacing: 8) {
                    Image(systemName: l.0).font(.system(size: 10.5, weight: .semibold)).foregroundColor(l.2).frame(width: 14)
                    Text(l.1).font(.system(size: 12)).foregroundColor(.primary.opacity(0.78)).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(tileFill))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

/// 这家的数据多久前查的；超过 30 分钟在名字旁放一个小钟
func agoText(_ d: Date) -> String {
    let m = Int(Date().timeIntervalSince(d) / 60)
    return m < 1 ? "刚刚" : (m < 60 ? "\(m) 分钟前" : "\(m / 60) 小时前")
}
struct StaleClock: View {
    let p: Prov
    var body: some View {
        if let c = p.checked, Date().timeIntervalSince(c) > 1800 {
            Image(systemName: "clock").font(.system(size: 9.5, weight: .medium)).foregroundColor(.secondary.opacity(0.8))
                .help("这家是\(agoText(c))查的。T3 只在你用它时才更新这家，点刷新也刷不动")
        }
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
            StaleClock(p: p)
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
        for x in [a, b].compactMap({ $0 }) { out.append(kindName(x) + "：" + (left(x).map { "剩 \($0)%，" } ?? "已重置，等 T3 重新查，") + resetText(x.resets)) }
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
            BrandLogo(group: provGroup(p), size: 16)
                .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(provColor(p).opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                // 名字可以直接改：同一家好几个账号时起个好认的名字；清空就恢复成自动的名字
                if isSnapshot { Text(shown(p)).font(.system(size: 13, weight: .semibold)).lineLimit(1) }
                else {
                    TextField(autoName(p), text: Binding(get: { s.aliases[p.file] ?? "" }, set: { v in s.aliases[p.file] = v.trimmingCharacters(in: .whitespaces).isEmpty ? nil : v }))
                        .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold)).help("点这里改名字；清空就用自动的名字")
                }
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
/// 大块拖动：用通用数据类型（不是文字），这样不会被列表里「行」的拖放接走
private func sectionProvider(_ sec: String) -> NSItemProvider {
    let p = NSItemProvider()
    p.registerDataRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .ownProcess) { done in done(Data(sec.utf8), nil); return nil }
    return p
}
struct SectionDrag: ViewModifier {
    let sec: String; @Binding var dragging: String?
    func body(content: Content) -> some View {
        if isSnapshot { content } else { content.onDrag { dragging = sec; return sectionProvider(sec) } }
    }
}
/// 列表卡片顶边的小横条：鼠标移到列表上才显出来，按住它拖整块列表
struct SectionGrip: View {
    let sec: String; @Binding var dragging: String?
    @State private var hover = false
    var body: some View {
        if !isSnapshot {
            Capsule().fill(Color.primary.opacity(hover ? 0.32 : 0.12)).frame(width: 30, height: 4)
                .frame(width: 70, height: 14).contentShape(Rectangle())
                .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
                .onDrag { dragging = sec; return sectionProvider(sec) }
                .help("按住拖动，挪整块列表")
        }
    }
}
struct SectionDrop: ViewModifier {
    let target: String; @Binding var dragging: String?; let s: Store
    func body(content: Content) -> some View {
        if isSnapshot { content } else { content.onDrop(of: [UTType.data], delegate: SectionDropDelegate(target: target, dragging: $dragging, s: s)) }
    }
}
struct SectionDropDelegate: DropDelegate {
    let target: String; @Binding var dragging: String?; let s: Store
    func dropEntered(info: DropInfo) { guard let d = dragging, d != target else { return }; withAnimation(motion(.qSpring)) { s.moveSection(d, onto: target) } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: dragging == nil ? .cancel : .move) }
    func performDrop(info: DropInfo) -> Bool { let had = dragging != nil; dragging = nil; return had }
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
struct Req { var date: Date; var prov: String; var model: String; var inp: Double; var out: Double; var cw: Double; var cr: Double; var cost: Double; var session: String; var nSess = 0
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

struct Agg: Identifiable { var id: String { name }; var name: String; var tokens = 0.0; var cost = 0.0; var sessions = Set<String>(); var sessN = 0
    var sessionCount: Int { max(sessions.subtracting([""]).count, sessN) } }
struct DayPt: Identifiable { var id: String { "\(date.timeIntervalSince1970)\(prov)" }; var date: Date; var prov: String; var cost: Double; var tokens: Double }
struct ModelRow: Identifiable { var id: String { model }; var model: String; var prov: String; var cost = 0.0; var tokens = 0.0 }

final class DetailModel: ObservableObject {
    @Published var range = 2 { didSet { load() } }
    @Published var metric = 0
    @Published var loading = false
    @Published var error: String?
    @Published var note: String?
    @Published var byProv: [Agg] = []; @Published var daily: [DayPt] = []; @Published var models: [ModelRow] = []
    @Published var tot = (inp: 0.0, out: 0.0, cw: 0.0, cr: 0.0, cost: 0.0, sessions: 0)
    let ranges: [(String, String, String)] = [("过去 24 小时", "--last", "24h"), ("7 天", "--days", "7"), ("30 天", "--days", "30"), ("90 天", "--days", "90")]
    func load() {
        loading = true; error = nil
        let r = ranges[range]
        let secs: Double = r.1 == "--last" ? 86400 : (Double(r.2) ?? 30) * 86400
        let hourly = r.1 == "--last"
        DispatchQueue.global().async {
            // 先问 T3 要汇总（含 Gemini）；T3 没开就退回读缓存文件（不含 Gemini）
            let since = hourly ? Date().addingTimeInterval(-secs) : Calendar.current.date(byAdding: .day, value: -(Int(secs / 86400) - 1), to: Calendar.current.startOfDay(for: Date()))!
            let fromT3 = loadT3Summary(since: since, hourly: hourly)
            let reqs = fromT3 ?? loadT3Requests(since: Date().addingTimeInterval(-secs))
            DispatchQueue.main.async {
                if let reqs = reqs { self.compute(reqs) } else { self.error = "读不到 T3 Code 的用量数据：请先打开一次 T3 Code。" }
                self.note = fromT3 == nil && reqs != nil ? "T3 没开：先显示缓存里的数据，不含 Gemini。打开 T3 后点右上角刷新。" : nil
                self.loading = false
            }
        }
    }
    func compute(_ reqs: [Req]) {
        var agg = [String: Agg](), mod = [String: ModelRow](), day = [String: DayPt]()
        var t = (inp: 0.0, out: 0.0, cw: 0.0, cr: 0.0, cost: 0.0, sessions: Set<String>()); var sessN = 0
        let cal = Calendar.current, hourly = range == 0
        for q in reqs {
            var a = agg[q.prov] ?? Agg(name: q.prov); a.tokens += q.tokens; a.cost += q.cost; a.sessions.insert(q.session); a.sessN += q.nSess; agg[q.prov] = a
            var m = mod[q.model] ?? ModelRow(model: q.model, prov: q.prov); m.tokens += q.tokens; m.cost += q.cost; mod[q.model] = m
            let d = hourly ? cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: q.date))! : cal.startOfDay(for: q.date)
            let k = "\(d.timeIntervalSince1970)|\(q.prov)"
            var x = day[k] ?? DayPt(date: d, prov: q.prov, cost: 0, tokens: 0); x.cost += q.cost; x.tokens += q.tokens; day[k] = x
            t.inp += q.inp; t.out += q.out; t.cw += q.cw; t.cr += q.cr; t.cost += q.cost; t.sessions.insert(q.session); sessN += q.nSess
        }
        byProv = provNames.compactMap { agg[$0] }.filter { $0.tokens > 0 || $0.cost > 0 }
        models = Array(mod.values); daily = Array(day.values).sorted { $0.date < $1.date }
        tot = (t.inp, t.out, t.cw, t.cr, t.cost, max(t.sessions.subtracting([""]).count, sessN))
        // 曲线图要每天都有点：没用的那天补 0，线才会落到底
        if !hourly, let first = daily.first?.date {
            var filled = [String: DayPt](); for x in daily { filled["\(x.date.timeIntervalSince1970)|\(x.prov)"] = x }
            let provs = Set(daily.map { $0.prov }); var d = first
            while d <= cal.startOfDay(for: Date()) {
                for pv in provs where filled["\(d.timeIntervalSince1970)|\(pv)"] == nil { filled["\(d.timeIntervalSince1970)|\(pv)"] = DayPt(date: d, prov: pv, cost: 0, tokens: 0) }
                d = cal.date(byAdding: .day, value: 1, to: d)!
            }
            daily = Array(filled.values).sorted { $0.date < $1.date }
        }
    }
}

struct DetailView: View {
    @ObservedObject var m: DetailModel; @ObservedObject var s: Store
    @State private var spins = 0.0
    var useCost: Bool { m.metric == 0 }
    func val(_ a: Agg) -> Double { useCost ? a.cost : a.tokens }
    var total: Double { useCost ? m.tot.cost : m.tot.inp + m.tot.out + m.tot.cw + m.tot.cr }
    func fmt(_ v: Double) -> String { useCost ? fmtCost(v) : fmtTok(v) }
    func groupLabel(_ g: String) -> String { g == "Antigravity" ? "Gemini" : g }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: tokenIcon(18)).resizable().renderingMode(.template).frame(width: 18, height: 18)
                Text("用量").font(.system(size: 18, weight: .semibold))
                Text(m.metric == 2 ? "各家额度" : m.ranges[m.range].0 + (useCost ? " · API 估算" : "")).font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
                if m.metric != 2 { PillSeg(items: m.ranges.map { $0.0 }, sel: Binding(get: { m.range }, set: { m.range = $0 })) }
                PillSeg(items: ["费用", "token", "限制"], sel: Binding(get: { m.metric }, set: { m.metric = $0 }))
                Button { withAnimation(motion(.qSpin)) { spins += 1 }; m.load(); s.reload() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .medium)).foregroundColor(.secondary)
                        .rotationEffect(.degrees(spins * 360)).frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(PressStyle(scale: 0.85)).help("重新读取")
            }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 14)
            if isSnapshot { content } else { ScrollView { content } }
        }
        .frame(minWidth: 920, minHeight: 660)
        .background(PanelBG(color: m.byProv.max { val($0) < val($1) }.map { gColor($0.name) } ?? .gray))
    }
    @ViewBuilder var content: some View {
        Group { if m.metric == 2 { limits } else { usage } }.padding(.horizontal, 24).padding(.bottom, 24)
    }
    var limits: some View {
        VStack(spacing: 12) { ForEach(s.provs) { p in LimitCard(s: s, p: p) } }
    }
    var usage: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let e = m.error { Text(e).font(.system(size: 12)).foregroundColor(.orange) }
            if let n = m.note { HStack(spacing: 6) { Image(systemName: "info.circle"); Text(n) }.font(.system(size: 12)).foregroundColor(.secondary) }
            // 第一块：总数 + 各家（像 T3 的用量页）
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(useCost ? "总花费 · API 估算" : "处理的 token").font(.system(size: 12)).foregroundColor(.secondary)
                    Text(fmt(total)).font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit().foregroundColor(inkStrong)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .contentTransition(.numericText(value: total)).animation(motion(.qRise), value: total)
                    Text("约 \(m.tot.sessions) 个会话" + (m.loading ? " · 读取中…" : "")).font(.system(size: 12)).foregroundColor(.secondary)
                }.frame(width: 215, alignment: .leading)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 24, alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 16) {
                    ForEach(m.byProv) { a in provRow(a) }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).tileBG()
            // 第二块：每天的平滑曲线
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Text(useCost ? "每天费用" : (m.range == 0 ? "每小时处理的 token" : "每天处理的 token")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    ForEach(m.byProv) { a in HStack(spacing: 5) { Circle().fill(gColor(a.name)).frame(width: 7, height: 7); BrandLogo(group: a.name, size: 11); Text(groupLabel(a.name)).font(.system(size: 11)).foregroundColor(.secondary) } }
                }
                chart
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).tileBG()
            HStack(spacing: 12) {
                stat("处理的 token", fmtTok(m.tot.inp + m.tot.out + m.tot.cw + m.tot.cr), "sum")
                stat("缓存读取", fmtTok(m.tot.cr), "arrow.down.doc")
                stat("未缓存输入", fmtTok(m.tot.inp), "text.cursor")
                stat("缓存写入", fmtTok(m.tot.cw), "square.and.arrow.down")
                stat("输出", fmtTok(m.tot.out), "text.bubble")
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("按模型").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("费用").frame(width: 100, alignment: .trailing); Text("占比").frame(width: 120, alignment: .trailing); Text("token").frame(width: 80, alignment: .trailing)
                }.font(.system(size: 11)).foregroundColor(.secondary).padding(.horizontal, 18).padding(.vertical, 12)
                let rows = Array(m.models.sorted { (useCost ? $0.cost > $1.cost : $0.tokens > $1.tokens) }.prefix(12))
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    Divider().padding(.leading, 18)
                    ModelLine(r: r, i: i, share: useCost ? (m.tot.cost > 0 ? r.cost / m.tot.cost : 0) : (total > 0 ? r.tokens / total : 0))
                }
            }.padding(.bottom, 6).tileBG()
        }
    }
    /// 一家一行：色点 + logo + 名字 + 会话数，下面「占 x% · 另一个数」，右边是这一项的数
    func provRow(_ a: Agg) -> some View {
        let share = total > 0 ? val(a) / total : 0
        let pct = share > 0 && share < 0.001 ? "<0.1%" : String(format: "%.1f%%", share * 100)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(gColor(a.name)).frame(width: 8, height: 8)
                BrandLogo(group: a.name, size: 16)
                Text(groupLabel(a.name)).font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize()
                Spacer(minLength: 6)
                Text(fmt(val(a))).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).fixedSize()
            }
            Text("\(a.sessionCount) 个会话 · \(pct) · " + (useCost ? fmtTok(a.tokens) + " token" : fmtCost(a.cost)))
                .font(.system(size: 11.5)).foregroundColor(.secondary).lineLimit(1).minimumScaleFactor(0.8).padding(.leading, 16)
        }
    }
    func stat(_ t: String, _ v: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) { Image(systemName: icon).font(.system(size: 10.5)); Text(t).font(.system(size: 11.5)) }.foregroundColor(.secondary)
            Text(v).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().foregroundColor(inkStrong)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).tileBG()
    }
    var chart: some View {
        let names = provNames.filter { n in m.daily.contains { $0.prov == n } }
        return Chart(m.daily) { p in
            let y = useCost ? p.cost : p.tokens
            AreaMark(x: .value("时间", p.date, unit: m.range == 0 ? .hour : .day), y: .value("值", y), stacking: .unstacked)
                .foregroundStyle(by: .value("来源", p.prov)).opacity(0.13).interpolationMethod(.monotone)
            LineMark(x: .value("时间", p.date, unit: m.range == 0 ? .hour : .day), y: .value("值", y))
                .foregroundStyle(by: .value("来源", p.prov)).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)).interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(domain: names, range: names.map { gColor($0) })
        .chartLegend(.hidden)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel().font(.system(size: 10)).foregroundStyle(Color.secondary) } }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { v in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.1))
            AxisValueLabel { if let d = v.as(Double.self) { Text(useCost ? (useCny ? "¥" : "$") + String(format: "%.0f", useCny ? d * usdToCny : d) : fmtTok(d)).font(.system(size: 10)).foregroundColor(.secondary) } }
        } }
        .frame(height: 280)
    }
}
/// 限制页的一家：宽卡片，5 小时和本周左右并排，底部一行是提醒和这家的花费，每张卡结构一样、高度一致
struct LimitCard: View {
    @ObservedObject var s: Store; let p: Prov
    var body: some View {
        let (a, b) = pickWins(p), w = bindingWin(p), eff = effLeft(p)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                BrandLogo(group: provGroup(p), size: 18).frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 9).fill(provColor(p).opacity(0.13)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) { Text(shown(p)).font(.system(size: 15, weight: .semibold)); StaleClock(p: p) }
                    Text([p.plan, p.checked.map { agoText($0) + "查的" } ?? "没读到"].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(eff.map { "\(s.showUsed ? 100 - $0 : $0)%" } ?? "–").font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit().foregroundColor(levelColor(eff))
                    Text(s.showUsed ? "已用" : "能用").font(.system(size: 10.5)).foregroundColor(.secondary)
                }
            }
            if p.wins.isEmpty { Text("T3 还没查到这家的额度：T3 刚打开时要等一会儿，或这个账号没登录").font(.system(size: 12)).foregroundColor(.secondary) }
            else {
                HStack(alignment: .top, spacing: 24) { column(a, "5 小时"); column(b, "本周") }
            }
            Divider()
            HStack(spacing: 8) {
                if let e = exhaustETA(w), let ww = w {
                    HStack(spacing: 5) { Image(systemName: "hourglass").font(.system(size: 10.5, weight: .semibold)); Text("照这速度 \(whenText(e)) 用完\(kindName(ww))额度") }
                        .font(.system(size: 11.5)).foregroundColor(.orange).padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.orange.opacity(0.12)))
                } else if w != nil {
                    HStack(spacing: 5) { Image(systemName: "checkmark.circle").font(.system(size: 10.5)); Text("照现在的速度，重置前用不完") }.font(.system(size: 11.5)).foregroundColor(.secondary)
                }
                Spacer()
                let g = provGroup(p), c = s.cost.byGroup[g]
                if let c = c {
                    Text((g == "Antigravity" ? "Gemini 合计 " : "") + "今天 ").foregroundColor(.secondary).font(.system(size: 12))
                    + Text(s.spend(c[0], c[2])).font(.system(size: 12, weight: .semibold))
                    + Text(" · 7 天 " + s.spend(c[1], c[3])).foregroundColor(.secondary).font(.system(size: 12))
                } else { Text("暂无花费数据").font(.system(size: 12)).foregroundColor(.secondary) }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).tileBG()
    }
    /// 一个窗口：标题和剩余、带时间竖线的进度条、重置时间；这家没有这个限制就写明
    @ViewBuilder func column(_ x: Win?, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let x = x {
                let l = left(x)
                HStack {
                    Text(kindName(x)).font(.system(size: 12.5, weight: .medium)).foregroundColor(.secondary)
                    Spacer()
                    Text(l.map { "\(s.showUsed ? "用了" : "剩") \(s.showUsed ? 100 - $0 : $0)%" } ?? "已重置").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundColor(levelColor(l))
                }
                Bar(pct: l ?? 0, color: l.map { barTint($0, p) } ?? .clear, h: 7, mark: elapsedFrac(x))
                Text(l == nil ? "\(resetShort(x.resets)) 已过，等 T3 重新查" : (x.resets.map { whenText($0) + " 重置 · 还有 " + countdown($0) } ?? "还没开始计时"))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                HStack { Text(title).font(.system(size: 12.5, weight: .medium)).foregroundColor(.secondary); Spacer() }
                Capsule().fill(Color.primary.opacity(0.05)).frame(height: 7)
                Text("这家没有\(title)限制").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.8))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 按模型那一行：名次、logo、模型名、费用、占比条、token
struct ModelLine: View {
    let r: ModelRow; let i: Int; let share: Double
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            Text("\(i + 1)").font(.system(size: 11)).monospacedDigit().foregroundColor(.secondary).frame(width: 18, alignment: .leading)
            BrandLogo(group: r.prov, size: 13).frame(width: 18)
            Text(r.model).font(.system(size: 12.5)).lineLimit(1)
            Spacer()
            Text(r.cost > 0 ? fmtCost(r.cost) : "–").font(.system(size: 12.5, weight: .medium)).monospacedDigit().frame(width: 100, alignment: .trailing)
            HStack(spacing: 6) {
                Bar(pct: Int((share * 100).rounded()), color: gColor(r.prov), h: 4).frame(width: 60)
                Text(String(format: "%.1f%%", share * 100)).font(.system(size: 11)).monospacedDigit().foregroundColor(.secondary).frame(width: 46, alignment: .trailing)
            }.frame(width: 120, alignment: .trailing)
            Text(fmtTok(r.tokens)).font(.system(size: 12)).monospacedDigit().foregroundColor(.secondary).frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(Color.primary.opacity(hover ? 0.035 : 0))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
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
        if CommandLine.arguments.contains("--t3-refresh") { // 测试用：只跑一次「让 T3 重查」，打印结果后退出
            T3Refresh.run { ok, msg in print(ok ? "OK" : "FAIL", msg ?? ""); exit(ok ? 0 : 1) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[i + 1]
            detail.load()
            DispatchQueue.main.asyncAfter(deadline: .now() + (isDemo ? 2.5 : 8)) { // 等花费和 T3 汇总读完
                for (pg, pn, cm) in [(0, "main_min", true), (0, "main_full", false), (1, "manage", true)] { for (ap, an) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                    self.store.compact = cm
                    NSAppearance(named: ap)!.performAsCurrentDrawingAppearance {
                        let r = ImageRenderer(content: Root(s: self.store, page: pg).environment(\.colorScheme, ap == .darkAqua ? .dark : .light)); r.scale = 2
                        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: dir + "/\(pn)_\(an).png"))
                        }
                    }
                } }
                for (mt, mn) in [(0, "detail_cost"), (1, "detail_token"), (2, "detail_limits")] { for (ap, an) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                    self.detail.metric = mt
                    NSAppearance(named: ap)!.performAsCurrentDrawingAppearance {
                        let r = ImageRenderer(content: DetailView(m: self.detail, s: self.store).frame(width: 960).environment(\.colorScheme, ap == .darkAqua ? .dark : .light)); r.scale = 1.5
                        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: dir + "/\(mn)_\(an).png"))
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
