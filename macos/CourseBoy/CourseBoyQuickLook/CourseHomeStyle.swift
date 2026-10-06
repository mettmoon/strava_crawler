import SwiftUI

/// 홈 화면 색. 라이트는 하늘색 그라데이션 위 흰 유리 카드, 다크는 남색 그라데이션 위 어두운 유리 카드.
enum HomePalette {
    static let backgroundTop = Color(light: .init(red: 0.36, green: 0.55, blue: 0.85, alpha: 1), dark: .init(red: 0.05, green: 0.09, blue: 0.19, alpha: 1))
    static let backgroundBottom = Color(light: .init(red: 0.88, green: 0.92, blue: 0.97, alpha: 1), dark: .init(red: 0.10, green: 0.17, blue: 0.31, alpha: 1))
    /// 카드와 하단 버튼의 글자색.
    static let ink = Color(light: .init(red: 0.13, green: 0.24, blue: 0.45, alpha: 1), dark: .white)
    static let cardFill = Color(light: .white.withAlphaComponent(0.6), dark: .white.withAlphaComponent(0.08))
    static let cardStroke = Color(light: .white.withAlphaComponent(0.95), dark: .white.withAlphaComponent(0.16))
    static let thumbnailFill = Color(light: .init(red: 0.80, green: 0.87, blue: 0.96, alpha: 1), dark: .init(red: 0.13, green: 0.21, blue: 0.36, alpha: 1))
    static let thumbnailGrid = Color(light: .white.withAlphaComponent(0.6), dark: .white.withAlphaComponent(0.12))
    static let buttonFill = Color(light: .white.withAlphaComponent(0.92), dark: .white.withAlphaComponent(0.14))
    /// 빈 화면에서 강조하는 하단 버튼.
    static let prominentFill = Color(light: .init(red: 0.13, green: 0.24, blue: 0.45, alpha: 1), dark: .init(red: 0.62, green: 0.76, blue: 1.0, alpha: 1))
    static let prominentInk = Color(light: .white, dark: .init(red: 0.05, green: 0.09, blue: 0.19, alpha: 1))
}

extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

/// 홈 화면 정렬 기준.
enum RecentCourseSort: String, CaseIterable, Identifiable {
    case recent
    case distance
    case ascent
    case name

    var id: Self { self }

    var title: String {
        switch self {
        case .recent: "최근순"
        case .distance: "거리순"
        case .ascent: "상승고도순"
        case .name: "이름순"
        }
    }

    func sorted(_ courses: [RecentCourse]) -> [RecentCourse] {
        switch self {
        case .recent:
            courses.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        case .distance:
            courses.sorted { $0.distanceKm > $1.distanceKm }
        case .ascent:
            courses.sorted { ($0.ascentMeters ?? -1) > ($1.ascentMeters ?? -1) }
        case .name:
            courses.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
}

/// 홈 화면 파일 형식 필터.
enum RecentCourseKindFilter: String, CaseIterable, Identifiable {
    case all
    case gpx
    case tcx

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "전체"
        case .gpx: "GPX"
        case .tcx: "TCX"
        }
    }

    func includes(_ course: RecentCourse) -> Bool {
        switch self {
        case .all: true
        case .gpx: course.fileKind == "GPX"
        case .tcx: course.fileKind == "TCX"
        }
    }
}

extension RecentCourse {
    /// 카드의 날짜. 오늘·어제는 말로, 올해는 월·일만, 그 이전은 연도까지 쓴다.
    var lastOpenedLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(lastOpenedAt) { return "오늘" }
        if calendar.isDateInYesterday(lastOpenedAt) { return "어제" }
        let sameYear = calendar.isDate(lastOpenedAt, equalTo: .now, toGranularity: .year)
        return lastOpenedAt.formatted(
            sameYear
                ? .dateTime.month(.defaultDigits).day()
                : .dateTime.year().month(.defaultDigits).day()
        )
    }

    /// "18.4 km · ▲ 486 m". 고도 데이터가 없으면 거리만 쓴다.
    var statsLabel: String {
        let distance = String(format: "%.1f km", distanceKm)
        guard let ascentMeters else { return distance }
        return "\(distance) · ▲ \(String(format: "%.0f m", ascentMeters))"
    }
}
