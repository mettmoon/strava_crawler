import AppKit
import CoreGraphics
import Foundation
import MapKit
import CourseBoyKit

@MainActor
enum CourseShareRenderer {
    static func render(
        snapshot: CourseShareSnapshot,
        options: CourseShareOptions
    ) async throws -> CourseShareRenderResult {
        guard options.isValid else { throw CourseShareError.invalidImageSize }
        if options.outputMode.includesMap, !snapshot.hasRoute {
            throw CourseShareError.noRoute
        }
        if options.outputMode.includesElevation, !snapshot.hasElevation {
            throw CourseShareError.noElevation
        }

        var mapImage: NSImage?
        var elevationImage: NSImage?

        if options.outputMode.includesMap {
            mapImage = try await CourseShareMapRenderer.render(
                snapshot: snapshot,
                options: options
            )
        }
        try Task.checkCancellation()

        if options.outputMode.includesElevation {
            elevationImage = try CourseShareElevationRenderer.render(
                snapshot: snapshot,
                size: options.effectiveElevationSize,
                darkMode: options.usesDarkElevationStyle,
                showsWaypoints: options.showsElevationWaypoints
            )
        }
        try Task.checkCancellation()

        let artifacts: [CourseShareArtifact]
        switch options.outputMode {
        case .combined:
            guard let mapImage, let elevationImage else {
                throw CourseShareError.imageEncodingFailed
            }
            let combined = try CourseShareBitmap.combined(
                top: mapImage,
                topSize: options.mapSize,
                bottom: elevationImage,
                bottomSize: options.effectiveElevationSize
            )
            artifacts = [CourseShareArtifact(kind: .combined, image: combined)]

        case .mapOnly:
            guard let mapImage else { throw CourseShareError.imageEncodingFailed }
            artifacts = [CourseShareArtifact(kind: .map, image: mapImage)]

        case .elevationOnly:
            guard let elevationImage else { throw CourseShareError.imageEncodingFailed }
            artifacts = [CourseShareArtifact(kind: .elevation, image: elevationImage)]

        case .separate:
            guard let mapImage, let elevationImage else {
                throw CourseShareError.imageEncodingFailed
            }
            artifacts = [
                CourseShareArtifact(kind: .map, image: mapImage),
                CourseShareArtifact(kind: .elevation, image: elevationImage),
            ]
        }

        let preview = artifacts.count == 1
            ? artifacts[0].image
            : try CourseShareBitmap.contactSheet(artifacts.map(\.image))
        return CourseShareRenderResult(artifacts: artifacts, previewImage: preview)
    }
}

