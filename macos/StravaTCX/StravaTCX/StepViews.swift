import SwiftUI
import StravaTCXKit

// MARK: - 공통 UI 헬퍼

struct StepTitle: View {
    let title: String
    let subtitle: String
    init(_ title: String, _ subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .frame(maxWidth: 360)
    }
}

func categoryLabel(_ cat: String?) -> String {
    guard let cat else { return "—" }
    return cat == "HC" ? "HC" : "Cat \(cat)"
}

/// Table 행용 식별 래퍼 (CoursePointEntry 는 Identifiable 아님)
struct IdentifiedEntry: Identifiable {
    let id: Int
    let entry: CoursePointEntry
}

// MARK: - Step 1: 설정

struct SetupStepView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepTitle("설정", "Strava 세션 쿠키와 라우트 ID 를 입력하세요.")

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("_strava4_session 값", text: $model.cookie)
                        .textFieldStyle(.roundedBorder)
                    Text("브라우저 개발자도구 → Application → Cookies → strava.com 에서 복사")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            } label: {
                Label("Strava 쿠키 (_strava4_session)", systemImage: "key.fill")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("예: 3495269006478904270", text: $model.routeID)
                        .textFieldStyle(.roundedBorder)
                    Text("strava.com/routes/<여기 숫자>")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            } label: {
                Label("Route ID", systemImage: "number")
            }
        }
    }
}

// MARK: - Step 2: TCX 다운로드

struct DownloadStepView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle("TCX 다운로드", "라우트의 TCX 트랙을 가져옵니다.")
            InfoRow("Route ID", model.routeID)
            if model.tcxData != nil {
                InfoRow("Trackpoint", "\(model.trackPointCount) 개")
                Label("다운로드 완료", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("아래 ‘TCX 다운로드’ 버튼을 누르세요.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Step 3: 세그먼트

struct SegmentsStepView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepTitle("세그먼트", "라우트에 포함된 Strava 세그먼트입니다.")
            if model.segments.isEmpty {
                Text("‘세그먼트 불러오기’ 를 누르세요.")
                    .foregroundStyle(.secondary)
            } else {
                Table(model.segments) {
                    TableColumn("#") { s in Text(s.order.map(String.init) ?? "—") }
                        .width(28)
                    TableColumn("이름") { s in Text(s.name) }
                    TableColumn("카테고리") { s in Text(categoryLabel(s.climbCategory)) }
                        .width(80)
                    TableColumn("거리") { s in Text(s.distanceText ?? "—") }
                        .width(80)
                    TableColumn("경사") { s in Text(s.avgGrade ?? "—") }
                        .width(70)
                }
                .frame(minHeight: 240)
            }
        }
    }
}

// MARK: - Step 4: CoursePoint

struct CoursePointsStepView: View {
    @Bindable var model: AppModel

    private var rows: [IdentifiedEntry] {
        model.entries
            .sorted { $0.idx < $1.idx }
            .enumerated()
            .map { IdentifiedEntry(id: $0.offset, entry: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepTitle("CoursePoint", "옵션을 정하고 CoursePoint 를 생성합니다.")

            Picker("최소 카테고리", selection: $model.minCategory) {
                Text("전체").tag(String?.none)
                Text("4↑").tag(String?.some("4"))
                Text("3↑").tag(String?.some("3"))
                Text("2↑").tag(String?.some("2"))
                Text("1↑").tag(String?.some("1"))
                Text("HC").tag(String?.some("HC"))
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .onChange(of: model.minCategory) { _, _ in
                model.regenerateCoursePointsIfNeeded()
            }

            if model.entries.isEmpty {
                Text("‘CoursePoint 생성’ 을 누르세요.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.entries.count)개 CoursePoint")
                    .font(.headline)
                Table(rows) {
                    TableColumn("위치") { r in
                        Text(r.entry.isStart ? "시작" : "종료")
                            .foregroundStyle(r.entry.isStart ? .primary : .secondary)
                    }
                    .width(48)
                    TableColumn("PointType") { r in Text(r.entry.pointType) }
                        .width(130)
                    TableColumn("Notes (RWGPS)") { r in Text(model.previewNotes(for: r.entry)) }
                }
                .frame(minHeight: 260)
            }
        }
    }
}

// MARK: - Step 5: 내보내기

struct ExportStepView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepTitle("내보내기", "생성된 TCX 를 저장합니다.")
            InfoRow("Route ID", model.routeID)
            InfoRow("Trackpoint", "\(model.trackPointCount) 개")
            InfoRow("세그먼트", "\(model.segments.count) 개")
            InfoRow("CoursePoint", "\(model.entries.count) 개")
            Label("저장 기능은 Step 4 에서 구현됩니다.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }
}
