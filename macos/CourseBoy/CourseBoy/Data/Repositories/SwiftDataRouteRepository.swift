import Foundation
import SwiftData

@MainActor
final class SwiftDataRouteRepository: RouteRepository {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    /// 매 operation 마다 새 ModelContext 를 만들어 사용한다.
    /// mainContext 를 계속 쓰면 fetched RouteRecord 가 tcxData(수 MB) 를 물고
    /// 컨텍스트에 무한히 축적된다. 앱 어디에서도 @Query 를 쓰지 않으므로
    /// per-operation context 로 바꿔도 뷰 갱신 문제는 없다.
    private func newContext() -> ModelContext {
        ModelContext(container)
    }

    func fetchAll() async throws -> [Route] {
        let context = newContext()
        let records = try context.fetch(
            FetchDescriptor<RouteRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )
        return records.map(RouteMapper.toDomain)
    }

    func fetch(id: String) async throws -> Route? {
        let context = newContext()
        let routeID = id
        let records = try context.fetch(
            FetchDescriptor<RouteRecord>(predicate: #Predicate { $0.routeID == routeID })
        )
        return records.first.map(RouteMapper.toDomain)
    }

    func save(_ route: Route) async throws {
        let context = newContext()
        let routeID = route.id
        let existing = try context.fetch(
            FetchDescriptor<RouteRecord>(predicate: #Predicate { $0.routeID == routeID })
        ).first
        if let existing {
            RouteMapper.apply(route, to: existing)
        } else {
            context.insert(RouteMapper.toRecord(route))
        }
        try context.save()
    }

    func delete(id: String) async throws {
        let context = newContext()
        let routeID = id
        let records = try context.fetch(
            FetchDescriptor<RouteRecord>(predicate: #Predicate { $0.routeID == routeID })
        )
        for record in records { context.delete(record) }
        try context.save()
    }

    func reconcileStuckProcessing() async throws {
        let context = newContext()
        let stuck = try context.fetch(
            FetchDescriptor<RouteRecord>(predicate: #Predicate { $0.statusRaw == "processing" })
        )
        for record in stuck {
            record.status = .failed
            record.errorMessage = "처리가 중단되었습니다. 다시 시도하세요."
        }
        if !stuck.isEmpty { try context.save() }
    }
}