@MainActor
private enum CourseShareBitmap {
    static func makeImage(
        size: CourseSharePixelSize,
        drawing: (_ rect: NSRect) throws -> Void
    ) throws -> NSImage {
        guard size.isValid,
              let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: size.width,
                pixelsHigh: size.height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [.alphaFirst],
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let graphicsContext = NSGraphicsContext(bitmapImageRep: representation)
        else {
            throw CourseShareError.imageEncodingFailed
        }

        representation.size = NSSize(width: size.width, height: size.height)
        let rect = NSRect(x: 0, y: 0, width: size.width, height: size.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.shouldAntialias = true
        do {
            try drawing(rect)
            graphicsContext.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        } catch {
            NSGraphicsContext.restoreGraphicsState()
            throw error
        }

        let image = NSImage(size: rect.size)
        image.addRepresentation(representation)
        return image
    }

    static func combined(
        top: NSImage,
        topSize: CourseSharePixelSize,
        bottom: NSImage,
        bottomSize: CourseSharePixelSize
    ) throws -> NSImage {
        let outputSize = CourseSharePixelSize(
            width: topSize.width,
            height: topSize.height + bottomSize.height
        )
        return try makeImage(size: outputSize) { rect in
            NSColor.white.setFill()
            rect.fill()
            bottom.draw(
                in: NSRect(x: 0, y: 0, width: outputSize.width, height: bottomSize.height),
                from: .zero,
                operation: .copy,
                fraction: 1
            )
            top.draw(
                in: NSRect(
                    x: 0,
                    y: bottomSize.height,
                    width: outputSize.width,
                    height: topSize.height
                ),
                from: .zero,
                operation: .copy,
                fraction: 1
            )
            NSColor.black.withAlphaComponent(0.18).setFill()
            NSRect(x: 0, y: bottomSize.height - 1, width: outputSize.width, height: 2).fill()
        }
    }

    static func contactSheet(_ images: [NSImage]) throws -> NSImage {
        let gap = 24
        let padding = 24
        let maximumContentWidth: CGFloat = 1_200
        let scaledSizes = images.map { image -> CGSize in
            let scale = min(
                1,
                maximumContentWidth / max(1, max(image.size.width, image.size.height))
            )
            return CGSize(
                width: image.size.width * scale,
                height: image.size.height * scale
            )
        }
        let width = Int(scaledSizes.map(\.width).max() ?? 800) + padding * 2
        let contentHeight = Int(scaledSizes.reduce(0) { $0 + $1.height })
        let height = contentHeight + max(0, images.count - 1) * gap + padding * 2
        let safeSize = CourseSharePixelSize(width: width, height: height)
        return try makeImage(size: safeSize) { rect in
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
            var y = CGFloat(padding)
            for (image, scaledSize) in zip(images, scaledSizes).reversed() {
                let x = (rect.width - scaledSize.width) / 2
                image.draw(
                    in: NSRect(origin: CGPoint(x: x, y: y), size: scaledSize),
                    from: .zero,
                    operation: .copy,
                    fraction: 1
                )
                y += scaledSize.height + CGFloat(gap)
            }
        }
    }

    static func pngData(for image: NSImage) throws -> Data {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            throw CourseShareError.imageEncodingFailed
        }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CourseShareError.imageEncodingFailed
        }
        return data
    }
}

private struct CourseShareMapViewport {
    let mapRect: MKMapRect

    init(sectionTrackPoints: [[TrackPoint]], size: CourseSharePixelSize) throws {
        let points = sectionTrackPoints.flatMap { $0 }
        guard !points.isEmpty else { throw CourseShareError.noRoute }

        let mapPoints = points.map {
            MKMapPoint(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon))
        }
        var minX = mapPoints.map(\.x).min() ?? 0
        var maxX = mapPoints.map(\.x).max() ?? 0
        var minY = mapPoints.map(\.y).min() ?? 0
        var maxY = mapPoints.map(\.y).max() ?? 0

        let averageLatitude = points.reduce(0) { $0 + $1.lat } / Double(points.count)
        let minimumSpan = max(1, MKMapPointsPerMeterAtLatitude(averageLatitude) * 1_000)
        if maxX - minX < minimumSpan {
            let delta = (minimumSpan - (maxX - minX)) / 2
            minX -= delta
            maxX += delta
        }
        if maxY - minY < minimumSpan {
            let delta = (minimumSpan - (maxY - minY)) / 2
            minY -= delta
            maxY += delta
        }

        let horizontalPadding = (maxX - minX) * 0.12
        let verticalPadding = (maxY - minY) * 0.12
        minX -= horizontalPadding
        maxX += horizontalPadding
        minY -= verticalPadding
        maxY += verticalPadding

        let imageAspect = Double(size.width) / Double(size.height)
        let currentWidth = maxX - minX
        let currentHeight = maxY - minY
        let currentAspect = currentWidth / currentHeight
        if currentAspect < imageAspect {
            let desiredWidth = currentHeight * imageAspect
            let delta = (desiredWidth - currentWidth) / 2
            minX -= delta
            maxX += delta
        } else {
            let desiredHeight = currentWidth / imageAspect
            let delta = (desiredHeight - currentHeight) / 2
            minY -= delta
            maxY += delta
        }

