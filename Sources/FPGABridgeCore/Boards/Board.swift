import Foundation

/// A development board and the Vivado part it carries.
public struct Board: Equatable, Identifiable, Sendable {
    /// Short id used on the command line, e.g. "basys3".
    public let id: String
    public let displayName: String
    /// Vivado part string, as passed to `synth_design -part`.
    public let part: String
    public let family: String
    /// Other accepted spellings, beyond what `BoardCatalog.normalize` already folds together.
    public let aliases: [String]
    /// The name openFPGALoader knows this board by (`-b`), which tells it the cable and how to reach the chip.
    public let loaderName: String?

    public init(id: String, displayName: String, part: String, family: String, aliases: [String] = [],
                loaderName: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.part = part
        self.family = family
        self.aliases = aliases
        self.loaderName = loaderName
    }
}
