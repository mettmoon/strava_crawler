import SwiftUI
import StravaTCXKit

/// ‘추가하기’ 시트 — 라우트 변환 위저드. 저장 시 onSave(record) 호출 후 닫힘.
struct AddRouteView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = AppModel()
    let onSave: (RouteRecord) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("라우트 추가").font(.headline)
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()

            StepHeaderView(current: model.step)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()

            ScrollView {
                stepContent
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let err = model.errorMessage {
                ErrorBanner(message: err)
            }
            Divider()
            NavBarView(model: model)
        }
        .frame(width: 860, height: 640)
        .onAppear {
            model.onComplete = { record in
                onSave(record)
                dismiss()
            }
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch model.step {
        case .route: RouteStepView(model: model)
        case .download: DownloadStepView(model: model)
        case .segments: SegmentsStepView(model: model)
        case .coursePoints: CoursePointsStepView(model: model)
        case .save: SaveStepView(model: model)
        }
    }
}

// MARK: - 상단 단계 표시

struct StepHeaderView: View {
    let current: AppModel.Step

    var body: some View {
        HStack(spacing: 0) {
            let steps = AppModel.Step.allCases
            ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                Label(step.title, systemImage: step.systemImage)
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(step == current ? .semibold : .regular))
                    .foregroundStyle(tint(for: step))
                if idx < steps.count - 1 {
                    Image(systemName: "chevron.compact.right")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                }
            }
        }
    }

    private func tint(for step: AppModel.Step) -> Color {
        if step.rawValue < current.rawValue { return .green }
        if step == current { return .accentColor }
        return .secondary
    }
}

// MARK: - 하단 내비게이션

struct NavBarView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Button("이전") { model.back() }
                .disabled(!model.canGoBack)
            Spacer()
            if let p = model.progress {
                ProgressView(value: p).frame(width: 120)
            } else if model.isBusy {
                ProgressView().controlSize(.small)
            }
            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button(model.primaryTitle) {
                Task { await model.performPrimary() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.primaryEnabled)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(.callout)
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.85))
    }
}
