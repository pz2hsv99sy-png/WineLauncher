import Foundation
import Darwin
import AppKit

@MainActor
class ResourceMonitor: ObservableObject {
    @Published var cpuPercent: Double = 0
    @Published var ramUsedGB: Double = 0
    @Published var ramTotalGB: Double = 0
    @Published var wineMemoryMB: Double = 0
    @Published var wineHistory: [Double] = []   // recent Wine RAM samples, for the graph

    private var timer: Timer?
    private var prevCPU: (user: UInt32, sys: UInt32, idle: UInt32) = (0, 0, 0)
    private let historyMax = 48
    private var seeded = false   // first real reading replaces the 0 baseline

    func start() {
        seeded = false
        wineHistory.removeAll()
        ramTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.update() }
        }
        update()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func update() {
        let cpu = readCPU()
        let ram = readRAMUsed()
        let wine = readWineMemory()

        // Exponential smoothing so the displayed numbers don't jitter every
        // tick. First real sample seeds the values directly.
        let a = 0.35
        if !seeded {
            cpuPercent = cpu; ramUsedGB = ram; wineMemoryMB = wine
            seeded = true
        } else {
            cpuPercent  = cpuPercent  * (1 - a) + cpu  * a
            ramUsedGB   = ramUsedGB   * (1 - a) + ram  * a
            wineMemoryMB = wineMemoryMB * (1 - a) + wine * a
        }

        // Keep a rolling history of Wine RAM for the sparkline graph.
        wineHistory.append(wineMemoryMB)
        if wineHistory.count > historyMax { wineHistory.removeFirst() }

        objectWillChange.send()
    }

    // MARK: - CPU via host_statistics

    private func readCPU() -> Double {
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpuInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = cpuInfo.cpu_ticks.0
        let sys  = cpuInfo.cpu_ticks.1
        let idle = cpuInfo.cpu_ticks.2

        let dUser = Double(user &- prevCPU.user)
        let dSys  = Double(sys  &- prevCPU.sys)
        let dIdle = Double(idle &- prevCPU.idle)
        let total = dUser + dSys + dIdle

        prevCPU = (user, sys, idle)
        guard total > 0 else { return 0 }
        return min(100, (dUser + dSys) / total * 100)
    }

    // MARK: - RAM via vm_statistics64

    private func readRAMUsed() -> Double {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = Double(vm_kernel_page_size)
        let used = Double(vmStats.active_count + vmStats.wire_count) * pageSize
        return used / 1_073_741_824
    }

    // MARK: - Wine process memory (real RSS via libproc, no shell spawn)

    private func readWineMemory() -> Double {
        // Enumerate every PID, keep the ones that belong to Wine (the
        // wine*-preloader / wineserver processes host the game too), and sum
        // their real resident memory. This replaces the old bogus estimate
        // (process count × 50 MB) which wildly over-counted orphan processes.
        let maxPids = Int(proc_listallpids(nil, 0))
        guard maxPids > 0 else { return 0 }
        var pids = [pid_t](repeating: 0, count: maxPids + 64)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return 0 }
        let n = Int(bytes) / MemoryLayout<pid_t>.size

        var totalBytes: UInt64 = 0
        var nameBuf = [CChar](repeating: 0, count: 1024)
        for i in 0..<n {
            let pid = pids[i]
            if pid <= 0 { continue }
            let nlen = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            guard nlen > 0 else { continue }
            let name = String(cString: nameBuf).lowercased()
            // Wine hosts every Windows process inside a *-preloader; wineserver
            // is the bottle manager. Both together are the real "Wine" footprint.
            guard name.contains("wine") else { continue }

            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            let r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
            if r == size { totalBytes += info.pti_resident_size }
        }
        return Double(totalBytes) / 1_048_576.0   // MB
    }
}
