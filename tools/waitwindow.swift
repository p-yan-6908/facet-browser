// Launches a command and reports how long until the named app puts a real window on
// screen. Uses the window server, so it measures time-to-usable-window rather than
// time-to-process-exists. Only unrestricted window keys are read (owner name, bounds),
// so no Screen Recording permission is needed.
//
//   waitwindow <AppOwnerName> <timeoutSeconds> -- <launch command...>
import Foundation
import CoreGraphics
setvbuf(stdout, nil, _IONBF, 0)

let argv = Array(CommandLine.arguments.dropFirst())
guard let sep = argv.firstIndex(of: "--"), sep >= 2 else {
    FileHandle.standardError.write(Data("usage: waitwindow <owner> <timeout> -- cmd...\n".utf8))
    exit(64)
}
let owner = argv[0]
let timeout = Double(argv[1]) ?? 30
let cmd = Array(argv[(sep + 1)...])

func hasWindow() -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return false }
    for w in list {
        guard (w[kCGWindowOwnerName as String] as? String) == owner else { continue }
        guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
        guard let b = w[kCGWindowBounds as String] as? [String: Any],
              let h = b["Height"] as? Double, let width = b["Width"] as? Double else { continue }
        if h > 200 && width > 300 { return true }   // a browser window, not a tooltip
    }
    return false
}

let t0 = Date()
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
p.arguments = cmd
p.standardOutput = FileHandle.nullDevice
p.standardError = FileHandle.nullDevice
try p.run()

while Date().timeIntervalSince(t0) < timeout {
    if hasWindow() {
        print(String(format: "%.2f", Date().timeIntervalSince(t0)))
        exit(0)
    }
    usleep(20_000)   // 20 ms
}
print("timeout")
exit(1)
