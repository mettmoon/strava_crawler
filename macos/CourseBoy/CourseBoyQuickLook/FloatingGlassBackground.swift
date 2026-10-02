import SwiftUI

extension View {
    /// iOS 26 이상은 Liquid Glass, 그 이전은 머티리얼 카드로 지도 위에 띄운다.
    @ViewBuilder
    func floatingCardBackground(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        }
    }

    /// 지도 위 원형 버튼 배경. iOS 26 이상은 누르면 반응하는 Liquid Glass, 그 이전은 머티리얼에 얇은 테두리를 두른다.
    @ViewBuilder
    func floatingCircleBackground() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: Circle())
        } else {
            background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                }
        }
    }
}
