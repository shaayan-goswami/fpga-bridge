import XCTest
@testable import FPGABridgeCore

final class ChipLayoutTests: XCTestCase {
    func testThePackageGridFollowsThePinNames() throws {
        let part = try PartDataTests.basys3()
        let layout = PackageLayout(part: part)
        XCTAssertEqual(layout.rows.count, 19)
        XCTAssertEqual(layout.columns, 19)
        XCTAssertEqual(layout.centers.count, 238, "every pin has a place")
        let a1 = try XCTUnwrap(layout.centers["A1"]), w19 = try XCTUnwrap(layout.centers["W19"]), w5 = try XCTUnwrap(layout.centers["W5"])
        XCTAssertLessThan(a1.x, w19.x)
        XCTAssertLessThan(a1.y, w19.y, "A is the top row")
        XCTAssertEqual(layout.pin(at: w5), "W5")
        XCTAssertEqual(layout.pin(at: CGPoint(x: w5.x + 8, y: w5.y - 8)), "W5")
        XCTAssertNil(layout.pin(at: .zero))
        XCTAssertEqual(layout.size.width, PackageLayout.margin * 2 + 19 * PackageLayout.pitch)
    }

    func testTileCategories() {
        XCTAssertEqual(TileCategory(tileType: "CLBLL_L"), .clbL)
        XCTAssertEqual(TileCategory(tileType: "CLBLM_R"), .clbM)
        XCTAssertEqual(TileCategory(tileType: "BRAM_L"), .bram)
        XCTAssertEqual(TileCategory(tileType: "BRAM_INT_INTERFACE_L"), .empty)
        XCTAssertEqual(TileCategory(tileType: "LIOB33_SING"), .io)
        XCTAssertEqual(TileCategory(tileType: "CMT_TOP_R_LOWER_B"), .clockManagement)
        XCTAssertEqual(TileCategory(tileType: "GTP_CHANNEL_0"), .transceiver)
        XCTAssertEqual(TileCategory(tileType: "GTP_INT_INTERFACE"), .empty)
        XCTAssertEqual(TileCategory(tileType: "INT_L"), .interconnect)
    }

    func testTheDieLayout() throws {
        let part = try PartDataTests.basys3()
        let die = DieLayout(part: part)
        XCTAssertGreaterThan(die.size.width, 0)
        XCTAssertGreaterThan(die.size.height, die.size.width, "an Artix-7 die is taller than wide in tiles")

        // Column 19 is block RAM: one block per five rows, with the NULL tiles above folded in.
        let bram = try XCTUnwrap(die.block(x: 19, y: 1))
        XCTAssertEqual(bram.category, .bram)
        XCTAssertEqual(bram.rows, 5)
        XCTAssertEqual(die.block(x: 19, y: 3)?.frame, bram.frame)
        // A CLB is one row; interconnect columns are thin.
        let clb = try XCTUnwrap(die.block(x: 24, y: 1))
        XCTAssertEqual(clb.rows, 1)
        XCTAssertEqual(clb.frame.width, DieLayout.wide)
        XCTAssertEqual(die.block(x: 4, y: 1)?.frame.width, DieLayout.narrow)
        // The top of the die (high GRID_Y) is drawn at the top.
        XCTAssertLessThan(try XCTUnwrap(die.block(x: 24, y: 150)).frame.minY, clb.frame.minY)
        XCTAssertEqual(die.block(at: CGPoint(x: clb.frame.midX, y: clb.frame.midY))?.x, 24)

        // Clock region X0Y0 is the bottom left.
        let x0y0 = die.frame(of: try XCTUnwrap(part.regions.first { $0.name == "X0Y0" }))
        let x1y2 = die.frame(of: try XCTUnwrap(part.regions.first { $0.name == "X1Y2" }))
        XCTAssertGreaterThan(x0y0.minY, x1y2.minY)
        XCTAssertLessThan(x0y0.minX, x1y2.minX)
    }

    func testSitesSplitTheirTile() throws {
        let part = try PartDataTests.basys3()
        let die = DieLayout(part: part)
        let left = try XCTUnwrap(die.frame(ofSite: "SLICE_X0Y0")), right = try XCTUnwrap(die.frame(ofSite: "SLICE_X1Y0"))
        XCTAssertEqual(left.width, DieLayout.wide / 2)
        XCTAssertLessThan(left.minX, right.minX, "slice X0 is the left one")
        XCTAssertEqual(left.minY, right.minY)
        let io = try XCTUnwrap(die.frame(ofSite: "IOB_X1Y26")), below = try XCTUnwrap(die.frame(ofSite: "IOB_X1Y25"))
        XCTAssertLessThan(io.minY, below.minY, "Y26 is above Y25 in the same I/O tile")
        XCTAssertEqual(die.sites(at: CGPoint(x: left.midX, y: left.midY), in: part).first, "SLICE_X0Y0")
        XCTAssertNil(die.frame(ofSite: "NOT_A_SITE"))
    }
}
