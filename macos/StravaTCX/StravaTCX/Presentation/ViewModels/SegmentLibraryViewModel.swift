import Foundation
import Observation
import StravaTCXKit

@MainActor
@Observable
final class SegmentLibraryViewModel {
    private(set) var segments: [SegmentInfo] = []
    private(set) var isLoading = false
    var searchText: String = ""

    private let segmentRepository: any SegmentRepository

    init(segmentRepository: any SegmentRepository) {
        self.segmentRepository = segmentRepository
    }

    var filteredSegments: [SegmentInfo] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return segments }
        return segments.filter { $0.name.lowercased().contains(q) }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        segments = (try? await segmentRepository.fetchAll()) ?? []
    }
}
