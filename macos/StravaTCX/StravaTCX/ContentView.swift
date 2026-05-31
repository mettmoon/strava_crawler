import SwiftUI
import StravaTCXKit

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bicycle")
                .font(.system(size: 52))
                .foregroundStyle(.tint)

            Text("Strava → TCX")
                .font(.largeTitle.bold())
            Text("CueSheet 생성기")
                .foregroundStyle(.secondary)

            Divider().frame(width: 220)

            // StravaTCXKit 링크/동작 확인 (Step 1 스캐폴딩 검증용)
            VStack(alignment: .leading, spacing: 6) {
                Label(kitStatus, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(sampleLine)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var kitStatus: String {
        "StravaTCXKit 연결됨"
    }

    private var sampleLine: String {
        let g = Classification.gradeClass("7.0%")
        let cat = Classification.startPointType("Category2")
        return "grade(7.0%)=\(g.rawValue)\(g.arrow) · cat(2)=\(cat)"
    }
}

#Preview {
    ContentView()
        .frame(width: 760, height: 560)
}
