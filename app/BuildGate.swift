// BuildGate menu bar app: shows running builds and edits ~/.buildgate/config.json,
// which the buildgate shims (go, npm, pnpm, ...) read on every invocation.
import Combine
import Darwin
import ServiceManagement
import SwiftUI

let baseDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".buildgate")
let lockDir = baseDir.appendingPathComponent("locks")
let configURL = baseDir.appendingPathComponent("config.json")
let allTools = ["go", "npm", "pnpm", "yarn", "npx", "bun"]

/// A build tool gated by subcommand (any argument starting with one of
/// `commands`); no commands means every run except version/help/watch.
struct Rule: Codable, Equatable {
    var tool: String
    var commands: [String]
    var enabled = true
}

let defaultRules = [
    Rule(tool: "flutter", commands: ["build", "test", "analyze", "drive"]),
    Rule(tool: "dart", commands: ["compile", "test", "analyze", "build_runner"]),
    Rule(tool: "xcodebuild", commands: []),
    Rule(tool: "swift", commands: ["build", "test"]),
    Rule(tool: "pod", commands: ["install", "update"]),
    Rule(tool: "gradle", commands: ["assemble", "build", "bundle", "test", "check", "lint", "install"]),
    Rule(tool: "react-native", commands: ["run-ios", "run-android", "build-ios", "build-android", "bundle"]),
    Rule(tool: "expo", commands: ["export", "prebuild"]),
    Rule(tool: "tsc", commands: []),
    Rule(tool: "vite", commands: ["build"]),
    Rule(tool: "next", commands: ["build", "lint"]),
    Rule(tool: "turbo", commands: ["build", "lint", "typecheck", "check"]),
    Rule(tool: "nx", commands: ["build", "lint", "typecheck"]),
    Rule(tool: "cargo", commands: ["build", "test", "check", "clippy", "install"]),
    Rule(tool: "mvn", commands: ["package", "install", "compile", "test", "verify"]),
    Rule(tool: "bazel", commands: ["build", "test"]),
    Rule(tool: "docker", commands: ["build"]),
]

struct Config: Codable, Equatable {
    var enabled = true
    var maxBuilds = 2
    var tools = allTools
    var goCommands = ["build", "test", "install", "vet"]
    var nodeScripts = ["build", "typecheck", "tsc", "lint", "eslint"]
    var whenFull = "reject"
    var killExtra = true
    var extraTools = ["golangci-lint", "staticcheck", "eslint"]
    var rules = defaultRules
    var limitXcode = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        maxBuilds = (try? c.decode(Int.self, forKey: .maxBuilds)) ?? d.maxBuilds
        tools = (try? c.decode([String].self, forKey: .tools)) ?? d.tools
        goCommands = (try? c.decode([String].self, forKey: .goCommands)) ?? d.goCommands
        nodeScripts = (try? c.decode([String].self, forKey: .nodeScripts)) ?? d.nodeScripts
        whenFull = (try? c.decode(String.self, forKey: .whenFull)) ?? d.whenFull
        killExtra = (try? c.decode(Bool.self, forKey: .killExtra)) ?? d.killExtra
        extraTools = (try? c.decode([String].self, forKey: .extraTools)) ?? d.extraTools
        rules = (try? c.decode([Rule].self, forKey: .rules)) ?? d.rules
        limitXcode = (try? c.decode(Bool.self, forKey: .limitXcode)) ?? d.limitXcode
    }

    /// Tools that get a shim in ~/.buildgate/bin (rule tools only when installed).
    var shimTools: [String] { extraTools + rules.filter(\.enabled).map(\.tool) }
}

struct XcodeBuild {
    var since: Date
    var lastBusy: Date
    var fd: Int32 = -1
    var rejected = false
    var cwd = ""
}

struct Build: Identifiable {
    let id: String
    let pid: pid_t
    let since: String
    let cwd: String
    let command: String
}

func parseBuild(_ url: URL) -> Build? {
    guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let lines = s.split(separator: "\n", maxSplits: 1).map(String.init)
    guard let head = lines.first else { return nil }
    var pid: pid_t = 0
    var since = ""
    var cwd = ""
    if let r = head.range(of: "cwd=") { cwd = String(head[r.upperBound...]) }
    for part in head.split(separator: " ") {
        if part.hasPrefix("pid=") { pid = pid_t(part.dropFirst(4)) ?? 0 }
        if part.hasPrefix("since=") { since = String(part.dropFirst(6)) }
    }
    guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return nil }
    let cmd = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    return Build(id: url.lastPathComponent, pid: pid, since: since, cwd: cwd, command: cmd)
}

struct Proc {
    let pid: pid_t
    let ppid: pid_t
    let cpu: Double  // % of one core
    let rssKB: Int
    let age: Int  // seconds
    let command: String
}

/// One build shown in the panel: a build process plus everything it spawned.
struct Row: Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    let command: String
    let cwd: String
    let age: Int
    let cpu: Double  // % of the whole machine
    let memBytes: UInt64
    let gated: Bool
}

let coreCount = Double(ProcessInfo.processInfo.activeProcessorCount)

let interpreters: Set<String> = ["node", "bash", "sh", "zsh", "ruby", "python", "python3"]
let genericScripts: Set<String> = ["cli", "index", "main"]
let scriptDirs: Set<String> = ["bin", "dist", "lib", "build", "src", "cli", ".bin"]

/// The tool the user ran, unwrapped from its interpreter:
/// `node …/pnpm.cjs build` → pnpm build, `ruby …/pod install` → pod install,
/// `dart … flutter_tools.snapshot build apk` → flutter build apk,
/// `java … GradleWrapperMain assembleDebug` → gradle assembleDebug.
func unwrapCommand(_ command: String) -> [String] {
    var args = command.split(separator: " ").map(String.init)
    guard !args.isEmpty else { return [] }
    args[0] = (args[0] as NSString).lastPathComponent
    if let i = args.firstIndex(where: { $0.hasSuffix("flutter_tools.snapshot") }) {
        return ["flutter"] + args[(i + 1)...]
    }
    if args[0] == "java" {
        if let i = args.firstIndex(where: { $0.hasPrefix("org.gradle.") && ($0.hasSuffix(".GradleWrapperMain") || $0.hasSuffix(".GradleMain")) }) {
            return ["gradle"] + args[(i + 1)...]
        }
        return args
    }
    guard interpreters.contains(args[0]),
          let i = args.indices.dropFirst().first(where: { !args[$0].hasPrefix("-") }) else { return args }
    let script = (args[i] as NSString).lastPathComponent
    var name = (script as NSString).deletingPathExtension
    if let t = nodeTools.first(where: { script.hasPrefix($0) }) {
        name = t
    } else if genericScripts.contains(name) {
        // …/node_modules/expo/bin/cli → expo
        name = (args[i] as NSString).pathComponents.dropLast().reversed().first { !scriptDirs.contains($0) } ?? name
    }
    return [name] + args[(i + 1)...]
}

