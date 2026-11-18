import Foundation
import SwiftData
import CourseBoyKit

/// 처리 완료된(또는 처리 중인) 라우트를 DB 에 저장하는 SwiftData 모델.
///
/// 추가 시에는 원본 TCX(raw)와 전체 세그먼트만 저장하고, CoursePoint·내보낼 TCX 는
/// 상세화면에서 현재 `minCategory` 로 매번 즉석 계산한다.
@Model
final class RouteRecord {
    var routeID: String = ""
    var title: String = ""
    var createdAt: Date = Date()

    /// 추가 파이프라인 진행 상태. 진행률(fraction)은 영속하지 않고 RouteListViewModel 이 인메모리로 관리.
    var statusRaw: String = Status.ready.rawValue
    var errorMessage: String?

    /// 상세화면에서 선택한 CoursePoint 최소 카테고리 필터. nil = 전체.
    var minCategory: String?
    var trackPointCount: Int = 0
    /// 현재 `minCategory` 기준 CoursePoint 수 캐시 (리스트 행 표시용). 완료·필터 변경 시 갱신.
    var coursePointCount: Int = 0

    /// 다운로드한 원본 라우트 TCX. CoursePoint/내보낼 TCX 재현의 원천.
    @Attribute(.externalStorage) var tcxData: Data = Data()

    /// 라우트에 포함된 세그먼트 (표시 + Cuesheet 재계산 공용).
    var segments: [SegmentInfo] = []

    init(
        routeID: String,
        title: String,
        createdAt: Date,
        status: Status,
        minCategory: String? = nil,
        trackPointCount: Int = 0,
        coursePointCount: Int = 0,
        tcxData: Data = Data(),
        segments: [SegmentInfo] = []
    ) {
        self.routeID = routeID
        self.title = title
        self.createdAt = createdAt
        self.statusRaw = status.rawValue
        self.minCategory = minCategory
        self.trackPointCount = trackPointCount
        self.coursePointCount = coursePointCount
        self.tcxData = tcxData
        self.segments = segments
    }

    var fileNamePrefix: String {
        "route_\(routeID)"
    }

    // MARK: - 상태

    enum Status: String {
        case processing   // 다운로드·세그먼트 수집 중
        case ready        // 열람·내보내기 가능
        case failed       // 처리 실패 (재시도 가능)
    }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .ready }
        set { statusRaw = newValue.rawValue }
    }
}
