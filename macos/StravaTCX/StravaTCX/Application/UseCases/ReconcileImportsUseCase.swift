import Foundation

struct ReconcileImportsUseCase: Sendable {
    let routeRepository: any RouteRepository

    func execute() async throws {
        try await routeRepository.reconcileStuckProcessing()
    }
}
