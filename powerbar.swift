// powerbar (Apple Silicon): menu-bar readout of battery charge/discharge power, whole-system power and SoC power.
// Battery: AppleSmartBattery InstantAmperage (mA, negative = discharging) x Voltage (mV).
// System: AppleSmartBattery PowerTelemetryData SystemLoad (mW, what the whole machine draws, on AC or battery).
// SoC: IOReport "Energy Model" counters (CPU / GPU / ANE / DRAM energy), turned into watts between two samples.
// Temperature: hottest "PMU tdie" sensor from the HID event system.
// Lid: writes /Users/Shared/powerbar/lid ("awake" | "sleep"); the root service pbd applies it with pmset.
// History: one sample every five minutes in ~/Library/Application Support/powerbar/history.csv (60 days), a 12-hour
// chart in the menu and a records window with a chart of any range. The menu is one panel of cards.
import Cocoa
import IOKit

func batteryInfo() -> (watts: Double, percent: Int, external: Bool, whLeft: Double?, whFull: Double?, minutes: Int?, system: Double?, adapter: Double?)? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
    func num(_ k: String) -> Int64? { (prop(k) as? NSNumber)?.int64Value }
    guard let v = num("Voltage") else { return nil }
    // InstantAmperage is stored as an unsigned 64-bit two's complement value
    let a = num("InstantAmperage") ?? num("Amperage") ?? 0
    let ext = (prop("ExternalConnected") as? Bool) ?? false
    let cur = Double(num("CurrentCapacity") ?? 0), mx = Double(num("MaxCapacity") ?? 0)
    let pct = mx > 100 ? Int((cur / mx * 100).rounded()) : Int(cur)
    var whLeft: Double? = nil, whFull: Double? = nil
    if let rc = num("AppleRawCurrentCapacity"), let rm = num("AppleRawMaxCapacity"), rm > 100 {
        whLeft = Double(rc) * Double(v) / 1_000_000.0; whFull = Double(rm) * Double(v) / 1_000_000.0
    }
    let t = num(ext ? "AvgTimeToFull" : "AvgTimeToEmpty") ?? num("TimeRemaining")
    let mins = (t != nil && t! > 0 && t! < 6000) ? Int(t!) : nil
    var sys: Double? = nil, adp: Double? = nil
    if let pt = prop("PowerTelemetryData") as? [String: Any] {
        if let l = (pt["SystemLoad"] as? NSNumber)?.int64Value, l > 0, l < 400_000 { sys = Double(l) / 1000 }
        if let p = (pt["SystemPowerIn"] as? NSNumber)?.int64Value, p > 0, p < 400_000 { adp = Double(p) / 1000 }
    }
    return (Double(a) * Double(v) / 1_000_000.0, pct, ext, whLeft, whFull, mins, sys, adp)
}

// UI language: Chinese or English, chosen in the menu (kept in the user defaults); the system language decides at first.
var english: Bool = {
    if let v = UserDefaults.standard.object(forKey: "english") as? Bool { return v }
    return !(Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
}()
func L(_ zh: String, _ en: String) -> String { english ? en : zh }

// IOReport (private, lives in the dyld shared cache): energy counters of the SoC blocks.
final class SoCPower {
    typealias CopyCh = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    typealias CreateSub = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias StrF = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias IntF = @convention(c) (CFDictionary, Int32) -> Int64
    var samples: CreateSamples?, delta: Delta?, name: StrF?, unit: StrF?, value: IntF?
    var sub: OpaquePointer?, subbed: CFMutableDictionary?
    var last: (CFDictionary, Date)?

    init() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        func f<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }
        guard let copy = f("IOReportCopyChannelsInGroup", CopyCh.self), let create = f("IOReportCreateSubscription", CreateSub.self),
              let ch = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return }
        samples = f("IOReportCreateSamples", CreateSamples.self); delta = f("IOReportCreateSamplesDelta", Delta.self)
        name = f("IOReportChannelGetChannelName", StrF.self); unit = f("IOReportChannelGetUnitLabel", StrF.self)
        value = f("IOReportSimpleGetIntegerValue", IntF.self)
        var s: Unmanaged<CFMutableDictionary>? = nil
        sub = create(nil, ch, &s, 0, nil); subbed = s?.takeRetainedValue()
    }

    // watts per block since the previous call (nil on the first call)
    func read() -> (cpu: Double, gpu: Double, ane: Double, dram: Double)? {
        guard let sub, let subbed, let samples, let delta, let name, let value,
              let now = samples(sub, subbed, nil)?.takeRetainedValue() else { return nil }
        let t = Date()
        defer { last = (now, t) }
        guard let (prev, pt) = last, let d = delta(prev, now, nil)?.takeRetainedValue() as NSDictionary?,
              let chans = d["IOReportChannels"] as? [NSDictionary] else { return nil }
        let dt = t.timeIntervalSince(pt)
        guard dt > 0.2 else { return nil }
        var cpu = 0.0, gpu = 0.0, ane = 0.0, dram = 0.0
        for c in chans {
            let cd = c as CFDictionary
            guard let n = name(cd)?.takeUnretainedValue() as String? else { continue }
            let u = (unit?(cd)?.takeUnretainedValue() as String?) ?? "mJ"
            let scale = u == "nJ" ? 1e-9 : (u == "uJ" || u == "µJ" ? 1e-6 : 1e-3)
            let w = Double(value(cd, 0)) * scale / dt
            if n == "CPU Energy" { cpu = w } else if n == "GPU Energy" { gpu = w }
            else if n.hasPrefix("ANE") { ane += w } else if n == "DRAM" { dram = w }
        }
        return (cpu, gpu, ane, dram)
    }
}