        mapRect = MKMapRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    func point(for coordinate: CLLocationCoordinate2D, size: CourseSharePixelSize) -> CGPoint {
        let mapPoint = MKMapPoint(coordinate)
        let x = (mapPoint.x - mapRect.minX) / mapRect.width * Double(size.width)
        let topY = (mapPoint.y - mapRect.minY) / mapRect.height * Double(size.height)
        return CGPoint(x: x, y: Double(size.height) - topY)
    }
}

@MainActor
private enum CourseShareMapRenderer {
    static func render(
        snapshot: CourseShareSnapshot,
        options: CourseShareOptions
    ) async throws -> NSImage {
        let viewport = try CourseShareMapViewport(
            sectionTrackPoints: snapshot.sectionTrackPoints,
            size: options.mapSize
        )

        let baseImage: NSImage
        switch options.mapBackground {
        case .appleLight:
            baseImage = try await appleMapImage(
                viewport: viewport,
                size: options.mapSize,
                appearance: NSAppearance(named: .aqua)
            )
        case .appleDark:
            baseImage = try await appleMapImage(
                viewport: viewport,
                size: options.mapSize,
                appearance: NSAppearance(named: .darkAqua)
            )
        case .openStreetMap:
            baseImage = try await OSMCourseShareMapRenderer.render(
                viewport: viewport,
                size: options.mapSize
            )
        case .solid:
            baseImage = try CourseShareBitmap.makeImage(size: options.mapSize) { rect in
                options.solidBackgroundColor.nsColor.setFill()
                rect.fill()
            }
        }

        return try CourseShareBitmap.makeImage(size: options.mapSize) { rect in
            baseImage.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            drawRoute(
                sectionTrackPoints: snapshot.sectionTrackPoints,
                viewport: viewport,
                size: options.mapSize,
                lineWidth: CGFloat(options.routeLineWidth)
            )
            drawMarkers(
                snapshot: snapshot,
                viewport: viewport,
                size: options.mapSize,
                showsEndpoints: options.showsMapEndpoints,
                showsWaypoints: options.showsMapWaypoints
            )
        }
    }

    private static func appleMapImage(
        viewport: CourseShareMapViewport,
        size: CourseSharePixelSize,
        appearance: NSAppearance?
    ) async throws -> NSImage {
        let options = MKMapSnapshotter.Options()
        options.mapRect = viewport.mapRect
        options.size = CGSize(width: size.width, height: size.height)
        options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        options.appearance = appearance

        let snapshotter = MKMapSnapshotter(options: options)
        return try await withCheckedThrowingContinuation { continuation in
            snapshotter.start { snapshot, error in
                if let image = snapshot?.image {
                    continuation.resume(returning: image)
                } else {
                    _ = error
                    continuation.resume(throwing: CourseShareError.mapSnapshotFailed)
                }
            }
        }
    }

    private static func drawRoute(
        sectionTrackPoints: [[TrackPoint]],
        viewport: CourseShareMapViewport,
        size: CourseSharePixelSize,
        lineWidth: CGFloat
    ) {
        let paths = sectionTrackPoints.compactMap { points -> NSBezierPath? in
            guard points.count >= 2 else { return nil }
            let path = NSBezierPath()
            let first = points[0]
            path.move(to: viewport.point(
                for: CLLocationCoordinate2D(latitude: first.lat, longitude: first.lon),
                size: size
            ))
            for point in points.dropFirst() {
                path.line(to: viewport.point(
                    for: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon),
                    size: size
                ))
            }
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            return path
        }

