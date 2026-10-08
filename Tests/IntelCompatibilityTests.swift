// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Exercise the consumer policies with device identity and decoded SMC data;
/// no fixture can access GPU services, helper IPC, or fan writes.
enum IntelCompatibilityTests {
    class Fixture {
        var cpuTemperaturePlatform = CPUTemperaturePlatform.intel
        var lastGPUDeviceID: UInt64?
        var lastGPUUsage: Double?
        var missedGPUUsageSamples = 0
        var gpuTemperatureCache: CachedSensorReading?
        let historyCapacity = 120
        var gpuHistory = MetricHistory(capacity: 120)
    }

    static func run(_ suite: TestSuite) {
        FanControlGateTests.run(suite)
        let amd = GPUDeviceReading(registryID: 20, vendor: .amd, isBuiltIn: true, utilization: 0.18)
        let intel = GPUDeviceReading(registryID: 10, vendor: .intel, isBuiltIn: true, utilization: 0.03)
        let temperatures: [(key: String, value: Double)] = [("TGDD", 82), ("TG0P", 75)]
        func pair(_ devices: [GPUDeviceReading], _ readings: [(key: String, value: Double)] = [])
            -> (id: UInt64?, usage: Double?, temperature: Double?) {
            Monitor().readGPUMetrics(devices: devices, readings: readings)
        }
        for devices in [[amd, intel], [intel, amd], [amd]] {
            let result = pair(devices, temperatures)
            suite.expect(result.id == amd.registryID && result.usage == 0.18 && result.temperature == 82,
                         "AMD-first, Intel-first and AMD-only pair Radeon usage with Radeon temperature")
        }
        let intelOnly = pair([intel], temperatures)
        suite.expect(intelOnly.id == intel.registryID && intelOnly.usage == 0.03 && intelOnly.temperature == nil,
                     "Intel-only never borrows the absent Radeon temperature")
        let missingTemperature = pair([intel, amd], [("TG1P", 82)])
        suite.expect(missingTemperature.usage == 0.18 && missingTemperature.temperature == nil,
                     "selected Radeon without a validated sensor remains temperature-unavailable")
        let amdWithoutUsage = GPUDeviceReading(registryID: 20, vendor: .amd, isBuiltIn: true, utilization: nil)
        let missingUsage = pair([intel, amdWithoutUsage], temperatures)
        suite.expect(missingUsage.id == 20 && missingUsage.usage == nil && missingUsage.temperature == 82,
                     "missing Radeon utilization cannot substitute Intel utilization")
        let secondAMD = GPUDeviceReading(registryID: 30, vendor: .amd, isBuiltIn: true, utilization: 0.5)
        suite.expect(pair([amd, secondAMD], temperatures).temperature == nil,
                     "multiple internal AMD accelerators leave global SMC temperature association unavailable")
        let externalAMD = GPUDeviceReading(registryID: 5, vendor: .amd, isBuiltIn: false, utilization: 0.5)
        suite.expect(pair([externalAMD, intel], temperatures).id == 10
                     && pair([externalAMD], temperatures).temperature == nil,
                     "attached GPUs do not inherit built-in Radeon SMC sensors")
        suite.expect(pair([], temperatures).id == nil && pair([], temperatures).temperature == nil,
                     "missing accelerators do not fabricate a GPU identity or temperature")

        let monitor = Monitor()
        monitor.synchronizeGPUDevice(20)
        monitor.lastGPUUsage = 0.18
        monitor.missedGPUUsageSamples = 2
        monitor.gpuTemperatureCache = CachedSensorReading(value: 82, updatedAt: 1, missedSamples: 0)
        monitor.gpuHistory.push(0.18)
        monitor.synchronizeGPUDevice(20)
        suite.expect(monitor.lastGPUUsage == 0.18 && monitor.gpuTemperatureCache?.value == 82,
                     "sampling the same GPU preserves its own bridges")
        monitor.synchronizeGPUDevice(10)
        suite.expect(monitor.lastGPUUsage == nil && monitor.gpuTemperatureCache == nil
                     && monitor.missedGPUUsageSamples == 0 && monitor.gpuHistory.values.isEmpty,
                     "the production device-change handler clears usage, temperature and history together")
        monitor.lastGPUUsage = 0.03
        monitor.synchronizeGPUDevice(nil)
        suite.expect(monitor.lastGPUUsage == nil && monitor.lastGPUDeviceID == nil,
                     "GPU disappearance clears attributes before another device can be published")

        for (key, component) in [("TC1C", "cpu-core"), ("TC0P", "cpu-aux"),
                                 ("TCGC", "intel-igpu"), ("TGDD", "radeon-die"),
                                 ("TG0P", "radeon-proximity"), ("TB0T", "battery")] {
            let reading = SMCDiagnosticSemantics.reading(key: key, value: 65, platform: .intel)
            let line = SMCDiagnosticSemantics.line(key: key, dataType: "sp78", value: 65, platform: .intel)
            suite.expect(reading?.component == component && reading?.unit == "°C"
                         && line?.contains(component) == true && line?.hasSuffix("°C") == true,
                         "diagnostics classify and format validated \(key) as \(component) Celsius")
        }
        for (key, component) in [("TC0T", "cpu-trend"), ("TCZZ", "unknown"), ("TGZZ", "unknown")] {
            let reading = SMCDiagnosticSemantics.reading(key: key, value: 2, platform: .intel)
            let line = SMCDiagnosticSemantics.line(key: key, dataType: "sp78", value: 2, platform: .intel)
            suite.expect(reading?.component == component && reading?.unit == "raw"
                         && line?.contains("°C") == false && line?.hasSuffix("raw") == true,
                         "\(key) remains \(component) raw data, never an absolute CPU/GPU temperature")
        }
        suite.expect(SMCDiagnosticSemantics.line(key: "TC1C", dataType: "sp78", value: .nan, platform: .intel) == nil,
                     "diagnostics reject nonfinite readings")
        suite.expect(!TemperatureSensorSelector.isCPUTemperatureKey("TCGC", platform: .intel)
                     && !TemperatureSensorSelector.isCPUCoreKey("TCGC", platform: .intel),
                     "the iGPU does not re-enter CPU discovery or the core set")

        let gpuInputs = FanControlPolicy.gpuThermalInputs(
            readings: [("TGDD", 70), ("TG0P", 85), ("TGZZ", 110), ("TG1P", 115)], platform: .intel)
        suite.expect(gpuInputs == [70],
                     "Intel fan policy A uses the preferred die reading, not proximity or arbitrary TG inputs")
        let aggregated = FanControlPolicy.aggregatedTemperatures(
            cpuReadings: [("TC1C", 65)], gpuReadings: gpuInputs, platform: .intel)
        suite.expect(aggregated.first { $0.source == .hottestGPU }?.celsius == 70,
                     "fan curve consumer receives the same Intel GPU reading as display")
        suite.expect(FanControlPolicy.gpuThermalInputs(readings: [("TGDD", 130), ("TG0P", 85)], platform: .intel) == [85],
                     "fan input shares the proximity fallback only when the die reading is invalid")
        suite.expect(FanControlPolicy.gpuThermalInputs(readings: [("TGZZ", 100)], platform: .intel).isEmpty,
                     "unknown GPU-family keys cannot activate a curve input")
        suite.expect(FanControlPolicy.controlIsValidated(platform: .appleM1Family, hostAllowsControl: true)
                     && !FanControlPolicy.controlIsValidated(platform: .unmappedAppleSilicon, hostAllowsControl: false),
                     "physical Apple Silicon stays eligible under Rosetta; an unidentified x86 host fails closed")
        suite.expect(!FanControlPolicy.controlIsValidated(platform: .intel),
                     "Intel activation remains gated regardless of valid temperature discovery")

        let apple = GPUDeviceReading(registryID: 40, vendor: .apple, isBuiltIn: true, utilization: 0.25)
        for platform in [CPUTemperaturePlatform.appleM1Family, .appleM3Family, .unmappedAppleSilicon] {
            let devices = [externalAMD, apple]
            let appleMonitor = Monitor()
            appleMonitor.cpuTemperaturePlatform = platform
            let result = appleMonitor.readGPUMetrics(devices: devices, readings: [("Tg0D", 62), ("Tg1D", 67)])
            suite.expect(result.id == 40 && result.usage == 0.25 && result.temperature == 67,
                         "Apple GPU attributes belong to AGX and retain hottest Tg selection")
            suite.expect(FanControlPolicy.controlIsValidated(platform: platform),
                         "the Intel validation gate does not change Apple activation policy")
        }
        suite.expect(FanControlPolicy.gpuThermalInputs(readings: [("Tg0D", 62), ("Tg1D", 67)],
                                                       platform: .appleM1Family) == [62, 67],
                     "Apple fan temperature pooling remains unchanged")
    }
}
