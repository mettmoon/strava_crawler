"""Strava route 페이지에서 segment 목록을 추출하여 route_<id>_segments.json 을 생성합니다.

사용법:
    python3 extract_segments.py <routeID> [--tcx route.tcx]

동작 순서:
    1. route 페이지(HTML) 를 받아 순서대로 segment ID 목록을 추출
    2. 각 segment 에 대해 get_segment_info.py 의 함수를 호출하여 상세 정보 수집
    3. TCX 트랙포인트로부터 누적거리를 계산하여 cache 에 함께 저장
    4. output/route_<id>_segments.json 에 저장하여 cuesheet 단계 재사용
"""
import argparse
import json
import math
import os
import re
import sys
import time
import xml.etree.ElementTree as ET
from collections import OrderedDict

import requests
from bs4 import BeautifulSoup

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from get_segment_info import (  # noqa: E402
    get_strava_segment_info,
    load_cookies,
)


# ---------------------------------------------------------------------------
# 1. route 페이지에서 segment ID 순서대로 추출
# ---------------------------------------------------------------------------
def fetch_route_html(route_id, cookies):
    url = f"https://www.strava.com/routes/{route_id}"
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        ),
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7",
    }
    r = requests.get(url, headers=headers, cookies=cookies, timeout=20)
    if r.status_code != 200:
        raise RuntimeError(f"route 페이지 요청 실패: HTTP {r.status_code}")
    return r.text


def extract_segment_ids(html):
    """route HTML 에서 순서대로 segment id 를 뽑아냅니다."""
    seg_ids = []
    seen = set()

    def push(sid):
        s = str(sid).strip()
        if s.isdigit() and s not in seen:
            seen.add(s)
            seg_ids.append(s)

    soup = BeautifulSoup(html, "html.parser")
    for el in soup.find_all(attrs={"data-segment-id": True}):
        push(el.get("data-segment-id"))

    for m in re.finditer(r'href="/segments/(\d+)"', html):
        push(m.group(1))

    json_block = re.search(r'"segments"\s*:\s*\[(.*?)\]', html, flags=re.DOTALL)
    if json_block:
        for m in re.finditer(r'"(?:segment_id|id)"\s*:\s*(\d+)', json_block.group(1)):
            push(m.group(1))

    if not seg_ids:
        for m in re.finditer(r'segment[_-]?id["\']?\s*[:=]\s*["\']?(\d+)', html, flags=re.IGNORECASE):
            push(m.group(1))

    return seg_ids


# ---------------------------------------------------------------------------
# 2. TCX 트랙포인트 → 누적거리 계산
# ---------------------------------------------------------------------------
def haversine_km(lat1, lon1, lat2, lon2):
    R = 6371.0088
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def parse_tcx_trackpoints(tcx_path):
    """TCX 에서 [(lat, lon, ele, time_str, cum_km)] 리스트를 반환."""
    tree = ET.parse(tcx_path)
    root = tree.getroot()
    pts = []

    def find_all_local(node, local_name):
        return [e for e in node.iter() if e.tag.split("}")[-1] == local_name]

    trackpoints = find_all_local(root, "Trackpoint")
    cum = 0.0
    prev = None
    for tp in trackpoints:
        lat_el = next((c for c in tp.iter() if c.tag.split("}")[-1] == "LatitudeDegrees"), None)
        lon_el = next((c for c in tp.iter() if c.tag.split("}")[-1] == "LongitudeDegrees"), None)
        ele_el = next((c for c in tp.iter() if c.tag.split("}")[-1] == "AltitudeMeters"), None)
        time_el = next((c for c in tp.iter() if c.tag.split("}")[-1] == "Time"), None)
        if lat_el is None or lon_el is None:
            continue
        try:
            lat = float(lat_el.text)
            lon = float(lon_el.text)
        except (TypeError, ValueError):
            continue
        ele = float(ele_el.text) if ele_el is not None and ele_el.text else None
        ts = time_el.text if time_el is not None else None
        if prev is not None:
            cum += haversine_km(prev[0], prev[1], lat, lon)
        pts.append((lat, lon, ele, ts, cum))
        prev = (lat, lon)
    return pts


def nearest_point_index(pts, lat, lon, start_idx=0):
    if lat is None or lon is None:
        return None
    best_i, best_d = None, float("inf")
    for i in range(start_idx, len(pts)):
        d = haversine_km(pts[i][0], pts[i][1], lat, lon)
        if d < best_d:
            best_d = d
            best_i = i
    return best_i


