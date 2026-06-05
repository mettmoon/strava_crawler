import Foundation
import Observation
import StravaTCXKit

@MainActor
@Observable
final class RouteListViewModel {
    private(set) var routes: [Route] = []
    private(set) var importProgress: [String: ImportRouteUseCase.Progress] = [:]

    private let importRouteUseCase: ImportRouteUseCase
    private let retryImportUseCase: RetryImportUseCase
    private let reconcileUseCase: ReconcileImportsUseCase
    private let reloadSegmentUseCase: ReloadSegmentUseCase
    private let deleteSegmentUseCase: DeleteSegmentUseCase
    private let routeRepository: any RouteRepository

    init(
        importRouteUseCase: ImportRouteUseCase,
        retryImportUseCase: RetryImportUseCase,
        reconcileUseCase: ReconcileImportsUseCase,
        reloadSegmentUseCase: ReloadSegmentUseCase,
        deleteSegmentUseCase: DeleteSegmentUseCase,
        routeRepository: any RouteRepository
    ) {
        self.importRouteUseCase = importRouteUseCase
        self.retryImportUseCase = retryImportUseCase
        self.reconcileUseCase = reconcileUseCase
        self.reloadSegmentUseCase = reloadSegmentUseCase
        self.deleteSegmentUseCase = deleteSegmentUseCase
        self.routeRepository = routeRepository
    }

    func load() async {
        routes = (try? await routeRepository.fetchAll()) ?? []
    }

    func reconcile() async {
        try? await reconcileUseCase.execute()
        await load()
    }

    func importRoute(_ myRoute: MyRoute) {
        Task {
            // 낙관적 추가: processing 상태 Route를 먼저 목록에 삽입
            let pending = Route(
                id: myRoute.id,
                title: myRoute.name.isEmpty ? "Route \(myRoute.id)" : myRoute.name,
                createdAt: Date(),
                status: .processing,
                errorMessage: nil,
                tcxData: Data(),
                segments: [],
                trackPointCount: 0,
                coursePointCount: 0
            )
            routes.insert(pending, at: 0)

            for await event in importRouteUseCase.execute(myRoute: myRoute) {
                switch event {
                case .success(let progress):
                    importProgress[myRoute.id] = progress
                case .failure(let error):
                    if let idx = routes.firstIndex(where: { $0.id == myRoute.id }) {
                        routes[idx].status = .failed
                        routes[idx].errorMessage = error.localizedDescription
                    }
                    importProgress.removeValue(forKey: myRoute.id)
                    return
                }
            }
            importProgress.removeValue(forKey: myRoute.id)
            await load()
        }
    }

    func retry(routeID: String) {
        Task {
            if let idx = routes.firstIndex(where: { $0.id == routeID }) {
                routes[idx].status = .processing
                routes[idx].errorMessage = nil
            }
            for await event in retryImportUseCase.execute(routeID: routeID) {
                switch event {
                case .success(let progress):
                    importProgress[routeID] = progress
                case .failure(let error):
                    if let idx = routes.firstIndex(where: { $0.id == routeID }) {
                        routes[idx].status = .failed
                        routes[idx].errorMessage = error.localizedDescription
                    }
                    importProgress.removeValue(forKey: routeID)
                    return
                }
            }
            importProgress.removeValue(forKey: routeID)
            await load()
        }
    }

    func delete(routeID: String) async {
        try? await routeRepository.delete(id: routeID)
        routes.removeAll { $0.id == routeID }
    }

    func reloadSegment(segmentID: String) async throws {
        try await reloadSegmentUseCase.execute(segmentID: segmentID)
        await load()
    }

    func deleteSegment(segmentID: String) async throws {
        try await deleteSegmentUseCase.execute(segmentID: segmentID)
        await load()
    }

    func updateMinCategory(routeID: String, minCategory: String?) async {
        guard var route = try? await routeRepository.fetch(id: routeID) else { return }
        route.minCategory = minCategory
        try? await routeRepository.save(route)
        if let idx = routes.firstIndex(where: { $0.id == routeID }) {
            routes[idx].minCategory = minCategory
        }
    }

    func progress(for routeID: String) -> ImportRouteUseCase.Progress? {
        importProgress[routeID]
    }
}
