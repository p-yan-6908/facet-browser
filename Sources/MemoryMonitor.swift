import Foundation
import Darwin

/// Activity Monitor groups an app's WebKit helper processes under the app by asking
/// the kernel which process is "responsible" for each one. We do the same, so the
/// readout in the toolbar is the real total, not a flattering subset.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

struct MemorySample {
    var totalBytes: UInt64 = 0
    var appBytes: UInt64 = 0
    var helperCount: Int = 0

    var display: String {
        let mb = Double(totalBytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }
}

enum MemoryMonitor {

    /// Phys-footprint of one process, the same number Activity Monitor's "Memory" column shows.
    ///
    /// `proc_pid_rusage` is declared as taking `rusage_info_t *` (i.e. `void **`), but it
    /// actually expects the address of the struct itself -- callers in C cast `&rusage` to
    /// that type. Passing a pointer-to-pointer makes the kernel write the whole struct over
    /// an 8-byte slot.
    private static func footprint(of pid: pid_t) -> UInt64 {
        let size = MemoryLayout<rusage_info_v4>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let rc = proc_pid_rusage(pid, 4 /* RUSAGE_INFO_V4 */,
                                 raw.assumingMemoryBound(to: rusage_info_t?.self))
        guard rc == 0 else { return 0 }
        return raw.load(as: rusage_info_v4.self).ri_phys_footprint
    }

    static func sample() -> MemorySample {
        var s = MemorySample()
        let me = getpid()
        // Normally WebKit's XPC helpers are attributed straight to us. When Kestrel is
        // started from a shell instead of LaunchServices, responsibility is inherited
        // from that shell, so fall back to our own responsible ancestor.
        let myResponsible = responsibility_get_pid_responsible_for_pid(me)
        let accepted: Set<pid_t> = myResponsible > 0 && myResponsible != me ? [me, myResponsible] : [me]
        s.appBytes = footprint(of: me)
        s.totalBytes = s.appBytes

        // proc_listallpids' return value has been documented as both a byte count and a
        // pid count; allocate generously and just skip empty slots so either is safe.
        let reported = proc_listallpids(nil, 0)
        guard reported > 0 else { return s }
        var pids = [pid_t](repeating: 0, count: Int(reported) * 2 + 64)
        let rc = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard rc > 0 else { return s }

        let pathBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 4096)
        defer { pathBuf.deallocate() }

        for pid in pids where pid > 0 && pid != me {
            pathBuf[0] = 0
            guard proc_pidpath(pid, pathBuf, 4096) > 0 else { continue }
            let path = String(cString: pathBuf)
            guard path.contains("WebKit.framework") || path.contains("com.apple.WebKit") else { continue }
            guard accepted.contains(responsibility_get_pid_responsible_for_pid(pid)) else { continue }
            let f = footprint(of: pid)
            guard f > 0 else { continue }
            s.totalBytes += f
            s.helperCount += 1
        }
        return s
    }
}
