import SwiftUI
import SceneKit
import StravaTCXKit

struct Route3DView: View {
    let trackPoints: [TrackPoint]
    @State private var exaggeration: Double = 1.0
    @State private var pathWidth: Double = 0.6

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if trackPoints.count < 2 {
                ContentUnavailableView("트랙포인트 없음", systemImage: "mountain.2")
            } else {
                SceneKitRouteView(trackPoints: trackPoints, exaggeration: exaggeration, pathWidth: pathWidth)
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
    let exaggeration: Double
    let pathWidth: Double

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1)
        view.scene = buildScene()
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        view.scene = buildScene()
    }

    // MARK: - Scene 구성

    private func buildScene() -> SCNScene {
        let scene = SCNScene()
        let result = RouteGeometryBuilder(points: trackPoints, exaggeration: exaggeration, halfWidth: Float(pathWidth)).build()

        // 수직 벽 (반투명, 경로 아래)
        scene.rootNode.addChildNode(SCNNode(geometry: result.wallGeometry))

        // 메인 리본 경로
        scene.rootNode.addChildNode(SCNNode(geometry: result.pathGeometry))

        // 시작/종료 마커
        scene.rootNode.addChildNode(markerNode(at: result.startPosition, color: .systemGreen))
        scene.rootNode.addChildNode(markerNode(at: result.endPosition,   color: .systemRed))

        // 바닥 그리드
        scene.rootNode.addChildNode(groundGrid(size: 140))

        // 조명: 위쪽 방향 + 부드러운 앰비언트
        scene.rootNode.addChildNode(directionalLight(direction: SCNVector3(-0.4, -1, -0.6), intensity: 800))
        scene.rootNode.addChildNode(directionalLight(direction: SCNVector3( 0.4, -0.5,  0.6), intensity: 300))
        scene.rootNode.addChildNode(ambientLight(intensity: 200))

        // 카메라
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.zFar = 1000
        cam.position = SCNVector3(0, 55, 100)
        cam.look(at: SCNVector3(0, 8, 0))
        scene.rootNode.addChildNode(cam)

        return scene
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

    private func groundGrid(size: Float) -> SCNNode {
        let plane = SCNPlane(width: CGFloat(size), height: CGFloat(size))
        let mat = SCNMaterial()
        // 격자 이미지를 코드로 생성
        mat.diffuse.contents = gridImage(size: 512, cells: 20)
        mat.isDoubleSided = true
        mat.lightingModel = .constant
        mat.transparency = 0.6
        plane.firstMaterial = mat

        let node = SCNNode(geometry: plane)
        // SCNPlane은 XY 평면 → XZ 평면으로 눕힘
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