func displayCommand(_ command: String) -> String {
    let args = unwrapCommand(command)
    return args.isEmpty ? command : args.joined(separator: " ")
}

func formatAge(_ s: Int) -> String {
    if s < 60 { return "\(s)s" }
    if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
    return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
}

func formatBytes(_ b: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
}

func formatRate(_ bytesPerSecond: UInt64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .decimal
    f.allowsNonnumericFormatting = false  // "0 KB/s", not "Zero KB/s"
    return f.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
}

/// 0...1 on a log scale from 1 KB/s to 1 GB/s, for the network bars.
func rateLevel(_ bytesPerSecond: UInt64) -> Double {
    bytesPerSecond < 1000 ? 0 : (log10(Double(bytesPerSecond)) - 3) / 6
}

struct Killed: Identifiable {
    let id = UUID()
    let at: Date
    let command: String
    let cwd: String
}

func parseEtime(_ s: Substring) -> Int {
    // [[dd-]hh:]mm:ss
    var days = 0
    var rest = s
    if let dash = s.firstIndex(of: "-") {
        days = Int(s[..<dash]) ?? 0
        rest = s[s.index(after: dash)...]
    }
    let parts = rest.split(separator: ":").compactMap { Int($0) }
    let secs = parts.reduce(0) { $0 * 60 + $1 }
    return days * 86400 + secs
}

func listProcs() -> [Proc] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axww", "-o", "pid=,ppid=,pcpu=,rss=,etime=,command="]
    let pipe = Pipe()
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
        let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        guard f.count == 6, let pid = pid_t(f[0]), let ppid = pid_t(f[1]) else { return nil }
        return Proc(pid: pid, ppid: ppid, cpu: Double(f[2]) ?? 0, rssKB: Int(f[3]) ?? 0,
                    age: parseEtime(f[4]), command: String(f[5]))
    }
}

func isShim(_ pid: pid_t) -> Bool {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
    return String(cString: buf).hasSuffix("/.buildgate/bin/buildgate")
}

func procCwd(_ pid: pid_t) -> String {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
    return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
}

let gateBinURL = baseDir.appendingPathComponent("bin/buildgate")

struct AgentStatus: Decodable, Identifiable {
    let id: String
    let name: String
    let how: String
    let found: Bool
    let ready: Bool
}

func runGate(_ args: [String]) -> Data {
    let p = Process()
    p.executableURL = gateBinURL
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return Data() }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data
}
let eventsURL = baseDir.appendingPathComponent("events.jsonl")

/// Reads one environment variable of another (same-user) process.
func procEnv(_ pid: pid_t, _ key: String) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
    let prefix = Array((key + "=").utf8)
    var start = 4
    for i in 4..<size where buf[i] == 0 {
        if i > start, buf[start..<i].starts(with: prefix) {
            return String(decoding: buf[(start + prefix.count)..<i], as: UTF8.self)
        }
        start = i + 1
    }
    return nil
}

/// Appends a kill to events.jsonl so the agent's PostToolUse hook can explain it.
func logKillEvent(pid: pid_t, command: String, cwd: String, running: [String], max: Int) {
    var e: [String: Any] = ["time": Date().formatted(.iso8601), "kind": "killed", "command": command,
                            "cwd": cwd, "running": running, "max": max]
    if let id = procEnv(pid, "BUILDGATE_TOOL_ID") { e["tool"] = id }
    guard var data = try? JSONSerialization.data(withJSONObject: e, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0A)
    if !FileManager.default.fileExists(atPath: eventsURL.path) { FileManager.default.createFile(atPath: eventsURL.path, contents: nil) }
    if let h = try? FileHandle(forWritingTo: eventsURL) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    }
}

/// Copies the gate binary bundled in the app to ~/.buildgate/bin and creates
/// the go/npm/pnpm/... shims, so the DMG install is self-contained.
func installGate(extra: [String]) {
    linkShims(extra)
    // Rule tools (flutter, cargo, ...) only get a shim when installed, which
    // needs the user's shell PATH; the gate's own `install` checks that.
    DispatchQueue.global().async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "\"$HOME/.buildgate/bin/buildgate\" install"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if p.isRunning { p.terminate() } }
        p.waitUntilExit()
    }
}

private func linkShims(_ extra: [String]) {
    guard let bundled = Bundle.main.url(forResource: "buildgate", withExtension: nil) else { return }
    let fm = FileManager.default
    try? fm.createDirectory(at: gateBinURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.createDirectory(at: lockDir, withIntermediateDirectories: true)
    if fm.contentsEqual(atPath: bundled.path, andPath: gateBinURL.path) == false {
        let tmp = gateBinURL.appendingPathExtension("new")
        try? fm.removeItem(at: tmp)
        if (try? fm.copyItem(at: bundled, to: tmp)) != nil {
            _ = try? fm.replaceItemAt(gateBinURL, withItemAt: tmp)
            chmod(gateBinURL.path, 0o755)
        }
    }
    let dir = gateBinURL.deletingLastPathComponent()
    for tool in allTools + extra {
        let link = dir.appendingPathComponent(tool)
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != "buildgate" {
            try? fm.removeItem(at: link)
            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: "buildgate")
        }
    }
}

let logsDir = baseDir.appendingPathComponent("logs")

struct LogEntry: Identifiable, Hashable {
    var id: String { url.lastPathComponent }
    let url: URL
    let command: String
    let cwd: String
    let pid: pid_t
    let started: Date
    let exit: String?  // "0 (12s)", "75 (rejected)"; nil while running or lost
    let alive: Bool
}

