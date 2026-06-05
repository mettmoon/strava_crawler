import Foundation
import StravaTCXKit

struct RetryImportUseCase: Sendable {
    let routeRepository: any RouteRepository
    let segmentRepository: any SegmentRepository
    let remoteService: any StravaRemoteService
    let credentialsProvider: @Sendable () -> Credentials
    let requestInterval: @Sendable () -> Double

    func execute(routeID: String) -> AsyncStream<Result<ImportRouteUseCase.Progress, Error>> {
        AsyncStream { continuation in
            Task {
                do {
                    guard var route = try await routeRepository.fetch(id: routeID) else {
                        continuation.finish()
                        return
                    }
                    guard route.status != .processing else {
                        continuation.finish()
                        return
                    }
                    route.status = .processing
                    route.errorMessage = nil
                    try await routeRepository.save(route)

                    let inner = ImportRouteUseCase(
                        routeRepository: routeRepository,
                        segmentRepository: segmentRepository,
                        remoteService: remoteService,
                        credentialsProvider: credentialsProvider,
                        requestInterval: requestInterval
                    )
                    let myRoute = MyRoute(id: routeID, name: route.title)
                    for await event in inner.execute(myRoute: myRoute) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.failure(error))
                    continuation.finish()
                }
            }
        }
    }
}
