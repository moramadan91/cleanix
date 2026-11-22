import Foundation

public enum NaddafError: Error, Equatable {
    case confirmationRequired
    case noAccess
    case readOnly
    case notAllowed
}