/// Reads the header (and exit trailer) of a build log written by the gate.
func parseLog(_ url: URL) -> LogEntry? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    let head = String(decoding: h.readData(ofLength: 4096), as: UTF8.self)
    var command = "", cwd = "", pid: pid_t = 0
    var started = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    for line in head.split(separator: "\n").prefix(6) {
        if line.hasPrefix("# command: ") { command = String(line.dropFirst(11)) }
        if line.hasPrefix("# cwd: ") { cwd = String(line.dropFirst(7)) }
        if line.hasPrefix("# pid: ") { pid = pid_t(line.dropFirst(7)) ?? 0 }
        if line.hasPrefix("# started: "), let d = ISO8601DateFormatter().date(from: String(line.dropFirst(11))) { started = d }
    }
    let size = h.seekToEndOfFile()
    h.seek(toFileOffset: size > 512 ? size - 512 : 0)
    let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    var exit: String?
    if let r = tail.range(of: "# exit: ", options: .backwards) {
        exit = String(tail[r.upperBound...].prefix { $0 != "\n" })
    }
    let alive = exit == nil && pid > 0 && kill(pid, 0) == 0
    return LogEntry(url: url, command: command, cwd: cwd, pid: pid, started: started, exit: exit, alive: alive)
}

func listLogs() -> [LogEntry] {
    let files = (try? FileManager.default.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "log" }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }
        .prefix(150).compactMap(parseLog)
}

let ansiRegex = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

/// Last ~256 KB of a log, without the header and terminal color codes.
func readLogTail(_ url: URL) -> String {
    guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? h.close() }
    let size = h.seekToEndOfFile()
    let window: UInt64 = 256 * 1024
    h.seek(toFileOffset: size > window ? size - window : 0)
    var text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    if size > window { text = "… (showing the last 256 KB)\n" + text.drop { $0 != "\n" } }
    text = ansiRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    return text.replacingOccurrences(of: "\r", with: "\n")
}

let nodeTools: Set<String> = ["npm", "pnpm", "yarn", "npx", "bun"]

let quickArgs: Set<String> = ["version", "--version", "-v", "help", "--help", "-h", "--watch", "-w", "watch",
                               "-version", "-help", "-usage", "-list", "-showsdks", "-showBuildSettings",
                               "-showdestinations", "-showTestPlans"]

/// Same as the gate: an argument (or the last part of a:b:task) starts with a command.
func matchesCommand(_ args: ArraySlice<String>, _ commands: [String]) -> Bool {
    args.contains { a in
        guard !a.hasPrefix("-") else { return false }
        let last = a.split(separator: ":").last.map(String.init) ?? a
        return commands.contains { !$0.isEmpty && (a.hasPrefix($0) || last.hasPrefix($0)) }
    }
}

func isBuild(_ command: String, _ cfg: Config) -> Bool {
    let args = unwrapCommand(command)
    guard let tool = args.first else { return false }
    if cfg.extraTools.contains(tool) {
        return !args.dropFirst().contains { quickArgs.contains($0) }
    }
    if let r = cfg.rules.first(where: { $0.enabled && $0.tool == tool }) {
        if r.commands.isEmpty { return !args.dropFirst().contains { quickArgs.contains($0) } }
        return matchesCommand(args.dropFirst(), r.commands)
    }
    guard cfg.tools.contains(tool) else { return false }
    let rest = args.dropFirst().filter { !$0.hasPrefix("-") }
    if tool == "go" {
        guard let sub = rest.first else { return false }
        return cfg.goCommands.contains(sub)
    }
    guard nodeTools.contains(tool) else { return false }
    return rest.contains { a in cfg.nodeScripts.contains { a.hasPrefix($0) } }
}

func appendLog(_ line: String) {
    let url = baseDir.appendingPathComponent("killed.log")
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(Data((line + "\n").utf8))
        try? h.close()
    }
}

struct SystemStats {
    var cpu = 0.0  // 0...1
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var cpuTemp: Double?  // °C, hottest CPU die sensor; nil where unknown (Intel)
    var netIn: UInt64 = 0  // bytes per second, Wi-Fi and Ethernet
    var netOut: UInt64 = 0
}

final class SystemSampler {
    private var prev: (busy: UInt64, total: UInt64)?
    private var prevNet: (rx: UInt64, tx: UInt64, at: TimeInterval)?
    private let temps = TempSensors()

    func sample() -> SystemStats {
        var out = SystemStats()
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let t = load.cpu_ticks
            let user = UInt64(t.0), sys = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
            let busy = user + sys + nice, total = busy + idle
            if let p = prev, total > p.total { out.cpu = Double(busy - p.busy) / Double(total - p.total) }
            prev = (busy, total)
        }
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vkr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if vkr == KERN_SUCCESS {
            // Same as Activity Monitor's "Memory Used": app + wired + compressed.
            let page = UInt64(vm_kernel_page_size)
            let app = UInt64(vm.internal_page_count) - min(UInt64(vm.internal_page_count), UInt64(vm.purgeable_count))
            out.memUsed = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        }
        // Same as `sysctl vm.swapusage`; macOS grows the swap file on demand.
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            out.swapUsed = swap.xsu_used
            out.swapTotal = swap.xsu_total
        }
        out.cpuTemp = temps.cpu()
        let net = networkBytes(), now = ProcessInfo.processInfo.systemUptime
        if let p = prevNet, now > p.at, net.rx >= p.rx, net.tx >= p.tx {
            out.netIn = UInt64(Double(net.rx - p.rx) / (now - p.at))
            out.netOut = UInt64(Double(net.tx - p.tx) / (now - p.at))
        }
        prevNet = (net.rx, net.tx, now)
        return out
    }
}

/// Bytes received and sent so far on the Wi-Fi and Ethernet interfaces (en*),
/// with 64-bit counters. VPN tunnels and loopback are left out so traffic is
/// not counted twice.
func networkBytes() -> (rx: UInt64, tx: UInt64) {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var len = 0
    guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return (0, 0) }
    var buf = [UInt8](repeating: 0, count: len)
    guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }
    var rx: UInt64 = 0, tx: UInt64 = 0, i = 0
    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
    buf.withUnsafeBytes { p in
        while i + MemoryLayout<if_msghdr>.size <= len {
            let h = p.loadUnaligned(fromByteOffset: i, as: if_msghdr.self)
            if Int32(h.ifm_type) == RTM_IFINFO2, i + MemoryLayout<if_msghdr2>.size <= len {
                let m = p.loadUnaligned(fromByteOffset: i, as: if_msghdr2.self)
                if if_indextoname(UInt32(m.ifm_index), &name) != nil, String(cString: name).hasPrefix("en") {
                    rx += m.ifm_data.ifi_ibytes
                    tx += m.ifm_data.ifi_obytes
                }
            }
            guard h.ifm_msglen > 0 else { break }
            i += Int(h.ifm_msglen)
        }
    }
    return (rx, tx)
}

