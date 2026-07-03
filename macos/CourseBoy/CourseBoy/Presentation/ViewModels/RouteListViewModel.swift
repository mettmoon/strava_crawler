import Foundation
import Observation
import CourseBoyKit

@MainActor
@Observable
final class RouteListViewModel {
    private(set) var routes: [Route] = []
    private(set) var importProgress: [String: ImportRouteUseCase.Progress] = [:]

    private let importRouteUseCase: ImportRouteUseCase
    private let retryImportUseCase: RetryImportUseCase
    private let reconcileUseCase: ReconcileImportsUseCase
    private let routeRepository: any RouteRepository

    /// route id 별 진행 중인 import Task. deinit 이나 취소 시 중단할 수 있도록 저장.
    private var importTasks: [String: Task<Void, Never>] = [:]

    init(
        importRouteUseCase: ImportRouteUseCase,
        retryImportUseCase: RetryImportUseCase,
        reconcileUseCase: ReconcileImportsUseCase,
        routeRepository: any RouteRepository
    ) {
        self.importRouteUseCase = importRouteUseCase
        self.retryImportUseCase = retryImportUseCase
        self.reconcileUseCase = reconcileUseCase
        self.routeRepository = routeRepository
    }

    deinit {
        for task in importTasks.values { task.cancel() }
    }

    func load() async {
        routes = (try? await routeRepository.fetchAll()) ?? []
    }

    func reconcile() async {
        try? await reconcileUseCase.execute()
        await load()
    }

    func importRoute(_ myRoute: MyRoute) {
        // 동일 route 를 이중으로 import 하는 걸 방지 (기존 Task 취소 후 재시작)
        importTasks[myRoute.id]?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
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
            self.routes.insert(pending, at: 0)

            defer {
                self.importProgress.removeValue(forKey: myRoute.id)
                self.importTasks.removeValue(forKey: myRoute.id)
            }

            for await event in self.importRouteUseCase.execute(myRoute: myRoute) {
                if Task.isCancelled { return }
                switch event {
                case .success(let progress):
                    self.importProgress[myRoute.id] = progress
                case .failure(let error):
                    if let idx = self.routes.firstIndex(where: { $0.id == myRoute.id }) {
                        self.routes[idx].status = .failed
                        self.routes[idx].errorMessage = error.localizedDescription
                    }
                    return
                }
            }
            await self.load()
        }
        importTasks[myRoute.id] = task
    }

    func retry(routeID: String) {
        importTasks[routeID]?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            if let idx = self.routes.firstIndex(where: { $0.id == routeID }) {
                self.routes[idx].status = .processing
                self.routes[idx].errorMessage = nil
            }

            defer {
                self.importProgress.removeValue(forKey: routeID)
                self.importTasks.removeValue(forKey: routeID)
            }

            for await event in self.retryImportUseCase.execute(routeID: routeID) {
                if Task.isCancelled { return }
                switch event {
                case .success(let progress):
                    self.importProgress[routeID] = progress
                case .failure(let error):
                    if let idx = self.routes.firstIndex(where: { $0.id == routeID }) {
                        self.routes[idx].status = .failed
                        self.routes[idx].errorMessage = error.localizedDescription
                    }
                    return
                }
            }
            await self.load()
        }
        importTasks[routeID] = task
    }

    func cancelImport(routeID: String) {
        importTasks[routeID]?.cancel()
        importTasks.removeValue(forKey: routeID)
        importProgress.removeValue(forKey: routeID)
    }

    func delete(routeID: String) async {
        try? await routeRepository.delete(id: routeID)
        routes.removeAll { $0.id == routeID }
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
