import SwiftUI
import SceneKit
import StravaTCXKit

struct Route3DView: View {
    let trackPoints: [TrackPoint]
    var highlightPoints: [TrackPoint] = []
    @State private var exaggeration: Double = 1.0
    @State private var pathWidth: Double = 0.6

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if trackPoints.count < 2 {
                ContentUnavailableView("트랙포인트 없음", systemImage: "mountain.2")
            } else {
                SceneKitRouteView(
                    trackPoints: trackPoints,
                    highlightPoints: highlightPoints,
                    exaggeration: exaggeration,
                    pathWidth: pathWidth
                )
                .ignoresSafeArea()
                overlayControls
            }
        }
    }

    private var overlayControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("고도 ×\(exaggeration, specifier: "%.1f")", systemImage: "mountain.2")
                .font(.caption.bold())
            Slider(value: $exaggeration, in: 1...10, step: 0.5)
                .frame(width: 180)
            Label("경로 폭 \(pathWidth, specifier: "%.1f")", systemImage: "road.lanes")
                .font(.caption.bold())
            Slider(value: $pathWidth, in: 0.1...5.0, step: 0.1)
                .frame(width: 180)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(16)
    }
}

// MARK: - NSViewRepresentable

struct SceneKitRouteView: NSViewRepresentable {
    let trackPoints: [TrackPoint]
    var highlightPoints: [TrackPoint] = []
    let exaggeration: Double
    let pathWidth: Double

    // MARK: Coordinator — 씬과 정규화 파라미터를 캐시

    final class Coordinator {
        // TrackPoint는 Equatable 미준수 → cumKm 배열로 동일성 판단
        var builtPointSignature: [Double] = []
        var builtExaggeration: Double = 0
        var builtHalfWidth: Float = 0

        var cachedScene: RouteGeometryBuilder.RouteScene?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1)
        rebuildScene(view: view, context: context)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        let signature = trackPoints.map(\.cumKm)
        let needsRebuild = coordinator.builtPointSignature != signature
            || coordinator.builtExaggeration != exaggeration
            || coordinator.builtHalfWidth != Float(pathWidth)