/// Apple silicon temperature sensors, read through IOKit's HID event system
/// (there is no public API for them; system monitor apps use the same). Looked up
/// with dlsym so a missing symbol only hides the temperature.
final class TempSensors {
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double
    private var client: AnyObject?  // owns the services below
    private var dies: [AnyObject] = []
    private var copyEvent: CopyEvent?
    private var getFloat: GetFloat?

    init() {
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
        typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
        typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
        typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
        guard let io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(io, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(io, "IOHIDEventSystemClientSetMatching"),
              let copyServices = dlsym(io, "IOHIDEventSystemClientCopyServices"),
              let copyProperty = dlsym(io, "IOHIDServiceClientCopyProperty"),
              let event = dlsym(io, "IOHIDServiceClientCopyEvent"),
              let float = dlsym(io, "IOHIDEventGetFloatValue"),
              let client = unsafeBitCast(create, to: Create.self)(kCFAllocatorDefault)?.takeRetainedValue()
        else { return }
        self.client = client
        // Apple vendor page 0xff00, usage 5: temperature sensors.
        _ = unsafeBitCast(setMatching, to: SetMatching.self)(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = unsafeBitCast(copyServices, to: CopyServices.self)(client)?.takeRetainedValue() as? [AnyObject] ?? []
        let product = unsafeBitCast(copyProperty, to: CopyProperty.self)
        // "PMU tdie1", "PMU2 tdie3", ...: the CPU dies.
        dies = services.filter { (product($0, "Product" as CFString)?.takeRetainedValue() as? String)?.contains("tdie") == true }
        copyEvent = unsafeBitCast(event, to: CopyEvent.self)
        getFloat = unsafeBitCast(float, to: GetFloat.self)
    }

    func cpu() -> Double? {
        guard let copyEvent, let getFloat else { return nil }
        let kIOHIDEventTypeTemperature: Int64 = 15
        let values = dies.compactMap { s -> Double? in
            guard let e = copyEvent(s, kIOHIDEventTypeTemperature, 0, 0)?.takeRetainedValue() else { return nil }
            let c = getFloat(e, Int32(kIOHIDEventTypeTemperature << 16))
            return c > 0 && c < 150 ? c : nil
        }
        return values.max()
    }
}

func childPids(_ pid: pid_t) -> [pid_t] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-P", String(pid)]
    let pipe = Pipe()
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let kids = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
    return kids + kids.flatMap(childPids)
}

@MainActor
final class Model: ObservableObject {
    @Published var config = Config() {
        didSet {
            guard config != oldValue else { return }
            save()
            if config.shimTools != oldValue.shimTools { installGate(extra: config.extraTools) }
        }
    }
    @Published var running: [Build] = []
    @Published var waiting: [Build] = []
    @Published var agents: [AgentStatus] = []
    private var ticks = 0
    @Published var killed: [Killed] = []
    @Published var rows: [Row] = []
    @Published var logs: [LogEntry] = []
    @Published var selectedLog: LogEntry.ID?
    @Published var waitingRows: [Row] = []
    @Published var system = SystemStats()
    private let sampler = SystemSampler()
    private var cwdCache: [pid_t: String] = [:]
    private var signalled: [pid_t: Date] = [:]
    private var configMtime: Date?
    private var timer: Timer?
    private var xcode: [pid_t: XcodeBuild] = [:]

