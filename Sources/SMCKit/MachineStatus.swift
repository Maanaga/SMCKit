//
// MachineStatus.swift
// SMCKit
//
// Aggregates CPU, memory, kernel, power, and battery data from Mach, sysctl,
// ProcessInfo, IOKit power sources, and optionally AppleSMC. Most fields are not
// provided by SMC alone; this is a convenience “system monitor” snapshot.

import Darwin
import Foundation
import IOKit.ps

/// Swift cannot import `HOST_CPU_LOAD_INFO_COUNT` / `HOST_VM_INFO64_COUNT` macros for these structs; use the same sizing as the C headers.
private let kHostCpuLoadInfoCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
private let kHostVMInfo64Count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

// MARK: - Public types

/// A point-in-time snapshot of machine status (CPU, memory, OS, power, battery).
public struct MachineStatus: Sendable {
    public var cpu: CPUStatus
    public var memory: MemoryStatus
    public var system: SystemStatus
    public var power: PowerStatus
    public var battery: BatteryStatusSnapshot?
    /// SMC-only extras when `SMCKit.open()` succeeded during capture.
    public var smcBattery: BatteryInfo?

    public init(
        cpu: CPUStatus,
        memory: MemoryStatus,
        system: SystemStatus,
        power: PowerStatus,
        battery: BatteryStatusSnapshot?,
        smcBattery: BatteryInfo? = nil
    ) {
        self.cpu = cpu
        self.memory = memory
        self.system = system
        self.power = power
        self.battery = battery
        self.smcBattery = smcBattery
    }
}

public struct CPUStatus: Sendable {
    public let physicalCores: Int
    public let logicalCores: Int
    /// Approximate recent CPU time shares (0–100), from two `host_statistics` samples.
    public let systemPercent: Double
    public let userPercent: Double
    public let idlePercent: Double
    public let nicePercent: Double
}

public struct MemoryStatus: Sendable {
    public let physicalBytes: UInt64
    public let freeBytes: UInt64
    public let wiredBytes: UInt64
    public let activeBytes: UInt64
    public let inactiveBytes: UInt64
    public let compressedBytes: UInt64
}

public struct SystemStatus: Sendable {
    public let hardwareModel: String
    public let sysname: String
    public let nodename: String
    public let release: String
    public let version: String
    public let machine: String
    public let uptimeSeconds: TimeInterval
    public let processCount: Int
    public let threadCount: Int
    public let loadAverage1m: Double
    public let loadAverage5m: Double
    public let loadAverage15m: Double
    /// Simple headroom heuristic: `max(0, logicalCores - load)` for each window.
    public let machFactor1m: Double
    public let machFactor5m: Double
    public let machFactor15m: Double
}

public struct PowerStatus: Sendable {
    /// `hw.cpufrequency / hw.cpufrequency_max` when both sysctl values are non-zero; otherwise `nil`.
    public let cpuSpeedLimitFraction: Double?
    public let logicalCPUsAvailable: Int
    /// Always `nil` unless we add a dedicated scheduler query; display as 100% when nil.
    public let schedulerLimitFraction: Double?
    public let thermalStateDescription: String
}

public struct BatteryStatusSnapshot: Sendable {
    public let isACPowered: Bool
    public let isFullyCharged: Bool
    public let isCharging: Bool
    public let chargePercent: Double
    public let currentCapacitymAh: Int?
    public let maxCapacitymAh: Int?
    public let designCapacitymAh: Int?
    public let cycleCount: Int?
    public let maxCycleCount: Int?
    /// From IOKit `Temperature` key (°C) when present.
    public let temperatureCelsius: Double?
    /// Minutes until empty (or until full when charging), when reported.
    public let timeRemainingMinutes: Int?
}

// MARK: - Capture

extension MachineStatus {

