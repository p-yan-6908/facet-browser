import Foundation
import Darwin
setvbuf(stdout, nil, _IONBF, 0)

@_silgen_name("responsibility_get_pid_responsible_for_pid")
func respFor(_ pid: pid_t) -> pid_t

func footprint(of pid: pid_t) -> UInt64 {
    let size = MemoryLayout<rusage_info_v4>.stride
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
    defer { raw.deallocate() }
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    guard proc_pid_rusage(pid, 4, raw.assumingMemoryBound(to: rusage_info_t?.self)) == 0 else { return 0 }
    return raw.load(as: rusage_info_v4.self).ri_phys_footprint
}
func path(of pid: pid_t) -> String {
    let b = UnsafeMutablePointer<CChar>.allocate(capacity: 4096); defer { b.deallocate() }
    b[0] = 0
    guard proc_pidpath(pid, b, 4096) > 0 else { return "" }
    return String(cString: b)
}

// Usage: memreport [AppName ...]   e.g. memreport Kestrel "Google Chrome" Safari
let targets = CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst())
                                              : ["Kestrel", "Google Chrome", "Safari"]
let reported = proc_listallpids(nil, 0)
var pids = [pid_t](repeating: 0, count: Int(reported) * 2 + 64)
_ = proc_listallpids(&pids, Int32(pids.count * 4))
let live = pids.filter { $0 > 0 }.map { (pid: $0, path: path(of: $0)) }

func mb(_ b: UInt64) -> String { String(format: "%8.1f MB", Double(b) / 1048576) }
func kind(_ p: String) -> String {
    for k in ["WebContent", "Networking", "GPU", "Helper (Renderer)", "Helper (GPU)",
              "Helper (Plugin)", "Helper"] where p.contains(k) { return k }
    return "helper"
}

for target in targets {
    // The main app process(es).
    let roots = live.filter { $0.path.contains("/\(target).app/Contents/MacOS/") }.map { $0.pid }
    guard !roots.isEmpty else { print("\(target): not running\n"); continue }
    let rootSet = Set(roots)

    // Helpers: anything the kernel says this app is responsible for, plus Chrome-style
    // helpers that live inside the app bundle itself.
    var total: UInt64 = 0
    var rows: [(UInt64, String)] = []
    for r in roots { let f = footprint(of: r); total += f; rows.append((f, "\(target) (pid \(r))")) }
    var helpers = 0
    for proc in live where !rootSet.contains(proc.pid) {
        let inBundle = proc.path.contains("/\(target).app/")
        let isWebKit = proc.path.contains("WebKit.framework") || proc.path.contains("com.apple.WebKit")
        guard inBundle || isWebKit else { continue }
        guard rootSet.contains(respFor(proc.pid)) else { continue }
        let f = footprint(of: proc.pid)
        guard f > 0 else { continue }
        total += f; helpers += 1
        rows.append((f, "\u{2514}\u{2500} \(kind(proc.path)) (pid \(proc.pid))"))
    }
    for (f, label) in rows { print("\(mb(f))  \(label)") }
    print(String(repeating: "\u{2500}", count: 52))
    print("\(mb(total))  \(target): \(roots.count) app + \(helpers) helper process\(helpers == 1 ? "" : "es")\n")
}
