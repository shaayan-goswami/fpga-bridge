import XCTest
@testable import FPGABridgeCore

final class XDCPinsTests: XCTestCase {
    /// The Basys 3 demo's constraints, as on the build machine (Digilent's `-dict` style).
    let basys3 = """
        ## Digilent Basys 3 pin assignments for demo_top.

        ## Clock: 100 MHz
        set_property -dict { PACKAGE_PIN W5  IOSTANDARD LVCMOS33 } [get_ports clk]
        create_clock -period 10.000 -name sys_clk [get_ports clk]

        ## Switches
        set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]
        set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]
        #set_property -dict { PACKAGE_PIN W16 IOSTANDARD LVCMOS33 } [get_ports {sw[2]}]

        ## Configuration
        set_property CFGBVS VCCO [current_design]
        set_property CONFIG_VOLTAGE 3.3 [current_design]

        """

    /// Vivado's own style: one property per line.
    let vivadoStyle = """
        set_property PACKAGE_PIN W5 [get_ports clk]
        set_property IOSTANDARD LVCMOS33 [get_ports clk]
        set_property PACKAGE_PIN U16 [get_ports {led[0]}]
        set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

        """

    func files(_ text: String) -> [XDCFile] { [XDCFile(path: "constraints/top.xdc", text: text)] }

    func set(_ property: String, _ port: String, _ value: String?, in text: String) -> String {
        XDCPins.set(property, of: port, to: value, in: files(text))[0].text
    }

    // MARK: Reading

    func testReadsBothStyles() {
        let dict = XDCPins.settings(in: basys3)
        XCTAssertEqual(dict.count, 6, "two keys on each of three live lines; the commented one and current_design ones don't count")
        XCTAssertEqual(dict.first, XDCPortSetting(line: 3, property: "PACKAGE_PIN", value: "W5", patterns: ["clk"], isDict: true))
        XCTAssertEqual(dict.last?.patterns, ["sw[1]"])

        let plain = XDCPins.settings(in: vivadoStyle)
        XCTAssertEqual(plain.map(\.property), ["PACKAGE_PIN", "IOSTANDARD", "PACKAGE_PIN", "IOSTANDARD"])
        XCTAssertEqual(plain[2].singlePort, "led[0]")
        XCTAssertNil(plain[3].singlePort, "a wildcard covers several ports")
    }

    func testEffectiveConstraintsFollowVivadosOrder() {
        let ports = ["clk", "led[0]", "led[1]", "sw[0]", "btn"]
        let found = XDCPins.constraints(for: ports, in: [XDCFile(path: "a.xdc", text: vivadoStyle),
                                                         XDCFile(path: "b.xdc", text: "set_property IOSTANDARD LVCMOS18 [get_ports clk]\n")])
        XCTAssertEqual(found["clk"], XDCPortConstraints(packagePin: "W5", ioStandard: "LVCMOS18"), "the later file wins")
        XCTAssertEqual(found["led[0]"], XDCPortConstraints(packagePin: "U16", ioStandard: "LVCMOS33"))
        XCTAssertEqual(found["led[1]"], XDCPortConstraints(packagePin: nil, ioStandard: "LVCMOS33"), "from the wildcard")
        XCTAssertNil(found["btn"])
        XCTAssertTrue(XDCPins.assignsPackagePins(files(vivadoStyle)))
        XCTAssertFalse(XDCPins.assignsPackagePins(files("create_clock -period 10 [get_ports clk]\n")))
    }

    func testPortNameForms() {
        let text = """
            set_property PACKAGE_PIN A1 [get_ports "quoted"]
            set_property PACKAGE_PIN A2 [get_ports {braced}]
            set_property PACKAGE_PIN A3 [get_ports bus\\[3\\]]
            set_property PACKAGE_PIN A4 [get_ports -quiet {two words}]; # a comment
            set_property {PACKAGE_PIN} {A5} [get_ports {braced_value}]
            set_property PACKAGE_PIN A6 [get_ports -filter {NAME =~ x*}]
              set_property -quiet PACKAGE_PIN A7 [get_ports indented]
            """
        let settings = XDCPins.settings(in: text)
        XCTAssertEqual(settings.map(\.patterns), [["quoted"], ["braced"], ["bus[3]"], ["two", "words"], ["braced_value"], ["indented"]])
        XCTAssertEqual(settings[4].value, "A5")
        XCTAssertTrue(XDCPins.glob("led[*]", matches: "led[12]"))
        XCTAssertTrue(XDCPins.glob("le?", matches: "led"))
        XCTAssertFalse(XDCPins.glob("led[*]", matches: "led"))
        XCTAssertFalse(XDCPins.glob("led", matches: "led[0]"))
    }