    /// Builds a snapshot. Optionally opens SMC briefly to attach `smcBattery` (does not throw if SMC is unavailable).
    public static func capture(
        loadSampleInterval: TimeInterval = 0.08,
        includeSMCBattery: Bool = true
    ) -> MachineStatus {
        let logical = Int(sysctlInt32("hw.logicalcpu") ?? sysctlInt32("hw.ncpu") ?? 1)
        let physical = Int(sysctlInt32("hw.physicalcpu") ?? sysctlInt32("hw.logicalcpu") ?? 1)

        let cpuPercents = sampleCpuPercents(intervalMicroseconds: useconds_t(loadSampleInterval * 1_000_000))

        let mem = captureMemory()

        let loads = MachineStatusHelpers.loadAverages()
        let threads = sysctlUint32("kern.num_taskthreads").map(Int.init) ?? 0
        let procs = MachineStatusHelpers.processCount()

        let mach1 = max(0, Double(logical) - loads.0)
        let mach5 = max(0, Double(logical) - loads.1)
        let mach15 = max(0, Double(logical) - loads.2)

        let power = capturePower(logicalCPUs: logical)

        let battery = captureBatteryFromIOPS()

        var smcBat: BatteryInfo?
        if includeSMCBattery {
            do {
                try SMCKit.open()
                defer { SMCKit.close() }
                smcBat = try SMCKit.batteryInformation()
            } catch {
                smcBat = nil
            }
        }

        let ua = MachineStatusHelpers.unameAll()

        return MachineStatus(
            cpu: CPUStatus(
                physicalCores: physical,
                logicalCores: logical,
                systemPercent: cpuPercents.system,
                userPercent: cpuPercents.user,
                idlePercent: cpuPercents.idle,
                nicePercent: cpuPercents.nice
            ),
            memory: mem,
            system: SystemStatus(
                hardwareModel: sysctlString("hw.model") ?? "(unknown)",
                sysname: ua.sysname,
                nodename: ua.nodename,
                release: ua.release,
                version: ua.version,
                machine: ua.machine,
                uptimeSeconds: MachineStatusHelpers.uptimeSeconds(),
                processCount: procs,
                threadCount: threads,
                loadAverage1m: loads.0,
                loadAverage5m: loads.1,
                loadAverage15m: loads.2,
                machFactor1m: mach1,
                machFactor5m: mach5,
                machFactor15m: mach15
            ),
            power: power,
            battery: battery,
            smcBattery: smcBat
        )
    }
}

// MARK: - SMCKit convenience

extension SMCKit {

    /// Full “machine status” snapshot (Mach, sysctl, IOKit power, optional SMC battery flags).
    public static func machineStatus(
        loadSampleInterval: TimeInterval = 0.08,
        includeSMCBattery: Bool = true
    ) -> MachineStatus {
        MachineStatus.capture(loadSampleInterval: loadSampleInterval, includeSMCBattery: includeSMCBattery)
    }

    /// Same data as ``machineStatus`` as a printable block (similar to classic system monitor output).
    public static func machineStatusReport(
        loadSampleInterval: TimeInterval = 0.08,
        includeSMCBattery: Bool = true
    ) -> String {
        MachineStatus.capture(loadSampleInterval: loadSampleInterval, includeSMCBattery: includeSMCBattery)
            .formattedReport()
    }
}

// MARK: - Formatting

extension MachineStatus: CustomStringConvertible {

    public var description: String { formattedReport() }

