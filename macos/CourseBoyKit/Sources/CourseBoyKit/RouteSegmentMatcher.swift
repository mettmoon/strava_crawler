import Foundation

/// 한 세그먼트가 라우트에서 실제로 등장하는 위치.
public struct RouteSegmentMatch: Sendable, Equatable {
    public var segmentID: String
    public var startIndex: Int
    public var endIndex: Int
    public var startKm: Double
    public var endKm: Double

    public init(segmentID: String, startIndex: Int, endIndex: Int, startKm: Double, endKm: Double) {
        self.segmentID = segmentID
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.startKm = startKm
        self.endKm = endKm
    }
}

/// 좌표가 여러 번 등장하는 왕복/순환 라우트에서도 세그먼트의 실제 통과 위치를 찾는다.
public enum RouteSegmentMatcher {

    public static func match(
        trackPoints pts: [TrackPoint],
        segments: [SegmentInfo]
    ) -> [String: RouteSegmentMatch] {
        guard pts.count > 1 else { return [:] }

        let ordered = segments.enumerated().sorted { lhs, rhs in
            let lhsOrder = lhs.element.order ?? Int.max
            let rhsOrder = rhs.element.order ?? Int.max
            return lhsOrder == rhsOrder ? lhs.offset < rhs.offset : lhsOrder < rhsOrder
        }.map(\.element)

        var result: [String: RouteSegmentMatch] = [:]
        var minimumStartIndex = 0

        for segment in ordered {
            guard let candidate = bestCandidate(
                for: segment,
                in: pts,
                minimumStartIndex: minimumStartIndex
            ) else { continue }

            result[segment.segmentID] = RouteSegmentMatch(
                segmentID: segment.segmentID,
                startIndex: candidate.startIndex,
                endIndex: candidate.endIndex,
                startKm: pts[candidate.startIndex].cumKm,
                endKm: pts[candidate.endIndex].cumKm
            )

            // 세그먼트는 서로 겹칠 수 있으므로 종료점이 아닌 시작점까지만 진행시킨다.
            minimumStartIndex = candidate.startIndex
        }

        return result
    }

    /// 매칭된 누적거리를 복사한 route 전용 세그먼트 배열을 만든다.
    public static func enriching(
        _ segments: [SegmentInfo],
        trackPoints: [TrackPoint]
    ) -> [SegmentInfo] {
        let matches = match(trackPoints: trackPoints, segments: segments)
        return segments.map { segment in
            guard let placement = matches[segment.segmentID] else { return segment }
            var copy = segment
            copy.startKm = placement.startKm
            copy.endKm = placement.endKm
            if copy.distanceKm == nil {
                copy.distanceKm = max(0, placement.endKm - placement.startKm)
            }
            return copy
        }
    }

    private struct Candidate {
        var startIndex: Int
        var endIndex: Int
        var score: Double
    }

    private static func bestCandidate(
        for segment: SegmentInfo,
        in pts: [TrackPoint],
        minimumStartIndex: Int
    ) -> Candidate? {
        guard let start = coordinate(segment.startPoint) else { return nil }
        let end = coordinate(segment.endPoint)
        let expectedLength = segmentLengthKm(segment)
        let lowerBound = min(max(0, minimumStartIndex), pts.count - 1)
        var best: Candidate?

        let startCandidates = startCandidateIndices(
            in: pts,
            coordinate: start,
            lowerBound: lowerBound,
            storedStartKm: segment.startKm
        )
        for startIndex in startCandidates {
            let startError = Geo.haversineKm(pts[startIndex].lat, pts[startIndex].lon, start.lat, start.lon)
            guard let endIndex = endIndex(
                for: segment,
                startIndex: startIndex,
                expectedLengthKm: expectedLength,
                endCoordinate: end,
                in: pts
            ), endIndex > startIndex else { continue }

            var score = startError * 3
            if let end {
                score += Geo.haversineKm(pts[endIndex].lat, pts[endIndex].lon, end.lat, end.lon) * 4
            }
            if let expectedLength {
                let actualLength = pts[endIndex].cumKm - pts[startIndex].cumKm
                score += abs(actualLength - expectedLength)
            }
            if let storedStart = segment.startKm, storedStart.isFinite {
                score += abs(pts[startIndex].cumKm - storedStart) * 6
            }
            score += geometryError(
                segment: segment,
                startIndex: startIndex,
                endIndex: endIndex,
                in: pts
            ) * 2

            if best == nil || score < best!.score {
                best = Candidate(startIndex: startIndex, endIndex: endIndex, score: score)
            }
        }

        return best
    }