    // MARK: Editing in place

    func testChangingAPinInADictKeepsTheRestOfTheLine() {
        let edited = set("PACKAGE_PIN", "clk", "W4", in: basys3)
        XCTAssertTrue(edited.contains("set_property -dict { PACKAGE_PIN W4  IOSTANDARD LVCMOS33 } [get_ports clk]"))
        XCTAssertEqual(edited.replacingOccurrences(of: "PACKAGE_PIN W4 ", with: "PACKAGE_PIN W5 "), basys3, "nothing else changed")
    }

    func testChangingAStandardInADict() {
        let edited = set("IOSTANDARD", "sw[1]", "LVCMOS18", in: basys3)
        XCTAssertTrue(edited.contains("set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS18 } [get_ports {sw[1]}]"))
        XCTAssertTrue(edited.contains("{ PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]"), "the other switch keeps its standard")
    }

    func testChangingAPlainLine() {
        let edited = set("PACKAGE_PIN", "led[0]", "E19", in: vivadoStyle)
        XCTAssertEqual(edited, vivadoStyle.replacingOccurrences(of: "U16", with: "E19"))
    }

    func testABracedValueStaysBraced() {
        let edited = set("PACKAGE_PIN", "p", "B2", in: "set_property PACKAGE_PIN {A1} [get_ports p]\n")
        XCTAssertEqual(edited, "set_property PACKAGE_PIN {B2} [get_ports p]\n")
    }

    func testTheCommentedOutLineIsNotTouched() {
        let edited = set("PACKAGE_PIN", "sw[2]", "W16", in: basys3)
        XCTAssertTrue(edited.contains("#set_property -dict { PACKAGE_PIN W16 IOSTANDARD LVCMOS33 } [get_ports {sw[2]}]"))
        XCTAssertTrue(edited.hasSuffix("set_property PACKAGE_PIN W16 [get_ports {sw[2]}]\n"), "added at the end, as Vivado does")
    }

    // MARK: Adding

    func testAMissingKeyJoinsThePortsDict() {
        let text = "set_property -dict { PACKAGE_PIN W5 } [get_ports clk]\n"
        XCTAssertEqual(set("IOSTANDARD", "clk", "LVCMOS33", in: text),
                       "set_property -dict { PACKAGE_PIN W5 IOSTANDARD LVCMOS33 } [get_ports clk]\n")
    }

    func testAMissingPropertyGoesNextToThePortsOtherLine() {
        let text = "set_property PACKAGE_PIN W5 [get_ports clk]\ncreate_clock -period 10 [get_ports clk]\n"
        XCTAssertEqual(set("IOSTANDARD", "clk", "LVCMOS33", in: text),
                       "set_property PACKAGE_PIN W5 [get_ports clk]\nset_property IOSTANDARD LVCMOS33 [get_ports clk]\ncreate_clock -period 10 [get_ports clk]\n")
    }

    func testAPortNotMentionedIsAppendedToTheTargetFile() {
        let two = [XDCFile(path: "a.xdc", text: "# board\n"), XDCFile(path: "b.xdc", text: "# mine")]
        let edited = XDCPins.set("PACKAGE_PIN", of: "led[3]", to: "V19", in: two, target: 1)
        XCTAssertEqual(edited[0], two[0])
        XCTAssertEqual(edited[1].text, "# mine\nset_property PACKAGE_PIN V19 [get_ports {led[3]}]\n", "a file without a final line break gets one first")
        XCTAssertEqual(XDCPins.set("PACKAGE_PIN", of: "a", to: "A1", in: [XDCFile(path: "e.xdc", text: "")])[0].text,
                       "set_property PACKAGE_PIN A1 [get_ports a]\n")
    }

    func testAWildcardIsOverriddenForOnePortOnly() {
        let edited = set("IOSTANDARD", "led[0]", "LVCMOS18", in: vivadoStyle)
        XCTAssertEqual(edited, vivadoStyle.replacingOccurrences(of: "[get_ports {led[*]}]\n",
                                                                with: "[get_ports {led[*]}]\nset_property IOSTANDARD LVCMOS18 [get_ports {led[0]}]\n"))
        XCTAssertEqual(XDCPins.constraints(for: ["led[0]", "led[1]"], in: files(edited)).mapValues(\.ioStandard),
                       ["led[0]": "LVCMOS18", "led[1]": "LVCMOS33"])
    }