        if needsRebuild {
            rebuildScene(view: view, context: context)
        } else {
            updateHighlightPins(in: view, scene: coordinator.cachedScene)
        }
    }

    // MARK: - 씬 전체 재구성 (trackPoints / exaggeration / pathWidth 변경 시에만)

    private func rebuildScene(view: SCNView, context: Context) {
        let coordinator = context.coordinator
        let builder = RouteGeometryBuilder(points: trackPoints,
                                           exaggeration: exaggeration,
                                           halfWidth: Float(pathWidth))
        let result = builder.build()
        coordinator.cachedScene = result
        coordinator.builtPointSignature = trackPoints.map(\.cumKm)
        coordinator.builtExaggeration = exaggeration
        coordinator.builtHalfWidth = Float(pathWidth)

        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: result.wallGeometry))
        scene.rootNode.addChildNode(SCNNode(geometry: result.pathGeometry))

        // 시작/종료 마커 (하이라이트 없을 때 기본)
        scene.rootNode.addChildNode(markerNode(at: result.startPosition, color: .systemGreen))
        scene.rootNode.addChildNode(markerNode(at: result.endPosition,   color: .systemRed))

        scene.rootNode.addChildNode(groundGrid(size: 140))
        scene.rootNode.addChildNode(directionalLight(direction: SCNVector3(-0.4, -1, -0.6), intensity: 800))
        scene.rootNode.addChildNode(directionalLight(direction: SCNVector3( 0.4, -0.5,  0.6), intensity: 300))
        scene.rootNode.addChildNode(ambientLight(intensity: 200))

        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.zFar = 1000
        cam.position = SCNVector3(0, 55, 100)
        cam.look(at: SCNVector3(0, 8, 0))
        scene.rootNode.addChildNode(cam)

        view.scene = scene
        updateHighlightPins(in: view, scene: result)
    }

    // MARK: - 하이라이트 핀만 교체

    private func updateHighlightPins(in view: SCNView, scene: RouteGeometryBuilder.RouteScene?) {
        guard let root = view.scene?.rootNode else { return }

        // 기존 핀 제거
        for name in ["highlight-start", "highlight-end"] {
            root.childNode(withName: name, recursively: false)?.removeFromParentNode()
        }

        guard highlightPoints.count >= 2, let scene else { return }

        let startPos = position(for: highlightPoints.first!, normParams: scene.normParams)
        let endPos   = position(for: highlightPoints.last!,  normParams: scene.normParams)

        let startPin = pinNode(at: startPos, color: .systemGreen)
        startPin.name = "highlight-start"
        let endPin = pinNode(at: endPos, color: .systemRed)
        endPin.name = "highlight-end"

        root.addChildNode(startPin)
        root.addChildNode(endPin)
    }

    /// 캐시된 정규화 파라미터로 TrackPoint의 3D 위치를 계산한다.
    private func position(for point: TrackPoint,
                          normParams p: RouteGeometryBuilder.NormParams) -> SCNVector3 {
        let x = Float((point.lon - p.centerLon) * p.mPerDegLon * p.hScale)
        let z = Float(-(point.lat - p.centerLat) * p.mPerDegLat * p.hScale)
        let y = Float(((point.ele ?? p.eleMin) - p.eleMin) * p.eleScale)
        return SCNVector3(x, y, z)
    }

    // MARK: - 헬퍼 노드

    private func markerNode(at position: SCNVector3, color: NSColor) -> SCNNode {
        let sphere = SCNSphere(radius: 1.2)
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.lightingModel = .blinn
        mat.specular.contents = NSColor.white
        sphere.firstMaterial = mat
        let node = SCNNode(geometry: sphere)
        node.position = position
        return node
    }

    private func pinNode(at position: SCNVector3, color: NSColor) -> SCNNode {
        let pinHeight: Float = 6.0
        let headRadius: Float = 1.4

        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.lightingModel = .blinn
        mat.specular.contents = NSColor.white

        let stick = SCNCylinder(radius: 0.25, height: CGFloat(pinHeight))
        stick.firstMaterial = mat
        let stickNode = SCNNode(geometry: stick)
        stickNode.position = SCNVector3(0, pinHeight / 2, 0)

        let head = SCNSphere(radius: CGFloat(headRadius))
        head.firstMaterial = mat
        let headNode = SCNNode(geometry: head)
        headNode.position = SCNVector3(0, pinHeight + headRadius, 0)

        let root = SCNNode()
        root.addChildNode(stickNode)
        root.addChildNode(headNode)
        root.position = SCNVector3(position.x, position.y + 0.5, position.z)
        return root
    }

    private func groundGrid(size: Float) -> SCNNode {
        let plane = SCNPlane(width: CGFloat(size), height: CGFloat(size))
        let mat = SCNMaterial()
        mat.diffuse.contents = gridImage(size: 512, cells: 20)
        mat.isDoubleSided = true
        mat.lightingModel = .constant
        mat.transparency = 0.6
        plane.firstMaterial = mat

        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        node.position = SCNVector3(0, -0.05, 0)
        return node
    }

    private func gridImage(size: Int, cells: Int) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        NSColor(white: 0.25, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()

        NSColor(white: 0.45, alpha: 1).setStroke()
        let cellSize = CGFloat(size) / CGFloat(cells)
        let path = NSBezierPath()
        path.lineWidth = 0.8
        for i in 0...cells {
            let pos = CGFloat(i) * cellSize
            path.move(to: CGPoint(x: pos, y: 0))
            path.line(to: CGPoint(x: pos, y: CGFloat(size)))
            path.move(to: CGPoint(x: 0,   y: pos))
            path.line(to: CGPoint(x: CGFloat(size), y: pos))
        }
        path.stroke()
        img.unlockFocus()
        return img
    }

    private func directionalLight(direction: SCNVector3, intensity: CGFloat) -> SCNNode {
        let light = SCNLight()
        light.type = .directional
        light.intensity = intensity
        light.color = NSColor.white
        let node = SCNNode()
        node.light = light
        node.look(at: direction)
        return node
    }

    private func ambientLight(intensity: CGFloat) -> SCNNode {
        let light = SCNLight()
        light.type = .ambient
        light.intensity = intensity
        light.color = NSColor(calibratedRed: 0.7, green: 0.8, blue: 1.0, alpha: 1)
        let node = SCNNode()
        node.light = light
        return node
    }
}
