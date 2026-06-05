import Foundation
import Observation
import StravaTCXKit

@MainActor
@Observable
final class CourseEditorViewModel {
    var draft: CourseEditorDraft?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let courseID: UUID
    private let courseRepository: any CourseRepository
    private let computeSegmentUseCase: ComputeRouteSegmentUseCase

    init(
        courseID: UUID,
        courseRepository: any CourseRepository,
        computeSegmentUseCase: ComputeRouteSegmentUseCase
    ) {
        self.courseID = courseID
        self.courseRepository = courseRepository
        self.computeSegmentUseCase = computeSegmentUseCase
    }

    func load() async {
        guard let course = try? await courseRepository.fetch(id: courseID) else { return }
        // CourseEditorDraft는 CourseRecord를 받으므로, Course → CourseRecord 변환 후 생성
        let record = CourseMapper.toRecord(course)
        draft = CourseEditorDraft(from: record)
    }

    func appendRoutePoint(_ rp: CourseRoutePoint) async {
        guard let draft else { return }
        isLoading = true
        defer { isLoading = false }
        let segment = await computeSegmentUseCase.execute(from: draft.routePoints.last, to: rp)
        draft.appendRoutePoint(rp, segment: segment)
    }

    func moveRoutePoint(at idx: Int, to newRP: CourseRoutePoint) async {
        guard let draft else { return }
        isLoading = true
        defer { isLoading = false }

        var updated = draft.trackSegments

        // 앞 구간 (idx-1 → idx) 재계산
        if idx > 0, idx - 1 < updated.count {
            let before = draft.routePoints[idx - 1]
            let seg = await computeSegmentUseCase.execute(from: before, to: newRP)
            updated[idx - 1] = seg
        }
        // 뒤 구간 (idx → idx+1) 재계산
        if idx < draft.routePoints.count - 1, idx < updated.count {
            let after = draft.routePoints[idx + 1]
            let seg = await computeSegmentUseCase.execute(from: newRP, to: after)
            updated[idx] = seg
        }
        draft.moveRoutePoint(at: idx, to: newRP, updatedSegments: updated)
    }

    func save() async throws {
        guard let draft else { return }
        let record = CourseMapper.toRecord(Course(
            id: courseID,
            title: draft.title,
            createdAt: Date(),
            routePoints: draft.routePoints,
            trackSegments: draft.trackSegments,
            cuePoints: draft.cuePoints
        ))
        draft.commit(to: record)
        let course = CourseMapper.toDomain(record)
        try await courseRepository.save(course)
    }
}
