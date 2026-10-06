import CoursePreviewCore
import SwiftUI
import UniformTypeIdentifiers

/// 앱 첫 화면. 최근 연 코스와 즐겨찾기를 보여주고, 하단 버튼으로 시스템 파일 선택기를 연다.
/// 창마다 하나씩 떠서 iPad에서 여러 코스를 나란히 띄울 수 있다.
struct CourseHomeView: View {
    private let store = RecentCourseStore.shared

    @State private var presentedCourse: LoadedCourse?
    @State private var isImporting = false
    @State private var isSearching = false
    @State private var searchText = ""
    @FocusState private var isSearchFieldFocused: Bool
    @AppStorage("homeSort") private var sort: RecentCourseSort = .recent
    @AppStorage("homeKindFilter") private var kindFilter: RecentCourseKindFilter = .all
    @State private var showsSettings = false
    @State private var confirmsClearAll = false
    @State private var fileError: FilePreviewError?
    @State private var missingCourse: RecentCourse?
    @State private var openingID: RecentCourse.ID?
    @State private var shareItem: ShareFileItem?
    @State private var isDropTargeted = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var hasCourses: Bool { !store.courses.isEmpty }

    private var visibleCourses: [RecentCourse] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = store.courses.filter { course in
            kindFilter.includes(course)
                && (query.isEmpty
                    || course.title.localizedCaseInsensitiveContains(query)
                    || course.fileName.localizedCaseInsensitiveContains(query))
        }
        return sort.sorted(filtered)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [HomePalette.backgroundTop, HomePalette.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    headline
                        .padding(.top, 40)
                    if isSearching {
                        searchField
                            .padding(.top, 20)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    content
                        .padding(.top, 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.immediately)
            // 정렬·필터를 바꾸면 카드가 한꺼번에 튀지 않고 새 자리로 옮겨 가게 한다.
            .animation(.snappy(duration: 0.3), value: sort)
            .animation(.snappy(duration: 0.3), value: kindFilter)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar
            }
        }
        // 홈 위쪽은 라이트·다크 모두 진한 파란 배경이라 상태바 글자를 흰색으로 둔다.
        .statusBarStyle(.lightContent)
        .fullScreenCover(item: $presentedCourse) { course in
            CourseViewerScreen(course: course)
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: UTType.courseBoyReadable) { result in
            if case .success(let url) = result {
                Task { await open(url: url) }
            }
        }
        // Files 앱의 '다음으로 열기'나 공유로 들어온 파일은 홈을 거치지 않고 바로 연다.
        .onOpenURL { url in
            Task { await open(url: url) }
        }
        .dropDestination(for: DroppedCourseFile.self) { files, _ in
            guard let file = files.first else { return false }
            switch file.result {
            case .success(let read, let copy):
                store.record(read, from: copy, isLibraryCopy: true)
                presentedCourse = read.course
            case .failure(let message):
                fileError = FilePreviewError(message: message)
            }
            return true
        } isTargeted: { isTargeted in
            withAnimation(.easeInOut(duration: 0.15)) {
                isDropTargeted = isTargeted
            }
        }
        .overlay {
            if isDropTargeted {
                CourseDropTargetOverlay()
            }
        }
        .sheet(isPresented: $showsSettings) {
            AppInfoView()
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .confirmationDialog("최근 기록을 모두 지울까요?", isPresented: $confirmsClearAll, titleVisibility: .visible) {
            Button("모두 지우기", role: .destructive) {
                withAnimation {
                    store.removeAllRecents()
                }
            }
        } message: {
            Text("즐겨찾기한 코스와 원본 파일은 그대로 남습니다.")
        }
        .alert("파일을 찾을 수 없습니다", isPresented: missingAlertBinding, presenting: missingCourse) { course in
            Button("목록에서 제거", role: .destructive) {
                withAnimation {
                    store.remove(course.id)
                }
            }
            Button("취소", role: .cancel) {}
        } message: { course in
            Text("'\(course.fileName)' 파일이 옮겨졌거나 지워졌을 수 있습니다. 목록에서 지울까요?")
        }
        .alert(item: $fileError) { error in
            Alert(
                title: Text("파일을 열 수 없습니다"),
                message: Text(error.message),
                dismissButton: .default(Text("확인"))
            )
        }
        .task {
            await store.refreshAvailability()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.refreshAvailability() }
            }
        }
    }

    private var missingAlertBinding: Binding<Bool> {
        Binding {
            missingCourse != nil
        } set: { isPresented in
            if !isPresented {
                missingCourse = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("COURSEBOY")
                .font(.system(size: 15, weight: .heavy))
                .tracking(1.5)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Button {
                toggleSearch()
            } label: {
                HeaderCircleIcon(systemName: isSearching ? "xmark" : "magnifyingglass")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityLabel(isSearching ? "검색 닫기" : "검색")
            .disabled(!hasCourses)
            .opacity(hasCourses ? 1 : 0.5)

            Menu {
                Button("최근 기록 모두 지우기", systemImage: "trash", role: .destructive) {
                    confirmsClearAll = true
                }
                .disabled(!store.courses.contains { !$0.isFavorite })

                Button("설정", systemImage: "gearshape") {
                    showsSettings = true
                }
            } label: {
                HeaderCircleIcon(systemName: "line.3.horizontal")
            }
            .accessibilityLabel("메뉴")
        }
        .frame(height: 48)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("모든 길은\n코스가 된다.")
                .font(.system(size: horizontalSizeClass == .regular ? 52 : 40, weight: .heavy))
                .lineSpacing(-2)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(hasCourses ? "최근 연 코스를 이어서 확인하세요." : "GPX·TCX 파일을 열어 코스를 확인하세요.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .accessibilityElement(children: .combine)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(HomePalette.ink.opacity(0.6))
            TextField("코스 이름 검색", text: $searchText)
                .focused($isSearchFieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .foregroundStyle(HomePalette.ink)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(HomePalette.ink.opacity(0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("검색어 지우기")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(HomePalette.buttonFill, in: Capsule())
    }

    private func toggleSearch() {
        withAnimation(.snappy) {
            isSearching.toggle()
        }
        if isSearching {
            isSearchFieldFocused = true
        } else {
            searchText = ""
            isSearchFieldFocused = false
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !hasCourses {
            EmptyRecentsCard()
        } else {
            let courses = visibleCourses
            let favorites = courses.filter(\.isFavorite)
            let recents = courses.filter { !$0.isFavorite }

            if courses.isEmpty {
                Text(searchText.isEmpty ? "조건에 맞는 코스가 없습니다." : "검색 결과가 없습니다.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HomePalette.ink.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    // 즐겨찾기가 있을 때만 섹션 제목을 달아 둘을 구분한다.
                    if !favorites.isEmpty {
                        sectionHeader("즐겨찾기", systemImage: "star.fill")
                        courseGrid(favorites)
                    }
                    if !recents.isEmpty {
                        if !favorites.isEmpty {
                            sectionHeader("최근", systemImage: "clock")
                                .padding(.top, 12)
                        }
                        courseGrid(recents)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(HomePalette.ink)
            .accessibilityAddTraits(.isHeader)
    }

    /// iPhone은 1열, iPad는 폭에 따라 2~3열. 화면을 나눠 좁아지면 다시 1열이 된다.
    private func courseGrid(_ courses: [RecentCourse]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
            ForEach(courses) { course in
                courseCard(course)
            }
        }
    }

    private func courseCard(_ course: RecentCourse) -> some View {
        Button {
            Task { await open(recent: course) }
        } label: {
            RecentCourseCard(
                course: course,
                isMissing: store.missingIDs.contains(course.id),
                isOpening: openingID == course.id
            )
        }
        .buttonStyle(CardButtonStyle())
        .disabled(openingID != nil)
        .contextMenu {
            Button(
                course.isFavorite ? "즐겨찾기 해제" : "즐겨찾기",
                systemImage: course.isFavorite ? "star.slash" : "star"
            ) {
                withAnimation(.snappy) {
                    store.setFavorite(course.id, !course.isFavorite)
                }
            }
            Button("공유", systemImage: "square.and.arrow.up") {
                Task { await share(course) }
            }
            .disabled(store.missingIDs.contains(course.id))
            Divider()
            Button("목록에서 제거", systemImage: "trash", role: .destructive) {
                withAnimation(.snappy) {
                    store.remove(course.id)
                }
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                isImporting = true
            } label: {
                Label("파일 브라우저로 열기", systemImage: "folder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .foregroundStyle(hasCourses ? HomePalette.ink : HomePalette.prominentInk)
                    .background(hasCourses ? HomePalette.buttonFill : HomePalette.prominentFill, in: Capsule())
                    .shadow(color: .black.opacity(hasCourses ? 0.06 : 0.18), radius: 12, y: 4)
            }
            .buttonStyle(CardButtonStyle())
            .keyboardShortcut("o", modifiers: .command)

            if hasCourses {
                Menu {
                    // 메뉴 안의 인라인 Picker는 구역 제목이 사라져서 체크 표시 토글로 구역마다 하나만 고르게 한다.
                    Section("정렬") {
                        ForEach(RecentCourseSort.allCases) { option in
                            Toggle(option.title, isOn: selection($sort, option))
                        }
                    }

                    Section("형식") {
                        ForEach(RecentCourseKindFilter.allCases) { option in
                            Toggle(option.title, isOn: selection($kindFilter, option))
                        }
                    }
                } label: {
                    Image(systemName: kindFilter == .all
                        ? "line.3.horizontal.decrease"
                        : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(HomePalette.ink)
                        .frame(width: 56, height: 56)
                        .background(HomePalette.buttonFill, in: Circle())
                        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
                }
                .accessibilityLabel("정렬 및 필터")
            }
        }
        .frame(maxWidth: 600)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background {
            // 스크롤한 카드가 버튼 뒤로 자연스럽게 사라지게 바닥색으로 흐린다.
            LinearGradient(
                colors: [HomePalette.backgroundBottom.opacity(0), HomePalette.backgroundBottom],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
        }
    }

    /// 값 하나를 고르는 토글 바인딩. 켜면 그 값으로 바꾸고, 이미 고른 값을 끄는 것은 무시한다.
    private func selection<Value: Equatable>(_ binding: Binding<Value>, _ value: Value) -> Binding<Bool> {
        Binding {
            binding.wrappedValue == value
        } set: { isOn in
            if isOn {
                binding.wrappedValue = value
            }
        }
    }

    // MARK: - Actions

    private func open(url: URL) async {
        do {
            let file = try await CourseFileReader.read(url)
            store.record(file, from: url)
            presentedCourse = file.course
        } catch {
            fileError = FilePreviewError(message: error.localizedDescription)
        }
    }

    private func open(recent course: RecentCourse) async {
        openingID = course.id
        defer { openingID = nil }
        do {
            presentedCourse = try await store.open(course.id)
        } catch {
            missingCourse = course
        }
    }

    private func share(_ course: RecentCourse) async {
        do {
            shareItem = ShareFileItem(url: try await store.shareableURL(for: course.id))
        } catch {
            missingCourse = course
        }
    }
}

/// 헤더의 테두리 원형 버튼.
private struct HeaderCircleIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.12), in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
            }
            .contentShape(Circle())
    }
}

/// 누르면 살짝 줄어드는 카드·버튼 스타일.
private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 최근 코스가 하나도 없을 때 카드 자리에 보여주는 안내.
private struct EmptyRecentsCard: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 36, weight: .semibold))
            Text("아직 연 코스가 없어요")
                .font(.headline)
            Text("GPX·TCX 파일을 열면 여기에 표시됩니다.\n파일을 이 화면으로 끌어다 놓아도 됩니다.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .opacity(0.8)
        }
        .foregroundStyle(HomePalette.ink)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
        .background(HomePalette.cardFill, in: RoundedRectangle(cornerRadius: RecentCourseCard.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: RecentCourseCard.cornerRadius, style: .continuous)
                .strokeBorder(HomePalette.cardStroke, style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
        }
    }
}

struct ShareFileItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// 공유 시트.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

