# Strava Route → TCX (CueSheet 포함) 도구 모음

## 사전 준비
`cookies.json` 에 본인의 Strava 세션 쿠키를 저장합니다:
```json
{ "_strava4_session": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }
```

## 단건 segment 조회
```bash
python3 get_segment_info.py <segmentID>
# 캐시 무시하고 새로 요청
python3 get_segment_info.py <segmentID> --no-cache
```
결과는 `output/segment/segment_<id>.json` 에 캐시됩니다. 이후 호출은 HTTP 요청 없이 캐시 파일을 그대로 반환합니다.

## routeID → TCX 전체 파이프라인 (한 줄 실행)
```bash
python3 build_route.py 3495269006478904270
# 카테고리 2 이상(2,1,HC) 만 CoursePoint 로 포함
python3 build_route.py 3495269006478904270 --min-category 2
```
세 단계를 차례로 수행합니다:
1. `route_<id>.tcx` 다운로드
2. `route_<id>_segments.json` 생성 (Strava segment 정보 + TCX 트랙 누적거리)
3. `route_<id>_cued.tcx` 출력 - 각 segment 가 시작/종료 두 개의 `CoursePoint` 로 추가됨

## 단계별 실행
```bash
# 1) TCX 만 다운로드
python3 download_route_tcx.py <routeID> [out.tcx]

# 2) route_<id>_segments.json 생성 (TCX 필요)
python3 extract_segments.py <routeID> [--tcx route_<id>.tcx]

# 3) TCX 에 CoursePoint 추가
python3 add_cuesheet_to_tcx.py --tcx route_<id>.tcx [--cache route_<id>_segments.json] [--min-category 2]
```

## 분류 규칙

각 segment 의 **시작 지점** 과 **종료 지점** 두 개의 `CoursePoint` 가 추가됩니다.

| 위치 | 조건 | PointType |
| --- | --- | --- |
| 시작 | `climb_category = HC` | `Hors Category` |
| 시작 | `climb_category = 1` | `First Category` |
| 시작 | `climb_category = 2` | `Second Category` |
| 시작 | `climb_category = 3` | `Third Category` |
| 시작 | `climb_category = 4` | `Fourth Category` |
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

## 출력 폴더
모든 생성물은 `output/` 아래 종류별 하위 폴더로 저장됩니다 (자동 생성):

| 폴더 | 파일 |
| --- | --- |
| `output/route/` | `route_<id>.tcx`, `route_<id>_cued.tcx` |
| `output/route_segments/` | `route_<id>_segments.json` |
| `output/segment/` | `segment_<id>.json` (단건 조회 캐시) |

## 캐시 (route_<id>_segments.json)
`output/route_segments/route_<id>_segments.json` 에 segment 응답과 TCX 누적거리 계산값을 함께 저장합니다.
재실행 시 Strava HTTP 요청을 재사용하고, cuesheet 단계도 이 cache 만 사용합니다.

각 segment 엔트리에는 다음이 포함됩니다:

- `order` — route 내 순서
- `segment_id`, `name`
- `start_point`, `end_point` — [lat, lng]
- `start_km`, `end_km`, `distance_km` — TCX 트랙 기준 누적거리
- `distance`, `elevation_gain`, `avg_grade`, `lowest_elev`, `highest_elev`, `elev_difference`, `climb_category`