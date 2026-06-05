import Foundation
import StravaTCXKit

struct Route: Sendable, Identifiable, Hashable {
    let id: String
    var title: String
    var createdAt: Date
    var status: ImportStatus
    var errorMessage: String?
    var tcxData: Data
    var segments: [SegmentInfo]
    var trackPointCount: Int
    var coursePointCount: Int
    var minCategory: String?

    var fileNamePrefix: String { "route_\(id)" }
}

enum ImportStatus: String, Sendable {
    case processing
    case ready
    case failed
}
