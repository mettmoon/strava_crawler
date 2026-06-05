import Foundation
import StravaTCXKit

enum RouteMapper {
    static func toDomain(_ record: RouteRecord) -> Route {
        Route(
            id: record.routeID,
            title: record.title,
            createdAt: record.createdAt,
            status: ImportStatus(rawValue: record.statusRaw) ?? .ready,
            errorMessage: record.errorMessage,
            tcxData: record.tcxData,
            segments: record.segments,
            trackPointCount: record.trackPointCount,
            coursePointCount: record.coursePointCount,
            minCategory: record.minCategory
        )
    }

    static func apply(_ route: Route, to record: RouteRecord) {
        record.title = route.title
        record.statusRaw = route.status.rawValue
        record.errorMessage = route.errorMessage
        record.tcxData = route.tcxData
        record.segments = route.segments
        record.trackPointCount = route.trackPointCount
        record.coursePointCount = route.coursePointCount
        record.minCategory = route.minCategory
    }

    static func toRecord(_ route: Route) -> RouteRecord {
        RouteRecord(
            routeID: route.id,
            title: route.title,
            createdAt: route.createdAt,
            status: RouteRecord.Status(rawValue: route.status.rawValue) ?? .ready,
            minCategory: route.minCategory,
            trackPointCount: route.trackPointCount,
            coursePointCount: route.coursePointCount,
            tcxData: route.tcxData,
            segments: route.segments
        )
    }
}
