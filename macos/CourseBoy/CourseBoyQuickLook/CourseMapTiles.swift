import MapKit
import UIKit

/// 지도 탭에서 Apple 지도 대신 까는 래스터 타일 서버. 상용 제공자로 바꿀 때는 여기만 고친다.
struct CourseMapTileSource: Equatable {
    /// 디스크 캐시 폴더 이름으로도 쓴다.
    let id: String
    /// {s}는 subdomains 중 하나로, {z}/{x}/{y}는 타일 좌표로 바뀐다.
    let urlTemplate: String
    var subdomains: [String] = []
    /// 서버가 제공하는 최대 줌. 그보다 확대하면 이 줌의 타일을 잘라 늘려 그린다.
    let maximumZ: Int
    let attribution: String
    let copyrightURL: URL

    static let openStreetMap = CourseMapTileSource(
        id: "osm",
        urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
        maximumZ: 19,
        attribution: "© OpenStreetMap contributors",
        copyrightURL: URL(string: "https://www.openstreetmap.org/copyright")!
    )

    static let cyclOSM = CourseMapTileSource(
        id: "cyclosm",
        urlTemplate: "https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png",
        subdomains: ["a", "b", "c"],
        maximumZ: 20,
        attribution: "CyclOSM · © OpenStreetMap contributors",
        copyrightURL: URL(string: "https://www.openstreetmap.org/copyright")!
    )

    func url(z: Int, x: Int, y: Int) -> URL? {
        var string = urlTemplate
            .replacingOccurrences(of: "{z}", with: String(z))
            .replacingOccurrences(of: "{x}", with: String(x))
            .replacingOccurrences(of: "{y}", with: String(y))
        if !subdomains.isEmpty {
            // 같은 타일은 늘 같은 서브도메인으로 보내 서버 쪽 캐시를 잘 타게 한다.
            string = string.replacingOccurrences(of: "{s}", with: subdomains[abs(x + y) % subdomains.count])
        }
        return URL(string: string)
    }
}

/// Apple 지도를 대신하는 타일 오버레이. canReplaceMapContent로 Apple 지도를 끄는 역할만 하고,
/// 타일은 CourseTileRenderer가 직접 받아 그린다.
final class CourseTileOverlay: MKTileOverlay {
    let source: CourseMapTileSource
    /// 타일을 받았는지(true) 못 받았는지(false) 메인 스레드에서 알린다.
    var onLoadResult: ((Bool) -> Void)?

    init(source: CourseMapTileSource) {
        self.source = source
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        tileSize = CGSize(width: 256, height: 256)
        maximumZ = source.maximumZ
    }
}

/// 타일을 디코딩한 이미지로 메모리에 두고 바로 그린다. 아직 없는 타일은 받는 동안 이미 가진
/// 상위·하위 줌 타일로 대신 그린다. MKTileOverlayRenderer는 줌 단계가 바뀌면 그려 둔 타일을
/// 버리고 새 타일을 다 그릴 때까지 빈 칸을 보여 줘서, 확대·축소할 때마다 지도가 깜빡였다.
final class CourseTileRenderer: MKOverlayRenderer {
    /// 화면 포인트 기준 타일 한 장의 목표 크기. MKTileOverlayRenderer와 같은 줌 단계를 고른다.
    private static let tilePoints: Double = 256
    /// 대신 그릴 상위 줌 타일을 이만큼 위까지 찾는다.
    private static let fallbackAncestorLevels = 8
    /// 받지 못한 타일은 이 시간이 지나야 다시 요청한다. 오프라인일 때 그릴 때마다 요청하지 않게 한다.
    private static let retryInterval: TimeInterval = 15

    private static let images: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private let tileOverlay: CourseTileOverlay
    private let lock = NSLock()
    private var loading = Set<String>()
    private var failedAt: [String: Date] = [:]

    init(tileOverlay: CourseTileOverlay) {
        self.tileOverlay = tileOverlay
        super.init(overlay: tileOverlay)
    }

    /// 받지 못했던 타일까지 다시 요청한다.
    func reload() {
        lock.withLock { failedAt.removeAll() }
        setNeedsDisplay()
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let source = tileOverlay.source
        let wantedZ = Int(log2(MKMapSize.world.width * Double(zoomScale) / Self.tilePoints).rounded())
        // 서버 최대 줌보다 확대하면 최대 줌 타일을 늘려 그린다.
        let z = min(max(wantedZ, 0), source.maximumZ)
        let count = 1 << z
        let tileWidth = MKMapSize.world.width / Double(count)
        let minX = max(Int(floor(mapRect.minX / tileWidth)), 0)
        let maxX = min(Int(ceil(mapRect.maxX / tileWidth)), count) - 1
        let minY = max(Int(floor(mapRect.minY / tileWidth)), 0)
        let maxY = min(Int(ceil(mapRect.maxY / tileWidth)), count) - 1
        guard minX <= maxX, minY <= maxY else { return }

        context.interpolationQuality = .medium
        for x in minX...maxX {
            for y in minY...maxY {
                let tileRect = Self.mapRect(z: z, x: x, y: y)
                if let image = image(z: z, x: x, y: y) {
                    drawImage(image, in: tileRect, context: context)
                    continue
                }
                requestTile(z: z, x: x, y: y)
                drawFallback(z: z, x: x, y: y, tileRect: tileRect, context: context)
            }
        }
    }