        NSColor.black.withAlphaComponent(0.42).setStroke()
        for path in paths {
            path.lineWidth = lineWidth + 3
            path.stroke()
        }
        NSColor.systemOrange.setStroke()
        for path in paths {
            path.lineWidth = lineWidth
            path.stroke()
        }
    }

    private static func drawMarkers(
        snapshot: CourseShareSnapshot,
        viewport: CourseShareMapViewport,
        size: CourseSharePixelSize,
        showsEndpoints: Bool,
        showsWaypoints: Bool
    ) {
        guard let first = snapshot.sectionTrackPoints.first?.first,
              let last = snapshot.sectionTrackPoints.last?.last
        else { return }

        if showsEndpoints {
            let markerRadius = max(8, min(15, CGFloat(size.width) / 80))
            drawEndpoint(
                text: "S",
                color: .systemGreen,
                center: viewport.point(
                    for: CLLocationCoordinate2D(latitude: first.lat, longitude: first.lon),
                    size: size
                ),
                radius: markerRadius
            )
            drawEndpoint(
                text: "E",
                color: .systemRed,
                center: viewport.point(
                    for: CLLocationCoordinate2D(latitude: last.lat, longitude: last.lon),
                    size: size
                ),
                radius: markerRadius
            )
        }

        guard showsWaypoints else { return }
        for cue in snapshot.cuePoints {
            let center = viewport.point(
                for: CLLocationCoordinate2D(latitude: cue.lat, longitude: cue.lon),
                size: size
            )
            drawWaypoint(cue: cue, center: center, imageSize: size)
        }
    }

    private static func drawEndpoint(
        text: String,
        color: NSColor,
        center: CGPoint,
        radius: CGFloat
    ) {
        let rect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: -2, dy: -2)).fill()
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        ring.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: radius, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(
                x: center.x - textSize.width / 2,
                y: center.y - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }

    private static func drawWaypoint(
        cue: CourseCuePoint,
        center: CGPoint,
        imageSize: CourseSharePixelSize
    ) {
        let radius = max(5, min(9, CGFloat(imageSize.width) / 130))
        let dotRect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(ovalIn: dotRect.insetBy(dx: -2, dy: -2)).fill()
        NSColor.systemCyan.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        let rawLabel = cue.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = rawLabel.isEmpty ? cuePointLabel(for: cue.pointType) : rawLabel
        guard !label.isEmpty else { return }
        let fontSize = max(10, min(16, CGFloat(imageSize.width) / 90))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let padding = CGSize(width: 8, height: 4)
        var labelRect = NSRect(
            x: center.x + radius + 5,
            y: center.y - textSize.height / 2 - padding.height / 2,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height
        )
        labelRect.origin.x = min(
            max(4, labelRect.origin.x),
            CGFloat(imageSize.width) - labelRect.width - 4
        )
        labelRect.origin.y = min(
            max(4, labelRect.origin.y),
            CGFloat(imageSize.height) - labelRect.height - 4
        )

        NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
        NSColor.separatorColor.withAlphaComponent(0.8).setStroke()
        let border = NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5)
        border.lineWidth = 1
        border.stroke()
        (label as NSString).draw(
            at: CGPoint(
                x: labelRect.minX + padding.width,
                y: labelRect.minY + padding.height / 2
            ),
            withAttributes: attributes
        )
    }
}

private struct OSMTileCoordinate: Hashable, Sendable {
    let z: Int
    let x: Int
    let y: Int
}

private struct OSMTileData: Sendable {
    let coordinate: OSMTileCoordinate
    let data: Data
}

@MainActor
private enum OSMCourseShareMapRenderer {
    private static let tileSize = 256.0
    private static let maximumTileCount = 80