    init() {
        if let d = try? Data(contentsOf: configURL), let c = try? JSONDecoder().decode(Config.self, from: d) {
            config = c
        }
        save()  // writes new default fields into older config files
        installGate(extra: config.extraTools)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func save() {
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(config).write(to: configURL, options: .atomic)
        configMtime = mtime(configURL)
    }

    private func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Picks up edits made to config.json outside the app.
    private func reloadIfChanged() {
        guard let m = mtime(configURL), m != configMtime else { return }
        configMtime = m
        if let d = try? Data(contentsOf: configURL), let c = try? JSONDecoder().decode(Config.self, from: d), c != config {
            config = c
        }
    }

    func refresh() {
        reloadIfChanged()
        let files = (try? FileManager.default.contentsOfDirectory(at: lockDir, includingPropertiesForKeys: nil)) ?? []
        let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        running = sorted.filter { $0.lastPathComponent.hasPrefix("slot.") }.compactMap(parseBuild)
        waiting = sorted.filter { $0.lastPathComponent.hasPrefix("wait.") }.compactMap(parseBuild)
        if ticks % 5 == 0 { loadAgents() }
        ticks += 1
        system = sampler.sample()
        logs = listLogs()

        let procs = listProcs()
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [pid_t: [Proc]] = [:]
        for p in procs { children[p.ppid, default: []].append(p) }
        trackXcode(procs, byPid, children)
        running = sorted.filter { $0.lastPathComponent.hasPrefix("slot.") }.compactMap(parseBuild)
        var builds = Set(procs.filter { isBuild($0.command, config) }.map(\.pid))
        builds.formUnion(xcode.filter { !$0.value.rejected }.keys)
        let waitingPids = Set(waiting.map(\.pid))
        let holding = Set(running.map(\.pid))
        // A root is a build with no build ancestor (pnpm build -> tsc counts once).
        signalled = signalled.filter { Date().timeIntervalSince($0.value) < 10 }
        let allRoots = procs.filter { p in
            guard builds.contains(p.pid), signalled[p.pid] == nil else { return false }
            var cur = p.ppid
            while cur > 1, let parent = byPid[cur] {
                if builds.contains(cur) { return false }
                cur = parent.ppid
            }
            return true
        }
        func row(_ p: Proc) -> Row {
            var cpu = 0.0, kb = 0
            var stack = [p]
            while let q = stack.popLast() {
                cpu += q.cpu
                kb += q.rssKB
                stack += children[q.pid] ?? []
            }
            if cwdCache[p.pid] == nil { cwdCache[p.pid] = procCwd(p.pid) }
            // Gated if it, or a parent (e.g. `buildgate <cmd>`), holds a slot.
            var gated = false
            var cur = p.pid
            while cur > 1, !gated, let q = byPid[cur] {
                gated = holding.contains(cur)
                cur = q.ppid
            }
            if let x = xcode[p.pid] {
                return Row(pid: p.pid, command: "Xcode build", cwd: x.cwd, age: Int(Date().timeIntervalSince(x.since)),
                           cpu: cpu / coreCount, memBytes: UInt64(kb) * 1024, gated: gated)
            }
            return Row(pid: p.pid, command: displayCommand(p.command), cwd: cwdCache[p.pid] ?? "", age: p.age,
                       cpu: cpu / coreCount, memBytes: UInt64(kb) * 1024, gated: gated)
        }
        // A shim still deciding (≈1s) to admit or reject a build is not counted yet.
        let deciding = Set(allRoots.filter { !holding.contains($0.pid) && isShim($0.pid) }.map(\.pid))
        let roots = allRoots.filter { !waitingPids.contains($0.pid) && !deciding.contains($0.pid) }
        rows = roots.sorted { $0.age > $1.age }.map(row)
        waitingRows = allRoots.filter { waitingPids.contains($0.pid) }.map(row)
        let live = Set(procs.map(\.pid))
        cwdCache = cwdCache.filter { live.contains($0.key) }

        if config.enabled && config.killExtra { enforce(roots: roots, holding: holding) }
    }

    /// Builds started from the Xcode app run inside its build service, so there
    /// is no command to shim. A busy service (it has compiler children) takes a
    /// slot like a gated build; with no free slot its jobs are killed, which
    /// fails the build in Xcode the same way the gate rejects a command.
    private func trackXcode(_ procs: [Proc], _ byPid: [pid_t: Proc], _ children: [pid_t: [Proc]]) {
        let now = Date()
        let services = procs.filter { p in
            guard p.command.contains("SWBBuildService") || p.command.contains("XCBBuildService"),
                  let parent = byPid[p.ppid] else { return false }
            return parent.command.split(separator: " ").first?.hasSuffix("/Contents/MacOS/Xcode") == true
        }
        let active = config.enabled && config.limitXcode
        for s in services {
            let kids = children[s.pid] ?? []
            if !kids.isEmpty {
                if xcode[s.pid] == nil {
                    var x = XcodeBuild(since: now, lastBusy: now)
                    x.cwd = kids.lazy.map { procCwd($0.pid) }.first { !$0.isEmpty && $0 != "/" } ?? ""
                    xcode[s.pid] = x
                }
                xcode[s.pid]?.lastBusy = now
            }
            guard var x = xcode[s.pid] else { continue }
            if now.timeIntervalSince(x.lastBusy) > 3 || !active {
                releaseSlot(x.fd)
                xcode[s.pid] = nil
                continue
            }
            if x.fd < 0 && !x.rejected {
                x.fd = acquireSlot(pid: s.pid, cwd: x.cwd, label: "Xcode build")
                if x.fd < 0 {
                    x.rejected = true
                    let held = running.map { "\(displayCommand($0.command))  (in \($0.cwd))" }
                    logKillEvent(pid: s.pid, command: "Xcode build", cwd: x.cwd, running: held, max: config.maxBuilds)
                    appendLog("\(now.formatted(.iso8601)) rejected Xcode build pid \(s.pid) cwd=\(x.cwd) max=\(config.maxBuilds)")
                    killed.insert(Killed(at: now, command: "Xcode build", cwd: x.cwd), at: 0)
                    if killed.count > 10 { killed.removeLast(killed.count - 10) }
                }
            }
            if x.rejected { for k in kids { stopTree(k.pid) } }
            xcode[s.pid] = x
        }
        for (pid, x) in xcode where !services.contains(where: { $0.pid == pid }) {
            releaseSlot(x.fd)
            xcode[pid] = nil
        }
    }

    private func acquireSlot(pid: pid_t, cwd: String, label: String) -> Int32 {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        for i in 0..<config.maxBuilds {
            let fd = open(lockDir.appendingPathComponent("slot.\(i)").path, O_RDWR | O_CREAT, 0o644)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                ftruncate(fd, 0)
                let owner = Array("pid=\(pid) since=\(f.string(from: Date())) cwd=\(cwd)\n\(label)\n".utf8)
                _ = owner.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                return fd
            }
            close(fd)
        }
        return -1
    }

    private func releaseSlot(_ fd: Int32) {
        guard fd >= 0 else { return }
        ftruncate(fd, 0)
        close(fd)
    }

    /// Kills the newest builds beyond the limit, including ones that never
    /// went through the shims (old shells, IDEs, other agents).
    func enforce(roots: [Proc], holding: Set<pid_t>) {
        let extra = roots.count - config.maxBuilds
        guard extra > 0 else { return }
        // Keep slot holders, then the oldest; kill the youngest. Wait while the
        // youngest is <2s old so the gate can reject it with a proper message.
        let victims = roots
            .filter { !holding.contains($0.pid) && !holding.contains($0.ppid) }
            .sorted { $0.age != $1.age ? $0.age < $1.age : $0.pid > $1.pid }
            .prefix(extra)
        if victims.contains(where: { $0.age < 2 }) { return }
        let seen = roots.map { "\($0.pid)<\($0.ppid) \($0.age)s" }.joined(separator: ", ")
        let keptDesc = roots.filter { r in !victims.contains { $0.pid == r.pid } }
            .map { "\(displayCommand($0.command))  (in \(cwdCache[$0.pid] ?? procCwd($0.pid)))" }
        for v in victims {
            let cwd = procCwd(v.pid)
            logKillEvent(pid: v.pid, command: displayCommand(v.command), cwd: cwd, running: keptDesc, max: config.maxBuilds)
            stopTree(v.pid)
            signalled[v.pid] = Date()
            appendLog("\(Date().formatted(.iso8601)) killed pid \(v.pid) [\(v.command)] cwd=\(cwd) roots=\(seen) max=\(config.maxBuilds)")
            killed.insert(Killed(at: Date(), command: v.command, cwd: cwd), at: 0)
        }
        if killed.count > 10 { killed.removeLast(killed.count - 10) }
    }

