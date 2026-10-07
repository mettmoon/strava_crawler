import SwiftUI
import UIKit

/// 창마다 열어 둔 코스를 기억해, 앱이 의도치 않게 꺼졌다가(크래시·시스템 종료) 다시 켜지면 그 코스를 다시 연다.
///
/// 창(UISceneSession)의 persistentIdentifier를 열쇠로, 열고 닫는 즉시 UserDefaults에 적어 크래시 직전 상태도 남긴다.
/// 장면 상태(@SceneStorage)나 세션은 앱 전환기에서 닫아도 남아 의도한 종료를 가릴 수 없으므로 쓰지 않는다.
/// 대신 앱 전환기에서 닫으면 오는 종료 알림(applicationWillTerminate)에서 기록을 모두 지운다.
/// 크래시나 시스템 종료는 이 알림 없이 프로세스가 끝나므로 기록이 남는다.
/// 한계: 배경에서 이미 일시 정지된 앱을 나중에 전환기에서 닫으면 알림이 오지 않아 시스템 종료와 구분할 수 없고, 다시 열린다.
enum OpenCourseRestoration {
    private static let key = "openCourseBySceneSession"

    private static var entries: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func courseID(for session: String) -> RecentCourse.ID? {
        entries[session].flatMap(UUID.init(uuidString:))
    }

    static func set(_ id: RecentCourse.ID?, for session: String) {
        entries[session] = id?.uuidString
    }

    /// 버려진 세션의 기록을 지운다.
    static func discard(sessions: Set<String>) {
        guard !sessions.isEmpty else { return }
        entries = entries.filter { !sessions.contains($0.key) }
    }

    static func removeAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// 지금 살아 있지 않은 세션의 기록을 지운다. 버려진 세션 알림을 놓쳐도 기록이 쌓이지 않게 한다.
    @MainActor
    static func pruneClosedSessions() {
        let open = Set(UIApplication.shared.openSessions.map(\.persistentIdentifier))
        let stored = entries
        let pruned = stored.filter { open.contains($0.key) }
        if pruned.count != stored.count {
            entries = pruned
        }
    }
}

final class CourseBoyAppDelegate: NSObject, UIApplicationDelegate {
    /// 사용자가 앱 전환기에서 앱을 닫았다. 의도한 종료이므로 다음 실행 때 코스를 다시 열지 않는다.
    func applicationWillTerminate(_ application: UIApplication) {
        OpenCourseRestoration.removeAll()
        UserDefaults.standard.synchronize()
    }

    /// iPad에서 닫은 창의 기록을 지운다.
    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        OpenCourseRestoration.discard(sessions: Set(sceneSessions.map(\.persistentIdentifier)))
    }
}

extension View {
    /// 이 뷰가 놓인 창의 세션 식별자를 알려준다.
    func onSceneSession(_ action: @escaping (String) -> Void) -> some View {
        background(SceneSessionReader(action: action).frame(width: 0, height: 0))
    }
}

private struct SceneSessionReader: UIViewRepresentable {
    let action: (String) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.action = action
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.action = action
    }

    final class ReaderView: UIView {
        var action: ((String) -> Void)?
        private var reported: String?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let session = window?.windowScene?.session.persistentIdentifier, session != reported else { return }
            reported = session
            // 뷰 갱신 중에 SwiftUI 상태를 바꾸지 않도록 다음 차례로 미룬다.
            DispatchQueue.main.async { [action] in
                action?(session)
            }
        }
    }
}
