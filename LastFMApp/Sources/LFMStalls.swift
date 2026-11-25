import Foundation
import Darwin
#if canImport(UIKit)
import QuartzCore

// For the build's films only (-hitchLog YES, never on the phone): what the main thread was doing when it missed frames,
// so a hitch is named from its stack rather than guessed (Time Profiler's exports timed out on the runner, profile run 1).
// A watchdog thread watches the display link's heartbeat; once the main thread is more than 25 ms late it samples the
// main thread's stack every millisecond until the heartbeat returns. While the main thread is suspended nothing is
// allocated (the samples go into a buffer made up front): a lock the main thread holds would never be released.
// Caches/stalls.txt gets each stall over 40 ms: its start (seconds on the hitch log's clock), length, and every sample's
// frames, app frames as image+offset for atos (ci/lfm-stall-stacks.py), the rest as library`symbol.
final class StallSampler: @unchecked Sendable {
    static let shared = StallSampler()
    // Written by the display link on the main thread every frame; read by the watchdog. A plain double: a torn read
    // only shortens or lengthens one wait.
    nonisolated(unsafe) static var beat: CFTimeInterval = 0
    nonisolated(unsafe) static var origin: CFTimeInterval = 0
    private var main: thread_act_t = 0
    private let depth = 48
    private let capacity = 600_000
    private let buf: UnsafeMutablePointer<UInt64>
    private var used = 0
    private var started = false
    private init() { buf = .allocate(capacity: 600_000) }

    // Called on the main thread.
    func start() {
        guard !started else { return }
        started = true
        main = mach_thread_self()
        StallSampler.beat = CACurrentMediaTime()
        let t = Thread { [self] in run() }
        t.qualityOfService = .userInteractive
        t.start()
    }

    private func run() {
        while true {
            usleep(2_000)
            let now = CACurrentMediaTime()
            guard StallSampler.beat > 0, now - StallSampler.beat > 0.025 else { continue }
            // A stall: sampled until the heartbeat moves again.
            let began = StallSampler.beat
            let from = used
            var n = 0
            while StallSampler.beat == began, used + depth + 2 < capacity {
                sample(); n += 1
                usleep(1_000)
                if CACurrentMediaTime() - began > 8 { break }
            }
            let ms = (CACurrentMediaTime() - began) * 1000
            if ms >= 40, n > 0 { write(from: from, to: used, start: began - StallSampler.origin, ms: ms) }
            else { used = from }
        }
    }

    // One sample: the main thread suspended, its registers read, its frame-pointer chain walked into the buffer.
    private func sample() {
        guard thread_suspend(main) == KERN_SUCCESS else { return }
        let at = used
        buf[at] = UInt64(CACurrentMediaTime() * 1_000_000)
        var k = 0
        var pc: UInt64 = 0, fp: UInt64 = 0, lr: UInt64 = 0
        #if arch(arm64)
        var st = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &st) { p in p.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(main, ARM_THREAD_STATE64, $0, &count) } }
        if kr == KERN_SUCCESS { pc = st.__pc; fp = st.__fp; lr = st.__lr }
        #elseif arch(x86_64)
        var st = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &st) { p in p.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(main, x86_THREAD_STATE64, $0, &count) } }
        if kr == KERN_SUCCESS { pc = st.__rip; fp = st.__rbp }
        #endif
        let mask: UInt64 = 0x0000_FFFF_FFFF_FFFF
        if pc != 0 { buf[at + 2 + k] = pc & mask; k += 1 }
        if lr != 0 { buf[at + 2 + k] = lr & mask; k += 1 }
        var frame = (UInt64(0), UInt64(0))
        while fp != 0, k < depth {
            var got: vm_size_t = 0
            let r = withUnsafeMutableBytes(of: &frame) { b in
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), vm_size_t(16), vm_address_t(UInt(bitPattern: b.baseAddress!)), &got)
            }
            guard r == KERN_SUCCESS, got == 16 else { break }
            let next = frame.0, ret = frame.1 & mask
            if ret == 0 { break }
            buf[at + 2 + k] = ret; k += 1
            guard next > fp else { break }
            fp = next
        }
        thread_resume(main)
        buf[at + 1] = UInt64(k)
        used = at + 2 + k
    }

    // Each frame named: the app's own as image+offset (atos names them on the runner), the system's by dladdr.
    private var names: [UInt64: String] = [:]
    private func name(_ a: UInt64) -> String {
        if let n = names[a] { return n }
        var info = Dl_info()
        var out = String(format: "0x%llx", a)
        if dladdr(UnsafeRawPointer(bitPattern: UInt(a)), &info) != 0, let f = info.dli_fname {
            let path = String(cString: f)
            let lib = (path as NSString).lastPathComponent
            if path.contains(".app/") && !path.contains("/Frameworks/") {
                out = String(format: "@%@+0x%llx", lib, a - UInt64(UInt(bitPattern: info.dli_fbase)))
            } else if let s = info.dli_sname {
                out = lib + "`" + String(cString: s)
            } else { out = lib + "`?" }
        }
        names[a] = out
        return out
    }

    private func write(from: Int, to: Int, start: Double, ms: Double) {
        var lines = [String(format: "stall t %.2f ms %.0f", start, ms)]
        var i = from
        while i < to {
            let k = Int(buf[i + 1])
            var frames: [String] = []
            for j in 0..<k { frames.append(name(buf[i + 2 + j])) }
            lines.append("  " + frames.joined(separator: " | "))
            i += 2 + k
        }
        used = from
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("stalls.txt")
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }
}
#endif
