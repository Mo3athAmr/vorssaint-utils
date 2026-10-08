// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Darwin
import Foundation

enum CPUTemperaturePlatform: Equatable {
    case intel
    case appleM1Family
    case appleM2Family
    case appleM3Family
    case appleM4Family
    case appleM5Family
    case unmappedAppleSilicon
    case generic
}

/// The panel represents one primary GPU, not whichever accelerator answered
/// first. Registry IDs also prevent cached readings crossing device changes.
struct GPUDeviceReading {
    enum Vendor { case amd, intel, apple, other }
    let registryID: UInt64
    let vendor: Vendor
    let isBuiltIn: Bool
    let utilization: Double?
}

enum GPUMetricAssociation {
    static func selectedDevice(_ devices: [GPUDeviceReading],
                               platform: CPUTemperaturePlatform) -> GPUDeviceReading? {
        if platform == .intel {
            // Preserve the target Mac's discrete-GPU panel semantics even
            // when the integrated accelerator is enumerated first. Missing
            // utilization must not substitute a different GPU's utilization.
            return devices.sorted {
                func priority(_ device: GPUDeviceReading) -> Int {
                    if device.isBuiltIn && device.vendor == .amd { return 0 }
                    if device.isBuiltIn && device.vendor == .intel { return 1 }
                    return 2
                }
                let left = priority($0), right = priority($1)
                return left == right ? $0.registryID < $1.registryID : left < right
            }.first
        }
        // Apple chip temperatures belong to AGX, never an attached eGPU.
        return devices.first { $0.vendor == .apple }
            ?? devices.first { $0.utilization != nil }
    }

    static func temperature(for device: GPUDeviceReading?,
                            devices: [GPUDeviceReading],
                            readings: [(key: String, value: Double)],
                            platform: CPUTemperaturePlatform) -> Double? {
        guard let device else { return nil }
        if platform == .intel {
            // SMC's Radeon keys have no registry ID. Associate them only with
            // the single built-in AMD accelerator; ambiguity stays unavailable.
            guard device.vendor == .amd, device.isBuiltIn,
                  devices.filter({ $0.vendor == .amd && $0.isBuiltIn }).count == 1 else { return nil }
        } else {
            guard device.vendor == .apple else { return nil }
        }
        return TemperatureSensorSelector.displayedGPUTemperature(readings: readings, platform: platform)
    }
}

struct SMCDiagnosticReading {
    let component: String
    let value: Double
    /// A codec supplies a number, not its physical units. Unknown/trend keys
    /// remain raw until their scale and time base have been established.
    let unit: String
}

enum SMCDiagnosticSemantics {
    static func line(key: String, dataType: String, value: Double,
                     platform: CPUTemperaturePlatform) -> String? {
        guard let reading = reading(key: key, value: value, platform: platform) else { return nil }
        return String(format: "%-18@  %@  %@  %6.2f %@",
                      locale: Locale(identifier: "en_US_POSIX"),
                      reading.component as NSString, key, dataType, reading.value, reading.unit)
    }

    static func reading(key: String, value: Double,
                        platform: CPUTemperaturePlatform) -> SMCDiagnosticReading? {
        guard value.isFinite else { return nil }
        let component: String
        if key.range(of: "^TB[0-9]T$", options: .regularExpression) != nil {
            component = "battery"
        } else if TemperatureSensorSelector.isCPUTemperatureKey(key, platform: platform) {
            component = TemperatureSensorSelector.isCPUCoreKey(key, platform: platform)
                ? "cpu-core" : "cpu-aux"
        } else if TemperatureSensorSelector.isGPUTemperatureKey(key, platform: platform) {
            component = platform == .intel ? (key == "TGDD" ? "radeon-die" : "radeon-proximity") : "gpu"
        } else if platform == .intel && key == "TCGC" {
            component = "intel-igpu"
        } else if platform == .intel && key == "TC0T" {
            return SMCDiagnosticReading(component: "cpu-trend", value: value, unit: "raw")
        } else if platform == .intel && (key.hasPrefix("TC") || key.hasPrefix("TG")) {
            return SMCDiagnosticReading(component: "unknown", value: value, unit: "raw")
        } else {
            return nil
        }
        guard value > 1, value < 125 else { return nil }
        return SMCDiagnosticReading(component: component, value: value, unit: "°C")
    }
}

