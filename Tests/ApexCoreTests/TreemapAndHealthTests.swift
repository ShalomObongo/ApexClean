import XCTest

@testable import ApexCore

final class TreemapTests: XCTestCase {
    private func node(_ name: String, _ bytes: Int64) -> SpaceNode {
        SpaceNode(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            bytes: bytes,
            isDirectory: true,
            modified: nil
        )
    }

    func testTilesCoverTheContainerArea() {
        let nodes = [node("a", 500), node("b", 300), node("c", 150), node("d", 50)]
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let tiles = Treemap.layout(nodes, in: bounds)

        XCTAssertEqual(tiles.count, nodes.count)
        let totalArea = tiles.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        let expected = Double(bounds.width * bounds.height)
        XCTAssertEqual(totalArea, expected, accuracy: expected * 0.02, "Tiles should tile the container")
    }

    func testTileAreaIsProportionalToSize() {
        let nodes = [node("big", 750), node("small", 250)]
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let tiles = Treemap.layout(nodes, in: bounds)

        let big = tiles.first { $0.node.name == "big" }!
        let small = tiles.first { $0.node.name == "small" }!
        let ratio =
            Double(big.rect.width * big.rect.height)
            / Double(small.rect.width * small.rect.height)
        XCTAssertEqual(ratio, 3.0, accuracy: 0.15, "A 3:1 size ratio should give a 3:1 area ratio")
    }

    func testTilesStayInsideBounds() {
        let nodes = (1...20).map { node("n\($0)", Int64(21 - $0) * 100) }
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 480)
        for tile in Treemap.layout(nodes, in: bounds) {
            XCTAssertGreaterThanOrEqual(tile.rect.minX, -0.5)
            XCTAssertGreaterThanOrEqual(tile.rect.minY, -0.5)
            XCTAssertLessThanOrEqual(tile.rect.maxX, bounds.width + 0.5)
            XCTAssertLessThanOrEqual(tile.rect.maxY, bounds.height + 0.5)
        }
    }

    func testHandlesDegenerateInput() {
        XCTAssertTrue(Treemap.layout([], in: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
        XCTAssertTrue(Treemap.layout([node("z", 0)], in: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
        XCTAssertTrue(Treemap.layout([node("a", 10)], in: .zero).isEmpty)
    }
}

final class HealthScoreTests: XCTestCase {
    private func vitals(
        cpu: Double = 10,
        pressure: Double = 0.3,
        diskUsedFraction: Double = 0.5,
        thermal: ProcessInfo.ThermalState = .nominal,
        uptimeDays: Double = 1
    ) -> HealthScore {
        var cpuVitals = CPUVitals()
        cpuVitals.usage = cpu
        cpuVitals.logicalCores = 8

        var memory = MemoryVitals()
        memory.total = 16 * 1024 * 1024 * 1024
        memory.used = Int64(Double(memory.total) * 0.5)
        memory.pressure = pressure

        var storage = StorageVitals()
        storage.total = 500 * 1024 * 1024 * 1024
        storage.used = Int64(Double(storage.total) * diskUsedFraction)
        storage.free = storage.total - storage.used

        return HealthEvaluator.evaluate(
            cpu: cpuVitals,
            memory: memory,
            storage: storage,
            thermal: ThermalVitals(state: thermal),
            power: PowerVitals(),
            uptime: uptimeDays * 86_400
        )
    }

    func testHealthyMachineScoresHigh() {
        let score = vitals()
        XCTAssertGreaterThanOrEqual(score.value, 95)
        XCTAssertEqual(score.band, .excellent)
    }

    func testScoreIsBoundedToZeroHundred() {
        let worst = vitals(
            cpu: 100,
            pressure: 1.0,
            diskUsedFraction: 0.99,
            thermal: .critical,
            uptimeDays: 60
        )
        XCTAssertGreaterThanOrEqual(worst.value, 0)
        XCTAssertLessThanOrEqual(worst.value, 100)
        XCTAssertEqual(worst.band, .needsAttention)
    }

    func testScoreDecreasesMonotonicallyWithLoad() {
        // Higher CPU must never produce a better score — a bug that would let
        // the number rise as the machine got worse.
        var previous = 101
        for cpu in stride(from: 0.0, through: 100.0, by: 10.0) {
            let value = vitals(cpu: cpu).value
            XCTAssertLessThanOrEqual(value, previous, "Score rose as CPU went to \(cpu)%")
            previous = value
        }
    }

    func testEveryDeductionIsAttributable() {
        let score = vitals(cpu: 90, pressure: 0.9, diskUsedFraction: 0.95)
        let deducted = score.factors.reduce(0.0) { $0 + $1.deduction }
        XCTAssertEqual(Double(score.value), (100 - deducted).rounded(), accuracy: 1.0)
        for factor in score.significantFactors {
            XCTAssertFalse(factor.name.isEmpty)
            XCTAssertFalse(factor.detail.isEmpty, "A deduction must explain itself")
        }
    }

    func testStorageOnlyPenalisedWhenGenuinelyTight() {
        let roomy = vitals(diskUsedFraction: 0.5)
        let storageFactor = roomy.factors.first { $0.name == "Available storage" }
        XCTAssertEqual(storageFactor?.deduction ?? -1, 0, "Half-full disk is not a problem")
    }
}
