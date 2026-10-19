# CourseBoy

Strava 경로를 불러와 구간(segment) 정보를 CueSheet(`CoursePoint`)로 넣은 TCX 코스를 만드는 macOS 앱입니다.

iOS 앱은 [CourseBoyMobile](https://github.com/mettmoon/CourseBoyMobile)으로, 코스 파일 파서는 [CourseBoyPreviewCore](https://github.com/mettmoon/CourseBoyPreviewCore)로 분리했습니다.

## 구성

| 경로 | 내용 |
| --- | --- |
| `macos/CourseBoy` | macOS 앱(`CourseBoy`)과 Finder Quick Look 확장(`CourseBoyMacQuickLook`) |
| `macos/CourseBoyKit` | Strava 조회, TCX 파싱·생성, CueSheet 분류 로직 Swift 패키지와 `courseboy` CLI |

## 빌드

```bash
open macos/CourseBoy/CourseBoy.xcodeproj
```

```bash
swift test --package-path macos/CourseBoyKit
```

## CLI

이미 받아 둔 TCX와 segments JSON으로 CueSheet가 들어간 TCX를 만듭니다.

```bash
swift run --package-path macos/CourseBoyKit courseboy --tcx route.tcx --segments route_segments.json --min-category 2
```

`<입력>_cued.tcx`와 RWGPS용 `<입력>_cued_for_rwgps.tcx`가 함께 생성됩니다. `--out`으로 출력 경로를 바꿀 수 있습니다.

## 분류 규칙

각 segment 의 **시작 지점** 과 **종료 지점** 두 개의 `CoursePoint` 가 추가됩니다.

| 위치 | 조건 | PointType |
| --- | --- | --- |
| 시작 | `climb_category = HC` | `Hors Category` |
| 시작 | `climb_category = 1` | `1st Category` |
| 시작 | `climb_category = 2` | `2nd Category` |
| 시작 | `climb_category = 3` | `3rd Category` |
| 시작 | `climb_category = 4` | `4th Category` |
| 시작 | 그 외 (없음/0)  | `Sprint` |
| 종료 | 항상 | `Summit` |

### `--min-category` 필터
지정한 등급 **이상** 의 segment 만 CoursePoint 로 포함합니다.
등급 순서(낮음 → 높음): `4 < 3 < 2 < 1 < HC`

| 옵션값 | 포함되는 등급 |
| --- | --- |
| `4` | 4, 3, 2, 1, HC (= 카테고리 있는 모든 segment) |
| `3` | 3, 2, 1, HC |
| `2` | 2, 1, HC |
| `1` | 1, HC |
| `HC` | HC 만 |
| (미지정) | 카테고리 무관 전체 |
