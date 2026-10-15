import Foundation

/// Errors from this package. Their `description` is written for people to read.
public protocol DescribedError: Error, CustomStringConvertible {}

extension Error {
    /// Text to show in the UI. Our own errors already read well. For system errors (a failed file write, say) the
    /// default description is a dump of domain and code, so use the localized one instead.
    public var userMessage: String { (self as? any DescribedError)?.description ?? localizedDescription }
}
