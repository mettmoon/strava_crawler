import Foundation
import StravaTCXKit

struct ImportRouteUseCase: Sendable {

    struct Progress: Sendable {
        var fraction: Double?
        var message: String
    }

    let routeRepository: any RouteRepository
    let segmentRepository: any SegmentRepository
    let remoteService: any StravaRemoteService
    let credentialsProvider: @Sendable () -> Credentials
    let requestInterval: @Sendable () -> Double

    func execute(myRoute: MyRoute) -> AsyncStream<Result<Progress, Error>> {
        AsyncStream { continuation in
            Task {
                await run(myRoute: myRoute, continuation: continuation)
            }
        }
    }

    private func run(myRoute: MyRoute, continuation: AsyncStream<Result<Progress, Error>>.Continuation) async {
        do {
            let creds = credentialsProvider()

            // 1) TCX 다운로드
            continuation.yield(.success(Progress(fraction: nil, message: "TCX 다운로드 중…")))
            let tcxData = try await remoteService.downloadTCX(routeID: myRoute.id, credentials: creds)
            let tcxCourse = try TCXCourse(data: tcxData)

            let title: String
            if let name = tcxCourse.courseName, !name.isEmpty {
                title = name
            } else {
                title = myRoute.name.isEmpty ? "Route \(myRoute.id)" : myRoute.name
            }

            // 2) 세그먼트 ID 목록
            continuation.yield(.success(Progress(fraction: 0, message: "세그먼트 목록 가져오는 중…")))
            let ids = try await remoteService.fetchSegmentIDs(routeID: myRoute.id, credentials: creds)

            // 3) 각 세그먼트 fetch (캐시 우선)
            let interval = requestInterval()
            var didFetch = false
            var segments: [SegmentInfo] = []

            for (i, id) in ids.enumerated() {
                var info: SegmentInfo
                if let cached = try await segmentRepository.fetch(id: id) {
                    info = cached
                } else {
                    if didFetch, interval > 0 {
                        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    }
                    didFetch = true
                    continuation.yield(.success(Progress(
                        fraction: Double(i) / Double(max(ids.count, 1)),
                        message: "세그먼트 \(i + 1)/\(ids.count)…"
                    )))
                    info = try await remoteService.fetchSegment(id: id, credentials: creds)
                    try await segmentRepository.save(info)
                }
                info.order = i + 1
                segments.append(info)
            }

            // 4) 도메인 Route 생성 및 저장
            let cuesheetCount = Cuesheet.makeEntries(
                trackPoints: tcxCourse.trackPoints,
                segments: segments
            ).entries.count

            let route = Route(
                id: myRoute.id,
                title: title,
                createdAt: Date(),
                status: .ready,
                errorMessage: nil,
                tcxData: tcxData,
                segments: segments,
                trackPointCount: tcxCourse.trackPoints.count,
                coursePointCount: cuesheetCount
            )
            try await routeRepository.save(route)
            continuation.finish()
        } catch {
            continuation.yield(.failure(error))
            continuation.finish()
        }
    }
}
