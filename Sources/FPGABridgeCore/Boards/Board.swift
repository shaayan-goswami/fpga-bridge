import Foundation

/// A development board and the Vivado part it carries.
public struct Board: Equatable {
    /// Short id used on the command line, e.g. "basys3".
    public let id: String
    public let displayName: String
    /// Vivado part string, as passed to `synth_design -part`.
    public let part: String
    public let family: String
    /// Other accepted spellings, beyond what `BoardCatalog.normalize` already folds together.
    public let aliases: [String]

    public init(id: String, displayName: String, part: String, family: String, aliases: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.part = part
        self.family = family
        self.aliases = aliases
    }
}
