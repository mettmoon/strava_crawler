import Foundation

protocol RouteRepository: Sendable {
    func fetchAll() async throws -> [Route]
    func fetch(id: String) async throws -> Route?
    func save(_ route: Route) async throws
    func delete(id: String) async throws
    func reconcileStuckProcessing() async throws
}
