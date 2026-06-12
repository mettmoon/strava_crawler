import Foundation
import SwiftData

@MainActor
final class AppContainer {

    // MARK: - Infrastructure

    let modelContainer: ModelContainer

    // MARK: - Data layer

    let remoteService: LiveStravaRemoteService
    let segmentRepository: CachingSegmentRepository
    let routeRepository: SwiftDataRouteRepository
    let courseRepository: SwiftDataCourseRepository

    // MARK: - Use Cases

    let importRouteUseCase: ImportRouteUseCase
    let retryImportUseCase: RetryImportUseCase
    let fetchMyRoutesUseCase: FetchMyRoutesUseCase
    let reloadSegmentUseCase: ReloadSegmentUseCase
    let deleteSegmentUseCase: DeleteSegmentUseCase
    let buildCuesheetUseCase: BuildCuesheetUseCase
    let exportTCXUseCase: ExportTCXUseCase
    let makeCourseFromRouteUseCase: MakeCourseFromRouteUseCase
    let computeRouteSegmentUseCase: ComputeRouteSegmentUseCase
    let reconcileImportsUseCase: ReconcileImportsUseCase

    // MARK: - Init

    init() throws {
        modelContainer = try ModelContainer(for: RouteRecord.self, CourseRecord.self)

        let credProvider: @Sendable () -> Credentials = {
            Credentials(cookie: AppSettings.cookie, csrfToken: AppSettings.csrfToken)
        }
        let intervalProvider: @Sendable () -> Double = { AppSettings.segmentRequestInterval }

        remoteService = LiveStravaRemoteService()
        segmentRepository = CachingSegmentRepository(remoteService: remoteService)
        routeRepository = SwiftDataRouteRepository(container: modelContainer)
        courseRepository = SwiftDataCourseRepository(container: modelContainer)

        importRouteUseCase = ImportRouteUseCase(
            routeRepository: routeRepository,
            segmentRepository: segmentRepository,
            remoteService: remoteService,
            credentialsProvider: credProvider,
            requestInterval: intervalProvider
        )
        retryImportUseCase = RetryImportUseCase(
            routeRepository: routeRepository,
            segmentRepository: segmentRepository,
            remoteService: remoteService,
            credentialsProvider: credProvider,
            requestInterval: intervalProvider
        )
        fetchMyRoutesUseCase = FetchMyRoutesUseCase(
            remoteService: remoteService,
            credentialsProvider: credProvider
        )
        reloadSegmentUseCase = ReloadSegmentUseCase(
            segmentRepository: segmentRepository,
            routeRepository: routeRepository,
            remoteService: remoteService,
            credentialsProvider: credProvider
        )
        deleteSegmentUseCase = DeleteSegmentUseCase(routeRepository: routeRepository, segmentRepository: segmentRepository)
        buildCuesheetUseCase = BuildCuesheetUseCase(routeRepository: routeRepository)
        exportTCXUseCase = ExportTCXUseCase(routeRepository: routeRepository)
        makeCourseFromRouteUseCase = MakeCourseFromRouteUseCase(
            routeRepository: routeRepository,
            courseRepository: courseRepository
        )
        computeRouteSegmentUseCase = ComputeRouteSegmentUseCase()
        reconcileImportsUseCase = ReconcileImportsUseCase(routeRepository: routeRepository)
    }

    // MARK: - ViewModel Factories

    func makeRouteListViewModel() -> RouteListViewModel {
        RouteListViewModel(
            importRouteUseCase: importRouteUseCase,
            retryImportUseCase: retryImportUseCase,
            reconcileUseCase: reconcileImportsUseCase,
            routeRepository: routeRepository
        )
    }

    func makeCourseEditorViewModel(for courseID: UUID) -> CourseEditorViewModel {
        CourseEditorViewModel(
            courseID: courseID,
            courseRepository: courseRepository,
            computeSegmentUseCase: computeRouteSegmentUseCase
        )
    }

    func makeSegmentLibraryViewModel() -> SegmentLibraryViewModel {
        SegmentLibraryViewModel(segmentRepository: segmentRepository)
    }
}
