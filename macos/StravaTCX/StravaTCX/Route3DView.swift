import SwiftUI
import SceneKit
import StravaTCXKit

enum CameraPreset: String, CaseIterable, Identifiable {
    case isometric = "기본"
    case top = "상단"
    case side = "측면"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .isometric: return "view.3d"
        case .top:       return "square.grid.2x2"
        case .side:      return "rectangle"
        }
    }
}

struct Route3DView: View {
    let trackPoints: [TrackPoint]
    var highlightPoints: [TrackPoint] = []
    @State private var exaggeration: Double = 1.0
    @State private var pathWidth: Double = 0.6
    @State private var cameraPreset: CameraPreset = .isometric
    @State private var resetToken: UUID = UUID()
    @State private var showHelp: Bool = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if trackPoints.count < 2 {
                ContentUnavailableView("트랙포인트 없음", systemImage: "mountain.2")
            } else {
                SceneKitRouteView(
                    trackPoints: trackPoints,
                    highlightPoints: highlightPoints,
                    exaggeration: exaggeration,
                    pathWidth: pathWidth,
                    cameraPreset: cameraPreset,
                    resetToken: resetToken,
                    onPreset: { cameraPreset = $0 },
                    onReset:  { cameraPreset = .isometric; resetToken = UUID() }
                )
                .ignoresSafeArea()
                overlayControls
                cameraControls
                helpButton
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var cameraControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Picker("뷰", selection: $cameraPreset) {
                ForEach(CameraPreset.allCases) { preset in
                    Label(preset.rawValue, systemImage: preset.symbol).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            Button {
                cameraPreset = .isometric
                resetToken = UUID()
            } label: {
                Label("리셋", systemImage: "arrow.counterclockwise")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var helpButton: some View {
        Button {
            showHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
        .help("3D 뷰 조작법 보기")
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .popover(isPresented: $showHelp, arrowEdge: .trailing) {
            HelpPopover()
        }
    }
}

private struct HelpPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3D 뷰 조작법").font(.headline)

            section("마우스 / 트랙패드", rows: [
                ("드래그",         "회전"),
                ("⌥ + 드래그",    "이동(팬)"),
                ("스크롤 / 핀치",  "줌"),
            ])

            section("키보드", rows: [
                ("← → ↑ ↓", "회전"),
                ("+  /  -",  "줌"),
                ("1 / 2 / 3", "기본 / 상단 / 측면"),
                ("R",         "리셋"),
            ])
        }
        .padding(16)
        .frame(width: 260)
    }

    @ViewBuilder
    private func section(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { key, desc in
                HStack(spacing: 8) {
                    Text(key)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 4))
                    Text(desc).font(.caption)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - NSViewRepresentable

/// 화살표 / +- / R / 1·2·3 키를 처리하는 SCNView.
/// 회전·줌은 자체 처리하고, 프리셋/리셋은 SwiftUI 측 콜백으로 위임한다.
final class KeyResponderSCNView: SCNView {
    var onPreset: (CameraPreset) -> Void = { _ in }
    var onReset:  () -> Void = {}

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let rotateStep: Float = 8       // degree
        let zoomStep:   Float = 4       // dollyToTarget delta (양수 = 가까이)
        let controller = self.defaultCameraController

        switch Int(event.keyCode) {
        case 123: controller.rotateBy(x: -rotateStep, y: 0)         // ←
        case 124: controller.rotateBy(x:  rotateStep, y: 0)         // →
        case 126: controller.rotateBy(x: 0, y:  rotateStep)         // ↑
        case 125: controller.rotateBy(x: 0, y: -rotateStep)         // ↓
        case 24, 69:  controller.dolly(toTarget:  zoomStep)         // = / + (numpad)  → 줌인
        case 27, 78:  controller.dolly(toTarget: -zoomStep)         // - / _ (numpad)  → 줌아웃
        case 15:                                                    // R
            onReset()
        case 18: onPreset(.isometric)                               // 1
        case 19: onPreset(.top)                                     // 2
        case 20: onPreset(.side)                                    // 3
        default: super.keyDown(with: event)
        }
    }
}

struct SceneKitRouteView: NSViewRepresentable {
    let trackPoints: [TrackPoint]
    var highlightPoints: [TrackPoint] = []
    let exaggeration: Double
    let pathWidth: Double
    var cameraPreset: CameraPreset = .isometric
    var resetToken: UUID = UUID()
    var onPreset: (CameraPreset) -> Void = { _ in }
    var onReset:  () -> Void = {}

    // MARK: Coordinator — 씬과 정규화 파라미터를 캐시

    final class Coordinator {
        // TrackPoint는 Equatable 미준수 → cumKm 배열로 동일성 판단
        var builtPointSignature: [Double] = []
        var builtExaggeration: Double = 0
        var builtHalfWidth: Float = 0

        var cachedScene: RouteGeometryBuilder.RouteScene?

        var appliedPreset: CameraPreset?
        var appliedResetToken: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = KeyResponderSCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1)
        view.onPreset = onPreset
        view.onReset  = onReset

        let controller = view.defaultCameraController
        controller.interactionMode = .orbitTurntable
        controller.inertiaEnabled = true
        controller.maximumVerticalAngle = 89
        controller.minimumVerticalAngle = -10

        rebuildScene(view: view, context: context)

        // 뷰가 윈도우에 attach 되면 first responder 로 만들어 키 입력을 받게 한다.
        DispatchQueue.main.async { [weak view] in
            view?.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        if let keyView = view as? KeyResponderSCNView {
            keyView.onPreset = onPreset
            keyView.onReset  = onReset
        }

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

        let presetChanged = coordinator.appliedPreset != cameraPreset
        let resetChanged  = coordinator.appliedResetToken != resetToken
        if presetChanged || resetChanged {
            applyCameraPreset(cameraPreset, to: view, animated: !needsRebuild)
            coordinator.appliedPreset = cameraPreset
            coordinator.appliedResetToken = resetToken
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
        cam.camera?.zNear = 0.5
        let target = SCNVector3(0, 8, 0)
        scene.rootNode.addChildNode(cam)

        view.scene = scene
        view.pointOfView = cam
        view.defaultCameraController.target = target
        view.defaultCameraController.pointOfView = cam

        applyCameraPreset(cameraPreset, to: view, animated: false)
        coordinator.appliedPreset = cameraPreset
        coordinator.appliedResetToken = resetToken

        updateHighlightPins(in: view, scene: result)
    }

    // MARK: - 카메라 프리셋

    private func applyCameraPreset(_ preset: CameraPreset, to view: SCNView, animated: Bool) {
        guard let cam = view.pointOfView else { return }

        // 프리셋/리셋은 항상 경로 중앙을 보도록 target 도 함께 원위치한다.
        let target = SCNVector3(0, 8, 0)
        view.defaultCameraController.target = target

        let position: SCNVector3
        switch preset {
        case .isometric:
            position = SCNVector3(target.x,        target.y + 55,  target.z + 100)
        case .top:
            // 정수직이면 look(at:) 의 up 벡터가 모호해지므로 z 방향으로 살짝 빗각.
            position = SCNVector3(target.x,        target.y + 140, target.z + 1)
        case .side:
            position = SCNVector3(target.x + 130,  target.y + 20,  target.z)
        }

        let move = {
            cam.position = position
            cam.look(at: target)
        }

        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.4
            move()
            SCNTransaction.commit()
        } else {
            move()
        }
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