    static func render(
        viewport: CourseShareMapViewport,
        size: CourseSharePixelSize
    ) async throws -> NSImage {
        let coordinates = tileCoordinates(for: viewport.mapRect, outputSize: size)
        var loadedTiles: [OSMTileData] = []
        loadedTiles.reserveCapacity(coordinates.count)

        for start in stride(from: 0, to: coordinates.count, by: 6) {
            try Task.checkCancellation()
            let end = min(start + 6, coordinates.count)
            let batch = Array(coordinates[start ..< end])
            let results = try await withThrowingTaskGroup(
                of: OSMTileData.self,
                returning: [OSMTileData].self
            ) { group in
                for coordinate in batch {
                    group.addTask {
                        try await downloadTile(coordinate)
                    }
                }
                var values: [OSMTileData] = []
                for try await value in group {
                    values.append(value)
                }
                return values
            }
            loadedTiles.append(contentsOf: results)
        }

        return try CourseShareBitmap.makeImage(size: size) { rect in
            NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
            rect.fill()

            let worldWidth = MKMapSize.world.width
            for tile in loadedTiles {
                guard let image = NSImage(data: tile.data) else {
                    throw CourseShareError.tileDownloadFailed
                }
                let count = pow(2.0, Double(tile.coordinate.z))
                let mapTileSize = worldWidth / count
                let tileMapRect = MKMapRect(
                    x: Double(tile.coordinate.x) * mapTileSize,
                    y: Double(tile.coordinate.y) * mapTileSize,
                    width: mapTileSize,
                    height: mapTileSize
                )
                let destinationWidth = tileMapRect.width / viewport.mapRect.width * rect.width
                let destinationHeight = tileMapRect.height / viewport.mapRect.height * rect.height
                let destinationX = (tileMapRect.minX - viewport.mapRect.minX)
                    / viewport.mapRect.width * rect.width
                let topY = (tileMapRect.minY - viewport.mapRect.minY)
                    / viewport.mapRect.height * rect.height
                let destinationY = rect.height - topY - destinationHeight
                image.draw(
                    in: NSRect(
                        x: destinationX,
                        y: destinationY,
                        width: destinationWidth,
                        height: destinationHeight
                    ),
                    from: .zero,
                    operation: .copy,
                    fraction: 1
                )
            }
            drawAttribution(in: rect)
        }
    }

    nonisolated private static func downloadTile(
        _ coordinate: OSMTileCoordinate
    ) async throws -> OSMTileData {
        guard let url = URL(
            string: "https://tile.openstreetmap.org/\(coordinate.z)/\(coordinate.x)/\(coordinate.y).png"
        ) else {
            throw CourseShareError.tileDownloadFailed
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: 20
        )
        request.setValue(
            "CourseBoy/0.1 (macOS; OpenStreetMap image export)",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              !data.isEmpty
        else {
            throw CourseShareError.tileDownloadFailed
        }
        return OSMTileData(coordinate: coordinate, data: data)
    }

    private static func tileCoordinates(
        for mapRect: MKMapRect,
        outputSize: CourseSharePixelSize
    ) -> [OSMTileCoordinate] {
        let worldWidth = MKMapSize.world.width
        let pixelScale = max(
            Double(outputSize.width) / mapRect.width,
            Double(outputSize.height) / mapRect.height
        )
        var zoom = min(
            18,
            max(0, Int(floor(log2(pixelScale * worldWidth / tileSize))))
        )

        func range(at zoom: Int) -> (ClosedRange<Int>, ClosedRange<Int>) {
            let count = Int(pow(2.0, Double(zoom)))
            let mapTileSize = worldWidth / Double(count)
            let minimumX = max(0, min(count - 1, Int(floor(mapRect.minX / mapTileSize))))
            let maximumX = max(0, min(count - 1, Int(floor((mapRect.maxX - 1) / mapTileSize))))
            let minimumY = max(0, min(count - 1, Int(floor(mapRect.minY / mapTileSize))))
            let maximumY = max(0, min(count - 1, Int(floor((mapRect.maxY - 1) / mapTileSize))))
            return (minimumX ... maximumX, minimumY ... maximumY)
        }

        var ranges = range(at: zoom)
        while ranges.0.count * ranges.1.count > maximumTileCount, zoom > 0 {
            zoom -= 1
            ranges = range(at: zoom)
        }

        return ranges.1.flatMap { y in
            ranges.0.map { x in OSMTileCoordinate(z: zoom, x: x, y: y) }
        }
    }

    private static func drawAttribution(in rect: NSRect) {
        let text = "© OpenStreetMap contributors · openstreetmap.org/copyright"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(10, min(14, rect.width / 90))),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let box = NSRect(
            x: rect.maxX - textSize.width - 18,
            y: 8,
            width: textSize.width + 12,
            height: textSize.height + 6
        )
        NSColor.black.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(
            at: CGPoint(x: box.minX + 6, y: box.minY + 3),
            withAttributes: attributes
        )
    }
}