    func stopTree(_ pid: pid_t) {
        let all = [pid] + childPids(pid)
        for p in all.reversed() { kill(p, SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for p in all where kill(p, 0) == 0 { kill(p, SIGKILL) }
        }
    }

    /// Log of a running build: written by the gate wrapper that is `pid` or one of its parents.
    func logID(for row: Row) -> LogEntry.ID? {
        var cur = row.pid
        var parents: Set<pid_t> = []
        for _ in 0..<8 {
            parents.insert(cur)
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(cur, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid > 1 else { break }
            cur = pid_t(info.pbi_ppid)
        }
        return logs.first { $0.alive && parents.contains($0.pid) }?.id
    }

    func stop(_ pid: pid_t) {
        stopTree(pid)
        signalled[pid] = Date()
        rows.removeAll { $0.pid == pid }
        waitingRows.removeAll { $0.pid == pid }
    }

    /// Shells and AI agents, from `buildgate agents --json` (the gate owns setup).
    func loadAgents() {
        DispatchQueue.global().async {
            let data = runGate(["agents", "--json"])
            let list = (try? JSONDecoder().decode([AgentStatus].self, from: data)) ?? []
            DispatchQueue.main.async { self.agents = list }
        }
    }

    func setupAgent(_ id: String) {
        DispatchQueue.global().async {
            _ = runGate(["setup", id])
            DispatchQueue.main.async { self.loadAgents() }
        }
    }
}

@main
struct BuildGateApp: App {
    @StateObject private var model = Model()

    init() {
        // Hidden: `BuildGate --snapshot out.png` renders the panel and exits (for checking the UI).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                MainActor.assumeIsolated {
                    let m = Model()
                    m.refresh()
                    let logsShot = args.contains("--logs")
                    if logsShot { m.selectedLog = m.logs.first?.id }
                    let view = Group {
                        if logsShot {
                            HStack(spacing: 0) {
                                List(m.logs.prefix(6)) { e in Text(displayCommand(e.command)) }.frame(width: 260)
                                if let e = m.logs.first { LogDetail(entry: e) }
                            }.frame(width: 900, height: 420)
                        } else {
                            PanelView()
                        }
                    }.environmentObject(m)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, .dark)
                    let r = ImageRenderer(content: view)
                    r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: out)
                    }
                    exit(0)
                }
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            MenuLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        // Hidden: the menu bar panel in a normal window (`--panel-window`), for README screenshots.
        Window("BuildGate Panel", id: "panel") {
            PanelView().environmentObject(model)
                .ignoresSafeArea(.container, edges: .top)
                .onAppear {
                    // Look like the menu bar panel: no title bar or window buttons.
                    DispatchQueue.main.async {
                        for w in NSApp.windows where w.title == "BuildGate Panel" {
                            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                                w.standardWindowButton(b)?.isHidden = true
                            }
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("BuildGate Logs", id: "logs") {
            LogsView().environmentObject(model).modifier(DockWhileOpen())
        }
        .defaultSize(width: 980, height: 620)

        Window("BuildGate Settings", id: "settings") {
            SettingsView().environmentObject(model).modifier(DockWhileOpen())
        }
        .windowResizability(.contentSize)
    }
}

/// Menu bar label; also opens the Logs window at launch with `--open-logs` (for UI checks).
struct MenuLabel: View {
    @EnvironmentObject var model: Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            Image(systemName: model.config.enabled ? "hammer.fill" : "hammer")
            Text(model.config.enabled ? "\(model.rows.count)/\(model.config.maxBuilds)" : "off")
        }
        .onAppear {
            if CommandLine.arguments.contains("--open-logs") {
                // `--open-logs [TEXT]` selects the newest log whose command contains TEXT.
                let args = CommandLine.arguments
                let i = args.firstIndex(of: "--open-logs")!
                let match = i + 1 < args.count && !args[i + 1].hasPrefix("-") ? args[i + 1] : ""
                model.selectedLog = model.logs.first { match.isEmpty || $0.command.contains(match) }?.id
                openWindow(id: "logs")
            }
            if CommandLine.arguments.contains("--open-settings") { openWindow(id: "settings") }
            // Hidden, for README screenshots: `--panel-window` shows the panel in a
            // normal window; `--status-frame FILE` writes the status item's frame.
            let args = CommandLine.arguments
            if args.contains("--panel-window") { openWindow(id: "panel") }
            if let i = args.firstIndex(of: "--status-frame"), i + 1 < args.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let frames = NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") && $0.frame.minY > 0 }
                        .map { "\($0.frame.minX) \($0.frame.minY) \($0.frame.width) \($0.frame.height)" }
                    try? frames.joined(separator: "\n").write(toFile: args[i + 1], atomically: true, encoding: .utf8)
                }
            }
        }
    }
}

struct PanelView: View {
    @EnvironmentObject var model: Model
    @Environment(\.openWindow) private var openWindow
    @State private var size = CGSize.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppLogo(size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("BuildGate").font(.headline)
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $model.config.enabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            Grid(horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Meter(title: "CPU", value: model.system.cpu,
                          detail: "\(Int((model.system.cpu * 100).rounded()))%")
                    Meter(title: "Memory", value: Double(model.system.memUsed) / Double(max(model.system.memTotal, 1)),
                          detail: String(format: "%.1f / %.0f GB", Double(model.system.memUsed) / 1_073_741_824,
                                         Double(model.system.memTotal) / 1_073_741_824))
                    Meter(title: "Swap", value: model.system.swapTotal > 0 ? Double(model.system.swapUsed) / Double(model.system.swapTotal) : 0,
                          detail: formatBytes(model.system.swapUsed))
                        .help("Swap used \(formatBytes(model.system.swapUsed)) of \(formatBytes(model.system.swapTotal)) (macOS grows swap as needed)")
                }
                GridRow {
                    if let t = model.system.cpuTemp {
                        Meter(title: "Temp", value: t / 100, detail: "\(Int(t.rounded()))°C")
                            .help("Hottest CPU die sensor")
                    }
                    Meter(title: "↓ Down", value: rateLevel(model.system.netIn), detail: formatRate(model.system.netIn), tint: .accentColor)
                        .help("Received on Wi-Fi and Ethernet")
                    Meter(title: "↑ Up", value: rateLevel(model.system.netOut), detail: formatRate(model.system.netOut), tint: .accentColor)
                        .help("Sent on Wi-Fi and Ethernet")
                }
            }
            .padding(12)
            .panelSection()

