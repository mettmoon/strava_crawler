import Foundation

/// Strava climb_category / 경사도 분류 및 이름·수치 포맷 헬퍼.
/// Python 구현(get_segment_info.py / add_cuesheet_to_tcx.py)과 1:1 대응.
public enum Classification {

    // MARK: - climb_category

    /// Strava climb_category → TCX CoursePoint PointType
    static let categoryPointType: [String: String] = [
        "1": "First Category",
        "2": "Second Category",
        "3": "Third Category",
        "4": "Fourth Category",
        "HC": "Hors Category",
    ]

    /// 등급 순서 점수 (높을수록 어려움). 카테고리 없음 = 0
    static let categoryRankMap: [String: Int] = [
        "4": 1, "3": 2, "2": 3, "1": 4, "HC": 5,
    ]

    /// 'Category2' → '2', 'CategoryHC' → 'HC', 0/None/'NC' → nil 로 정규화.
    public static func normalizeClimbCategory(_ value: String?) -> String? {
        guard let raw = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "0" { return nil }
        var s = trimmed
        if let range = s.range(of: #"^category\s*"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(range)
        }
        s = s.trimmingCharacters(in: .whitespaces).uppercased()
        if s.isEmpty || s == "0" || s == "NC" { return nil }
        return s
    }

    /// 업힐 카테고리 → 시작 PointType. 카테고리 없거나 0 이면 Sprint.
    public static func startPointType(_ climbCategory: String?) -> String {
        guard let key = normalizeClimbCategory(climbCategory) else { return "Sprint" }
        return categoryPointType[key] ?? "Sprint"
    }

    /// 등급 → 점수 (없음=0, 4=1, ..., HC=5).
    public static func categoryRank(_ climbCategory: String?) -> Int {
        guard let key = normalizeClimbCategory(climbCategory) else { return 0 }
        return categoryRankMap[key] ?? 0
    }

    // MARK: - 경사도 구분

    public enum GradeClass: String, Codable, Sendable {
        case up, flat, down

        /// 시작 지점 prefix (RWGPS Name/Notes 용)
        public var arrow: String {
            switch self {
            case .up: return "↗"
            case .flat: return "→"
            case .down: return "↘"
            }
        }
    }

    public static let gradeFlatThreshold = 1.5

    /// avgGrade(%) → up(>1.5) / down(<-1.5) / flat([-1.5, 1.5]). 파싱 실패 시 flat.
    public static func gradeClass(_ grade: String?) -> GradeClass {
        guard let value = firstNumber(in: grade) else { return .flat }
        if value > gradeFlatThreshold { return .up }
        if value < -gradeFlatThreshold { return .down }
        return .flat
    }

    public static func gradeClass(value: Double?) -> GradeClass {
        guard let value else { return .flat }
        if value > gradeFlatThreshold { return .up }
        if value < -gradeFlatThreshold { return .down }
        return .flat
    }

    // MARK: - 이름 정리 (종료 지점 Name/Notes 용)

    /// segment 이름 정리:
    ///  1) 'by ...' (by 포함 그 뒤 전부) 제거
    ///  2) '#...' (# 포함 그 뒤 전부) 제거
    ///  3) 맨 앞뒤 특수문자(비 word 문자) 제거
    /// 각 단계 후 trim.
    public static func resolveSegmentName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "" }
        var s = name
        s = replacingRegex(s, pattern: #"\s*\bby\b.*$"#, options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        s = replacingRegex(s, pattern: #"\s*#.*$"#)
            .trimmingCharacters(in: .whitespaces)
        s = replacingRegex(s, pattern: #"^[^\w]+|[^\w]+$"#)
            .trimmingCharacters(in: .whitespaces)
        return s
    }

    // MARK: - 수치 포맷 (Python _format_* / _fmt_grade 대응)

    /// meters → '7.89 km' (>=1000) 또는 '529 m'
    public static func formatDistance(_ meters: Double?) -> String? {
        guard let v = meters else { return nil }
        if v >= 1000 { return String(format: "%.2f km", v / 1000) }
        return String(format: "%.0f m", v)
    }

    /// meters → '529 m'
    public static func formatMeters(_ value: Double?) -> String? {
        guard let v = value else { return nil }
        return String(format: "%.0f m", v)
    }

    /// percent → '6.71%' (Python '{v:g}%' 와 동일하게 불필요한 0 제거)
    public static func formatPercent(_ value: Double?) -> String? {
        guard let v = value else { return nil }
        return "\(trimNumber(v))%"
    }

    /// 경사도를 소수 첫째자리까지로 표기. '7.86396%' → '7.9%', '7%' → '7.0%'.
    public static func formatGrade(_ grade: String?) -> String? {
        guard let grade else { return nil }
        guard let v = firstNumber(in: grade) else { return grade }
        return String(format: "%.1f%%", (v * 10).rounded() / 10)
    }

    /// '0.71 km' → '0.71km' (공백 제거)
    public static func normalizeDistanceText(_ dist: String?) -> String {
        guard let dist, !dist.isEmpty else { return "" }
        return dist.replacingOccurrences(of: " ", with: "")
    }

    // MARK: - 내부 유틸

    /// 문자열에서 첫 번째 (부호 포함) 숫자를 Double 로.
    static func firstNumber(in text: String?) -> Double? {
        guard let text else { return nil }
        guard let range = text.range(of: #"-?\d+(?:\.\d+)?"#, options: .regularExpression) else {
            return nil
        }
        return Double(text[range])
    }

    /// Python '{v:g}' 유사 — 불필요한 후행 0 / 소수점 제거.
    static func trimNumber(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e16 {
            return String(format: "%.0f", v)
        }
        var s = String(format: "%.6g", v)
        // %g 가 지수표기로 가지 않는 일반 범위에서 후행 0 정리
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    static func replacingRegex(
        _ s: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    }
}
