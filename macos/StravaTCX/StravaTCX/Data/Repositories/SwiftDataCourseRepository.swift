import Foundation
import SwiftData

@MainActor
final class SwiftDataCourseRepository: CourseRepository {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func fetchAll() async throws -> [Course] {
        let context = container.mainContext
        let records = try context.fetch(
            FetchDescriptor<CourseRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )
        return records.map(CourseMapper.toDomain)
    }

    func fetch(id: UUID) async throws -> Course? {
        let context = container.mainContext
        let courseID = id
        let records = try context.fetch(
            FetchDescriptor<CourseRecord>(predicate: #Predicate { $0.id == courseID })
        )
        return records.first.map(CourseMapper.toDomain)
    }

    func save(_ course: Course) async throws {
        let context = container.mainContext
        let courseID = course.id
        let existing = try context.fetch(
            FetchDescriptor<CourseRecord>(predicate: #Predicate { $0.id == courseID })
        ).first
        if let existing {
            CourseMapper.apply(course, to: existing)
        } else {
            context.insert(CourseMapper.toRecord(course))
        }
        try context.save()
    }

    func delete(id: UUID) async throws {
        let context = container.mainContext
        let courseID = id
        let records = try context.fetch(
            FetchDescriptor<CourseRecord>(predicate: #Predicate { $0.id == courseID })
        )
        for record in records { context.delete(record) }
        try context.save()
    }
}
