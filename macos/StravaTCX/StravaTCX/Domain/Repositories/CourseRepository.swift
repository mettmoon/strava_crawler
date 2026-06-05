import Foundation

protocol CourseRepository: Sendable {
    func fetchAll() async throws -> [Course]
    func fetch(id: UUID) async throws -> Course?
    func save(_ course: Course) async throws
    func delete(id: UUID) async throws
}
