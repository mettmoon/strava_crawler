import SceneKit
import simd
import StravaTCXKit

/// TrackPoint 배열을 받아 SceneKit 렌더링용 지오메트리를 생성한다.
///
/// Metal에서 .line 프리미티브는 항상 1px이라 보이지 않으므로,
/// 경로를 일정 폭의 리본 메시(triangleStrip)로 만든다.
struct RouteGeometryBuilder {
    let points: [TrackPoint]
    let exaggeration: Double

    let halfWidth: Float
    private static let maxPoints = 3_000

    func build() -> RouteScene {
        let sampled = downsample(points)
        guard sampled.count >= 2 else { return .empty }

        let params = makeNormParams(sampled)
        let (centerVerts, colors) = normalize(sampled, params: params)

        return RouteScene(
            pathGeometry: makeRibbonGeometry(centers: centerVerts, colors: colors),
            wallGeometry: makeWallGeometry(centers: centerVerts, colors: colors),
            startPosition: scn(centerVerts.first!),
            endPosition: scn(centerVerts.last!),
            normParams: params
        )
    }

    // MARK: - NormParams

    struct NormParams {
        let centerLat: Double
        let centerLon: Double
        let eleMin: Double
        let mPerDegLat: Double
        let mPerDegLon: Double
        let hScale: Double
        let eleScale: Double
    }

    struct RouteScene {
        let pathGeometry: SCNGeometry
        let wallGeometry: SCNGeometry
        let startPosition: SCNVector3
        let endPosition: SCNVector3
        let normParams: NormParams

        static let empty = RouteScene(
            pathGeometry: SCNGeometry(),
            wallGeometry: SCNGeometry(),
            startPosition: .init(),
            endPosition: .init(),
            normParams: NormParams(centerLat: 0, centerLon: 0, eleMin: 0,
                                   mPerDegLat: 111_320, mPerDegLon: 111_320,
                                   hScale: 1, eleScale: 1)
        )
    }

    // MARK: - 좌표 정규화

    private func makeNormParams(_ pts: [TrackPoint]) -> NormParams {
        let lats = pts.map(\.lat)
        let lons = pts.map(\.lon)
        let eles = pts.compactMap(\.ele)

        let centerLat = (lats.min()! + lats.max()!) / 2
        let centerLon = (lons.min()! + lons.max()!) / 2
        let eleMin    = eles.isEmpty ? 0.0 : eles.min()!
        let eleMax    = eles.isEmpty ? 1.0 : eles.max()!
        let eleRange  = max(eleMax - eleMin, 1.0)

        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(centerLat * .pi / 180)

        let xSpan  = (lons.max()! - lons.min()!) * mPerDegLon
        let zSpan  = (lats.max()! - lats.min()!) * mPerDegLat
        let hSpan  = max(xSpan, zSpan, 1.0)
        let hScale = 100.0 / hSpan
        let eleScale = (hSpan * hScale * 0.05) / eleRange * exaggeration

        return NormParams(centerLat: centerLat, centerLon: centerLon, eleMin: eleMin,
                          mPerDegLat: mPerDegLat, mPerDegLon: mPerDegLon,
                          hScale: hScale, eleScale: eleScale)
    }

    private func normalize(_ pts: [TrackPoint], params p: NormParams) -> ([simd_float3], [simd_float4]) {
        var verts: [simd_float3] = []
        for pt in pts {
            let x = Float((pt.lon - p.centerLon) * p.mPerDegLon * p.hScale)
            let z = Float(-(pt.lat - p.centerLat) * p.mPerDegLat * p.hScale)
            let y = Float(((pt.ele ?? p.eleMin) - p.eleMin) * p.eleScale)
            verts.append(simd_float3(x, y, z))
        }

        var colors: [simd_float4] = []
        for i in 0 ..< pts.count {
            let grade: Double
            if i + 1 < pts.count {
                let ele0 = pts[i].ele ?? p.eleMin
                let ele1 = pts[i+1].ele ?? p.eleMin
                let dEle = ele1 - ele0

                let dLat = pts[i+1].lat - pts[i].lat
                let dLon = pts[i+1].lon - pts[i].lon
                let dxM  = dLon * p.mPerDegLon
                let dzM  = dLat * p.mPerDegLat
                let horizM = sqrt(dxM*dxM + dzM*dzM)

                grade = horizM > 0 ? (dEle / horizM) * 100 : 0
            } else {
                grade = 0
            }
            colors.append(gradeColor(grade))
        }
        return (verts, colors)
    }

    // MARK: - 색상

    private func gradeColor(_ grade: Double) -> simd_float4 {
        switch grade {
        case ..<(-3):    return simd_float4(0.00, 0.20, 0.80, 1)
        case -3..<0:     return simd_float4(0.25, 0.55, 1.00, 1)
        case 0..<3:      return simd_float4(0.20, 0.80, 0.30, 1)
        case 3..<6:      return simd_float4(1.00, 0.88, 0.10, 1)
        case 6..<9:      return simd_float4(1.00, 0.50, 0.05, 1)
        case 9..<12:     return simd_float4(0.90, 0.10, 0.10, 1)
        case 12..<15:    return simd_float4(0.65, 0.05, 0.05, 1)
        default:         return simd_float4(0.45, 0.00, 0.50, 1)
        }
    }