            if model.rows.isEmpty && model.waitingRows.isEmpty {
                Label("No builds running", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .panelSection()
            }
            if !model.rows.isEmpty { section("Running", model.rows) }
            if !model.waitingRows.isEmpty { section("Waiting", model.waitingRows) }
            if !model.killed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(text: "Killed for going over the limit")
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.killed.prefix(5)) { k in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(k.command).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                                Text("\(k.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")) · \(k.at.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .panelSection()
                }
            }

            HStack(spacing: 8) {
                Button {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Label("Settings…", systemImage: "gearshape") }
                Button {
                    if model.selectedLog == nil { model.selectedLog = model.logs.first?.id }
                    openWindow(id: "logs")
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Label("Logs", systemImage: "doc.text") }
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
            }
            .panelButtons()
        }
        .padding(16)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .panelGlass()
        .background(PanelWindowFit(size: size))
    }

    func section(_ title: String, _ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: title)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    if i > 0 { Divider().padding(.horizontal, 10) }
                    BuildRow(row: r).padding(.horizontal, 10).padding(.vertical, 8)
                }
            }
            .panelSection()
        }
    }

    var summary: String {
        guard model.config.enabled else { return "Off: builds are not limited" }
        let mode = model.config.whenFull == "wait" ? "extra builds wait" : "extra builds are rejected"
        return "\(model.rows.count) of \(model.config.maxBuilds) builds running, \(mode)"
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
    }
}

extension View {
    /// A rounded, slightly lighter group inside the panel.
    func panelSection() -> some View {
        background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Liquid Glass on macOS 26+; the system panel background before that.
    /// (Needs the macOS 26 SDK, Xcode 26; older Xcode builds without it.)
    @ViewBuilder func panelGlass() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            containerBackground(.clear, for: .window)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder func panelButtons() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            buttonStyle(.glass).controlSize(.large)
        } else {
            buttonStyle(.bordered).controlSize(.large)
        }
        #else
        buttonStyle(.bordered).controlSize(.large)
        #endif
    }
}

/// Keeps the menu bar window the size of the panel, top edge fixed: SwiftUI's
/// MenuBarExtra window grows with its content but does not shrink back, which
/// left the panel floating in the middle of a too-tall window.
struct PanelWindowFit: NSViewRepresentable {
    let size: CGSize
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let w = v.window, size.height > 0, !w.styleMask.contains(.titled) else { return }
            var f = w.frame
            guard abs(f.height - size.height) > 0.5 else { return }
            f.origin.y += f.height - size.height
            f.size.height = size.height
            w.setFrame(f, display: true)
        }
    }
}

/// The app icon, for headers.
struct AppLogo: View {
    var size: CGFloat = 22
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// Shows BuildGate in the Dock and ⌘-Tab while one of its windows is open
/// (it is a menu bar app otherwise).
struct DockWhileOpen: ViewModifier {
    static var open = 0
    func body(content: Content) -> some View {
        content
            .onAppear {
                DockWhileOpen.open += 1
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            .onDisappear {
                DockWhileOpen.open = max(0, DockWhileOpen.open - 1)
                if DockWhileOpen.open == 0 { NSApp.setActivationPolicy(.accessory) }
            }
    }
}

struct Meter: View {
    let title: String
    let value: Double
    let detail: String
    var tint: Color?  // fixed color instead of turning orange/red when high

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint ?? (value > 0.85 ? Color.red : value > 0.65 ? Color.orange : Color.accentColor))
                        .frame(width: g.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
    }
}

struct BuildRow: View {
    @EnvironmentObject var model: Model
    @Environment(\.openWindow) private var openWindow
    let row: Row

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.command).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                    if !row.gated {
                        Text("not gated").font(.caption2).foregroundStyle(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .help("Started outside BuildGate (old terminal, IDE, other tool)")
                    }
                }
                Text("\(row.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")) · \(formatAge(row.age)) · pid \(String(row.pid))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text("CPU \(Int((row.cpu).rounded()))%").font(.caption).monospacedDigit()
                Text(formatBytes(row.memBytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(minWidth: 64, alignment: .trailing)
            let logID = model.logID(for: row)
            HStack(spacing: 4) {
                Button {
                    model.selectedLog = logID
                    openWindow(id: "logs")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "doc.text.magnifyingglass").frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .disabled(logID == nil)
                .help(logID == nil ? "Started outside BuildGate or in a terminal: output is not captured" : "Show live output")
                Button { model.stop(row.pid) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .help("Kill this build and everything it started")
            }
            .buttonStyle(.borderless).font(.system(size: 16))
        }
    }
}