@MainActor
private enum CourseShareElevationRenderer {
    private struct Palette {
        let background: NSColor
        let primaryText: NSColor
        let secondaryText: NSColor
        let grid: NSColor
        let markerLabelBackground: NSColor
        let markerLabelBorder: NSColor
        let elevationFillTop: NSColor
        let elevationFillBottom: NSColor
        let elevationLine: NSColor

        static let light = Palette(
            background: NSColor(calibratedWhite: 1, alpha: 1),
            primaryText: NSColor(calibratedWhite: 0.12, alpha: 1),
            secondaryText: NSColor(calibratedWhite: 0.38, alpha: 1),
            grid: NSColor(calibratedWhite: 0.2, alpha: 0.22),
            markerLabelBackground: NSColor(calibratedWhite: 0.96, alpha: 0.98),
            markerLabelBorder: NSColor.systemCyan.withAlphaComponent(0.65),
            elevationFillTop: NSColor.systemOrange.withAlphaComponent(0.48),
            elevationFillBottom: NSColor.systemOrange.withAlphaComponent(0.08),
            elevationLine: .systemOrange
        )

        static let dark = Palette(
            background: NSColor(
                calibratedRed: 0.075,
                green: 0.085,
                blue: 0.105,
                alpha: 1
            ),
            primaryText: NSColor(calibratedWhite: 0.94, alpha: 1),
            secondaryText: NSColor(calibratedWhite: 0.72, alpha: 1),
            grid: NSColor(calibratedWhite: 1, alpha: 0.18),
            markerLabelBackground: NSColor(
                calibratedRed: 0.13,
                green: 0.15,
                blue: 0.18,
                alpha: 0.98
            ),
            markerLabelBorder: NSColor.systemCyan.withAlphaComponent(0.8),
            elevationFillTop: NSColor.systemOrange.withAlphaComponent(0.58),
            elevationFillBottom: NSColor.systemOrange.withAlphaComponent(0.12),
            elevationLine: NSColor(
                calibratedRed: 1,
                green: 0.56,
                blue: 0.18,
                alpha: 1
            )
        )
    }

    static func render(
        snapshot: CourseShareSnapshot,
        size: CourseSharePixelSize,
        darkMode: Bool,
        showsWaypoints: Bool
    ) throws -> NSImage {
        let elevations = snapshot.allTrackPoints.compactMap(\.ele)
        guard elevations.count >= 2 else { throw CourseShareError.noElevation }
        let palette = darkMode ? Palette.dark : Palette.light

        return try CourseShareBitmap.makeImage(size: size) { rect in
            palette.background.setFill()
            rect.fill()

            let leftMargin = max(52, rect.width * 0.055)
            let rightMargin = max(18, rect.width * 0.025)
            let bottomMargin = max(36, rect.height * 0.11)
            let topMargin = showsWaypoints
                ? max(70, min(94, rect.height * 0.26))
                : max(24, rect.height * 0.07)
            let plotRect = NSRect(
                x: leftMargin,
                y: bottomMargin,
                width: max(1, rect.width - leftMargin - rightMargin),
                height: max(1, rect.height - bottomMargin - topMargin)
            )

            var minimumElevation = elevations.min() ?? 0
            var maximumElevation = elevations.max() ?? 1
            if maximumElevation - minimumElevation < 20 {
                let midpoint = (minimumElevation + maximumElevation) / 2
                minimumElevation = midpoint - 10
                maximumElevation = midpoint + 10
            } else {
                let padding = (maximumElevation - minimumElevation) * 0.08
                minimumElevation -= padding
                maximumElevation += padding
            }
            let totalKm = max(
                0.001,
                snapshot.sectionTrackPoints.compactMap(\.last?.cumKm).max() ?? 0.001
            )

            drawGrid(
                plotRect: plotRect,
                totalKm: totalKm,
                minimumElevation: minimumElevation,
                maximumElevation: maximumElevation,
                palette: palette
            )
            drawElevationPaths(
                sectionTrackPoints: snapshot.sectionTrackPoints,
                plotRect: plotRect,
                totalKm: totalKm,
                minimumElevation: minimumElevation,
                maximumElevation: maximumElevation,
                palette: palette
            )
            if showsWaypoints {
                drawWaypoints(
                    snapshot: snapshot,
                    plotRect: plotRect,
                    totalKm: totalKm,
                    minimumElevation: minimumElevation,
                    maximumElevation: maximumElevation,
                    palette: palette
                )
            }
        }
    }