// HID temperature sensors (private IOKit API): hottest SoC die sensor.
final class SoCTemp {
    var client: AnyObject?
    var services: [AnyObject] = []
    var copyEvent: (@convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?)?
    var floatValue: (@convention(c) (AnyObject, Int32) -> Double)?
    init() {
        guard let io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        func g<T>(_ n: String, _ t: T.Type) -> T? { dlsym(io, n).map { unsafeBitCast($0, to: t) } }
        guard let create = g("IOHIDEventSystemClientCreate", (@convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?).self),
              let match = g("IOHIDEventSystemClientSetMatching", (@convention(c) (AnyObject, CFDictionary) -> Int32).self),
              let copySvcs = g("IOHIDEventSystemClientCopyServices", (@convention(c) (AnyObject) -> Unmanaged<CFArray>?).self),
              let copyProp = g("IOHIDServiceClientCopyProperty", (@convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?).self),
              let c = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        copyEvent = g("IOHIDServiceClientCopyEvent", (@convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?).self)
        floatValue = g("IOHIDEventGetFloatValue", (@convention(c) (AnyObject, Int32) -> Double).self)
        client = c
        _ = match(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        for s in (copySvcs(c)?.takeRetainedValue() as? [AnyObject]) ?? [] {
            let n = copyProp(s, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
            if n.contains("tdie") { services.append(s) }
        }
    }
    func read() -> Double? {
        guard let copyEvent, let floatValue else { return nil }
        var hi: Double? = nil
        for s in services {
            guard let e = copyEvent(s, 15, 0, 0)?.takeRetainedValue() else { continue }   // 15 = temperature event
            let v = floatValue(e, 15 << 16)
            if v > 0 && v < 150 { hi = max(hi ?? v, v) }
        }
        return hi
    }
}

// ---- energy history ----------------------------------------------------------------------------------------------
// One sample a minute (time, charge %, Wh left, average watts, on AC) in ~/Library/Application Support/powerbar/
// history.csv, 60 days kept. From it: sessions (the stretch between two changes of the power source, with the time the
// machine was actually awake in it), the chart of the last 12 hours, and the usual discharge power for the estimate.
struct Sample { let t: Double; let pct: Int; let wh: Double; let w: Double; let ext: Bool
    var brk: Bool = false }      // brk: the machine slept or was off before this sample (no awake time, no line to it)
struct Session { var start: Double, end: Double; var ext: Bool; var active: Double; var pct0: Int, pct1: Int; var wh0: Double, wh1: Double; var wsum: Double; var n: Int
    var avgW: Double { n > 0 ? wsum / Double(n) : 0 } }
final class History {
    static let interval = 300.0        // one sample every five minutes: 288 a day, about 0.5 MB for the 60 days kept
    static let gap = 750.0             // samples further apart than this count as a break even without the flag
    var samples: [Sample] = []
    let path: String
    var accW = 0.0, accN = 0, lastWrite = 0.0, lastExt: Bool? = nil
    var readOnly = false               // --snapshot: nothing is written
    var pendingBreak = true            // the first sample after a start or a wake carries the break flag
    var last: (pct: Int, wh: Double?, ext: Bool)? = nil
    private var typCache: [Bool: (count: Int, value: (watts: Double, minutes: Int)?)] = [:]
    static func line(_ s: Sample) -> String { "\(Int(s.t)),\(s.pct),\(String(format: "%.2f", s.wh)),\(String(format: "%.2f", s.w)),\(s.ext ? 1 : 0),\(s.brk ? 1 : 0)\n" }
    init() {
        let dir = NSHomeDirectory() + "/Library/Application Support/powerbar"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = dir + "/history.csv"
        let cut = Date().timeIntervalSince1970 - 60 * 86400
        // Read, drop what is older than 60 days, and thin what was written more often than the interval (files from
        // the one-a-minute version): a sample stays when the power source changes, after a break, or once the interval
        // has passed since the last one kept; its power is the mean of the ones it stands for.
        var prevT = 0.0, sumW = 0.0, cnt = 0, lines = 0
        for line in ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n") {
            lines += 1
            let f = line.split(separator: ",")
            guard f.count >= 5, let t = Double(f[0]), t > cut, t > prevT, let p = Int(f[1]), let wh = Double(f[2]), let w = Double(f[3]) else { continue }
            let ext = f[4] == "1", brk = (f.count >= 6 && f[5] == "1") || (prevT > 0 && t - prevT > History.gap) || samples.isEmpty
            prevT = t; sumW += w; cnt += 1
            if let k = samples.last, !brk, k.ext == ext, t - k.t < History.interval - 10 { continue }
            samples.append(Sample(t: t, pct: p, wh: wh, w: sumW / Double(cnt), ext: ext, brk: brk)); sumW = 0; cnt = 0
        }
        // a restart of powerbar itself is no break: the flag only when the last sample is old
        if let l = samples.last, Date().timeIntervalSince1970 - l.t <= History.gap { pendingBreak = false; lastWrite = l.t; lastExt = l.ext }
        if lines != samples.count || lines == 0 {
            try? samples.map { History.line($0) }.joined().write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    // first index with t >= the given time (samples are in time order)
    func lowerBound(_ t: Double) -> Int {
        var lo = 0, hi = samples.count
        while lo < hi { let m = (lo + hi) / 2; if samples[m].t < t { lo = m + 1 } else { hi = m } }
        return lo
    }
    func slice(from: Double, to: Double) -> ArraySlice<Sample> { let a = lowerBound(from); return samples[a..<max(a, lowerBound(to.nextUp))] }
    // called every tick with the current reading; writes a sample every five minutes, and at once when the power source
    // changes or when forced (going to sleep)
    func add(pct: Int, wh: Double?, w: Double, ext: Bool, force: Bool = false) {
        if readOnly { return }
        let now = Date().timeIntervalSince1970
        // The power source changed: what was gathered so far belongs to the old one. It is written under the old source
        // (it used to go out under the new one, so a battery stretch began with a charging sample and its average came
        // out several watts low), and the new stretch starts with this reading.
        if let le = lastExt, le != ext, accN > 0, let l = last, !pendingBreak, samples.last.map({ now - 1 > $0.t }) ?? true {
            let old = Sample(t: now - 1, pct: l.pct, wh: l.wh ?? 0, w: accW / Double(accN), ext: le, brk: false)
            samples.append(old); accW = 0; accN = 0
            if !readOnly, let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(History.line(old).data(using: .utf8)!); h.closeFile() }
        }
        accW += w; accN += 1; last = (pct, wh, ext)
        guard force || pendingBreak || now - lastWrite >= History.interval || (lastExt != nil && lastExt != ext) else { return }
        if let l = samples.last, now <= l.t { return }
        let smp = Sample(t: now, pct: pct, wh: wh ?? 0, w: accW / Double(accN), ext: ext, brk: pendingBreak)
        accW = 0; accN = 0; lastWrite = now; lastExt = ext; pendingBreak = false
        samples.append(smp)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(History.line(smp).data(using: .utf8)!); h.closeFile()
        } else { try? History.line(smp).write(toFile: path, atomically: true, encoding: .utf8) }
    }
    func willSleep() { if let l = last, accN > 0 { add(pct: l.pct, wh: l.wh, w: accW / Double(accN), ext: l.ext, force: true) } }
    func didWake() { pendingBreak = true; accW = 0; accN = 0 }
    // a gap of more than five minutes between samples is sleep or power-off: it splits nothing but adds no awake time
    func sessions(from: Double = 0, to: Double = .infinity) -> [Session] {
        var out: [Session] = []
        var prev: Sample? = nil
        for s in slice(from: from, to: to) {
            if out.isEmpty || out[out.count - 1].ext != s.ext {
                out.append(Session(start: s.t, end: s.t, ext: s.ext, active: 0, pct0: s.pct, pct1: s.pct, wh0: s.wh, wh1: s.wh, wsum: 0, n: 0))
            } else if let p = prev, !s.brk, s.t - p.t <= History.gap { out[out.count - 1].active += s.t - p.t }
            out[out.count - 1].end = s.t; out[out.count - 1].pct1 = s.pct; out[out.count - 1].wh1 = s.wh
            // a sample whose sign contradicts its source (written at a switch by the versions before the fix) is no part of the average
            if abs(s.w) < 150, s.ext ? s.w > -0.5 : s.w < 0.5 { out[out.count - 1].wsum += s.w; out[out.count - 1].n += 1 }
            prev = s
        }
        return out
    }
    // The usual power on battery (positive watts) or while charging, over the last 14 days: samples between the 10th and
    // the 90th percentile only, so a stuck gauge, a sample taken across a wake or a short burst do not move it.
    // Worked out again only when a sample was added. Needs half an hour of samples (six).
    func typicalWatts(charging: Bool) -> (watts: Double, minutes: Int)? {
        if let c = typCache[charging], c.count == samples.count { return c.value }
        var v = samples[lowerBound(Date().timeIntervalSince1970 - 14 * 86400)...].filter { $0.ext == charging && abs($0.w) < 150 && (charging ? $0.w > 1 : $0.w < -1) }.map { abs($0.w) }
        var out: (watts: Double, minutes: Int)? = nil
        if v.count >= 6 {
            v.sort()
            let mid = v[(v.count / 10)..<(v.count - v.count / 10)]
            out = (mid.reduce(0, +) / Double(mid.count), v.count * Int(History.interval / 60))
        }
        typCache[charging] = (samples.count, out)
        return out
    }
}
// battery charge over the last 12 hours: green while on AC, the text colour on battery; breaks where the machine slept
final class HistoryChart: NSView {
    var samples: [Sample] = []
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 64) }
    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 3)
        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        for f in [0.0, 0.5, 1.0] { let y = r.minY + r.height * f; let p = NSBezierPath(); p.move(to: NSPoint(x: r.minX, y: y)); p.line(to: NSPoint(x: r.maxX, y: y)); p.lineWidth = 1; p.stroke() }
        let now = Date().timeIntervalSince1970, span = 12.0 * 3600
        func pt(_ s: Sample) -> NSPoint { NSPoint(x: r.maxX - CGFloat((now - s.t) / span) * r.width, y: r.minY + CGFloat(s.pct) / 100 * r.height) }
        var prev: Sample? = nil
        var lo = 0, hi = samples.count
        while lo < hi { let m = (lo + hi) / 2; if samples[m].t < now - span { lo = m + 1 } else { hi = m } }
        for s in samples[lo...] {
            if let p = prev, !s.brk, s.t - p.t <= History.gap {
                (s.ext ? NSColor.systemGreen : NSColor.labelColor).setStroke()
                let path = NSBezierPath(); path.move(to: pt(p)); path.line(to: pt(s)); path.lineWidth = 1.6; path.lineCapStyle = .round; path.stroke()
            }
            prev = s
        }
    }
}

