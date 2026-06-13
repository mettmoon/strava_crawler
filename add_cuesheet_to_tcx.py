"""route_<id>_segments.json 의 segment 정보를 읽어 TCX <CoursePoint> 를 추가합니다.

사용법:
    python3 add_cuesheet_to_tcx.py --tcx route.tcx [--cache route_<id>_segments.json]
                                   [--out route_cued.tcx] [--min-category 2]

규칙:
  - 시작 지점: climb_category 가 있으면 그에 맞는 카테고리(First~Fourth/Hors Category),
               없거나 0 이면 Sprint
  - 종료 지점: 항상 Summit
  - 시작/종료 좌표에 가장 가까운 trackpoint 위치에 CoursePoint 삽입
  - CoursePoint 는 TCX 의 <Course> 안 <Track> 다음에 들어가야 합니다 (TCX 스키마 순서)
"""
import argparse
import json
import math
import os
import re
import sys
import xml.etree.ElementTree as ET


TCX_NS = "http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"


def haversine_km(lat1, lon1, lat2, lon2):
    R = 6371.0088
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _local(tag):
    return tag.split("}")[-1]


def parse_trackpoints(course_el):
    """course_el 의 모든 Trackpoint 노드 자체를 lat/lon 과 함께 반환."""
    pts = []
    for tp in course_el.iter():
        if _local(tp.tag) != "Trackpoint":
            continue
        lat = lon = ele = ts = None
        for c in tp:
            ln = _local(c.tag)
            if ln == "Position":
                for cc in c:
                    cn = _local(cc.tag)
                    if cn == "LatitudeDegrees":
                        lat = float(cc.text)
                    elif cn == "LongitudeDegrees":
                        lon = float(cc.text)
            elif ln == "AltitudeMeters" and c.text:
                try:
                    ele = float(c.text)
                except ValueError:
                    pass
            elif ln == "Time" and c.text:
                ts = c.text
        if lat is None or lon is None:
            continue
        pts.append({"tp": tp, "lat": lat, "lon": lon, "ele": ele, "time": ts})
    return pts


def nearest_idx(pts, lat, lon, start_idx=0):
    if lat is None or lon is None:
        return None
    best_i, best_d = None, float("inf")
    for i in range(start_idx, len(pts)):
        d = haversine_km(pts[i]["lat"], pts[i]["lon"], lat, lon)
        if d < best_d:
            best_d, best_i = d, i
    return best_i


# Strava climb_category → TCX CoursePoint PointType (Garmin TCX XSD values)
CATEGORY_POINT_TYPE = {
    "1": "1st Category",
    "2": "2nd Category",
    "3": "3rd Category",
    "4": "4th Category",
    "HC": "Hors Category",
}

# 등급 순서 점수 (높을수록 어려움). 카테고리 없음 = 0
CATEGORY_RANK = {"4": 1, "3": 2, "2": 3, "1": 4, "HC": 5}


def _category_key(climb_category):
    if climb_category in (None, "", 0, "0"):
        return None
    # 'Category2' / 'CategoryHC' 형식도 방어적으로 '2' / 'HC' 로 정규화
    key = re.sub(r"(?i)^category\s*", "", str(climb_category).strip()).strip().upper()
    if key in ("", "0", "NC"):
        return None
    return key


def start_point_type(climb_category):
    """업힐 카테고리 → PointType. 카테고리 없거나 0 이면 Sprint."""
    key = _category_key(climb_category)
    if key is None:
        return "Sprint"
    return CATEGORY_POINT_TYPE.get(key, "Sprint")


def category_rank(climb_category):
    """등급 → 점수 (없음=0, 4=1, ..., HC=5)."""
    key = _category_key(climb_category)
    return CATEGORY_RANK.get(key, 0) if key else 0


