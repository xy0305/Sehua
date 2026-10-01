import Foundation

/// One service actor for all native pages: prevents independent snapshots from
/// overwriting persistent task records and keeps the service's write gate shared.
@MainActor
enum Pan115UIService {
    private static let instance: Result<SHT115Service, Error> = Result { try SHT115Service() }
    static func get() throws -> SHT115Service { try instance.get() }
}