// The records window's chart: any stretch of the history. Upper pane = charge in percent (green on AC, text colour on
// battery, grey bands where the machine slept or was off), lower pane = power in watts (up = charging, down =
// discharging). Moving the pointer over it reports the sample under it.
final class RangeChart: NSView {
    var samples: [Sample] = []
    var t0 = 0.0, t1 = 1.0
    var onHover: ((String) -> Void)?
    private var hoverX: CGFloat? = nil
    private var area: NSTrackingArea?
    var plot: NSRect { NSRect(x: 44, y: 22, width: max(10, bounds.width - 56), height: max(10, bounds.height - 30)) }
    var pctRect: NSRect { let p = plot; return NSRect(x: p.minX, y: p.minY + p.height * 0.36, width: p.width, height: p.height * 0.64) }
    var wRect: NSRect { let p = plot; return NSRect(x: p.minX, y: p.minY, width: p.width, height: p.height * 0.28) }
    func x(_ t: Double) -> CGFloat { plot.minX + CGFloat((t - t0) / max(1, t1 - t0)) * plot.width }
    func visible() -> ArraySlice<Sample> {
        var lo = 0, hi = samples.count
        while lo < hi { let m = (lo + hi) / 2; if samples[m].t < t0 { lo = m + 1 } else { hi = m } }
        let a = lo; hi = samples.count
        while lo < hi { let m = (lo + hi) / 2; if samples[m].t <= t1 { lo = m + 1 } else { hi = m } }
        return samples[a..<lo]
    }
    override func updateTrackingAreas() {
        if let a = area { removeTrackingArea(a) }
        area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area!)
    }
    override func mouseMoved(with e: NSEvent) { hoverX = convert(e.locationInWindow, from: nil).x; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hoverX = nil; needsDisplay = true; onHover?("") }
    func text(_ s: String, at p: NSPoint, right: Bool = false, center: Bool = false) {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let sz = (s as NSString).size(withAttributes: a)
        (s as NSString).draw(at: NSPoint(x: right ? p.x - sz.width : center ? p.x - sz.width / 2 : p.x, y: p.y - sz.height / 2), withAttributes: a)
    }
    func hline(_ y: CGFloat, _ r: NSRect, alpha: CGFloat = 0.12) {
        NSColor.labelColor.withAlphaComponent(alpha).setStroke()
        let p = NSBezierPath(); p.move(to: NSPoint(x: r.minX, y: y)); p.line(to: NSPoint(x: r.maxX, y: y)); p.lineWidth = 1; p.stroke()
    }
    override func draw(_ dirty: NSRect) {
        let pr = pctRect, wr = wRect, vis = visible(), span = max(1, t1 - t0)
        for f in [0, 25, 50, 75, 100] { let y = pr.minY + pr.height * CGFloat(f) / 100; hline(y, pr); text("\(f)%", at: NSPoint(x: pr.minX - 5, y: y), right: true) }
        var wmax = 10.0
        for s in vis where abs(s.w) < 150 { wmax = max(wmax, abs(s.w)) }
        wmax = (wmax / 10).rounded(.up) * 10
        let wy = wr.midY
        hline(wr.maxY, wr, alpha: 0.06); hline(wr.minY, wr, alpha: 0.06); hline(wy, wr, alpha: 0.2)
        text("+\(Int(wmax))W", at: NSPoint(x: wr.minX - 5, y: wr.maxY), right: true); text("0", at: NSPoint(x: wr.minX - 5, y: wy), right: true)
        text("−\(Int(wmax))W", at: NSPoint(x: wr.minX - 5, y: wr.minY), right: true)
        // time ticks on local-time boundaries
        let steps: [Double] = [600, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 172800, 432000, 864000]
        let step = steps.first { span / $0 <= 8 } ?? 1728000
        let off = Double(TimeZone.current.secondsFromGMT())
        let f = DateFormatter(); f.dateFormat = step >= 86400 ? "MM-dd" : span > 86400 ? "MM-dd HH:mm" : "HH:mm"
        var t = ((t0 + off) / step).rounded(.up) * step - off
        while t <= t1 {
            let xx = x(t)
            NSColor.labelColor.withAlphaComponent(0.07).setStroke()
            let p = NSBezierPath(); p.move(to: NSPoint(x: xx, y: wr.minY)); p.line(to: NSPoint(x: xx, y: pr.maxY)); p.lineWidth = 1; p.stroke()
            text(f.string(from: Date(timeIntervalSince1970: t)), at: NSPoint(x: min(max(xx, plot.minX + 14), plot.maxX - 14), y: 9), center: true)
            t += step
        }
        // the curves; points closer than 0.7 px to the last drawn one are skipped (60 days = 86 000 samples)
        func py(_ s: Sample) -> CGFloat { pr.minY + CGFloat(s.pct) / 100 * pr.height }
        // (everything of one colour goes into one path: two strokes and two fills for the whole chart)
        let lines = [NSBezierPath(), NSBezierPath()], bars = [NSBezierPath(), NSBezierPath()], gaps = NSBezierPath()
        var anchor: Sample? = nil, prev: Sample? = nil
        for s in vis {
            if let p = prev, s.brk || s.t - p.t > History.gap {
                gaps.appendRect(NSRect(x: x(p.t), y: pr.minY, width: x(s.t) - x(p.t), height: pr.height))
                anchor = nil
            }
            if let a = anchor {
                let xa = x(a.t), xs = x(s.t)
                if xs - xa >= 0.7 || s.ext != a.ext {
                    let k = s.ext ? 1 : 0
                    lines[k].move(to: NSPoint(x: xa, y: py(a))); lines[k].line(to: NSPoint(x: xs, y: py(s)))
                    if abs(s.w) < 150 {
                        let h = CGFloat(s.w / wmax) * wr.height / 2
                        bars[k].appendRect(NSRect(x: xa, y: min(wy, wy + h), width: max(1, xs - xa), height: abs(h)))
                    }
                    anchor = s
                }
            } else { anchor = s }
            prev = s
        }
        NSColor.labelColor.withAlphaComponent(0.05).setFill(); gaps.fill()
        for (k, c) in [NSColor.labelColor, NSColor.systemGreen].enumerated() {
            c.withAlphaComponent(0.55).setFill(); bars[k].fill()
            c.setStroke(); lines[k].lineWidth = 1.6; lines[k].lineCapStyle = .round; lines[k].lineJoinStyle = .round; lines[k].stroke()
        }
        if vis.isEmpty { text(L("这段时间没有记录", "No records in this range"), at: NSPoint(x: pr.midX, y: pr.midY), center: true) }
        // the sample under the pointer
        guard let hx = hoverX, hx >= plot.minX, hx <= plot.maxX, !vis.isEmpty else { return }
        let ht = t0 + Double((hx - plot.minX) / plot.width) * span
        var best = vis.first!
        var lo = vis.startIndex, hi = vis.endIndex
        while lo < hi { let m = (lo + hi) / 2; if samples[m].t < ht { lo = m + 1 } else { hi = m } }
        for i in [lo - 1, lo] where i >= vis.startIndex && i < vis.endIndex { if abs(samples[i].t - ht) < abs(best.t - ht) { best = samples[i] } }
        guard abs(best.t - ht) <= max(History.interval, span / Double(plot.width) * 6) else { onHover?(""); return }
        let bx = x(best.t)
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        let p = NSBezierPath(); p.move(to: NSPoint(x: bx, y: wr.minY)); p.line(to: NSPoint(x: bx, y: pr.maxY)); p.lineWidth = 1; p.stroke()
        (best.ext ? NSColor.systemGreen : NSColor.labelColor).setFill()
        NSBezierPath(ovalIn: NSRect(x: bx - 3.5, y: py(best) - 3.5, width: 7, height: 7)).fill()
        let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"
        onHover?(df.string(from: Date(timeIntervalSince1970: best.t)) + " · \(best.pct)% · " + (best.ext ? L("接电", "on AC") : L("用电池", "on battery")) + String(format: " %+.1f W", best.w))
    }
}

