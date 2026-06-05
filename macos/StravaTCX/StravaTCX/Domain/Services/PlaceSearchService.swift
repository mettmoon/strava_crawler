import Foundation
import CoreLocation

struct PlaceResult: Sendable, Identifiable {
    let id: String
    var name: String
    var addressName: String
    var coordinate: CLLocationCoordinate2D
}

protocol PlaceSearchService: Sendable {
    func search(query: String) async throws -> [PlaceResult]
}
