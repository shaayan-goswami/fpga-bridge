import Foundation

/// Vivado's project settings: how the language is read, how synthesis and implementation run, how the bitstream is
/// written, and how simulation behaves. Stored in `fpga-bridge.json`; a missing field means Vivado's own default, so a
/// project with no settings generates exactly the script it always did.
///
/// Every value that reaches a Tcl script goes through `validate()` first. A project file can come from someone else,
/// and these end up in a script that runs on the build machine, so free-text options may not contain Tcl syntax.

private extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when the file doesn't mention it.
    func value<T: Decodable>(_ key: Key, _ fallback: T) throws -> T { try decodeIfPresent(T.self, forKey: key) ?? fallback }
}

public struct ProjectSettings: Codable, Equatable, Sendable {
    public var language = Language()
    public var simulation = Simulation()
    public var synthesis = Synthesis()
    public var implementation = Implementation()
    public var bitstream = Bitstream()
    /// Have the build also write the netlist, the I/O ports and a set of reports at each stage, which the app's
    /// Elaborated, Synthesized and Implemented Design views show. Costs a little build time and some files to fetch.
    public var collectDesignData = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.value(.language, Language())
        simulation = try c.value(.simulation, Simulation())
        synthesis = try c.value(.synthesis, Synthesis())
        implementation = try c.value(.implementation, Implementation())
        bitstream = try c.value(.bitstream, Bitstream())
        collectDesignData = try c.value(.collectDesignData, true)
    }

    private enum CodingKeys: String, CodingKey { case language, simulation, synthesis, implementation, bitstream, collectDesignData }

    /// True when nothing differs from Vivado's defaults.
    public var isDefault: Bool { self == ProjectSettings() }

    // MARK: Language (Settings > Elaboration)

    /// How HDL is read. Used by synthesis and by simulation.
    public struct Language: Codable, Equatable, Sendable {
        /// Verilog macros: `NAME` or `NAME=VALUE`.
        public var defines: [String] = []
        /// Folders searched for `` `include `` files, relative to the project.
        public var includeDirectories: [String] = []
        /// Top-level generics or parameters: `NAME=VALUE`.
        public var generics: [String] = []
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            defines = try c.value(.defines, [])
            includeDirectories = try c.value(.includeDirectories, [])
            generics = try c.value(.generics, [])
        }
        private enum CodingKeys: String, CodingKey { case defines, includeDirectories, generics }
    }

    // MARK: Simulation

    public struct Simulation: Codable, Equatable, Sendable {
        public enum Standard: String, Codable, CaseIterable, Sendable {
            case v2012 = "2012", v2009 = "2009", v2005 = "2005", v2001 = "2001"
            public var title: String {
                switch self {
                case .v2012: "SystemVerilog 2012"
                case .v2009: "SystemVerilog 2009"
                case .v2005: "Verilog 2005"
                case .v2001: "Verilog 2001"
                }
            }
        }

        public var standard = Standard.v2012
        /// Stop a simulation that hasn't finished after this long, in seconds.
        public var timeLimit = 120
        /// Write a waveform. Off makes big runs faster.
        public var recordWaveform = true
        /// How many levels of hierarchy under the testbench are recorded; 0 is all of them.
        public var waveformDepth = 0
        /// Show every compiler warning.
        public var allWarnings = false
        /// Plusargs for the run (`+seed=5`), separated by spaces.
        public var runtimeArguments = ""
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            standard = try c.value(.standard, Standard.v2012)
            timeLimit = try c.value(.timeLimit, 120)
            recordWaveform = try c.value(.recordWaveform, true)
            waveformDepth = try c.value(.waveformDepth, 0)
            allWarnings = try c.value(.allWarnings, false)
            runtimeArguments = try c.value(.runtimeArguments, "")
        }
        private enum CodingKeys: String, CodingKey { case standard, timeLimit, recordWaveform, waveformDepth, allWarnings, runtimeArguments }

        public static let timeLimitRange = 1...86_400
    }

    // MARK: Synthesis

    public struct Synthesis: Codable, Equatable, Sendable {
        public enum Flatten: String, Codable, CaseIterable, Sendable {
            case rebuilt, full, none
            public var title: String { self == .rebuilt ? "Rebuilt (default)" : rawValue.capitalized }
        }
        public enum FSM: String, Codable, CaseIterable, Sendable {
            case auto, oneHot = "one_hot", sequential, johnson, gray, off
            public var title: String { self == .auto ? "Auto (default)" : rawValue.replacingOccurrences(of: "_", with: "-").capitalized }
        }
        public enum Toggle3: String, Codable, CaseIterable, Sendable {
            case auto, on, off
            public var title: String { rawValue.capitalized }
        }

        public var directive = "Default"
        public var flattenHierarchy = Flatten.rebuilt
        public var fsmExtraction = FSM.auto
        public var retiming = false
        public var resourceSharing = Toggle3.auto
        public var keepEquivalentRegisters = false
        /// Limits on block RAMs and DSP slices; nil leaves it to Vivado.
        public var maxBlockRAM: Int?
        public var maxDSP: Int?
        /// Don't combine LUTs (`-no_lc`).
        public var noLUTCombining = false
        /// The shortest chain of registers made into a shift-register LUT (`-shreg_min_size`); nil is Vivado's 3.
        public var shregMinSize: Int?
        /// Merge control sets with fewer loads than this (`-control_set_opt_threshold`); nil is Vivado's "auto".
        public var controlSetOptThreshold: Int?
        public var moreOptions = ""
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            noLUTCombining = try c.value(.noLUTCombining, false)
            shregMinSize = try c.decodeIfPresent(Int.self, forKey: .shregMinSize)
            controlSetOptThreshold = try c.decodeIfPresent(Int.self, forKey: .controlSetOptThreshold)
            directive = try c.value(.directive, "Default")
            flattenHierarchy = try c.value(.flattenHierarchy, Flatten.rebuilt)
            fsmExtraction = try c.value(.fsmExtraction, FSM.auto)
            retiming = try c.value(.retiming, false)
            resourceSharing = try c.value(.resourceSharing, Toggle3.auto)
            keepEquivalentRegisters = try c.value(.keepEquivalentRegisters, false)
            maxBlockRAM = try c.decodeIfPresent(Int.self, forKey: .maxBlockRAM)
            maxDSP = try c.decodeIfPresent(Int.self, forKey: .maxDSP)
            moreOptions = try c.value(.moreOptions, "")
        }
        private enum CodingKeys: String, CodingKey {
            case directive, flattenHierarchy, fsmExtraction, retiming, resourceSharing, keepEquivalentRegisters, maxBlockRAM, maxDSP
            case noLUTCombining, shregMinSize, controlSetOptThreshold, moreOptions
        }

        /// The `synth_design` directives, as Vivado 2025.2 lists them for a synthesis run.
        public static let directives = ["Default", "RuntimeOptimized", "AreaOptimized_high", "AreaOptimized_medium", "AlternateRoutability",
                                        "AreaMapLargeShiftRegToBRAM", "AreaMultThresholdDSP", "FewerCarryChains", "PerformanceOptimized",
                                        "LogicCompaction", "PowerOptimized_high", "PowerOptimized_medium"]

        /// A named set of options, like Vivado's synthesis strategies. Each sets exactly what Vivado 2025.2's strategy
        /// of that name sets on a synthesis run (read from the run's STEPS.SYNTH_DESIGN.ARGS properties).
        public struct Strategy: Equatable, Sendable {
            public let name: String
            public let summary: String
            let apply: @Sendable (inout Synthesis) -> Void
            public static func == (a: Strategy, b: Strategy) -> Bool { a.name == b.name }
        }

        public static let strategies: [Strategy] = [
            Strategy(name: "Vivado Synthesis Defaults", summary: "Every option at Vivado's default.") { $0 = Synthesis() },
            Strategy(name: "Flow_AreaOptimized_high", summary: "The smallest design: area-optimized synthesis, with control sets merged wherever possible.") {
                $0 = Synthesis(); $0.directive = "AreaOptimized_high"; $0.controlSetOptThreshold = 1
            },
            Strategy(name: "Flow_AreaOptimized_medium", summary: "Smaller, with less effect on timing than AreaOptimized_high.") {
                $0 = Synthesis(); $0.directive = "AreaOptimized_medium"; $0.controlSetOptThreshold = 1
            },
            Strategy(name: "Flow_AreaMultThresholdDSP", summary: "More multipliers in DSP slices instead of LUTs.") {
                $0 = Synthesis(); $0.directive = "AreaMultThresholdDSP"
            },
            Strategy(name: "Flow_AlternateRoutability", summary: "A netlist that is easier to route: no LUT combining, longer shift registers in LUTs.") {
                $0 = Synthesis(); $0.directive = "AlternateRoutability"; $0.noLUTCombining = true; $0.shregMinSize = 10
            },
            Strategy(name: "Flow_PerfOptimized_high", summary: "The fastest design: one-hot state machines, no LUT combining or resource sharing.") {
                $0 = Synthesis(); $0.directive = "PerformanceOptimized"; $0.fsmExtraction = .oneHot; $0.keepEquivalentRegisters = true
                $0.resourceSharing = .off; $0.noLUTCombining = true; $0.shregMinSize = 5
            },
            Strategy(name: "Flow_PerfThresholdCarry", summary: "Fewer carry chains, for designs whose timing is limited by them.") {
                $0 = Synthesis(); $0.directive = "FewerCarryChains"; $0.keepEquivalentRegisters = true
                $0.resourceSharing = .off; $0.noLUTCombining = true
            },
            Strategy(name: "Flow_RuntimeOptimized", summary: "The fastest compile: no flattening and no state machine extraction.") {
                $0 = Synthesis(); $0.directive = "RuntimeOptimized"; $0.flattenHierarchy = .none; $0.fsmExtraction = .off
            },
        ]

        /// The strategy these options add up to, if they match one exactly (extra options count as a difference).
        public var matchingStrategy: String? {
            Synthesis.strategies.first { strategy in
                var fresh = Synthesis()
                strategy.apply(&fresh)
                return fresh == self
            }?.name
        }

        public mutating func apply(_ strategy: Strategy) { strategy.apply(&self) }
    }

    // MARK: Implementation

    public struct Implementation: Codable, Equatable, Sendable {
        public var optDirective = "Default"
        public var placeDirective = "Default"
        /// Run `phys_opt_design` after placement.
        public var physOpt = false
        public var physOptDirective = "Default"
        /// Run `phys_opt_design` again after routing.
        public var postRoutePhysOpt = false
        public var routeDirective = "Default"
        public var optMoreOptions = ""
        public var placeMoreOptions = ""
        public var routeMoreOptions = ""
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            optDirective = try c.value(.optDirective, "Default")
            placeDirective = try c.value(.placeDirective, "Default")
            physOpt = try c.value(.physOpt, false)
            physOptDirective = try c.value(.physOptDirective, "Default")
            postRoutePhysOpt = try c.value(.postRoutePhysOpt, false)
            routeDirective = try c.value(.routeDirective, "Default")
            optMoreOptions = try c.value(.optMoreOptions, "")
            placeMoreOptions = try c.value(.placeMoreOptions, "")
            routeMoreOptions = try c.value(.routeMoreOptions, "")
        }
        private enum CodingKeys: String, CodingKey { case optDirective, placeDirective, physOpt, physOptDirective, postRoutePhysOpt, routeDirective, optMoreOptions, placeMoreOptions, routeMoreOptions }

        public static let optDirectives = ["Default", "Explore", "ExploreArea", "RuntimeOptimized"]
        public static let placeDirectives = ["Default", "Explore", "ExtraNetDelay_high", "ExtraTimingOpt", "RuntimeOptimized", "Quick"]
        public static let physOptDirectives = ["Default", "Explore", "AggressiveExplore", "AggressiveFanoutOpt", "AlternateReplication", "RuntimeOptimized"]
        public static let routeDirectives = ["Default", "Explore", "NoTimingRelaxation", "MoreGlobalIterations", "HigherDelayCost", "RuntimeOptimized", "Quick"]

        /// A named set of directives, like Vivado's implementation strategies. Only the ones whose meaning is
        /// plain from the directives are offered.
        public struct Strategy: Equatable, Sendable {
            public let name: String
            public let summary: String
            let apply: @Sendable (inout Implementation) -> Void
            public static func == (a: Strategy, b: Strategy) -> Bool { a.name == b.name }
        }

        public static let strategies: [Strategy] = [
            Strategy(name: "Vivado Implementation Defaults", summary: "Every step on its default directive.") {
                $0 = Implementation()
            },
            Strategy(name: "Performance_Explore", summary: "Explore directives for every step, with physical optimization after placement.") {
                $0 = Implementation()
                $0.optDirective = "Explore"; $0.placeDirective = "Explore"
                $0.physOpt = true; $0.physOptDirective = "Explore"; $0.routeDirective = "Explore"
            },
            Strategy(name: "Flow_RuntimeOptimized", summary: "The fastest compile: runtime-optimized directives, no physical optimization.") {
                $0 = Implementation()
                $0.optDirective = "RuntimeOptimized"; $0.placeDirective = "RuntimeOptimized"; $0.routeDirective = "RuntimeOptimized"
            },
        ]

        /// The strategy these settings add up to, if they match one exactly (extra options count as a difference).
        public var matchingStrategy: String? {
            Implementation.strategies.first { strategy in
                var fresh = Implementation()
                strategy.apply(&fresh)
                return fresh == self
            }?.name
        }

        public mutating func apply(_ strategy: Strategy) { strategy.apply(&self) }
    }

    // MARK: Bitstream

    public struct Bitstream: Codable, Equatable, Sendable {
        public enum UnusedPin: String, Codable, CaseIterable, Sendable {
            case pulldown, pullup, pullnone
            public var title: String { self == .pulldown ? "Pull-down (default)" : self == .pullup ? "Pull-up" : "Float" }
        }

        /// Also write a `.bin` file, which is what flash programming uses.
        public var binFile = false
        /// Make the bitstream smaller (BITSTREAM.GENERAL.COMPRESS).
        public var compress = false
        /// Configuration clock in MHz (BITSTREAM.CONFIG.CONFIGRATE). Nil leaves it at Vivado's default.
        public var configRate: Int?
        /// Quad-SPI width for flash configuration (BITSTREAM.CONFIG.SPI_BUSWIDTH). Nil leaves it at the default.
        public var spiBusWidth: Int?
        public var unusedPin = UnusedPin.pulldown
        public var moreOptions = ""
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            binFile = try c.value(.binFile, false)
            compress = try c.value(.compress, false)
            configRate = try c.decodeIfPresent(Int.self, forKey: .configRate)
            spiBusWidth = try c.decodeIfPresent(Int.self, forKey: .spiBusWidth)
            unusedPin = try c.value(.unusedPin, UnusedPin.pulldown)
            moreOptions = try c.value(.moreOptions, "")
        }
        private enum CodingKeys: String, CodingKey { case binFile, compress, configRate, spiBusWidth, unusedPin, moreOptions }

        /// 7 series configuration rates.
        public static let configRates = [3, 6, 9, 12, 16, 22, 26, 33, 40, 50, 66]
        public static let spiBusWidths = [1, 2, 4]
    }

    // MARK: Validation

    public enum SettingsError: DescribedError, Equatable {
        case invalid(String)
        public var description: String {
            if case .invalid(let why) = self { return "Invalid settings: \(why)" }
            return ""
        }
    }

    /// For the settings screen: is this a valid macro (`NAME` or `NAME=VALUE`)?
    public static func isValidDefine(_ s: String) -> Bool { isAssignment(s, valueRequired: false) }
    /// Is this a valid generic (`NAME=VALUE`)?
    public static func isValidGeneric(_ s: String) -> Bool { isAssignment(s, valueRequired: true) }
    /// Is this a plain folder inside the project?
    public static func isValidIncludeDirectory(_ dir: String) -> Bool {
        !dir.isEmpty && !dir.hasPrefix("/") && !dir.split(separator: "/").contains("..")
            && dir.range(of: #"^[A-Za-z0-9_\-./ ]+$"#, options: .regularExpression) != nil
    }
    /// Is this free text safe to put on a Tcl line (flags and values only)?
    public static func isValidOptionText(_ s: String) -> Bool { isPlainOptions(s) }

    /// The same settings with whitespace trimmed and blank rows dropped, which is what a form leaves behind.
    public func cleaned() -> ProjectSettings {
        func list(_ items: [String]) -> [String] { items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        func text(_ s: String) -> String { s.split(whereSeparator: { $0 == " " }).joined(separator: " ") }
        var c = self
        c.language.defines = list(language.defines)
        c.language.generics = list(language.generics)
        c.language.includeDirectories = list(language.includeDirectories)
        c.simulation.runtimeArguments = text(simulation.runtimeArguments)
        c.synthesis.moreOptions = text(synthesis.moreOptions)
        c.implementation.optMoreOptions = text(implementation.optMoreOptions)
        c.implementation.placeMoreOptions = text(implementation.placeMoreOptions)
        c.implementation.routeMoreOptions = text(implementation.routeMoreOptions)
        c.bitstream.moreOptions = text(bitstream.moreOptions)
        return c
    }

    /// Letters, digits and `_`, not starting with a digit.
    static func isIdentifier(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    /// `NAME` or `NAME=VALUE`, where the value is plain: no spaces, quotes, braces or other Tcl syntax.
    static func isAssignment(_ s: String, valueRequired: Bool) -> Bool {
        let parts = s.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard isIdentifier(parts[0]) else { return false }
        if parts.count == 1 { return !valueRequired }
        return parts[1].range(of: #"^[A-Za-z0-9_.+\-']*$"#, options: .regularExpression) != nil && !parts[1].isEmpty
    }

    /// Words like `-name value` that can't carry Tcl syntax: no `[ ] { } " $ ; \` or newlines.
    static func isPlainOptions(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9_\-=.+,:/ ]*$"#, options: .regularExpression) != nil
    }

    public func validate() throws {
        func fail(_ why: String) -> SettingsError { .invalid(why) }
        for define in language.defines where !ProjectSettings.isAssignment(define, valueRequired: false) {
            throw fail("the macro '\(define)' must look like NAME or NAME=VALUE")
        }
        for generic in language.generics where !ProjectSettings.isAssignment(generic, valueRequired: true) {
            throw fail("the generic '\(generic)' must look like NAME=VALUE")
        }
        for dir in language.includeDirectories {
            guard !dir.hasPrefix("/"), !dir.split(separator: "/").contains(".."), !dir.isEmpty,
                  dir.range(of: #"^[A-Za-z0-9_\-./ ]+$"#, options: .regularExpression) != nil else {
                throw fail("the include folder '\(dir)' must be a plain path inside the project")
            }
        }

        guard Simulation.timeLimitRange.contains(simulation.timeLimit) else { throw fail("the simulation time limit must be 1 to 86400 seconds") }
        guard (0...64).contains(simulation.waveformDepth) else { throw fail("the waveform depth must be 0 to 64") }
        for word in simulation.runtimeArguments.split(separator: " ") where !word.hasPrefix("+") || !ProjectSettings.isPlainOptions(String(word)) {
            throw fail("simulation run arguments must be plusargs such as +seed=5, not '\(word)'")
        }

        guard Synthesis.directives.contains(synthesis.directive) else { throw fail("unknown synthesis directive '\(synthesis.directive)'") }
        for (name, value) in [("block RAM", synthesis.maxBlockRAM), ("DSP", synthesis.maxDSP)] {
            if let value, !(0...100_000).contains(value) { throw fail("the maximum \(name) count must be 0 or more") }
        }
        if let size = synthesis.shregMinSize, !(1...1_000).contains(size) { throw fail("the shift register minimum size must be 1 to 1000") }
        if let threshold = synthesis.controlSetOptThreshold, !(0...1_000_000).contains(threshold) {
            throw fail("the control set threshold must be 0 or more")
        }
        guard ProjectSettings.isPlainOptions(synthesis.moreOptions) else { throw fail("synthesis options may only contain letters, digits and - _ = . + , : /") }

        let i = implementation
        guard Implementation.optDirectives.contains(i.optDirective) else { throw fail("unknown opt_design directive '\(i.optDirective)'") }
        guard Implementation.placeDirectives.contains(i.placeDirective) else { throw fail("unknown place_design directive '\(i.placeDirective)'") }
        guard Implementation.physOptDirectives.contains(i.physOptDirective) else { throw fail("unknown phys_opt_design directive '\(i.physOptDirective)'") }
        guard Implementation.routeDirectives.contains(i.routeDirective) else { throw fail("unknown route_design directive '\(i.routeDirective)'") }
        for options in [i.optMoreOptions, i.placeMoreOptions, i.routeMoreOptions] where !ProjectSettings.isPlainOptions(options) {
            throw fail("implementation options may only contain letters, digits and - _ = . + , : /")
        }

        if let rate = bitstream.configRate, !Bitstream.configRates.contains(rate) { throw fail("the configuration rate must be one of \(Bitstream.configRates)") }
        if let width = bitstream.spiBusWidth, !Bitstream.spiBusWidths.contains(width) { throw fail("the SPI bus width must be 1, 2 or 4") }
        guard ProjectSettings.isPlainOptions(bitstream.moreOptions) else { throw fail("bitstream options may only contain letters, digits and - _ = . + , : /") }
    }
}
