import Foundation
import SwiftData

@MainActor
final class SwiftDataRouteRepository: RouteRepository {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func fetchAll() async throws -> [Route] {
        let context = container.mainContext
        let records = try context.fetch(
            FetchDescriptor<RouteRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )
        return records.map(RouteMapper.toDomain)
    }

    func fetch(id: String) async throws -> Route? {
        let context = container.mainContext
        let routeID = id
        let records = try context.fetch(
            FetchDescriptor<RouteRecord>(predicate: #Predicate { $0.routeID == routeID })
        )
        return records.first.map(RouteMapper.toDomain)
    }

    func save(_ route: Route) async throws {
        let context = container.mainContext
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
        let context = container.mainContext
        let routeID = id
        let records = try context.fetch(
            FetchDescriptor<RouteRecord>(predicate: #Predicate { $0.routeID == routeID })
        )
        for record in records { context.delete(record) }
        try context.save()
    }

    func reconcileStuckProcessing() async throws {
        let context = container.mainContext
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