    func testTheLastOfSeveralLinesIsTheOneEdited() {
        let text = "set_property PACKAGE_PIN A1 [get_ports p]\nset_property PACKAGE_PIN A2 [get_ports p]\n"
        XCTAssertEqual(set("PACKAGE_PIN", "p", "B1", in: text), "set_property PACKAGE_PIN A1 [get_ports p]\nset_property PACKAGE_PIN B1 [get_ports p]\n")
    }

    // MARK: Removing

    func testRemovingAPlainLineRemovesTheLine() {
        let edited = set("PACKAGE_PIN", "clk", nil, in: vivadoStyle)
        XCTAssertEqual(edited, vivadoStyle.replacingOccurrences(of: "set_property PACKAGE_PIN W5 [get_ports clk]\n", with: ""))
    }

    func testRemovingOneKeyOfADict() {
        XCTAssertTrue(set("PACKAGE_PIN", "clk", nil, in: basys3).contains("set_property -dict { IOSTANDARD LVCMOS33 } [get_ports clk]"))
        XCTAssertTrue(set("IOSTANDARD", "clk", nil, in: basys3).contains("set_property -dict { PACKAGE_PIN W5 } [get_ports clk]"))
        let only = "set_property -dict { PACKAGE_PIN W5 } [get_ports clk]\nnext\n"
        XCTAssertEqual(set("PACKAGE_PIN", "clk", nil, in: only), "next\n", "a dict left empty goes")
    }

    func testRemovingSomethingThatIsntThereChangesNothing() {
        XCTAssertEqual(set("PACKAGE_PIN", "nothing", nil, in: basys3), basys3)
    }

    // MARK: Line endings

    func testWindowsLineEndingsAreKept() {
        let crlf = basys3.replacingOccurrences(of: "\n", with: "\r\n")
        let edited = set("PACKAGE_PIN", "sw[0]", "U1", in: crlf)
        XCTAssertEqual(edited, crlf.replacingOccurrences(of: "PACKAGE_PIN V17", with: "PACKAGE_PIN U1"))
        let added = set("PACKAGE_PIN", "btn", "U18", in: crlf)
        XCTAssertTrue(added.hasSuffix("\r\nset_property PACKAGE_PIN U18 [get_ports btn]\r\n"))
        XCTAssertFalse(added.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "no bare line feeds mixed in")
        let inserted = set("IOSTANDARD", "clk", "LVCMOS33", in: "set_property PACKAGE_PIN W5 [get_ports clk]\r\nrest\r\n")
        XCTAssertEqual(inserted, "set_property PACKAGE_PIN W5 [get_ports clk]\r\nset_property IOSTANDARD LVCMOS33 [get_ports clk]\r\nrest\r\n")
        XCTAssertEqual(XDCPins.settings(in: crlf).count, 6)
    }

    func testAFileWithoutAFinalLineBreakStaysThatWay() {
        let text = "set_property PACKAGE_PIN W5 [get_ports clk]"
        XCTAssertEqual(set("IOSTANDARD", "clk", "LVCMOS33", in: text),
                       "set_property PACKAGE_PIN W5 [get_ports clk]\nset_property IOSTANDARD LVCMOS33 [get_ports clk]")
        XCTAssertEqual(set("PACKAGE_PIN", "clk", "W4", in: text), "set_property PACKAGE_PIN W4 [get_ports clk]")
    }

    func testContinuedLinesAreLeftAlone() {
        let text = "set_property PACKAGE_PIN W5 \\\n    [get_ports clk]\n"
        XCTAssertTrue(XDCPins.settings(in: text).isEmpty)
        XCTAssertTrue(set("PACKAGE_PIN", "clk", "W4", in: text).hasPrefix(text), "only appended to, never rewritten")
    }

    func testQuotingPortNames() {
        XCTAssertEqual(XDCPins.quoted("clk"), "clk")
        XCTAssertEqual(XDCPins.quoted("led[0]"), "{led[0]}")
        XCTAssertEqual(XDCPins.plainLine("IOSTANDARD", "LVCMOS33", "sw[15]"), "set_property IOSTANDARD LVCMOS33 [get_ports {sw[15]}]")
    }
}
