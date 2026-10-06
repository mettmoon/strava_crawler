import SwiftUI
import UIKit

extension View {
    /// 이 화면이 보이는 동안의 상태바 글자색. SwiftUI는 상태바 스타일을 지정하는 API가 없지만,
    /// 루트 호스팅 컨트롤러가 상태바 스타일을 자식 뷰 컨트롤러에 맡기므로 보이지 않는 자식을 끼워 넣어 정한다.
    /// 전체 화면으로 띄운 화면은 자기 상태바 스타일을 따로 쓰므로 영향을 받지 않는다.
    func statusBarStyle(_ style: UIStatusBarStyle) -> some View {
        background {
            StatusBarStyleView(style: style)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

private struct StatusBarStyleView: UIViewControllerRepresentable {
    let style: UIStatusBarStyle

    func makeUIViewController(context: Context) -> Controller {
        Controller(style: style)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.style = style
    }

    final class Controller: UIViewController {
        var style: UIStatusBarStyle {
            didSet {
                if style != oldValue {
                    requestStatusBarUpdate()
                }
            }
        }

        init(style: UIStatusBarStyle) {
            self.style = style
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var preferredStatusBarStyle: UIStatusBarStyle { style }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            requestStatusBarUpdate()
        }

        /// 상태바는 루트 컨트롤러에서부터 다시 묻기 때문에 맨 위 부모에게 갱신을 요청한다.
        private func requestStatusBarUpdate() {
            var root: UIViewController = self
            while let parent = root.parent {
                root = parent
            }
            root.setNeedsStatusBarAppearanceUpdate()
        }
    }
}