def load_cache(cache_path):
    if cache_path and os.path.exists(cache_path):
        try:
            with open(cache_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


def ns(name):
    """default namespace 적용된 element 생성용 tag."""
    return f"{{{TCX_NS}}}{name}"


def make_course_point(name, ts, lat, lon, ele, point_type, notes=None, allow_empty_name=False):
    cp = ET.Element(ns("CoursePoint"))
    n = ET.SubElement(cp, ns("Name"))
    # CoursePoint Name 은 호환성을 위해 32자로 잘라줌 (일부 기기/플랫폼에서 길이 제한)
    if allow_empty_name:
        n.text = (name or "")[:32]
    else:
        n.text = (name or "Segment")[:32]
    if ts:
        t = ET.SubElement(cp, ns("Time"))
        t.text = ts
    pos = ET.SubElement(cp, ns("Position"))
    ET.SubElement(pos, ns("LatitudeDegrees")).text = f"{lat:.7f}"
    ET.SubElement(pos, ns("LongitudeDegrees")).text = f"{lon:.7f}"
    if ele is not None:
        ET.SubElement(cp, ns("AltitudeMeters")).text = f"{ele:.2f}"
    ET.SubElement(cp, ns("PointType")).text = point_type
    if notes:
        ET.SubElement(cp, ns("Notes")).text = notes[:255]
    return cp


def _norm_dist(dist):
    """'0.71 km' → '0.71km' (예시 포맷에 맞춰 공백 제거)."""
    if not dist:
        return ""
    return str(dist).replace(" ", "")


def _fmt_grade(grade):
    """경사도를 소수 첫째자리까지로 표기. '7.86396%' → '7.9%', '7%' → '7.0%'."""
    if grade in (None, ""):
        return grade
    m = re.search(r"-?\d+(?:\.\d+)?", str(grade))
    if not m:
        return grade
    return f"{round(float(m.group()), 1):.1f}%"


# 경사도 구분 임계값(%)과 시작점 prefix(↗ 오르막 / → 평지 / ↘ 내리막)
GRADE_FLAT_THRESHOLD = 1.5
GRADE_ARROW = {"up": "↗", "flat": "→", "down": "↘"}


def _resolve_seg_name(name):
    """segment 이름 정리 (종료 지점 Name/Notes 용).

      1) 'by ...' (by 포함 그 뒤 전부) 제거 → strip
      2) '#...' (# 포함 그 뒤 전부) 제거 → strip
      3) 맨 앞뒤 특수문자(비 word 문자) 제거 → strip

    예) '떙기러가즈아~ by 팀바둑이'        → '떙기러가즈아'
        '🜲 아우라지-암내교 21km TT #령재치' → '아우라지-암내교 21km TT'
    """
    if not name:
        return name or ""
    s = str(name)
    s = re.sub(r"\s*\bby\b.*$", "", s, flags=re.IGNORECASE).strip()  # 1)
    s = re.sub(r"\s*#.*$", "", s).strip()                            # 2)
    s = re.sub(r"^[^\w]+|[^\w]+$", "", s, flags=re.UNICODE).strip()  # 3) 앞뒤
    return s


def _grade_class(grade):
    """avgGrade → 'up'(>1.5%) / 'down'(<-1.5%) / 'flat'([-1.5, 1.5]%).

    grade 값을 파싱하지 못하면 평지('flat')로 간주.
    """
    if grade in (None, ""):
        return "flat"
    m = re.search(r"-?\d+(?:\.\d+)?", str(grade))
    if not m:
        return "flat"
    val = float(m.group())
    if val > GRADE_FLAT_THRESHOLD:
        return "up"
    if val < -GRADE_FLAT_THRESHOLD:
        return "down"
    return "flat"


def insert_course_points(course_el, entries, for_rwgps=False):
    """entries(좌표/메타 정보 리스트)로 CoursePoint 를 만들어 course_el 에 삽입.

    for_rwgps=True 인 경우:
      - Description(Notes): segment 시작점은 거리/경사도 (예: '↗3.3km, 5.6%'),
        종료점은 segment 이름 (예: '🏁만항재 북-남')
      - 시작점 prefix: 오르막 ↗ / 평지 → / 내리막 ↘, 종료점 prefix: 🏁
      - Name 에도 Notes 와 동일한 값을 넣음 (Name 길이 제한 32자로 잘릴 수 있음)
    """
    # 기존 CoursePoint 제거 (재실행 시 중복 방지)
    for c in [c for c in list(course_el) if _local(c.tag) == "CoursePoint"]:
        course_el.remove(c)

    new_cps = []  # (tp_index, CoursePoint)
    for e in entries:
        if for_rwgps:
            if e["is_start"]:
                body = ", ".join(p for p in [_norm_dist(e.get("dist")), _fmt_grade(e.get("grade"))] if p)
                # 시작 지점 prefix: 오르막 ↗ / 평지 → / 내리막 ↘
                notes = GRADE_ARROW.get(e.get("grade_class"), "→") + body
            else:
                # 종료 지점: segment 이름을 정리(by/#/선행 특수문자 제거)한 뒤 🏁 prefix
                notes = "🏁" + _resolve_seg_name(e["seg_name"])
            cp = make_course_point(
                name=notes,
                ts=e["time"], lat=e["lat"], lon=e["lon"], ele=e["ele"],
                point_type=e["point_type"], notes=notes, allow_empty_name=True,
            )
        else:
            cp = make_course_point(
                name=e["name"],
                ts=e["time"], lat=e["lat"], lon=e["lon"], ele=e["ele"],
                point_type=e["point_type"], notes=e["notes"],
            )
        new_cps.append((e["idx"], cp))

    # trackpoint 인덱스 순서로 정렬
    new_cps.sort(key=lambda x: x[0])

    # TCX 스키마: Course 안에서 CoursePoint 는 Track 다음에 옵니다.
    track_indices = [i for i, c in enumerate(list(course_el)) if _local(c.tag) == "Track"]
    insert_at = (track_indices[-1] + 1) if track_indices else len(list(course_el))
    for offset, (_idx, cp) in enumerate(new_cps):
        course_el.insert(insert_at + offset, cp)
    return len(new_cps)


def find_course(root):
    for el in root.iter():
        if _local(el.tag) == "Course":
            return el
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tcx", required=True, help="입력 TCX 파일")
    ap.add_argument("--out", default=None, help="출력 TCX 경로 (기본: output/<tcx>_cued.tcx)")
    ap.add_argument("--cache", default=None, help="route_<id>_segments.json 경로")
    ap.add_argument(
        "--min-category",
        default=None,
        help="포함할 최소 카테고리 (4|3|2|1|HC). 미지정 시 카테고리 무관 전체 포함.",
    )
    args = ap.parse_args()

    min_rank = category_rank(args.min_category) if args.min_category else 0

    here = os.path.dirname(os.path.abspath(__file__))
    route_dir = os.path.join(here, "output", "route")
    seg_dir = os.path.join(here, "output", "route_segments")
    os.makedirs(route_dir, exist_ok=True)
    os.makedirs(seg_dir, exist_ok=True)

    # TCX 파일명에서 base 추출 (예: route_3495269006478904270.tcx → route_3495269006478904270)
    base = os.path.splitext(os.path.basename(args.tcx))[0]
    if base.endswith("_cued"):
        base = base[: -len("_cued")]

    cache_path = args.cache or os.path.join(seg_dir, f"{base}_segments.json")
    out_path = args.out or os.path.join(route_dir, f"{base}_cued.tcx")
    # rwgps 전용 파일: <out>_for_rwgps.tcx
    out_base, out_ext = os.path.splitext(out_path)
    rwgps_out_path = f"{out_base}_for_rwgps{out_ext}"

    if not os.path.exists(args.tcx):
        sys.exit(f"❌ TCX 파일 없음: {args.tcx}")
    if not os.path.exists(cache_path):
        sys.exit(f"❌ segments json 없음: {cache_path}\n   먼저 extract_segments.py 또는 build_route.py 를 실행하세요.")

    # TCX 파싱 (네임스페이스 보존)
    ET.register_namespace("", TCX_NS)
    tree = ET.parse(args.tcx)
    root = tree.getroot()

    # Course 찾기
    course_el = None
    for el in root.iter():
        if _local(el.tag) == "Course":
            course_el = el
            break
    if course_el is None:
        sys.exit("❌ TCX 에 <Course> 가 없습니다 (activity TCX 인가요?). 라우트 TCX 가 필요합니다.")

    pts = parse_trackpoints(course_el)
    if not pts:
        sys.exit("❌ TCX 에 trackpoint 가 없습니다.")
    print(f"📍 trackpoint {len(pts)} 개")

    cache = load_cache(cache_path)
    if not cache:
        sys.exit(f"❌ segments json 에 segment 정보가 없습니다: {cache_path}")

    # order 순으로 정렬 (없으면 dict 삽입 순서 유지)
    sorted_items = sorted(
        cache.items(),
        key=lambda kv: kv[1].get("order", float("inf")) if isinstance(kv[1], dict) else float("inf"),
    )
    print(f"📄 {os.path.basename(cache_path)}: {len(sorted_items)} segments")

    # CoursePoint 메타 정보 수집 (실제 element 생성/삽입은 출력 파일별로 수행)
    entries = []  # 각 항목: idx/time/lat/lon/ele/point_type/name/notes/seg_name/is_start/dist/grade
    for sid, info in sorted_items:
        if not isinstance(info, dict) or info.get("error"):
            continue
        name = (info.get("name") or "Segment").strip()

        # 카테고리 필터
        if min_rank > 0 and category_rank(info.get("climb_category")) < min_rank:
            continue

        start_pt = info.get("start_point") or [None, None]
        end_pt = info.get("end_point") or [None, None]
        if start_pt[0] is None and end_pt[0] is None:
            print(f"  ⚠️ segment {sid}: 좌표 없음 - skip")
            continue

        # Notes 에 요약 정보 (기본 _cued.tcx 용)
        notes_bits = []
        if info.get("distance"):
            notes_bits.append(f"Dist {info['distance']}")
        if info.get("elev_difference"):
            notes_bits.append(f"Elev {info['elev_difference']}")
        if info.get("avg_grade"):
            notes_bits.append(f"Grade {_fmt_grade(info['avg_grade'])}")
        if info.get("climb_category") not in (None, "", "0", 0):
            notes_bits.append(f"Cat {info['climb_category']}")
        notes_bits.append(f"id:{sid}")
        notes = " | ".join(notes_bits)

        order = info.get("order", "?")

        # 경사도 구분: 오르막/평지/내리막
        gclass = _grade_class(info.get("avg_grade"))

        # 시작 지점
        idx_s = nearest_idx(pts, start_pt[0], start_pt[1]) if start_pt[0] is not None else None
        if idx_s is not None:
            # 오르막은 카테고리(또는 Sprint), 평지·내리막은 Straight
            stype = start_point_type(info.get("climb_category")) if gclass == "up" else "Straight"
            entries.append({
                "idx": idx_s,
                "time": pts[idx_s]["time"],
                "lat": pts[idx_s]["lat"],
                "lon": pts[idx_s]["lon"],
                "ele": pts[idx_s]["ele"],
                "point_type": stype,
                "name": name,
                "notes": notes,
                "seg_name": name,
                "is_start": True,
                "dist": info.get("distance"),
                "grade": info.get("avg_grade"),
                "grade_class": gclass,
            })
            print(f"  + {order:>3}. {(name + ' 시작')[:30]:30s} [{stype}] @ tp#{idx_s}")

        # 종료 지점 (시작점 이후만 탐색)
        if end_pt[0] is not None:
            search_from = (idx_s + 1) if idx_s is not None else 0
            idx_e = nearest_idx(pts, end_pt[0], end_pt[1], start_idx=search_from)
            if idx_e is not None:
                # 내리막 종료는 Valley, 그 외는 Summit
                etype = "Valley" if gclass == "down" else "Summit"
                entries.append({
                    "idx": idx_e,
                    "time": pts[idx_e]["time"],
                    "lat": pts[idx_e]["lat"],
                    "lon": pts[idx_e]["lon"],
                    "ele": pts[idx_e]["ele"],
                    "point_type": etype,
                    "name": f"{name} 종료",
                    "notes": notes,
                    "seg_name": name,
                    "is_start": False,
                    "dist": info.get("distance"),
                    "grade": info.get("avg_grade"),
                    "grade_class": gclass,
                })
                print(f"  + {order:>3}. {(name + ' 종료')[:30]:30s} [{etype}] @ tp#{idx_e}")

    # 1) 기본 출력 (_cued.tcx)
    n = insert_course_points(course_el, entries, for_rwgps=False)
    tree.write(out_path, encoding="utf-8", xml_declaration=True)
    print(f"✅ {n} 개 CoursePoint 추가 → {out_path}")

    # 2) RWGPS 전용 출력 (_cued_for_rwgps.tcx)
    #    - Name 미사용 / Description: 시작점=거리·경사도, 정상=이름
    tree_rwgps = ET.parse(args.tcx)
    course_el_rwgps = find_course(tree_rwgps.getroot())
    n_rwgps = insert_course_points(course_el_rwgps, entries, for_rwgps=True)
    tree_rwgps.write(rwgps_out_path, encoding="utf-8", xml_declaration=True)
    print(f"✅ {n_rwgps} 개 CoursePoint 추가 (RWGPS) → {rwgps_out_path}")


if __name__ == "__main__":
    main()