// ---- small view helpers ------------------------------------------------------------------------------------------
func label(_ s: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, mono: Bool = false) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    t.textColor = color; t.lineBreakMode = .byTruncatingTail
    t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return t
}
func symbol(_ name: String, size: CGFloat = 14) -> NSImageView {
    let v = NSImageView()
    if let i = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
        v.image = i.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium))
    }
    v.contentTintColor = .secondaryLabelColor
    v.widthAnchor.constraint(equalToConstant: size > 20 ? 36 : 22).isActive = true
    v.heightAnchor.constraint(equalToConstant: size + 6).isActive = true
    v.imageScaling = .scaleProportionallyDown
    return v
}
func spacer() -> NSView {      // takes the free width of a row, no height of its own
    let v = NSView(); v.setContentHuggingPriority(.init(1), for: .horizontal)
    let h = v.heightAnchor.constraint(equalToConstant: 1); h.priority = .defaultHigh; h.isActive = true
    return v
}
func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = .horizontal; s.spacing = spacing; s.alignment = .centerY; return s
}
// a rounded card with a caption above its content
final class Card: NSView {
    let stack = NSStackView()
    let caption = label(size: 11, weight: .semibold, color: .secondaryLabelColor)
    init(_ rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 10
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.setHuggingPriority(.required, for: .vertical)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor)])
        stack.addArrangedSubview(caption)
        for r in rows { stack.addArrangedSubview(r); r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor }
    override var wantsUpdateLayer: Bool { true }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let soc = SoCPower()
    let temp = SoCTemp()
    let history = History()
    let chart = HistoryChart()
    let axisL = label(size: 10, color: .tertiaryLabelColor), axisM = label(size: 10, color: .tertiaryLabelColor), axisR = label(size: 10, color: .tertiaryLabelColor)
    let sessionLine = label(size: 12), historyLine = label(size: 12, color: .secondaryLabelColor)
    let recordsButton = NSButton(title: "", target: nil, action: nil)
    var recordsWindow: NSWindow?
    func hm(_ secs: Double) -> String { let m = Int((secs / 60).rounded()); return m >= 60 ? L("\(m / 60) 小时 \(m % 60) 分", "\(m / 60) h \(m % 60) min") : L("\(m) 分钟", "\(m) min") }
    func describe(_ s: Session, long: Bool) -> String {
        let f = DateFormatter(); f.dateFormat = long ? "MM-dd HH:mm" : "HH:mm"
        let kind = s.ext ? L("接电", "On AC   ") : L("电池", "Battery ")
        let w = abs(s.avgW) >= 0.05 ? String(format: L(" · 均 %.1f W", " · avg %.1f W"), abs(s.avgW)) : ""
        return "\(kind) \(f.string(from: Date(timeIntervalSince1970: s.start)))–\(f.string(from: Date(timeIntervalSince1970: s.end))) · " + hm(s.active) + " · \(s.pct0)% → \(s.pct1)%" + w
    }
    func refreshHistory(whLeft: Double?, whFull: Double?, external: Bool) {
        chart.samples = history.samples; chart.needsDisplay = true
        if recordsWindow?.isVisible == true { refreshRecords() }
        if let cur = history.sessions().last {
            sessionLine.stringValue = (cur.ext ? L("本次接电已 ", "On AC for ") : L("本次用电池已 ", "On battery for ")) + hm(cur.active) + " · \(cur.pct0)% → \(cur.pct1)%"
        } else { sessionLine.stringValue = L("还没有记录", "No records yet") }
        if !external, let t = history.typicalWatts(charging: false), let left = whLeft {
            historyLine.stringValue = L("按历史用量还能用约 ", "At the usual rate: about ") + hm(left / t.watts * 3600) + String(format: L("（%.1f W）", " (%.1f W)"), t.watts)
        } else if external, let t = history.typicalWatts(charging: true), let left = whLeft, let full = whFull, full - left > 0.5 {
            historyLine.stringValue = L("按历史充电速度约 ", "At the usual rate: about ") + hm((full - left) / t.watts * 3600) + L(" 充满", " to full") + String(format: L("（%.0f W）", " (%.0f W)"), t.watts)
        } else if external { historyLine.stringValue = L("已接电源", "On AC power") }
        else { historyLine.stringValue = L("历史记录不足，用电池满半小时后给出估计", "Estimate after half an hour on battery") }
    }
    // ---- the records window: a chart of any stretch of the history, a summary of it and its sessions ----------------
    let rangeSeg = NSSegmentedControl(labels: ["", "", "", "", "", "", ""], trackingMode: .selectOne, target: nil, action: nil)
    let rangeSpans: [Double] = [6 * 3600, 86400, 3 * 86400, 7 * 86400, 30 * 86400]      // then "all" and "custom"
    let fromPicker = NSDatePicker(), toPicker = NSDatePicker()
    let rangeChart = RangeChart()
    let rangeSummary = label(size: 12), rangeHover = label(size: 12, color: .secondaryLabelColor, mono: true)
    let recordsText = NSTextView()
    var recordsCount = -1
    func buildRecords() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.minSize = NSSize(width: 640, height: 460)
        rangeSeg.target = self; rangeSeg.action = #selector(rangePicked); rangeSeg.selectedSegment = 1; rangeSeg.controlSize = .small
        for p in [fromPicker, toPicker] {
            p.datePickerStyle = .textFieldAndStepper; p.datePickerElements = [.yearMonthDay, .hourMinute]; p.controlSize = .small
            p.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular); p.target = self; p.action = #selector(rangeTyped)
        }
        rangeChart.onHover = { [weak self] s in self?.rangeHover.stringValue = s.isEmpty ? L("把指针移到曲线上查看某一刻的电量和功率", "Move the pointer over the chart for the reading at that moment") : s }
        rangeChart.onHover?("")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        recordsText.isEditable = false; recordsText.drawsBackground = false; recordsText.autoresizingMask = [.width]
        recordsText.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular); recordsText.textContainerInset = NSSize(width: 2, height: 4)
        scroll.documentView = recordsText
        let top = hstack([rangeSeg, spacer(), fromPicker, label("–", color: .secondaryLabelColor), toPicker])
        let stack = NSStackView(views: [top, rangeSummary, rangeChart, rangeHover, scroll])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(); root.addSubview(stack); w.contentView = root
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                                     stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                     rangeChart.heightAnchor.constraint(greaterThanOrEqualToConstant: 240), scroll.heightAnchor.constraint(equalToConstant: 150)])
        for v in stack.arrangedSubviews { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        rangeChart.setContentHuggingPriority(.init(1), for: .vertical)
        return w
    }
    @objc func rangePicked() { recordsCount = -1; refreshRecords() }
    @objc func rangeTyped() { rangeSeg.selectedSegment = 6; recordsCount = -1; refreshRecords() }
    func refreshRecords() {
        // called every tick while the window is open: work only when a sample was added or the range was changed
        guard let w = recordsWindow, recordsCount != history.samples.count else { return }
        recordsCount = history.samples.count
        w.title = L("充放电记录", "Charge and discharge records")
        let names = [L("6 小时", "6 h"), L("24 小时", "24 h"), L("3 天", "3 d"), L("7 天", "7 d"), L("30 天", "30 d"), L("全部", "All"), L("自选", "Custom")]
        for (i, n) in names.enumerated() { rangeSeg.setLabel(n, forSegment: i) }
        let now = Date().timeIntervalSince1970, i = rangeSeg.selectedSegment
        var t0 = now - 86400, t1 = now
        if i >= 0 && i < rangeSpans.count { t0 = now - rangeSpans[i] }
        else if i == 5 { t0 = min(history.samples.first?.t ?? now - 3600, now - 600) }
        else { t0 = fromPicker.dateValue.timeIntervalSince1970; t1 = toPicker.dateValue.timeIntervalSince1970; if t1 < t0 + 600 { t1 = t0 + 600 } }
        if i != 6 { fromPicker.dateValue = Date(timeIntervalSince1970: t0); toPicker.dateValue = Date(timeIntervalSince1970: t1) }
        rangeChart.samples = history.samples; rangeChart.t0 = t0; rangeChart.t1 = t1; rangeChart.needsDisplay = true
        let ses = history.sessions(from: t0, to: t1)
        var batt = 0.0, ac = 0.0, bw = 0.0, bn = 0, cw = 0.0, cn = 0
        for s in ses { if s.ext { ac += s.active; cw += s.wsum; cn += s.n } else { batt += s.active; bw += s.wsum; bn += s.n } }
        if let a = ses.first, let b = ses.last {
            let asleep = max(0, b.end - a.start - batt - ac)
            rangeSummary.stringValue = L("这段时间：用电池 ", "In this range: on battery ") + hm(batt) + (bn > 0 && batt >= 60 ? String(format: L("（均 %.1f W）", " (avg %.1f W)"), abs(bw / Double(bn))) : "")
                + L(" · 接电 ", " · on AC ") + hm(ac) + (cn > 0 && ac >= 60 ? String(format: L("（均 %.1f W）", " (avg %.1f W)"), abs(cw / Double(cn))) : "")
                + L(" · 休眠或关机 ", " · asleep or off ") + hm(asleep) + L("（灰色段）", " (grey bands)")
        } else { rangeSummary.stringValue = L("这段时间没有记录", "No records in this range") }
        let rows = ses.reversed().filter { $0.active >= 60 }.prefix(300)
        recordsText.string = rows.isEmpty ? L("没有满一分钟的充放电记录", "No session of a minute or more") : rows.map { describe($0, long: true) }.joined(separator: "\n")
        recordsText.textColor = .labelColor
    }
    @objc func showRecords() {
        if recordsWindow == nil { recordsWindow = buildRecords(); recordsWindow!.center() }
        recordsCount = -1; refreshRecords()
        NSApp.activate(ignoringOtherApps: true); recordsWindow!.makeKeyAndOrderFront(nil)
        item.menu?.cancelTracking()
    }
    let width: CGFloat = 340
    var lastWatts: Double = 0
    var battAvg: Double? = nil      // battery watts averaged over about a minute: the estimate should not jump
    var socAvg: (cpu: Double, gpu: Double, ane: Double, dram: Double)? = nil
    let modeDir = "/Users/Shared/powerbar"

    // readout
    let bigWatts = label(size: 28, weight: .semibold, mono: true)
    let battState = label(size: 12, color: .secondaryLabelColor)
    let battIcon = symbol("battery.75", size: 22)
    let timeLine = label(size: 12)
    let sysLine = label(size: 12, color: .secondaryLabelColor, mono: true)
    let socLine = label(size: 12, color: .secondaryLabelColor, mono: true)

    // options
    let lidSwitch = NSSwitch()
    let lidLabel = label(size: 12)
    let langButton = NSButton(title: "", target: nil, action: nil), quitButton = NSButton(title: "", target: nil, action: nil)

    var cards: [Card] = []
    let panel = NSStackView()
    let panelItem = NSMenuItem()

    func readLine(_ path: String) -> String { ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    func writeLine(_ path: String, _ s: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? (s + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // ---- lid ----
    func lidAwake() -> Bool { readLine(modeDir + "/lid") == "awake" }
    @objc func toggleLid(_ s: NSSwitch) { writeLine(modeDir + "/lid", s.state == .on ? "awake" : "sleep") }

    // ---- language, layout ----
    @objc func toggleLanguage() { english.toggle(); UserDefaults.standard.set(english, forKey: "english"); relabel(); tick(); resize() }
    @objc func quit() { NSApp.terminate(nil) }
    func relabel() {
        let caps = [L("电源", "POWER"), L("电量记录 · 近 12 小时", "CHARGE HISTORY · LAST 12 HOURS"), L("选项", "OPTIONS")]
        axisL.stringValue = L("12 小时前", "12 h ago"); axisM.stringValue = L("绿色 = 接电", "green = on AC"); axisR.stringValue = L("现在", "now")
        recordsButton.title = L("记录曲线与明细…", "Chart and records…"); recordsCount = -1; refreshRecords()
        for (i, c) in cards.enumerated() { c.caption.stringValue = caps[i] }
        lidLabel.stringValue = L("合盖不休眠（继续运行）", "Keep running with the lid closed")
        langButton.title = english ? "中文" : "English"
        quitButton.title = L("退出 powerbar", "Quit powerbar")
    }
    func resize() {
        panel.layoutSubtreeIfNeeded()
        let h = panel.fittingSize.height
        panel.setFrameSize(NSSize(width: width, height: h))
        panelItem.view = panel
    }
    func menuWillOpen(_ menu: NSMenu) { tick(); resize() }

    func applicationDidFinishLaunching(_ n: Notification) {
        // power card
        let top = hstack([bigWatts, spacer(), battIcon])
        let power = Card([top, battState, timeLine, sysLine, socLine])
        power.stack.setCustomSpacing(2, after: top); power.stack.setCustomSpacing(6, after: battState)
        power.stack.setCustomSpacing(4, after: sysLine)
        // options card
        lidSwitch.controlSize = .mini; lidSwitch.target = self; lidSwitch.action = #selector(toggleLid(_:))
        for b in [langButton, quitButton] { b.bezelStyle = .rounded; b.controlSize = .small; b.target = self }
        langButton.action = #selector(toggleLanguage); quitButton.action = #selector(quit)
        let opts = Card([hstack([lidLabel, spacer(), lidSwitch]), hstack([langButton, spacer(), quitButton])])
        recordsButton.bezelStyle = .rounded; recordsButton.controlSize = .small; recordsButton.target = self; recordsButton.action = #selector(showRecords)
        let axis = hstack([axisL, spacer(), axisM, spacer(), axisR])
        let hist = Card([chart, axis, sessionLine, historyLine, hstack([spacer(), recordsButton])])
        hist.stack.setCustomSpacing(2, after: chart)
        cards = [power, hist, opts]

        panel.orientation = .vertical; panel.alignment = .leading; panel.spacing = 8
        panel.setHuggingPriority(.required, for: .vertical)
        panel.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        for c in cards { panel.addArrangedSubview(c); c.widthAnchor.constraint(equalToConstant: width - 20).isActive = true }
        panel.widthAnchor.constraint(equalToConstant: width).isActive = true
        relabel()

        let menu = NSMenu(); menu.delegate = self
        menu.addItem(panelItem)
        item.menu = menu
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        _ = soc.read()   // first sample: the next one gives watts
        tick(); resize()
        // a sample on the way into sleep, and the next one after the wake marked as following a break
        let wsn = NSWorkspace.shared.notificationCenter
        wsn.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.history.willSleep() }
        wsn.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.history.didWake() }
        // .common: the panel keeps updating while the menu is open
        let t = Timer(timeInterval: 2, repeats: true) { _ in self.tick() }
        RunLoop.main.add(t, forMode: .common)
    }

    func tick() {
        var title = "—"
        if var b = batteryInfo() {
            // the gauge can report nonsense for a sample when the adapter is plugged or unplugged: keep the previous reading
            if abs(b.watts) > 150 { b.watts = lastWatts } else { lastWatts = b.watts }
            let w = b.watts
            if abs(w) < 0.05 { title = b.external ? "⚡︎0W" : "0W" }
            else if w > 0 { title = String(format: "⚡︎+%.1fW", w) }
            else { title = String(format: "%.1fW", w) }
            bigWatts.stringValue = abs(w) < 0.05 ? "0.0 W" : String(format: "%+.1f W", w)
            bigWatts.textColor = w > 0.05 ? .systemGreen : (w < -0.05 ? .labelColor : .secondaryLabelColor)
            let state = w > 0.05 ? L("充电", "Charging") : (w < -0.05 ? L("放电", "Discharging") : L("未充放电", "Idle"))
            battState.stringValue = "\(state) · \(b.percent)% · " + (b.external ? L("已接电源", "on AC") : L("电池供电", "on battery"))
            let level = b.percent >= 88 ? "100" : b.percent >= 63 ? "75" : b.percent >= 38 ? "50" : b.percent >= 13 ? "25" : "0"
            let name = w > 0.05 || (b.external && b.percent >= 99) ? "battery.100.bolt" : "battery.\(level)"
            battIcon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .regular))
            // a new direction (plugged in / unplugged) starts the average again
            if let a = battAvg, (a > 0) == (w > 0) { battAvg = a * 0.93 + w * 0.07 } else { battAvg = w }
            func hm(_ h: Double) -> String { let m = Int((h * 60).rounded()); return m >= 60 ? L("\(m / 60) 小时 \(m % 60) 分", "\(m / 60) h \(m % 60) min") : L("\(m) 分钟", "\(m) min") }
            let avg = battAvg ?? w
            if avg < -0.3, let left = b.whLeft { timeLine.stringValue = L("预计还能用 ", "About ") + hm(left / -avg) + String(format: L(" · 剩 %.0f Wh · 均 %.1f W", " left · %.0f Wh · avg %.1f W"), left, -avg) }
            else if avg > 0.3, let left = b.whLeft, let full = b.whFull, full > left { timeLine.stringValue = L("预计 ", "Full in about ") + hm((full - left) / avg) + L(" 后充满", "") }
            else if let m = b.minutes { timeLine.stringValue = (b.external ? L("预计充满还需 ", "Full in about ") : L("预计还能用 ", "Time left: about ")) + hm(Double(m) / 60) }
            else { timeLine.stringValue = b.external ? L("已接电源", "On AC power") : L("预计时间：计算中", "Estimating time left…") }
            if let s = b.system {
                var t = String(format: L("整机 %.1f W", "System %.1f W"), s)
                if b.external, let a = b.adapter { t += String(format: L(" · 适配器输入 %.1f W", " · adapter in %.1f W"), a) }
                sysLine.stringValue = t
            } else { sysLine.stringValue = L("整机功耗：读不到", "System power: no data") }
            history.add(pct: b.percent, wh: b.whLeft, w: w, ext: b.external)
            refreshHistory(whLeft: b.whLeft, whFull: b.whFull, external: b.external)
        } else { bigWatts.stringValue = "—"; battState.stringValue = L("读不到电池", "No battery data"); timeLine.stringValue = ""; sysLine.stringValue = "" }
        if let p = soc.read() {
            let k = 0.4
            socAvg = socAvg.map { ($0.cpu * (1 - k) + p.cpu * k, $0.gpu * (1 - k) + p.gpu * k, $0.ane * (1 - k) + p.ane * k, $0.dram * (1 - k) + p.dram * k) } ?? p
        }
        if let a = socAvg {
            var t = String(format: "CPU %.2f W · GPU %.2f W", a.cpu, a.gpu)
            if a.ane >= 0.01 { t += String(format: " · ANE %.2f W", a.ane) }
            t += String(format: L(" · 内存 %.2f W", " · DRAM %.2f W"), a.dram)
            if let c = temp.read() { t += String(format: " · %.0f°C", c) }
            socLine.stringValue = t
        } else { socLine.stringValue = L("读不到 SoC 功耗", "No SoC power data") }
        item.button?.title = title
        lidSwitch.state = lidAwake() ? .on : .off
    }
}

