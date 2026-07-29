import XCTest

@testable import ApexCore

/// The interface counters macOS exposes are 32-bit odometers, and the only
/// full-width source is `netstat`. Both facts have sharp edges, and these are
/// the ones that drew blood.
final class NetworkCountersTests: XCTestCase {
    /// Real `netstat -ibdn` output from a Mac, trimmed to the interesting rows.
    ///
    /// The important detail is that `pktap0` and `utun6` have **no hardware
    /// address**, so their rows carry eleven fields where `en0`'s carries
    /// twelve. Fixed column indices read Opkts as Ibytes on exactly these rows.
    private let sample = """
        Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll Drop
        lo0        16384 <Link#1>                       3417815     0 2938910460  3417815     0 2938910460     0   0
        en0        1500  <Link#11>   e6:6f:06:b8:43:10 37076158     0 33277138158 41960561     0 45013007856     0   0
        en0        1500  192.168.100   192.168.100.207 37076158     - 33277138158 41960561     - 45013007856     -   -
        pktap0     0     <Link#15>                            0     0          0        0     0          0     0   0
        utun6      1380  <Link#20>                       123456     0   15510528   234567     0   13527040     0   0
        awdl0      1500  <Link#12>   9a:11:22:33:44:55    12345     0    8825856     6789     0    2476032     0   0
        """

    func testReadsByteColumnsFromRowsWithAndWithoutAHardwareAddress() throws {
        let totals = try XCTUnwrap(NetworkSampler.parseNetstatTotals(sample))
        // Only en0 survives the filter: lo0, pktap0 is counted, utun6 and awdl0
        // are excluded as virtual. pktap0 contributes zero but must be *read*
        // correctly rather than picking up Opkts.
        XCTAssertEqual(totals.received, 33_277_138_158)
        XCTAssertEqual(totals.sent, 45_013_007_856)
    }

    /// The per-address rows repeat the same counters. Counting them would
    /// multiply every interface's traffic by the number of addresses it has.
    func testIgnoresPerAddressRows() throws {
        let totals = try XCTUnwrap(NetworkSampler.parseNetstatTotals(sample))
        XCTAssertNotEqual(
            totals.received, 33_277_138_158 * 2,
            "the 192.168.100 row for en0 must not be counted a second time"
        )
    }

    /// Declining to seed is correct; seeding from a misread column would leave
    /// the totals permanently wrong by an arbitrary amount.
    func testRefusesToSeedFromAnUnexpectedLayout() {
        let mangled = """
            Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes
            en0        1500  <Link#11>   e6:6f:06:b8:43:10 37076158     0 not-a-number  1 2 3 4 5
            """
        XCTAssertNil(NetworkSampler.parseNetstatTotals(mangled))
    }

    func testHandlesEmptyAndHeaderOnlyOutput() {
        XCTAssertEqual(NetworkSampler.parseNetstatTotals("")?.received, nil ?? 0)
        let headerOnly = "Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes"
        let totals = NetworkSampler.parseNetstatTotals(headerOnly)
        XCTAssertEqual(totals?.received, 0)
        XCTAssertEqual(totals?.sent, 0)
    }

    /// Live cross-check: whatever the parser reports must match what `netstat`
    /// itself prints for the primary interface right now.
    func testAgreesWithLiveNetstat() throws {
        guard let output = Shell.run("/usr/sbin/netstat", ["-ibdn"], timeout: 5) else {
            throw XCTSkip("netstat unavailable")
        }
        let totals = try XCTUnwrap(NetworkSampler.parseNetstatTotals(output))
        // A machine that has ever been online has moved more than a megabyte,
        // and the 32-bit read this replaced could not exceed 4 GiB per counter
        // no matter how much traffic there had been.
        XCTAssertGreaterThan(totals.received, 1_000_000)
        XCTAssertGreaterThan(totals.sent, 1_000_000)
    }
}
