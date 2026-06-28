import Foundation

// Scans a Windows .exe and its folder to figure out what tools are needed.
struct DetectionService {

    // Returns true if the exe looks like Steam
    static func isSteam(exePath: String) -> Bool {
        let name = URL(fileURLWithPath: exePath).lastPathComponent.lowercased()
        return name == "steam.exe" || name == "steamsetup.exe"
    }

    static func detect(exePath: String) -> GameDetection {
        var d = GameDetection()
        let url = URL(fileURLWithPath: exePath)
        let folder = url.deletingLastPathComponent().path

        // Steam gets DX12 + full prereqs by default
        if isSteam(exePath: exePath) {
            d.arch = "x64"
            d.directX = "dx12"
            d.needsDXVK = true
            d.needsVKD3D = true
            d.notes = ["Steam for Windows — full prerequisites will be installed (VC++, .NET, DXVK, VKD3D)."]
            return d
        }

        d.arch = readArch(exePath)
        d.directX = detectDirectX(folder: folder, exePath: exePath)
        d.antiCheat = detectAntiCheat(folder: folder)
        d.needsDXVK = ["dx9", "dx10", "dx11"].contains(d.directX)
        d.needsVKD3D = d.directX == "dx12"

        if let ac = d.antiCheat {
            d.notes.append("\(ac) detected — online multiplayer may not work. Single-player with bypass patch is supported.")
        }
        if d.needsVKD3D {
            d.notes.append("DX12 game — VKD3D-Proton will be installed.")
        }
        if d.needsDXVK {
            d.notes.append("DX\(d.directX.dropFirst(2)) game — DXVK will be installed.")
        }
        if d.arch == "x86" {
            d.notes.append("32-bit executable — will run with 32-bit Wine prefix (win32).")
        }
        return d
    }

    // Read PE header Machine field
    private static func readArch(_ path: String) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "unknown" }
        defer { fh.closeFile() }
        let header = fh.readData(ofLength: 0x40)
        guard header.count >= 0x40 else { return "unknown" }
        // PE offset is at 0x3C
        let peOffset = Int(header[0x3C]) | (Int(header[0x3D]) << 8) |
                       (Int(header[0x3E]) << 16) | (Int(header[0x3F]) << 24)
        fh.seek(toFileOffset: UInt64(peOffset + 4))
        let machineData = fh.readData(ofLength: 2)
        guard machineData.count == 2 else { return "unknown" }
        let machine = UInt16(machineData[0]) | (UInt16(machineData[1]) << 8)
        switch machine {
        case 0x014C: return "x86"
        case 0x8664: return "x64"
        default: return "unknown"
        }
    }

    // Check folder for DX-related DLLs + common patterns
    private static func detectDirectX(folder: String, exePath: String) -> String {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
        let lowered = items.map { $0.lowercased() }

        // DX12 indicators
        let dx12hints = ["d3d12.dll", "d3d12core.dll", "d3d12sdklayers.dll"]
        if dx12hints.contains(where: { lowered.contains($0) }) { return "dx12" }

        // DX11 indicators
        let dx11hints = ["d3d11.dll", "dxgi.dll"]
        if dx11hints.contains(where: { lowered.contains($0) }) { return "dx11" }

        // DX9 indicators
        let dx9hints = ["d3d9.dll", "d3dx9", "d3dx9_"]
        if dx9hints.contains(where: { hint in lowered.contains(where: { $0.hasPrefix(hint) }) }) { return "dx9" }

        // Fallback: scan strings in exe for DX imports
        return scanExeForDX(exePath) ?? "dx11"  // dx11 is safest default
    }

    private static func scanExeForDX(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        // Look for import strings
        func contains(_ needle: [UInt8]) -> Bool {
            return data.range(of: Data(needle)) != nil
        }
        let d3d12 = Array("D3D12".utf8)
        let d3d11 = Array("D3D11".utf8)
        let d3d9  = Array("D3D9".utf8)
        if contains(d3d12) { return "dx12" }
        if contains(d3d11) { return "dx11" }
        if contains(d3d9)  { return "dx9" }
        return nil
    }

    // Check for known anti-cheat files
    private static func detectAntiCheat(folder: String) -> String? {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(atPath: folder).map { $0.lowercased() }) ?? []

        let eacPatterns = ["easyanticheat", "eac_launcher", "easyanticheat_setup.exe"]
        if eacPatterns.contains(where: { pattern in items.contains(where: { $0.hasPrefix(pattern) }) }) {
            return "EAC"
        }
        let bePatterns = ["battleyeclient", "battleye"]
        if bePatterns.contains(where: { pattern in items.contains(where: { $0.hasPrefix(pattern) }) }) {
            return "BattlEye"
        }
        // Recurse one level into subdirs
        let subdirs = (try? fm.contentsOfDirectory(atPath: folder)
            .filter { (try? fm.contentsOfDirectory(atPath: "\(folder)/\($0)")) != nil }) ?? []
        for sub in subdirs.prefix(5) {
            let subItems = (try? fm.contentsOfDirectory(atPath: "\(folder)/\(sub)").map { $0.lowercased() }) ?? []
            if eacPatterns.contains(where: { p in subItems.contains(where: { $0.hasPrefix(p) }) }) { return "EAC" }
            if bePatterns.contains(where: { p in subItems.contains(where: { $0.hasPrefix(p) }) }) { return "BattlEye" }
        }
        return nil
    }
}