    // MARK: - 리본 메시 (경로 상단 수평 띠)

    private func makeRibbonGeometry(centers: [simd_float3], colors: [simd_float4]) -> SCNGeometry {
        var verts:  [simd_float3] = []
        var vcols:  [simd_float4] = []
        var normals:[simd_float3] = []

        let hw = halfWidth

        for i in 0 ..< centers.count {
            let dir = tangent(at: i, centers: centers)
            let perp = simd_normalize(simd_float3(-dir.z, 0, dir.x))
            let left  = centers[i] + perp *  hw
            let right = centers[i] - perp *  hw

            verts.append(left)
            verts.append(right)
            vcols.append(colors[i])
            vcols.append(colors[i])
            let up = simd_float3(0, 1, 0)
            normals.append(up); normals.append(up)
        }

        let n = verts.count
        let vertexSrc = floatSource(verts, semantic: .vertex,    components: 3, stride: MemoryLayout<simd_float3>.size)
        let normalSrc = floatSource(normals, semantic: .normal,  components: 3, stride: MemoryLayout<simd_float3>.size)
        let colorSrc  = floatSource(vcols, semantic: .color,     components: 4, stride: MemoryLayout<simd_float4>.size)

        let indices = (0 ..< Int32(n)).map { $0 }
        let element = SCNGeometryElement(
            data: indices.withUnsafeBytes { Data($0) },
            primitiveType: .triangleStrip,
            primitiveCount: n - 2,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geo = SCNGeometry(sources: [vertexSrc, normalSrc, colorSrc], elements: [element])
        let mat = SCNMaterial()
        mat.lightingModel = .lambert
        mat.isDoubleSided = true
        geo.firstMaterial = mat
        return geo
    }

    // MARK: - 수직 벽 (경로 아래 반투명)

    private func makeWallGeometry(centers: [simd_float3], colors: [simd_float4]) -> SCNGeometry {
        var verts: [simd_float3] = []
        var vcols: [simd_float4] = []

        for i in 0 ..< centers.count {
            verts.append(centers[i])
            verts.append(simd_float3(centers[i].x, 0, centers[i].z))
            let c = colors[i]
            vcols.append(simd_float4(c.x, c.y, c.z, 0.5))
            vcols.append(simd_float4(c.x, c.y, c.z, 0.0))
        }

        let n = verts.count
        let vertexSrc = floatSource(verts, semantic: .vertex, components: 3, stride: MemoryLayout<simd_float3>.size)
        let colorSrc  = floatSource(vcols, semantic: .color,  components: 4, stride: MemoryLayout<simd_float4>.size)

        let indices = (0 ..< Int32(n)).map { $0 }
        let element = SCNGeometryElement(
            data: indices.withUnsafeBytes { Data($0) },
            primitiveType: .triangleStrip,
            primitiveCount: n - 2,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geo = SCNGeometry(sources: [vertexSrc, colorSrc], elements: [element])
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.transparency = 0.5
        mat.blendMode = .alpha
        geo.firstMaterial = mat
        return geo
    }

    // MARK: - 헬퍼

    private func tangent(at i: Int, centers: [simd_float3]) -> simd_float3 {
        if i == 0 {
            return simd_normalize(centers[1] - centers[0])
        } else if i == centers.count - 1 {
            return simd_normalize(centers[i] - centers[i-1])
        } else {
            return simd_normalize(centers[i+1] - centers[i-1])
        }
    }

    private func floatSource(_ data: [simd_float3], semantic: SCNGeometrySource.Semantic,
                              components: Int, stride: Int) -> SCNGeometrySource {
        SCNGeometrySource(
            data: data.withUnsafeBytes { Data($0) },
            semantic: semantic, vectorCount: data.count,
            usesFloatComponents: true, componentsPerVector: components,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride
        )
    }

    private func floatSource(_ data: [simd_float4], semantic: SCNGeometrySource.Semantic,
                              components: Int, stride: Int) -> SCNGeometrySource {
        SCNGeometrySource(
            data: data.withUnsafeBytes { Data($0) },
            semantic: semantic, vectorCount: data.count,
            usesFloatComponents: true, componentsPerVector: components,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride
        )
    }

    private func scn(_ v: simd_float3) -> SCNVector3 { SCNVector3(v.x, v.y, v.z) }

    // MARK: - 다운샘플링

    private func downsample(_ pts: [TrackPoint]) -> [TrackPoint] {
        guard pts.count > Self.maxPoints else { return pts }
        let step = pts.count / Self.maxPoints
        var result: [TrackPoint] = []
        for i in stride(from: 0, to: pts.count, by: step) { result.append(pts[i]) }
        if result.last?.cumKm != pts.last?.cumKm { result.append(pts.last!) }
        return result
    }
}
