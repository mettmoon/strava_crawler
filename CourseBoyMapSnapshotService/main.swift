import AppKit
import Foundation
import MapKit

final class MapSnapshotServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MapSnapshotServiceProtocol.self)
        connection.exportedObject = MapSnapshotRenderer()
        connection.resume()
        return true
    }
}

final class MapSnapshotRenderer: NSObject, MapSnapshotServiceProtocol {
    func makeSnapshot(requestData: Data, reply: @escaping (Data?, String?) -> Void) {
        let request: MapSnapshotRequest
        do {
            request = try JSONDecoder().decode(MapSnapshotRequest.self, from: requestData)
        } catch {
            reply(nil, "잘못된 요청: \(error.localizedDescription)")
            return
        }
        DispatchQueue.main.async {
            Self.render(request, reply: reply)
        }
    }

    private static func render(_ request: MapSnapshotRequest, reply: @escaping (Data?, String?) -> Void) {
        let segments = request.segments.map { segment in
            segment.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count == 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
            }
        }
        let coordinates = segments.flatMap { $0 }
        let size = NSSize(width: max(request.width, 1), height: max(request.height, 1))

        let options = MKMapSnapshotter.Options()
        options.size = size
        options.appearance = NSAppearance(named: request.isDark ? .darkAqua : .aqua)
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration

        if coordinates.count >= 2 {
            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            options.mapRect = paddedMapRect(polyline.boundingMapRect, size: size, padding: 44)
        } else if let coordinate = coordinates.first {
            options.region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 1_000,
                longitudinalMeters: 1_000
            )
        }

        MKMapSnapshotter(options: options).start(with: .main) { snapshot, error in
            guard let snapshot else {
                reply(nil, error?.localizedDescription ?? "지도 스냅샷을 만들지 못했습니다.")
                return
            }
            reply(draw(snapshot: snapshot, segments: segments, markers: request.markers), nil)
        }
    }

    /// 경로가 가장자리에 붙지 않도록 화면 기준 여백만큼 지도 영역을 넓힌다.
    private static func paddedMapRect(_ rect: MKMapRect, size: NSSize, padding: Double) -> MKMapRect {
        let usableWidth = max(size.width - padding * 2, 1)
        let usableHeight = max(size.height - padding * 2, 1)
        let pointsPerPixel = max(rect.width / usableWidth, rect.height / usableHeight, 1)
        let width = size.width * pointsPerPixel
        let height = size.height * pointsPerPixel
        return MKMapRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func draw(
        snapshot: MKMapSnapshotter.Snapshot,
        segments: [[CLLocationCoordinate2D]],
        markers: [MapSnapshotRequest.Marker]
    ) -> Data? {
        let image = snapshot.image
        let composed = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            // macOS의 snapshot.point(for:)는 이미지와 같은 좌하단 원점 좌표를 돌려준다.
            func point(_ coordinate: CLLocationCoordinate2D) -> NSPoint {
                snapshot.point(for: coordinate)
            }

            // 조각마다 따로 그려서 섹션이 바뀌는 곳은 선이 끊긴다.
            // 수만 개 점을 경로 하나로 stroke 하면 겹친 윤곽을 채우느라 수십 초가 걸리므로,
            // 조각별로 나눠 그리고 화면에서 1pt 안쪽으로 붙은 점은 건너뛴다.
            NSColor.systemBlue.setStroke()
            for segment in segments where segment.count >= 2 {
                let screenPoints = simplified(segment.map(point), minimumDistance: 1)
                guard screenPoints.count >= 2 else { continue }
                let path = NSBezierPath()
                path.move(to: screenPoints[0])
                for screenPoint in screenPoints.dropFirst() {
                    path.line(to: screenPoint)
                }
                path.lineWidth = 4
                path.lineJoinStyle = .round
                path.lineCapStyle = .round
                path.stroke()
            }

            for marker in markers {
                let center = point(CLLocationCoordinate2D(latitude: marker.latitude, longitude: marker.longitude))
                let radius: CGFloat = marker.kind == .cue ? 6 : 8
                let circle = NSBezierPath(ovalIn: NSRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
                color(for: marker).setFill()
                circle.fill()
                circle.lineWidth = 2
                NSColor.white.setStroke()
                circle.stroke()
            }
            return true
        }

        guard
            let tiff = composed.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// 직전에 남긴 점과 `minimumDistance`보다 가까운 점은 버린다. 끝점은 항상 남긴다.
    private static func simplified(_ points: [NSPoint], minimumDistance: CGFloat) -> [NSPoint] {
        guard var last = points.first else { return [] }
        let minimumSquared = minimumDistance * minimumDistance
        var result = [last]
        for point in points.dropFirst() {
            let dx = point.x - last.x
            let dy = point.y - last.y
            if dx * dx + dy * dy >= minimumSquared {
                result.append(point)
                last = point
            }
        }
        if let end = points.last, result.last != end {
            result.append(end)
        }
        return result
    }

    private static func color(for marker: MapSnapshotRequest.Marker) -> NSColor {
        switch marker.kind {
        case .start: return .systemGreen
        case .end: return .systemRed
        case .cue:
            switch marker.pointType {
            case "Water": return .systemBlue
            case "Food": return .systemOrange
            case "Danger", "First Aid": return .systemRed
            case "Summit": return .systemGreen
            case "Left", "Right": return .systemPurple
            default: return .systemGray
            }
        }
    }
}

let delegate = MapSnapshotServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