struct CachedSensorReading {
    var value: Double
    var updatedAt: TimeInterval
    var missedSamples: Int
}

enum TemperatureSensorSelector {
    static let minimumChipTemperature = 10.0

    // Intel AppleSMC key names are case-sensitive. These were observed on a
    // MacBookPro16,1; TC1C...TC8C are the eight PECI core readings. TCGC is
    // the Intel integrated graphics core and is intentionally not a CPU key.
    private static let intelCPUCoreKeys = Set((1...8).map { "TC\($0)C" })
    private static let intelCPUAuxiliaryKeys: Set<String> = [
        "TC0E", "TC0F", "TC0P", "TCMX", "TCSA", "TCXC",
    ]
    // TGDD is the Radeon die reading on the target Mac. TG0P is a lower
    // confidence proximity fallback; VRAM/VR sensors are deliberately excluded.
    private static let intelGPUTemperatureKeys: Set<String> = ["TGDD", "TG0P"]

    private static let appleM1CPUCoreKeys: Set<String> = [
        "Tp09", "Tp0T",
        "Tp01", "Tp05", "Tp0D", "Tp0H",
        "Tp0L", "Tp0P", "Tp0X", "Tp0b",
    ]

    private static let appleM2CPUCoreKeys: Set<String> = [
        "Tp1h", "Tp1t", "Tp1p", "Tp1l",
        "Tp01", "Tp05", "Tp09", "Tp0D",
        "Tp0X", "Tp0b", "Tp0f", "Tp0j",
    ]

    private static let appleM3CPUCoreKeys: Set<String> = [
        "Te05", "Te0L", "Te0P", "Te0S",
        "Tf04", "Tf09", "Tf0A", "Tf0B",
        "Tf0D", "Tf0E", "Tf44", "Tf49",
        "Tf4A", "Tf4B", "Tf4D", "Tf4E",
    ]

    private static let appleM4CPUCoreKeys: Set<String> = [
        "Te05", "Te0S", "Te09", "Te0H",
        "Tp01", "Tp05", "Tp09", "Tp0D",
        "Tp0V", "Tp0Y", "Tp0b", "Tp0e",
    ]

    private static let appleM5CPUCoreKeys: Set<String> = [
        "Tp00", "Tp04", "Tp08", "Tp0C",
        "Tp0G", "Tp0K",
        "Tp0O", "Tp0R", "Tp0U", "Tp0X",
        "Tp0a", "Tp0d", "Tp0g", "Tp0j",
        "Tp0m", "Tp0p", "Tp0u", "Tp0y",
    ]

    static func platform(brandString: String?) -> CPUTemperaturePlatform {
        let brand = brandString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Preserve the established Tp/Te reading path for this supported chip
        // until a verified per-core map is available.
        if brand == "Apple A18 Pro" { return .generic }
        switch appleSiliconGeneration(in: brand) {
        case 1: return .appleM1Family
        case 2: return .appleM2Family
        case 3: return .appleM3Family
        case 4: return .appleM4Family
        case 5: return .appleM5Family
        default:
            if brand.hasPrefix("Apple ") { return .unmappedAppleSilicon }
            if brand.localizedCaseInsensitiveContains("Intel") { return .intel }
            return .generic
        }
    }