def parse_distance_km(text):
    """'5.04 km' / '500 m' / '1.2 mi' → km(float)."""
    if not text:
        return None
    m = re.search(r"(-?[\d,]+\.?\d*)\s*(km|mi|m)?", str(text))
    if not m:
        return None
    val = float(m.group(1).replace(",", ""))
    unit = (m.group(2) or "km").lower()
    if unit == "mi":
        return val * 1.609344
    if unit == "m":
        return val / 1000.0
    return val


# ---------------------------------------------------------------------------
# 3. 메인 동작: cache 생성
# ---------------------------------------------------------------------------
def extract_to_cache(route_id, tcx_path, cache_path, sleep_sec=1.2):
    """route → segment 정보를 route_<id>_segments.json 에 저장."""
    cookies = load_cookies()

    print("▶ route 페이지에서 segment 목록 추출 중...")
    html = fetch_route_html(route_id, cookies)
    seg_ids = extract_segment_ids(html)
    if not seg_ids:
        raise RuntimeError("segment ID 를 추출하지 못했습니다.")
    print(f"  → {len(seg_ids)} 개 발견")

    print(f"▶ TCX 트랙 파싱 중: {tcx_path}")
    pts = parse_tcx_trackpoints(tcx_path)
    if not pts:
        raise RuntimeError("TCX 에 trackpoint 가 없습니다.")
    print(f"  → trackpoint {len(pts)} 개, 총 거리 {pts[-1][4]:.2f} km")

    # 기존 캐시 로드 (Strava 응답 재사용)
    cache = {}
    if os.path.exists(cache_path):
        try:
            with open(cache_path, "r", encoding="utf-8") as f:
                cache = json.load(f)
        except Exception:
            cache = {}

    enriched = OrderedDict()
    search_start = 0

    for idx, sid in enumerate(seg_ids, start=1):
        print(f"  [{idx}/{len(seg_ids)}] segment {sid} ...", end="", flush=True)

        info = cache.get(sid)
        if not info or info.get("error"):
            raw = get_strava_segment_info(sid)
            try:
                info = json.loads(raw)
            except json.JSONDecodeError:
                info = {"error": "json decode failed", "raw": raw}
            if sleep_sec > 0:
                time.sleep(sleep_sec)

        if "error" in info:
            print(f"  ⚠️ {info['error']}")
            continue

        # trackpoint 기반 누적거리 계산
        start_pt = info.get("start_point") or [None, None]
        end_pt = info.get("end_point") or [None, None]
        nearest_start = nearest_point_index(pts, start_pt[0], start_pt[1], start_idx=search_start)
        start_km = pts[nearest_start][4] if nearest_start is not None else None

        dist_km = parse_distance_km(info.get("distance"))
        if dist_km is None and nearest_start is not None and end_pt[0] is not None:
            ne = nearest_point_index(pts, end_pt[0], end_pt[1], start_idx=nearest_start)
            if ne is not None and ne > nearest_start:
                dist_km = pts[ne][4] - start_km

        end_km = (start_km + dist_km) if (start_km is not None and dist_km is not None) else None

        info["order"] = idx
        info["start_km"] = round(start_km, 3) if start_km is not None else None
        info["end_km"] = round(end_km, 3) if end_km is not None else None
        info["distance_km"] = round(dist_km, 3) if dist_km is not None else None

        enriched[sid] = info
        if nearest_start is not None:
            search_start = nearest_start
        print(" ok")

    cache.update(enriched)
    os.makedirs(os.path.dirname(os.path.abspath(cache_path)) or ".", exist_ok=True)
    with open(cache_path, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False, indent=2)
    print(f"✅ segments json 저장 → {cache_path} ({len(enriched)} segments)")
    return enriched


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("route_id")
    ap.add_argument("--tcx", help="TCX 파일 경로 (없으면 output/route_<id>.tcx 가정)")
    ap.add_argument("--cache", default=None, help="segment 캐시 경로")
    ap.add_argument("--sleep", type=float, default=1.2, help="segment 요청 간 대기(초)")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    route_dir = os.path.join(here, "output", "route")
    seg_dir = os.path.join(here, "output", "route_segments")
    os.makedirs(route_dir, exist_ok=True)
    os.makedirs(seg_dir, exist_ok=True)

    tcx_path = args.tcx or os.path.join(route_dir, f"route_{args.route_id}.tcx")
    cache_path = args.cache or os.path.join(seg_dir, f"route_{args.route_id}_segments.json")

    if not os.path.exists(tcx_path):
        print(f"❌ TCX 파일이 없습니다: {tcx_path}", file=sys.stderr)
        print("   먼저 download_route_tcx.py 로 받으세요.", file=sys.stderr)
        sys.exit(1)

    extract_to_cache(args.route_id, tcx_path, cache_path, args.sleep)


if __name__ == "__main__":
    main()
