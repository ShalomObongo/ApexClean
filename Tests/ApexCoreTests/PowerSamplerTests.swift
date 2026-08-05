import IOKit.ps
import XCTest

@testable import ApexCore

final class PowerSamplerTests: XCTestCase {
    func testUPSIsNotReportedAsAnInternalBattery() {
        var vitals = PowerVitals()
        PowerSampler.mergePowerSource(
            [
                kIOPSTypeKey: kIOPSUPSType,
                kIOPSCurrentCapacityKey: 50,
                kIOPSMaxCapacityKey: 100,
            ],
            into: &vitals
        )
        XCTAssertFalse(vitals.hasBattery)
    }

    func testInternalBatteryPercentageIsClamped() {
        var vitals = PowerVitals()
        PowerSampler.mergePowerSource(
            [
                kIOPSTypeKey: kIOPSInternalBatteryType,
                kIOPSCurrentCapacityKey: 120,
                kIOPSMaxCapacityKey: 100,
                kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            ],
            into: &vitals
        )
        XCTAssertTrue(vitals.hasBattery)
        XCTAssertEqual(vitals.percentage, 100)
        XCTAssertTrue(vitals.isPluggedIn)
    }
}