    /// 전체 경로에서 시작 좌표까지의 지역 최소점만 후보로 남겨 반복 매칭 비용을 제한한다.
    private static func startCandidateIndices(
        in pts: [TrackPoint],
        coordinate: (lat: Double, lon: Double),
        lowerBound: Int,
        storedStartKm: Double?
    ) -> [Int] {
        let upperBound = pts.count - 2
        guard lowerBound <= upperBound else { return [] }

        var distances: [Double] = []
        distances.reserveCapacity(upperBound - lowerBound + 1)
        for index in lowerBound...upperBound {
            distances.append(Geo.haversineKm(
                pts[index].lat, pts[index].lon,
                coordinate.lat, coordinate.lon
            ))
        }
        guard let minimum = distances.min() else { return [] }
        let threshold = minimum + 0.075
        var candidates: [Int] = []

        for offset in distances.indices where distances[offset] <= threshold {
            let previous = offset > 0 ? distances[offset - 1] : Double.infinity
            let next = offset + 1 < distances.count ? distances[offset + 1] : Double.infinity
            if distances[offset] <= previous && distances[offset] <= next {
                candidates.append(lowerBound + offset)
            }
        }

        if let storedStartKm, storedStartKm.isFinite,
           let storedIndex = Geo.nearestIndex(pts, distanceKm: storedStartKm),
           storedIndex >= lowerBound, storedIndex <= upperBound,
           !candidates.contains(storedIndex) {
            candidates.append(storedIndex)
        }

        return candidates.sorted()
    }

    private static func endIndex(
        for segment: SegmentInfo,
        startIndex: Int,
        expectedLengthKm: Double?,
        endCoordinate: (lat: Double, lon: Double)?,
        in pts: [TrackPoint]
    ) -> Int? {
        if let expectedLengthKm, expectedLengthKm > 0 {
            let targetKm = pts[startIndex].cumKm + expectedLengthKm
            guard targetKm <= pts.last!.cumKm + max(0.2, expectedLengthKm * 0.2) else { return nil }

            let tolerance = max(0.12, min(1.0, expectedLengthKm * 0.15))
            let lowerKm = max(pts[startIndex + 1].cumKm, targetKm - tolerance)
            let upperKm = min(pts.last!.cumKm, targetKm + tolerance)
            guard lowerKm <= upperKm,
                  let lowerIndex = Geo.nearestIndex(pts, distanceKm: lowerKm),
                  let upperIndex = Geo.nearestIndex(pts, distanceKm: upperKm)
            else { return nil }

            if let endCoordinate {
                return nearestCoordinateIndex(
                    in: pts,
                    lat: endCoordinate.lat,
                    lon: endCoordinate.lon,
                    range: max(startIndex + 1, lowerIndex)...max(startIndex + 1, upperIndex)
                )
            }
            return Geo.nearestIndex(pts, distanceKm: targetKm)
        }

        guard let endCoordinate else { return nil }
        return nearestCoordinateIndex(
            in: pts,
            lat: endCoordinate.lat,
            lon: endCoordinate.lon,
            range: (startIndex + 1)...(pts.count - 1)
        )
    }

    private static func nearestCoordinateIndex(
        in pts: [TrackPoint],
        lat: Double,
        lon: Double,
        range: ClosedRange<Int>
    ) -> Int? {
        let lower = min(max(0, range.lowerBound), pts.count - 1)
        let upper = min(max(lower, range.upperBound), pts.count - 1)
        var bestIndex: Int?
        var bestDistance = Double.infinity
        for index in lower...upper {
            let distance = Geo.haversineKm(pts[index].lat, pts[index].lon, lat, lon)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    private static func geometryError(
        segment: SegmentInfo,
        startIndex: Int,
        endIndex: Int,
        in pts: [TrackPoint]
    ) -> Double {
        guard let coordinates = segment.coordinates, coordinates.count >= 2 else { return 0 }
        let sampleCount = min(7, coordinates.count)
        var total = 0.0
        var used = 0

        for sample in 0..<sampleCount {
            let coordinateIndex = sample * (coordinates.count - 1) / (sampleCount - 1)
            guard let coordinate = coordinate(coordinates[coordinateIndex]) else { continue }
            let fraction: Double
            if let distances = segment.distances,
               distances.count == coordinates.count,
               let totalDistance = distances.last,
               totalDistance > 0 {
                fraction = min(max(distances[coordinateIndex] / totalDistance, 0), 1)
            } else {
                fraction = Double(coordinateIndex) / Double(coordinates.count - 1)
            }
            let targetKm = pts[startIndex].cumKm
                + (pts[endIndex].cumKm - pts[startIndex].cumKm) * fraction
            guard let routeIndex = Geo.nearestIndex(pts, distanceKm: targetKm) else { continue }
            total += Geo.haversineKm(
                pts[routeIndex].lat, pts[routeIndex].lon,
                coordinate.lat, coordinate.lon
            )
            used += 1
        }

        return used > 0 ? total / Double(used) : 0
    }

    private static func segmentLengthKm(_ segment: SegmentInfo) -> Double? {
        if let value = segment.distanceKm, value.isFinite, value > 0 { return value }
        if let value = segment.distanceMeters, value.isFinite, value > 0 { return value / 1_000 }
        if let distances = segment.distances, let value = distances.last, value.isFinite, value > 0 {
            return value / 1_000
        }
        guard let text = segment.distanceText,
              let range = text.range(of: #"[\d,]+(?:\.\d+)?"#, options: .regularExpression),
              let value = Double(text[range].replacingOccurrences(of: ",", with: ""))
        else { return nil }
        let lowercased = text.lowercased()
        if lowercased.contains("mi") { return value * 1.609344 }
        if lowercased.contains("km") { return value }
        return value / 1_000
    }

    private static func coordinate(_ values: [Double]?) -> (lat: Double, lon: Double)? {
        guard let values, values.count >= 2 else { return nil }
        return (values[0], values[1])
    }
}
