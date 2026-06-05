import SwiftUI
import StravaTCXKit

// MARK: - Sidebar 선택 타입

enum SidebarItem: Hashable {
    case route(Route)
    case segment(SegmentInfo)
    case course(CourseRecord)
}

// MARK: - 공통 헬퍼

func categoryLabel(_ cat: String?) -> String {
    guard let cat else { return "—" }
    return cat == "HC" ? "HC" : "Cat \(cat)"
}

func pointTypeColor(_ pointType: String) -> Color {
    switch pointType {
    case "Summit":  return .green
    case "Valley":  return .blue
    case "Straight": return .secondary
    case "Sprint":  return .purple
    default:        return .orange
    }
}

func trackPoints(for segment: SegmentInfo) -> [TrackPoint] {
    guard let coords = segment.coordinates, !coords.isEmpty else { return [] }
    let elevs = segment.elevations
    let dists = segment.distances
    return coords.enumerated().map { i, c in
        let lat  = c.count >= 1 ? c[0] : 0
        let lon  = c.count >= 2 ? c[1] : 0
        let ele  = (elevs != nil && i < elevs!.count) ? elevs![i] : nil
        let cumKm = (dists != nil && i < dists!.count) ? dists![i] / 1000.0 : 0
        return TrackPoint(lat: lat, lon: lon, ele: ele, time: nil, cumKm: cumKm)
    }
}

/// Table 행용 식별 래퍼
struct IdentifiedEntry: Identifiable {
    let id: Int
    let entry: CoursePointEntry
}

func previewNotes(for e: CoursePointEntry) -> String {
    if e.isStart {
        let body = [Classification.normalizeDistanceText(e.dist), Classification.formatGrade(e.grade)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        return e.gradeClass.arrow + body
    } else {
        return "🏁" + Classification.resolveSegmentName(e.segName)
    }
}