    private static func drawGrid(
        plotRect: NSRect,
        totalKm: Double,
        minimumElevation: Double,
        maximumElevation: Double,
        palette: Palette
    ) {
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: palette.secondaryText,
        ]

        for index in 0 ... 4 {
            let ratio = CGFloat(index) / 4
            let x = plotRect.minX + plotRect.width * ratio
            let y = plotRect.minY + plotRect.height * ratio

            palette.grid.withAlphaComponent(index == 0 ? 0.9 : 0.55).setStroke()
            let vertical = NSBezierPath()
            vertical.move(to: CGPoint(x: x, y: plotRect.minY))
            vertical.line(to: CGPoint(x: x, y: plotRect.maxY))
            vertical.lineWidth = 1
            vertical.stroke()

            let horizontal = NSBezierPath()
            horizontal.move(to: CGPoint(x: plotRect.minX, y: y))
            horizontal.line(to: CGPoint(x: plotRect.maxX, y: y))
            horizontal.lineWidth = 1
            horizontal.stroke()

            let distanceText = String(format: "%.0f km", totalKm * Double(index) / 4)
            let distanceSize = (distanceText as NSString).size(withAttributes: labelAttributes)
            (distanceText as NSString).draw(
                at: CGPoint(
                    x: x - distanceSize.width / 2,
                    y: plotRect.minY - distanceSize.height - 8
                ),
                withAttributes: labelAttributes
            )

            let elevation = minimumElevation
                + (maximumElevation - minimumElevation) * Double(index) / 4
            let elevationText = String(format: "%.0f m", elevation)
            let elevationSize = (elevationText as NSString).size(withAttributes: labelAttributes)
            (elevationText as NSString).draw(
                at: CGPoint(
                    x: plotRect.minX - elevationSize.width - 8,
                    y: y - elevationSize.height / 2
                ),
                withAttributes: labelAttributes
            )
        }
    }

    private static func drawElevationPaths(
        sectionTrackPoints: [[TrackPoint]],
        plotRect: NSRect,
        totalKm: Double,
        minimumElevation: Double,
        maximumElevation: Double,
        palette: Palette
    ) {
        func point(_ trackPoint: TrackPoint) -> CGPoint? {
            guard let elevation = trackPoint.ele else { return nil }
            let x = plotRect.minX + CGFloat(trackPoint.cumKm / totalKm) * plotRect.width
            let ratio = (elevation - minimumElevation) / (maximumElevation - minimumElevation)
            let y = plotRect.minY + CGFloat(ratio) * plotRect.height
            return CGPoint(x: x, y: y)
        }

        for section in sectionTrackPoints {
            var chunks: [[CGPoint]] = []
            var current: [CGPoint] = []
            for trackPoint in section {
                if let value = point(trackPoint) {
                    current.append(value)
                } else if !current.isEmpty {
                    chunks.append(current)
                    current = []
                }
            }
            if !current.isEmpty { chunks.append(current) }

            for chunk in chunks where chunk.count >= 2 {
                let fillPath = NSBezierPath()
                fillPath.move(to: CGPoint(x: chunk[0].x, y: plotRect.minY))
                chunk.forEach { fillPath.line(to: $0) }
                fillPath.line(to: CGPoint(x: chunk.last!.x, y: plotRect.minY))
                fillPath.close()
                let gradient = NSGradient(colors: [
                    palette.elevationFillTop,
                    palette.elevationFillBottom,
                ])
                gradient?.draw(in: fillPath, angle: -90)

                let linePath = NSBezierPath()
                linePath.move(to: chunk[0])
                chunk.dropFirst().forEach { linePath.line(to: $0) }
                linePath.lineJoinStyle = .round
                linePath.lineCapStyle = .round
                linePath.lineWidth = max(2, plotRect.width / 650)
                palette.elevationLine.setStroke()
                linePath.stroke()
            }
        }
    }

    private static func drawWaypoints(
        snapshot: CourseShareSnapshot,
        plotRect: NSRect,
        totalKm: Double,
        minimumElevation: Double,
        maximumElevation: Double,
        palette: Palette
    ) {
        let pointsWithElevation = snapshot.allTrackPoints.filter { $0.ele != nil }
        guard !pointsWithElevation.isEmpty else { return }
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: palette.primaryText,
        ]
        var rowRightEdges = Array(repeating: -CGFloat.greatestFiniteMagnitude, count: 4)

        for cue in snapshot.cuePoints.sorted(by: { $0.distanceMeters < $1.distanceMeters }) {
            let cueKm = min(max(cue.distanceMeters / 1_000, 0), totalKm)
            guard let nearest = pointsWithElevation.min(by: {
                abs($0.cumKm - cueKm) < abs($1.cumKm - cueKm)
            }), let elevation = nearest.ele else { continue }

            let x = plotRect.minX + CGFloat(cueKm / totalKm) * plotRect.width
            let ratio = (elevation - minimumElevation) / (maximumElevation - minimumElevation)
            let y = plotRect.minY + CGFloat(ratio) * plotRect.height

            NSColor.systemCyan.withAlphaComponent(0.55).setStroke()
            let guide = NSBezierPath()
            guide.move(to: CGPoint(x: x, y: plotRect.minY))
            guide.line(to: CGPoint(x: x, y: plotRect.maxY))
            guide.lineWidth = 1
            guide.stroke()

            NSColor.systemCyan.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 4, y: y - 4, width: 8, height: 8)).fill()

            let trimmedName = cue.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = trimmedName.isEmpty ? cuePointLabel(for: cue.pointType) : trimmedName
            let textSize = (label as NSString).size(withAttributes: labelAttributes)
            let boxWidth = textSize.width + 12
            let proposedLeft = min(
                max(plotRect.minX, x - boxWidth / 2),
                plotRect.maxX - boxWidth
            )
            guard let row = rowRightEdges.indices.first(where: {
                rowRightEdges[$0] + 6 <= proposedLeft
            }) else { continue }
            rowRightEdges[row] = proposedLeft + boxWidth

            let box = NSRect(
                x: proposedLeft,
                y: plotRect.maxY + 7 + CGFloat(row) * 18,
                width: boxWidth,
                height: 16
            )
            palette.markerLabelBackground.setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            palette.markerLabelBorder.setStroke()
            let border = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            border.lineWidth = 1
            border.stroke()
            (label as NSString).draw(
                at: CGPoint(
                    x: box.minX + 6,
                    y: box.midY - textSize.height / 2
                ),
                withAttributes: labelAttributes
            )
        }
    }
}

@MainActor
enum CourseShareImageEncoding {
    static func pngData(for image: NSImage) throws -> Data {
        try CourseShareBitmap.pngData(for: image)
    }
}