    static func currentPlatform() -> CPUTemperaturePlatform {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return .unmappedAppleSilicon
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return .unmappedAppleSilicon
        }
        return platform(brandString: String(cString: buffer))
    }

    static func displayedCPUTemperature(readings: [(key: String, value: Double)],
                                        platform: CPUTemperaturePlatform) -> Double? {
        let valid = readings.filter { isPlausibleTemperature($0.value) }
        guard !valid.isEmpty else { return nil }

        let core = valid.filter { isCPUCoreKey($0.key, platform: platform) }
        if let value = core.map({ $0.value }).max() {
            return value
        }
        // Not every Mac carries the sensors its chip generation is mapped to.
        // One that does not showed the hottest reading of its CPU families
        // instead, for as long as the app has had this panel, until 3.3.3
        // restricted the answer to the mapped sensors and left those Macs with
        // nothing. This is that reading, restored exactly. Fan control is a
        // separate decision and keeps requiring its own mapped readings.
        return valid.map { $0.value }.max()
    }

    static func hasCPUCoreSet(platform: CPUTemperaturePlatform) -> Bool {
        switch platform {
        case .intel, .appleM1Family, .appleM2Family, .appleM3Family, .appleM4Family, .appleM5Family:
            return true
        case .unmappedAppleSilicon, .generic: return false
        }
    }

    static func isCPUCoreKey(_ key: String, platform: CPUTemperaturePlatform) -> Bool {
        switch platform {
        case .intel:
            return intelCPUCoreKeys.contains(key)
        case .appleM1Family:
            return appleM1CPUCoreKeys.contains(key)
        case .appleM2Family:
            return appleM2CPUCoreKeys.contains(key)
        case .appleM3Family:
            return appleM3CPUCoreKeys.contains(key)
        case .appleM4Family:
            return appleM4CPUCoreKeys.contains(key)
        case .appleM5Family:
            return appleM5CPUCoreKeys.contains(key)
        case .unmappedAppleSilicon, .generic:
            return false
        }
    }

    static func isCPUTemperatureKey(_ key: String,
                                    platform: CPUTemperaturePlatform) -> Bool {
        if platform == .intel {
            return intelCPUCoreKeys.contains(key) || intelCPUAuxiliaryKeys.contains(key)
        }
        if key.hasPrefix("Tp") || key.hasPrefix("Te") { return true }
        return platform == .appleM3Family && key.hasPrefix("Tf")
    }

    static func isGPUTemperatureKey(_ key: String,
                                    platform: CPUTemperaturePlatform) -> Bool {
        if platform == .intel { return intelGPUTemperatureKeys.contains(key) }
        return key.hasPrefix("Tg")
    }

    static func displayedGPUTemperature(readings: [(key: String, value: Double)],
                                        platform: CPUTemperaturePlatform) -> Double? {
        let valid = readings.filter {
            isGPUTemperatureKey($0.key, platform: platform)
                && isPlausibleTemperature($0.value)
        }
        guard !valid.isEmpty else { return nil }
        if platform == .intel {
            return valid.first(where: { $0.key == "TGDD" })?.value
                ?? valid.first(where: { $0.key == "TG0P" })?.value
        }
        return valid.map(\.value).max()
    }

    static func stabilizedTemperature(_ reading: Double?,
                                      cache: inout CachedSensorReading?,
                                      now: TimeInterval,
                                      maxAge: TimeInterval,
                                      minimum: Double = 1) -> Double? {
        if let reading, reading > 1, reading >= minimum, reading < 125 {
            cache = CachedSensorReading(value: reading, updatedAt: now, missedSamples: 0)
            return reading
        }
        guard var cached = cache else { return nil }
        cached.missedSamples += 1
        if cached.missedSamples <= 4, now - cached.updatedAt <= maxAge {
            cache = cached
            return cached.value
        }
        cache = nil
        return nil
    }

    private static func appleSiliconGeneration(in brand: String) -> Int? {
        guard brand.hasPrefix("Apple M") else { return nil }
        let remainder = brand.dropFirst("Apple M".count)
        guard let first = remainder.first, let generation = Int(String(first)) else { return nil }
        guard generation >= 1, generation <= 5 else { return nil }
        let afterGeneration = remainder.dropFirst()
        guard afterGeneration.isEmpty || afterGeneration.first == " " else { return nil }
        return generation
    }

    private static func isPlausibleTemperature(_ value: Double) -> Bool {
        value >= minimumChipTemperature && value < 125
    }
}