    /// 축소할 때는 받아 둔 하위 줌 타일 4장으로, 확대할 때는 가장 가까운 상위 줌 타일의 일부를 늘려 채운다.
    private func drawFallback(z: Int, x: Int, y: Int, tileRect: MKMapRect, context: CGContext) {
        if z < tileOverlay.source.maximumZ {
            let children = [(0, 0), (1, 0), (0, 1), (1, 1)].map { dx, dy in
                (2 * x + dx, 2 * y + dy, image(z: z + 1, x: 2 * x + dx, y: 2 * y + dy))
            }
            if children.allSatisfy({ $0.2 != nil }) {
                for (childX, childY, image) in children {
                    drawImage(image!, in: Self.mapRect(z: z + 1, x: childX, y: childY), context: context)
                }
                return
            }
        }

        for levels in 1...Self.fallbackAncestorLevels where levels <= z {
            let ancestorZ = z - levels
            let ancestorX = x >> levels
            let ancestorY = y >> levels
            guard let image = image(z: ancestorZ, x: ancestorX, y: ancestorY) else { continue }
            context.saveGState()
            context.clip(to: rect(for: tileRect))
            drawImage(image, in: Self.mapRect(z: ancestorZ, x: ancestorX, y: ancestorY), context: context)
            context.restoreGState()
            return
        }
    }

    private func drawImage(_ image: CGImage, in mapRect: MKMapRect, context: CGContext) {
        let rect = rect(for: mapRect)
        // 렌더러 좌표계는 y가 아래로 커지므로 이미지를 뒤집어 그린다.
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private func key(z: Int, x: Int, y: Int) -> String {
        "\(tileOverlay.source.id)/\(z)/\(x)/\(y)"
    }

    private func image(z: Int, x: Int, y: Int) -> CGImage? {
        Self.images.object(forKey: key(z: z, x: x, y: y) as NSString)
    }

    private func requestTile(z: Int, x: Int, y: Int) {
        let key = key(z: z, x: x, y: y)
        let shouldLoad = lock.withLock { () -> Bool in
            if loading.contains(key) { return false }
            if let failed = failedAt[key], Date().timeIntervalSince(failed) < Self.retryInterval { return false }
            loading.insert(key)
            return true
        }
        guard shouldLoad else { return }

        CourseTileCache.shared.tileData(source: tileOverlay.source, z: z, x: x, y: y) { [weak self] outcome in
            guard let self else { return }
            let image = (try? outcome.get()).flatMap(Self.decodedImage)
            if let image {
                Self.images.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
            }
            self.lock.withLock {
                self.loading.remove(key)
                if image == nil {
                    self.failedAt[key] = Date()
                } else {
                    self.failedAt.removeValue(forKey: key)
                }
            }
            DispatchQueue.main.async {
                if image != nil {
                    self.setNeedsDisplay(Self.mapRect(z: z, x: x, y: y))
                }
                self.tileOverlay.onLoadResult?(image != nil)
            }
        }
    }

    /// 그릴 때 디코딩하지 않도록 미리 풀어 둔다.
    private static func decodedImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    private static func mapRect(z: Int, x: Int, y: Int) -> MKMapRect {
        let width = MKMapSize.world.width / Double(1 << z)
        return MKMapRect(x: Double(x) * width, y: Double(y) * width, width: width, height: width)
    }
}

/// 받은 타일을 Caches 폴더에 두고 재사용한다. 공용 타일 서버의 사용 정책을 지키도록
/// 고유 User-Agent를 보내고, 같은 타일을 동시에 두 번 받지 않으며, 미리 내려받지 않는다.
final class CourseTileCache: @unchecked Sendable {
    static let shared = CourseTileCache()

    enum TileError: Error {
        case invalidURL
        case badStatus(Int)
    }

    /// 이 기간 안에 받은 타일은 서버에 다시 묻지 않는다.
    private static let freshness: TimeInterval = 7 * 24 * 60 * 60
    private static let byteLimit = 200 * 1024 * 1024
    /// 용량을 넘으면 오래 안 쓴 타일부터 이만큼까지 지운다.
    private static let trimTarget = 160 * 1024 * 1024
    /// 이만큼 새로 저장할 때마다 용량을 확인한다.
    private static let trimCheckInterval = 200
    /// 읽을 때마다 사용 시각을 고치면 쓰기가 많아지므로, 이보다 오래된 경우에만 고친다.
    private static let touchInterval: TimeInterval = 24 * 60 * 60

