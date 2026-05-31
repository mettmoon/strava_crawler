import Foundation
import SwiftData

/// 처리 완료된 라우트를 DB 에 저장하는 SwiftData 모델.
@Model
final class RouteRecord {
    var routeID: String = ""
    var title: String = ""
    var createdAt: Date = Date()
    var minCategory: String?
    var trackPointCount: Int = 0
    var coursePointCount: Int = 0

    // 생성된 TCX 산출물 (나중에 파일로 재내보내기 가능)
    @Attribute(.externalStorage) var cuedTCX: Data = Data()
    @Attribute(.externalStorage) var rwgpsTCX: Data = Data()

    // 열람용 스냅샷
    var segments: [StoredSegment] = []
    var coursePoints: [StoredCoursePoint] = []

    init(
        routeID: String,
        title: String,
        createdAt: Date,
        minCategory: String?,
        trackPointCount: Int,
        coursePointCount: Int,
        cuedTCX: Data,
        rwgpsTCX: Data,
        segments: [StoredSegment],
        coursePoints: [StoredCoursePoint]
    ) {
        self.routeID = routeID
        self.title = title
        self.createdAt = createdAt
        self.minCategory = minCategory
        self.trackPointCount = trackPointCount
        self.coursePointCount = coursePointCount
        self.cuedTCX = cuedTCX
        self.rwgpsTCX = rwgpsTCX
        self.segments = segments
        self.coursePoints = coursePoints
    }

    var fileNamePrefix: String {
        "route_\(routeID)"
    }
}

struct StoredSegment: Codable, Hashable, Identifiable {
    var id = UUID()
    var order: Int?
    var name: String
    var category: String?
    var distance: String?
    var grade: String?
}

struct StoredCoursePoint: Codable, Hashable, Identifiable {
    var id = UUID()
    var isStart: Bool
    var pointType: String
    var notes: String
}
