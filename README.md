# CourseBoy

Strava 경로를 불러와 구간(segment) 정보를 CueSheet(`CoursePoint`)로 넣은 TCX 코스를 만드는 macOS 앱입니다.

iOS 앱은 [CourseBoyMobile](https://github.com/mettmoon/CourseBoyMobile)으로, 코스 파일 파서는 [CourseBoyPreviewCore](https://github.com/mettmoon/CourseBoyPreviewCore)로, Strava·TCX·CueSheet 로직과 `courseboy` CLI는 [CourseBoyKit](https://github.com/mettmoon/CourseBoyKit)으로 분리했습니다.

## 구성

| 경로 | 내용 |
| --- | --- |
| `CourseBoy.xcodeproj` | Xcode 프로젝트 |
| `CourseBoy` | macOS 앱(`CourseBoy`) |
| `CourseBoyMacQuickLook` | Finder Quick Look 확장 |
| `CourseBoyMapSnapshotService` | 지도 스냅샷 XPC 서비스 |

## 의존 패키지

Xcode 프로젝트가 GitHub 원격 패키지(`main` 브랜치)로 참조합니다. 고정된 리비전은 `Package.resolved`에 있습니다.

| 패키지 | 제품 |
| --- | --- |
| [CourseBoyKit](https://github.com/mettmoon/CourseBoyKit) | `CourseBoyKit` |
| [CourseBoyPreviewCore](https://github.com/mettmoon/CourseBoyPreviewCore) | `CoursePreviewCore` |
| [CourseBoyMapFile](https://github.com/mettmoon/CourseBoyMapFile) | `CourseBoyMapFile` — Garmin IMG 지도 오버레이와 노면 정보 |

패키지를 고친 뒤에는 Xcode에서 File → Packages → Update to Latest Package Versions로 갱신하고 바뀐 `Package.resolved`를 커밋합니다.

## 빌드

```bash
open CourseBoy.xcodeproj
```

## CLI와 분류 규칙

`courseboy` CLI 사용법과 CueSheet 분류 규칙은 [CourseBoyKit README](https://github.com/mettmoon/CourseBoyKit#readme)에 있습니다.