// the view drawn over the window background of its appearance (a bare cacheDisplay is transparent: white text on
// nothing looked like an empty picture in dark mode)
@discardableResult func snapshotPNG(_ v: NSView, _ path: String, _ look: NSAppearance) -> NSBitmapImageRep {
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    let dark = look.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    look.performAsCurrentDrawingAppearance {
        (dark ? NSColor(calibratedWhite: 0.16, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1)).setFill()
        v.bounds.fill()
        v.displayIgnoringOpacity(v.bounds, in: ctx)
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    return rep
}
let app = NSApplication.shared
let delegate = App()
// powerbar --snapshot <file.png> [dark]: draw the panel once into a picture (for looking at the layout); the history
// is not written in this mode
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--snapshot" {
    app.appearance = NSAppearance(named: CommandLine.arguments.count > 3 ? .darkAqua : .aqua)
    delegate.history.readOnly = true
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    Thread.sleep(forTimeInterval: 1); delegate.tick()
    if delegate.history.samples.count < 30 {      // a made-up day for the picture
        var smp: [Sample] = []; let now = Date().timeIntervalSince1970; var pct = 96.0
        for i in stride(from: 700, to: 0, by: -1) {
            let t = now - Double(i) * 60
            if i > 520 { pct -= 0.25 } else if i > 430 { continue } else if i > 330 { pct = min(100, pct + 0.6) } else { pct -= 0.2 }
            smp.append(Sample(t: t, pct: Int(pct), wh: pct * 0.7, w: i > 330 && i <= 430 ? 60 : -9, ext: i > 330 && i <= 430))
        }
        delegate.history.samples = smp
        delegate.refreshHistory(whLeft: 30, whFull: 70, external: false)
    }
    delegate.resize()
    let v = delegate.panel
    let win = NSWindow(contentRect: NSRect(origin: .zero, size: v.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
    win.backgroundColor = .windowBackgroundColor; win.contentView = v; win.appearance = app.appearance
    v.layoutSubtreeIfNeeded(); v.display()
    snapshotPNG(v, CommandLine.arguments[2], app.appearance!)
    exit(0)
}
// powerbar --snapshot-records <file.png> [dark] [segment]: the records window with three made-up days
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--snapshot-records" {
    app.appearance = NSAppearance(named: CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "dark" ? .darkAqua : .aqua)
    var smp: [Sample] = []; let now = Date().timeIntervalSince1970; var pct = 80.0
    for i in stride(from: 3 * 1440, to: 0, by: -5) {
        let c = i % 700
        if c > 300 { pct = max(5, pct - 0.2) } else if c > 220 { continue } else { pct = min(100, pct + 0.5) }
        let ac = c <= 220
        smp.append(Sample(t: now - Double(i) * 60, pct: Int(pct), wh: pct * 0.7, w: ac ? (pct >= 100 ? 0 : 60 - pct * 0.4) : -7 - Double(i % 37) * 0.2, ext: ac))
    }
    delegate.history.samples = smp
    let w = delegate.buildRecords(); delegate.recordsWindow = w
    if CommandLine.arguments.count > 4, let n = Int(CommandLine.arguments[4]) { delegate.rangeSeg.selectedSegment = n }
    w.appearance = app.appearance; delegate.refreshRecords()
    let v = w.contentView!; v.layoutSubtreeIfNeeded(); v.display()
    snapshotPNG(v, CommandLine.arguments[2], app.appearance!)
    exit(0)
}
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