    private let directory: URL
    private let session: URLSession
    private let fileManager = FileManager.default
    /// pending과 writesSinceTrim은 이 큐에서만 다룬다.
    private let queue = DispatchQueue(label: "CourseTileCache", qos: .userInitiated)
    /// 디스크 읽기와 완료 콜백(이미지 디코딩 포함)은 서로 기다리지 않게 병렬 큐에서 한다.
    private let ioQueue = DispatchQueue(label: "CourseTileCache.io", qos: .userInitiated, attributes: .concurrent)
    /// 디코딩한 이미지 캐시에서 밀려난 타일을 디스크까지 가지 않고 다시 쓰도록 원본도 메모리에 둔다.
    private let memory: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private var pending: [String: [(Result<Data, Error>) -> Void]] = [:]
    private var writesSinceTrim = 0

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("MapTiles", isDirectory: true)

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 공용 타일 서버 부하를 줄이려고 호스트당 동시 연결을 2개로 묶는다.
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: configuration)

        queue.async { [self] in trimIfNeeded() }
    }

    /// 타일 서버 운영자가 문제가 있을 때 연락할 수 있도록 User-Agent에 넣는 연락처.
    private static let contact = "https://www.navelo.cc; ys_qwerty700@naver.com"

    /// OSM 타일 정책은 앱을 식별할 수 있는 User-Agent를 요구한다.
    private static var userAgent: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let bundleID = Bundle.main.bundleIdentifier ?? "CourseBoy"
        return "CourseBoy/\(version) (\(bundleID); iOS; +\(contact))"
    }

    func tileData(
        source: CourseMapTileSource,
        z: Int,
        x: Int,
        y: Int,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let file = directory
            .appendingPathComponent(source.id, isDirectory: true)
            .appendingPathComponent("\(z)/\(x)/\(y).png")
        let key = file.path
        if let cached = memory.object(forKey: key as NSString) {
            completion(.success(cached as Data))
            return
        }

        ioQueue.async { [self] in
            if let cached = cachedTile(at: file), cached.isFresh {
                remember(cached.data, key: key)
                completion(.success(cached.data))
                return
            }
            queue.async { [self] in
                fetch(source: source, z: z, x: x, y: y, file: file, key: key, completion: completion)
            }
        }
    }

    private func fetch(
        source: CourseMapTileSource,
        z: Int,
        x: Int,
        y: Int,
        file: URL,
        key: String,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        // 디스크를 확인하는 사이 같은 타일을 다 받았으면 그대로 쓴다.
        if let cached = memory.object(forKey: key as NSString) {
            let data = cached as Data
            ioQueue.async { completion(.success(data)) }
            return
        }
        if pending[key] != nil {
            pending[key]?.append(completion)
            return
        }
        pending[key] = [completion]

        guard let url = source.url(z: z, x: x, y: y) else {
            finish(key: key, file: file, result: .failure(TileError.invalidURL))
            return
        }
        session.dataTask(with: url) { [self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<Data, Error>
            if let data, (200..<300).contains(status) {
                result = .success(data)
            } else {
                result = .failure(error ?? TileError.badStatus(status))
            }
            queue.async { [self] in
                finish(key: key, file: file, result: result)
            }
        }.resume()
    }

    private func finish(key: String, file: URL, result: Result<Data, Error>) {
        var result = result
        switch result {
        case .success(let data):
            store(data, at: file)
            remember(data, key: key)
        case .failure:
            // 오프라인이거나 서버가 막았으면 기한이 지난 타일이라도 보여 준다.
            if let stale = cachedTile(at: file) {
                result = .success(stale.data)
            }
        }
        let completions = pending.removeValue(forKey: key) ?? []
        let finalResult = result
        ioQueue.async {
            for completion in completions {
                completion(finalResult)
            }
        }
    }

    private func remember(_ data: Data, key: String) {
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }

    private func cachedTile(at file: URL) -> (data: Data, isFresh: Bool)? {
        guard let values = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]),
              let data = try? Data(contentsOf: file) else { return nil }
        let now = Date()
        // 생성 시각은 받은 시각(새로 받으면 파일을 바꿔 쓴다), 수정 시각은 마지막으로 쓴 시각으로 둔다.
        let isFresh = values.creationDate.map { now.timeIntervalSince($0) < Self.freshness } ?? false
        if let used = values.contentModificationDate, now.timeIntervalSince(used) > Self.touchInterval {
            try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        }
        return (data, isFresh)
    }

    private func store(_ data: Data, at file: URL) {
        do {
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            return
        }
        writesSinceTrim += 1
        if writesSinceTrim >= Self.trimCheckInterval {
            trimIfNeeded()
        }
    }

    /// 용량을 넘었으면 가장 오래 안 쓴 타일부터 지운다.
    private func trimIfNeeded() {
        writesSinceTrim = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }

        var files: [(url: URL, size: Int, used: Date)] = []
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let size = values.totalFileAllocatedSize ?? 0
            total += size
            files.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > Self.byteLimit else { return }

        for file in files.sorted(by: { $0.used < $1.used }) {
            guard total > Self.trimTarget else { break }
            if (try? fileManager.removeItem(at: file.url)) != nil {
                total -= file.size
            }
        }
    }
}