    public func formattedReport() -> String {
        var lines: [String] = []
        lines.append("// MACHINE STATUS")
        lines.append("")
        lines.append("-- CPU --")
        lines.append(MachineStatusHelpers.padded("PHYSICAL CORES:", "\(cpu.physicalCores)"))
        lines.append(MachineStatusHelpers.padded("LOGICAL CORES:", "\(cpu.logicalCores)"))
        lines.append(MachineStatusHelpers.padded("SYSTEM:", String(format: "%.0f%%", cpu.systemPercent)))
        lines.append(MachineStatusHelpers.padded("USER:", String(format: "%.0f%%", cpu.userPercent)))
        lines.append(MachineStatusHelpers.padded("IDLE:", String(format: "%.0f%%", cpu.idlePercent)))
        lines.append(MachineStatusHelpers.padded("NICE:", String(format: "%.0f%%", cpu.nicePercent)))
        lines.append("")
        lines.append("-- MEMORY --")
        lines.append(MachineStatusHelpers.padded("PHYSICAL SIZE:", MachineStatusHelpers.bytesToGB(memory.physicalBytes)))
        lines.append(MachineStatusHelpers.padded("FREE:", MachineStatusHelpers.bytesToGB(memory.freeBytes)))
        lines.append(MachineStatusHelpers.padded("WIRED:", MachineStatusHelpers.bytesToMB(memory.wiredBytes)))
        lines.append(MachineStatusHelpers.padded("ACTIVE:", MachineStatusHelpers.bytesToGB(memory.activeBytes)))
        lines.append(MachineStatusHelpers.padded("INACTIVE:", MachineStatusHelpers.bytesToMB(memory.inactiveBytes)))
        lines.append(MachineStatusHelpers.padded("COMPRESSED:", MachineStatusHelpers.bytesToMB(memory.compressedBytes)))
        lines.append("")
        lines.append("-- SYSTEM --")
        lines.append(MachineStatusHelpers.padded("MODEL:", system.hardwareModel))
        lines.append(MachineStatusHelpers.padded("SYSNAME:", system.sysname))
        lines.append(MachineStatusHelpers.padded("NODENAME:", system.nodename))
        lines.append(MachineStatusHelpers.padded("RELEASE:", system.release))
        lines.append(MachineStatusHelpers.padded("VERSION:", system.version))
        lines.append(MachineStatusHelpers.padded("MACHINE:", system.machine))
        lines.append(MachineStatusHelpers.padded("UPTIME:", MachineStatusHelpers.formatUptime(system.uptimeSeconds)))
        lines.append(MachineStatusHelpers.padded("PROCESSES:", "\(system.processCount)"))
        lines.append(MachineStatusHelpers.padded("THREADS:", "\(system.threadCount)"))
        lines.append(MachineStatusHelpers.padded("LOAD AVERAGE:", String(format: "[%.2f, %.2f, %.2f]", system.loadAverage1m, system.loadAverage5m, system.loadAverage15m)))
        lines.append(MachineStatusHelpers.padded("MACH FACTOR:", String(format: "[%.3f, %.3f, %.3f]", system.machFactor1m, system.machFactor5m, system.machFactor15m)))
        lines.append("")
        lines.append("-- POWER --")
        let limitStr = power.cpuSpeedLimitFraction.map { String(format: "%.1f%%", $0 * 100) } ?? "N/A"
        lines.append(MachineStatusHelpers.padded("CPU SPEED LIMIT:", limitStr))
        lines.append(MachineStatusHelpers.padded("CPUs AVAILABLE:", "\(power.logicalCPUsAvailable)"))
        let schedStr = power.schedulerLimitFraction.map { String(format: "%.1f%%", $0 * 100) } ?? "100.0%"
        lines.append(MachineStatusHelpers.padded("SCHEDULER LIMIT:", schedStr))
        lines.append(MachineStatusHelpers.padded("THERMAL LEVEL:", power.thermalStateDescription))
        lines.append("")
        lines.append("-- BATTERY --")
        if let b = battery {
            lines.append(MachineStatusHelpers.padded("AC POWERED:", "\(b.isACPowered)"))
            lines.append(MachineStatusHelpers.padded("CHARGED:", "\(b.isFullyCharged)"))
            lines.append(MachineStatusHelpers.padded("CHARGING:", "\(b.isCharging)"))
            lines.append(MachineStatusHelpers.padded("CHARGE:", String(format: "%.1f%%", b.chargePercent)))
            lines.append(MachineStatusHelpers.padded("CAPACITY:", b.currentCapacitymAh.map { "\($0) mAh" } ?? "N/A"))
            lines.append(MachineStatusHelpers.padded("MAX CAPACITY:", b.maxCapacitymAh.map { "\($0) mAh" } ?? "N/A"))
            lines.append(MachineStatusHelpers.padded("DESGIN CAPACITY:", b.designCapacitymAh.map { "\($0) mAh" } ?? "N/A"))
            lines.append(MachineStatusHelpers.padded("CYCLES:", b.cycleCount.map(String.init) ?? "N/A"))
            lines.append(MachineStatusHelpers.padded("MAX CYCLES:", b.maxCycleCount.map(String.init) ?? "N/A"))
            let tempStr: String
            if let t = b.temperatureCelsius {
                tempStr = String(format: "%.1f°C", t)
            } else {
                tempStr = "N/A"
            }
            lines.append(MachineStatusHelpers.padded("TEMPERATURE:", tempStr))
            let timeStr = b.timeRemainingMinutes.map(MachineStatusHelpers.formatMinutes) ?? "N/A"
            lines.append(MachineStatusHelpers.padded("TIME REMAINING:", timeStr))
        } else {
            lines.append("  (no battery data — desktop or IOKit power sources unavailable)")
        }
        if let s = smcBattery {
            lines.append("")
            lines.append("-- SMC BATTERY (flags) --")
            lines.append(MachineStatusHelpers.padded("BATTERY COUNT:", "\(s.batteryCount)"))
            lines.append(MachineStatusHelpers.padded("AC PRESENT (SMC):", "\(s.isACPresent)"))
            lines.append(MachineStatusHelpers.padded("ON BATTERY:", "\(s.isBatteryPowered)"))
            lines.append(MachineStatusHelpers.padded("BATTERY OK:", "\(s.isBatteryOk)"))
            lines.append(MachineStatusHelpers.padded("CHARGING (SMC):", "\(s.isCharging)"))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Internals

private enum MachineStatusHelpers {

    static func padded(_ label: String, _ value: String) -> String {
        let pad = 18
        let l = label.count >= pad ? String(label.prefix(pad)) : label + String(repeating: " ", count: pad - label.count)
        return "  \(l)\(value)"
    }

    static func bytesToGB(_ b: UInt64) -> String {
        String(format: "%.2fGB", Double(b) / (1024 * 1024 * 1024))
    }

    static func bytesToMB(_ b: UInt64) -> String {
        String(format: "%.0fMB", Double(b) / (1024 * 1024))
    }

    static func formatUptime(_ seconds: TimeInterval) -> String {
        let s = Int64(max(0, seconds))
        let days = s / 86_400
        let hrs = (s % 86_400) / 3600
        let mins = (s % 3600) / 60
        let secs = s % 60
        return "\(days)d \(hrs)h \(mins)m \(secs)s"
    }

    static func formatMinutes(_ m: Int) -> String {
        if m < 0 { return "N/A" }
        let h = m / 60
        let mm = m % 60
        return String(format: "%d:%02d", h, mm)
    }

    static func loadAverages() -> (Double, Double, Double) {
        var load = [Double](repeating: 0, count: 3)
        let n = getloadavg(&load, 3)
        if n != 3 {
            return (0, 0, 0)
        }
        return (load[0], load[1], load[2])
    }

    static func uptimeSeconds() -> TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        let err = sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        guard err == 0 else { return 0 }
        let boot = TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - boot
    }

    /// Darwin `utsname` layout: five 256-byte C strings.
    static func unameAll() -> (sysname: String, nodename: String, release: String, version: String, machine: String) {
        var u = utsname()
        uname(&u)
        func field(_ offset: Int, _ len: Int) -> String {
            withUnsafePointer(to: &u) {
                $0.withMemoryRebound(to: Int8.self, capacity: MemoryLayout<utsname>.size) { raw in
                    let start = raw.advanced(by: offset)
                    let buf = UnsafeBufferPointer(start: start, count: len)
                    let arr = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                    return String(decoding: arr, as: UTF8.self)
                }
            }
        }
        return (
            field(0, 256),
            field(256, 256),
            field(512, 256),
            field(768, 256),
            field(1024, 256)
        )
    }

    /// `proc_listallpids(nil, 0)` returns the buffer size in bytes required for all PIDs.
    static func processCount() -> Int {
        let bytesNeeded = proc_listallpids(nil, 0)
        guard bytesNeeded > 0 else { return 0 }
        return Int(bytesNeeded) / MemoryLayout<pid_t>.size
    }
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    let len = buf.firstIndex(of: 0) ?? buf.count
    return String(decoding: buf.prefix(len).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func sysctlInt32(_ name: String) -> Int32? {
    var v: Int32 = 0
    var sz = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &v, &sz, nil, 0) == 0 else { return nil }
    return v
}

private func sysctlUint64(_ name: String) -> UInt64? {
    var v: UInt64 = 0
    var sz = MemoryLayout<UInt64>.size
    guard sysctlbyname(name, &v, &sz, nil, 0) == 0 else { return nil }
    return v
}

private func sysctlUint32(_ name: String) -> UInt32? {
    var v: UInt32 = 0
    var sz = MemoryLayout<UInt32>.size
    guard sysctlbyname(name, &v, &sz, nil, 0) == 0 else { return nil }
    return v
}

private func hostCpuLoad() -> host_cpu_load_info? {
    var load = host_cpu_load_info()
    let result = withUnsafeMutablePointer(to: &load) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(kHostCpuLoadInfoCount)) { buf in
            var count = kHostCpuLoadInfoCount
            return host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, buf, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return load
}

/// `cpu_ticks` order: USER, SYSTEM, IDLE, NICE (`CPU_STATE_*`).
private func cpuTickDeltas(_ a: host_cpu_load_info, _ b: host_cpu_load_info) -> (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
    let du = UInt64(b.cpu_ticks.0) &- UInt64(a.cpu_ticks.0)
    let ds = UInt64(b.cpu_ticks.1) &- UInt64(a.cpu_ticks.1)
    let di = UInt64(b.cpu_ticks.2) &- UInt64(a.cpu_ticks.2)
    let dn = UInt64(b.cpu_ticks.3) &- UInt64(a.cpu_ticks.3)
    return (du, ds, di, dn)
}

private func sampleCpuPercents(intervalMicroseconds: useconds_t) -> (system: Double, user: Double, idle: Double, nice: Double) {
    guard let first = hostCpuLoad() else { return (0, 0, 0, 0) }
    usleep(intervalMicroseconds)
    guard let second = hostCpuLoad() else { return (0, 0, 0, 0) }
    let d = cpuTickDeltas(first, second)
    let sum = Double(d.user + d.system + d.idle + d.nice)
    guard sum > 0 else { return (0, 0, 0, 0) }
    return (
        system: Double(d.system) / sum * 100,
        user: Double(d.user) / sum * 100,
        idle: Double(d.idle) / sum * 100,
        nice: Double(d.nice) / sum * 100
    )
}

private func captureMemory() -> MemoryStatus {
    let physical = sysctlUint64("hw.memsize") ?? 0
    let pageSize = UInt64(sysctlInt32("hw.pagesize") ?? 4096)

    var stats = vm_statistics64()
    let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(kHostVMInfo64Count)) { buf in
            var c = kHostVMInfo64Count
            return host_statistics64(mach_host_self(), HOST_VM_INFO64, buf, &c)
        }
    }
    guard kr == KERN_SUCCESS else {
        return MemoryStatus(
            physicalBytes: physical,
            freeBytes: 0,
            wiredBytes: 0,
            activeBytes: 0,
            inactiveBytes: 0,
            compressedBytes: 0
        )
    }

    let free = UInt64(stats.free_count) * pageSize
    let wired = UInt64(stats.wire_count) * pageSize
    let active = UInt64(stats.active_count) * pageSize
    let inactive = UInt64(stats.inactive_count) * pageSize
    let compressed = UInt64(stats.compressor_page_count) * pageSize

    return MemoryStatus(
        physicalBytes: physical,
        freeBytes: free,
        wiredBytes: wired,
        activeBytes: active,
        inactiveBytes: inactive,
        compressedBytes: compressed
    )
}

private func capturePower(logicalCPUs: Int) -> PowerStatus {
    let maxF = sysctlUint64("hw.cpufrequency_max") ?? 0
    let curF = sysctlUint64("hw.cpufrequency") ?? 0
    let frac: Double?
    if maxF > 0, curF > 0 {
        frac = Double(curF) / Double(maxF)
    } else {
        frac = nil
    }

    let thermalStr: String
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: thermalStr = "Nominal"
    case .fair: thermalStr = "Fair"
    case .serious: thermalStr = "Serious"
    case .critical: thermalStr = "Critical"
    @unknown default: thermalStr = "Not Published"
    }