struct LogsView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        NavigationSplitView {
            List(model.logs, selection: $model.selectedLog) { e in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        StatusDot(entry: e)
                        Text(displayCommand(e.command)).font(.system(.callout, design: .monospaced)).lineLimit(1)
                    }
                    Text("\(e.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    Text("\(e.started.formatted(date: .abbreviated, time: .standard)) · \(statusText(e))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            .overlay {
                if model.logs.isEmpty {
                    Text("No build logs yet").foregroundStyle(.secondary)
                }
            }
        } detail: {
            if let id = model.selectedLog, let e = model.logs.first(where: { $0.id == id }) {
                LogDetail(entry: e)
            } else {
                Text("Select a build").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

func statusText(_ e: LogEntry) -> String {
    if e.alive { return "running" }
    guard let x = e.exit else { return "ended (no exit recorded)" }
    if x.hasPrefix("0 ") { return "ok \(x.dropFirst(2))" }
    if x.contains("rejected") { return "rejected: too many builds" }
    if x.hasPrefix("143") || x.hasPrefix("137") { return "killed \(x)" }
    return "failed, exit \(x)"
}

struct StatusDot: View {
    let entry: LogEntry
    var color: Color {
        if entry.alive { return .blue }
        guard let x = entry.exit else { return .gray }
        if x.hasPrefix("0 ") { return .green }
        if x.contains("rejected") { return .orange }
        return .red
    }
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

struct LogDetail: View {
    @EnvironmentObject var model: Model
    let entry: LogEntry
    @State private var text = ""
    @State private var follow = true
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                StatusDot(entry: entry)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayCommand(entry.command)).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                    Text("\(entry.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")) · \(statusText(entry))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
                Button { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
                Button { NSWorkspace.shared.open(entry.url) } label: { Image(systemName: "arrow.up.forward.app") }
                    .help("Open in default editor")
                if entry.alive {
                    Button(role: .destructive) { model.stop(entry.pid) } label: { Label("Kill", systemImage: "xmark.circle.fill") }
                        .buttonStyle(.borderedProminent).tint(.red)
                }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    Text(text.isEmpty ? "(no output yet)" : text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: text) { _, _ in if follow { proxy.scrollTo("end", anchor: .bottom) } }
                .onAppear { load(); proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .onChange(of: entry.id) { _, _ in load() }
        .onReceive(tick) { _ in if entry.alive || text.isEmpty { load() } }
    }

    func load() {
        let body = readLogTail(entry.url)
        // drop the "# ..." header lines
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        let trimmed = lines.drop { $0.hasPrefix("# ") || $0.isEmpty }.joined(separator: "\n")
        if trimmed != text { text = trimmed }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: Model
    @State private var goText = ""
    @State private var nodeText = ""
    @State private var extraText = ""
    @State private var newTool = ""
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            HStack(spacing: 12) {
                AppLogo(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("BuildGate").font(.title3.weight(.semibold))
                    Text("Limits how many builds run at once")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            Section("Limit") {
                Toggle("Limit builds", isOn: $model.config.enabled)
                Stepper("Max builds at the same time: \(model.config.maxBuilds)", value: $model.config.maxBuilds, in: 1...16)
                Picker("When the limit is reached", selection: $model.config.whenFull) {
                    Text("Reject the new build (it fails)").tag("reject")
                    Text("Wait in line").tag("wait")
                }
                Toggle(isOn: $model.config.killExtra) {
                    Text("Kill builds that skip the limit")
                    Text("Watches all processes and kills the newest builds over the limit, even ones started from old terminals, IDEs or other tools.")
                }
            }
            Section("Tools to limit") {
                HStack {
                    ForEach(allTools, id: \.self) { tool in
                        Toggle(tool, isOn: Binding(
                            get: { model.config.tools.contains(tool) },
                            set: { on in
                                model.config.tools = allTools.filter { $0 == tool ? on : model.config.tools.contains($0) }
                            }))
                        .toggleStyle(.checkbox)
                        .padding(.trailing, 8)
                    }
                }
            }
            Section {
                TextField("Go commands", text: $goText, prompt: Text("build, test, install, vet"))
                    .onChange(of: goText) { _, v in model.config.goCommands = words(v) }
                TextField("npm / pnpm / yarn / bun scripts", text: $nodeText, prompt: Text("build, typecheck, tsc, lint, eslint"))
                    .onChange(of: nodeText) { _, v in model.config.nodeScripts = words(v) }
                TextField("Other heavy commands", text: $extraText, prompt: Text("golangci-lint, staticcheck, eslint"))
                    .onChange(of: extraText) { _, v in model.config.extraTools = words(v) }
            } header: {
                Text("Which commands count as a build")
            } footer: {
                Text("Comma separated. Go matches the exact subcommand (go build). Node matches any word that starts with it, so \"build\" also covers build:prod. Other heavy commands are always limited (except version/help), also when run from make. go run, dev servers and installs are never limited.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach($model.config.rules, id: \.tool) { $rule in
                    RuleRow(rule: $rule) { model.config.rules.removeAll { $0.tool == rule.tool } }
                }
                HStack {
                    TextField("Add a tool", text: $newTool, prompt: Text("tool name, e.g. webpack"))
                        .onSubmit(addTool)
                    Button("Add", action: addTool).disabled(newTool.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Toggle(isOn: $model.config.limitXcode) {
                    Text("Xcode app builds (⌘B, ⌘R)")
                    Text("Builds started in Xcode take a slot too. With no free slot, Xcode's build fails right away.")
                }
            } header: {
                Text("More build tools")
            } footer: {
                Text("A tool counts when any word starts with one of its commands (gradle assemble covers assembleDebug and :app:assembleRelease). Empty means every run except version, help and --watch. Tools that are not installed are skipped. Children of a limited build (flutter build → xcodebuild, gradle) count once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(model.agents.filter(\.found)) { a in
                    HStack {
                        Image(systemName: a.ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(a.ready ? .green : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name)
                            Text(a.how).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !a.ready { Button("Set up") { model.setupAgent(a.id) } }
                    }
                }
                if model.agents.contains(where: { $0.found && !$0.ready }) {
                    Button("Set up all") { model.setupAgent("all") }
                }
            } header: {
                Text("Shells and AI agents")
            } footer: {
                Text("With \"All shells\" set up, every terminal, IDE and agent (Cursor, Zed, Gemini, Aider, …) is limited. Claude Code and Codex also get hooks that tell the agent a build was rejected by BuildGate, not broken; other agents get a short note in their global instructions. Codex asks you to review a new hook once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("System") {
                Toggle("Open at login", isOn: $loginEnabled)
                    .onChange(of: loginEnabled) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { loginEnabled = SMAppService.mainApp.status == .enabled }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
        .onAppear {
            goText = model.config.goCommands.joined(separator: ", ")
            nodeText = model.config.nodeScripts.joined(separator: ", ")
            extraText = model.config.extraTools.joined(separator: ", ")
        }
    }

    func addTool() {
        let tool = newTool.trimmingCharacters(in: .whitespaces)
        guard !tool.isEmpty, !model.config.rules.contains(where: { $0.tool == tool }) else { return }
        model.config.rules.append(Rule(tool: tool, commands: ["build"]))
        newTool = ""
    }

    func words(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct RuleRow: View {
    @Binding var rule: Rule
    let remove: () -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 10) {
            Toggle(rule.tool, isOn: $rule.enabled)
                .font(.body.monospaced())
                .frame(width: 130, alignment: .leading)
            TextField("", text: $text, prompt: Text("every run"))
                .labelsHidden()
                .disabled(!rule.enabled)
                .onChange(of: text) { _, v in
                    rule.commands = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove \(rule.tool)")
        }
        .onAppear { text = rule.commands.joined(separator: ", ") }
    }
}
