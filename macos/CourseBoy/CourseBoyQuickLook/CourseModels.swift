import CoursePreviewCore
import SwiftUI
import UIKit

struct CuePointGlyph {
    var symbol: String?
    var text: String?
    var color: Color
    var uiColor: UIColor
}

func cuePointGlyph(for value: String) -> CuePointGlyph {
    switch value {
    case "Summit":
        return .init(symbol: "mountain.2.fill", text: nil, color: .green, uiColor: .systemGreen)
    case "Valley":
        return .init(symbol: "arrow.down.to.line", text: nil, color: .teal, uiColor: .systemTeal)
    case "Water":
        return .init(symbol: "drop.fill", text: nil, color: .blue, uiColor: .systemBlue)
    case "Food":
        return .init(symbol: "fork.knife", text: nil, color: .orange, uiColor: .systemOrange)
    case "Danger":
        return .init(
            symbol: "exclamationmark.triangle.fill",
            text: nil,
            color: .red,
            uiColor: .systemRed
        )
    case "Left":
        return .init(symbol: "arrow.turn.up.left", text: nil, color: .purple, uiColor: .systemPurple)
    case "Right":
        return .init(symbol: "arrow.turn.up.right", text: nil, color: .purple, uiColor: .systemPurple)
    case "Straight":
        return .init(symbol: "arrow.up", text: nil, color: .gray, uiColor: .systemGray)
    case "First Aid":
        return .init(symbol: "cross.fill", text: nil, color: .red, uiColor: .systemRed)
    case "1st Category":
        return .init(symbol: nil, text: "1", color: .yellow, uiColor: .systemYellow)
    case "2nd Category":
        return .init(symbol: nil, text: "2", color: .yellow, uiColor: .systemYellow)
    case "3rd Category":
        return .init(symbol: nil, text: "3", color: .yellow, uiColor: .systemYellow)
    case "4th Category":
        return .init(symbol: nil, text: "4", color: .yellow, uiColor: .systemYellow)
    case "Hors Category":
        return .init(symbol: nil, text: "HC", color: .red, uiColor: .systemRed)
    case "Sprint":
        return .init(symbol: "bolt.fill", text: nil, color: .yellow, uiColor: .systemYellow)
    default:
        return .init(symbol: "mappin", text: nil, color: .orange, uiColor: .systemOrange)
    }
}
