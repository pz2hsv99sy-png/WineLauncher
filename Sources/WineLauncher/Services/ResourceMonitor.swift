import Foundation
import Darwin

@MainActor
class ResourceMonitor: ObservableObject {
    @Published var cpuPercent: Double = 0
    @Published var ramUsedGB: Double = 0
    @Published var ramTotalGB: Double = 0
    @Published var wineMemoryMB: Double = 0

    private var timer: Timer?
    private var prevCPU: (user: UInt32, sys: UInt32, idle: UInt32) = (0, 0, 0)

    func start() {
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
        cpuPercent = readCPU()
        ramUsedGB = readRAMUsed()
        wineMemoryMB = readWineMemory()
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

    // MARK: - Wine process memory

    private func readWineMemory() -> Double {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "ps -A -o rss,comm | grep -i wine | awk '{s+=$1} END {print s}'"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "0"
        return (Double(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 1024
    }
}
