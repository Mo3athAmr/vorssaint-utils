// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Compile the actual hardware class against a read-only SMC double. Even a
/// broken gate cannot reach real hardware, and the double rejects every write.
enum FanControlGateTests {
    final class SMCClient {
        struct Key { let name: String; let dataType: String; let dataSize: UInt32 }
        static var values: [String: Double] = [:]
        static var reads = 0
        static var writes = 0
        init?() {}
        func key(named name: String) -> Key? {
            Self.reads += 1
            return Self.values[name].map { _ in Key(name: name, dataType: "sp78", dataSize: 2) }
        }
        func keys(where predicate: (String) -> Bool) -> [Key] {
            Self.values.keys.filter(predicate).map { Key(name: $0, dataType: "sp78", dataSize: 2) }
        }
        func readValue(_ key: Key) -> Double? { Self.values[key.name] }
        func readBytes(_ key: Key) -> [UInt8]? { nil }
        func writeValue(_ value: Double, to key: Key) throws {
            Self.writes += 1
            throw FanControlHardwareError.operationFailed
        }
        func writeBytes(_ bytes: [UInt8], to key: Key) throws {
            Self.writes += 1
            throw FanControlHardwareError.operationFailed
        }
    }

    static func run(_ suite: TestSuite) {
        SMCClient.values = [:]
        SMCClient.reads = 0
        SMCClient.writes = 0
        let hardware = Hardware(temperaturePlatform: .intel)!
        let operations: [(String, () throws -> Void)] = [
            ("probe", { _ = try hardware.readOnlySnapshot() }),
            ("validate", { try hardware.validateAutomaticControl() }),
            ("start", { _ = try hardware.startCooling(level: 100) }),
            ("update", { _ = try hardware.updateCooling(level: 100) }),
        ]
        for (name, operation) in operations {
            do {
                try operation()
                suite.expect(false, "Intel \(name) must reject unvalidated control")
            } catch FanControlHardwareError.unsupported {
                suite.expect(true, "Intel \(name) reports unsupported control")
            } catch {
                suite.expect(false, "Intel \(name) bypassed its validation gate: \(error)")
            }
        }
        suite.expect(SMCClient.reads == 0 && SMCClient.writes == 0,
                     "Intel activation gates run before fan discovery or any SMC write")
        SMCClient.values = ["TC1C": 65, "TCGC": 100, "TGDD": 70, "TG0P": 85, "TGZZ": 110]
        let temperatures = hardware.readTemperatures()
        suite.expect(temperatures.first { $0.source == .hottestGPU }?.celsius == 70
                     && temperatures.first { $0.source == .hottestCPU }?.celsius == 65,
                     "the production fan consumer uses preferred Radeon input and excludes iGPU/arbitrary keys")
        SMCClient.values = [:]
    }
}
