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


# Strava climb_category → TCX CoursePoint PointType
CATEGORY_POINT_TYPE = {
    "1": "First Category",
    "2": "Second Category",
    "3": "Third Category",
    "4": "Fourth Category",
    "HC": "Hors Category",
}

# 등급 순서 점수 (높을수록 어려움). 카테고리 없음 = 0
CATEGORY_RANK = {"4": 1, "3": 2, "2": 3, "1": 4, "HC": 5}


def _category_key(climb_category):
    if climb_category in (None, "", 0, "0"):
        return None
    return str(climb_category).strip().upper()


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


def make_course_point(name, ts, lat, lon, ele, point_type, notes=None):
    cp = ET.Element(ns("CoursePoint"))
    n = ET.SubElement(cp, ns("Name"))
    # CoursePoint Name 은 TCX 스키마상 최대 10자 (실제로는 더 길어도 동작하지만 호환성을 위해 잘라줌)
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

    # 기존 CoursePoint 제거 (재실행 시 중복 방지)
    existing_cp = [c for c in list(course_el) if _local(c.tag) == "CoursePoint"]
    for c in existing_cp:
        course_el.remove(c)
    if existing_cp:
        print(f"♻️  기존 CoursePoint {len(existing_cp)} 개 제거")

    new_cps = []  # (tp_index, CoursePoint) - 마지막에 tp_index 순으로 정렬
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

        # Notes 에 요약 정보
        notes_bits = []
        if info.get("distance"):
            notes_bits.append(f"Dist {info['distance']}")
        if info.get("elev_difference"):
            notes_bits.append(f"Elev {info['elev_difference']}")
        if info.get("avg_grade"):
            notes_bits.append(f"Grade {info['avg_grade']}")
        if info.get("climb_category") not in (None, "", "0", 0):
            notes_bits.append(f"Cat {info['climb_category']}")
        notes_bits.append(f"id:{sid}")
        notes = " | ".join(notes_bits)

        order = info.get("order", "?")

        # 시작 지점
        idx_s = nearest_idx(pts, start_pt[0], start_pt[1]) if start_pt[0] is not None else None
        if idx_s is not None:
            stype = start_point_type(info.get("climb_category"))
            cp = make_course_point(
                name=name,
                ts=pts[idx_s]["time"],
                lat=pts[idx_s]["lat"],
                lon=pts[idx_s]["lon"],
                ele=pts[idx_s]["ele"],
                point_type=stype,
                notes=notes,
            )
            new_cps.append((idx_s, cp))
            print(f"  + {order:>3}. {(name + ' 시작')[:30]:30s} [{stype}] @ tp#{idx_s}")

        # 종료 지점 (시작점 이후만 탐색)
        if end_pt[0] is not None:
            search_from = (idx_s + 1) if idx_s is not None else 0
            idx_e = nearest_idx(pts, end_pt[0], end_pt[1], start_idx=search_from)
            if idx_e is not None:
                cp = make_course_point(
                    name=f"{name} 종료",
                    ts=pts[idx_e]["time"],
                    lat=pts[idx_e]["lat"],
                    lon=pts[idx_e]["lon"],
                    ele=pts[idx_e]["ele"],
                    point_type="Summit",
                    notes=notes,
                )
                new_cps.append((idx_e, cp))
                print(f"  + {order:>3}. {(name + ' 종료')[:30]:30s} [Summit] @ tp#{idx_e}")

    # trackpoint 인덱스 순서로 정렬
    new_cps.sort(key=lambda x: x[0])

    # TCX 스키마: Course 안에서 CoursePoint 는 Track 다음, Notes 등 보다 뒤에 옵니다.
    # 보수적으로 Track 의 끝 다음 위치에 삽입합니다.
    track_indices = [i for i, c in enumerate(list(course_el)) if _local(c.tag) == "Track"]
    insert_at = (track_indices[-1] + 1) if track_indices else len(list(course_el))
    for offset, (_idx, cp) in enumerate(new_cps):
        course_el.insert(insert_at + offset, cp)

    # 출력
    tree.write(out_path, encoding="utf-8", xml_declaration=True)
    print(f"✅ {len(new_cps)} 개 CoursePoint 추가 → {out_path}")


if __name__ == "__main__":
    main()