    return PowerStatus(
        cpuSpeedLimitFraction: frac,
        logicalCPUsAvailable: logicalCPUs,
        schedulerLimitFraction: nil,
        thermalStateDescription: thermalStr
    )
}

private func captureBatteryFromIOPS() -> BatteryStatusSnapshot? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
    guard let array = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [AnyObject], !array.isEmpty else { return nil }

    var best: [String: Any]?
    for ref in array {
        guard let desc = IOPSGetPowerSourceDescription(blob, ref)?.takeUnretainedValue() as? [String: Any] else { continue }
        let type = desc["Type"] as? String
        if type == "InternalBattery" || type == "Battery" {
            best = desc
            break
        }
        best = best ?? desc
    }
    guard let dict = best ?? (array.first.flatMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }) else {
        return nil
    }

    let state = dict["Power Source State"] as? String
    let isAC = state == "AC Power"
    let isOnBattery = state == "Battery Power"

    let current = dict["Current Capacity"] as? Int ?? dict["Current"] as? Int
    let maxCap = dict["Max Capacity"] as? Int
    let design = dict["DesignCapacity"] as? Int ?? dict["Design Capacity"] as? Int

    let pct: Double
    if let c = current, let m = maxCap, m > 0 {
        pct = Double(c) / Double(m) * 100
    } else if let c = current {
        pct = Double(c)
    } else {
        pct = 0
    }

    let charging = dict["Is Charging"] as? Bool ?? ((dict["Is Charging"] as? String)?.lowercased() == "yes")
    let timeEmpty = dict["Time to Empty"] as? Int
    let timeFull = dict["Time to Full"] as? Int
    let timeRemaining: Int?
    if charging {
        timeRemaining = timeFull
    } else if isOnBattery {
        timeRemaining = timeEmpty
    } else {
        timeRemaining = timeEmpty ?? timeFull
    }

    let tempRaw = dict["Temperature"]
    let tempC: Double?
    if let t = tempRaw as? Double {
        tempC = interpretTemperature(t)
    } else if let t = tempRaw as? Int {
        tempC = interpretTemperature(Double(t))
    } else {
        tempC = nil
    }

    let cycles = dict["CycleCount"] as? Int ?? dict["Cycle Count"] as? Int
    let maxCycles = dict["AppleRawMaxCycleCount"] as? Int

    let fullyCharged: Bool
    if let c = current, let m = maxCap, m > 0 {
        fullyCharged = c >= m && !charging
    } else {
        fullyCharged = !charging && isAC
    }

    return BatteryStatusSnapshot(
        isACPowered: isAC || !isOnBattery,
        isFullyCharged: fullyCharged,
        isCharging: charging,
        chargePercent: min(100, max(0, pct)),
        currentCapacitymAh: current,
        maxCapacitymAh: maxCap,
        designCapacitymAh: design,
        cycleCount: cycles,
        maxCycleCount: maxCycles,
        temperatureCelsius: tempC,
        timeRemainingMinutes: timeRemaining
    )
}

private func interpretTemperature(_ raw: Double) -> Double {
    if raw > 500 {
        return raw / 100.0
    }
    if raw > 200 {
        return raw / 10.0
    }
    return raw
}
