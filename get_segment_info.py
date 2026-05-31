"""Strava segment 페이지에서 상세 정보를 추출합니다.

사용법:
    python3 get_segment_info.py <segmentID>

cookies.json 에 _strava4_session 쿠키가 있어야 로그인 정보가 보입니다.
"""
import json
import os
import re

import requests
from bs4 import BeautifulSoup


def load_cookies(file_path=None):
    """외부 json 파일에서 쿠키를 읽어옵니다."""
    if file_path is None:
        file_path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "cookies.json"
        )
    if not os.path.exists(file_path):
        print(
            f"⚠️ 경고: {file_path} 파일이 없습니다. 비로그인 상태로 요청합니다."
        )
        return {}
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        print(f"⚠️ 쿠키 파일을 읽는 중 오류 발생: {e}")
        return {}


# 결과 키 ↔ 라벨 매핑
STAT_LABEL_MAP = [
    ("distance", ["Distance", "거리"]),
    ("elevation_gain", ["Elevation Gain", "획득 고도", "획득고도", "고도 상승"]),
    ("avg_grade", ["Avg Grade", "Average Grade", "평균 경사도", "평균경사도"]),
    ("lowest_elev", ["Lowest Elev", "Lowest Elevation", "최저 고도", "최저고도"]),
    ("highest_elev", ["Highest Elev", "Highest Elevation", "최고 고도", "최고고도"]),
    ("elev_difference", ["Elev Difference", "Elevation Difference", "고도 차이", "고도차"]),
    ("climb_category", ["Climb Category", "등반 카테고리", "등반카테고리"]),
]


def extract_pageprops(soup):
    """Strava segment 페이지의 __NEXT_DATA__ → props.pageProps 추출."""
    tag = soup.find("script", id="__NEXT_DATA__")
    if not tag or not tag.string:
        return None
    try:
        data = json.loads(tag.string)
    except (json.JSONDecodeError, ValueError):
        return None
    try:
        return data.get("props", {}).get("pageProps", {}) or {}
    except AttributeError:
        return None


def _latlng_from_streams(streams):
    if not isinstance(streams, dict):
        return None, None
    location = streams.get("location")
    if not (isinstance(location, list) and len(location) >= 2):
        return None, None
    first, last = location[0], location[-1]
    if not (
        isinstance(first, list) and len(first) == 2
        and isinstance(last, list) and len(last) == 2
    ):
        return None, None
    return (
        [float(first[0]), float(first[1])],
        [float(last[0]), float(last[1])],
    )


# 저장할 pageProps 하위 키 (요청 사양)
PAGEPROPS_KEYS = ("metadata", "measurements", "streams", "mapImages")


def _pageprops_subset(pageprops):
    if not isinstance(pageprops, dict):
        return {k: None for k in PAGEPROPS_KEYS}
    return {k: pageprops.get(k) for k in PAGEPROPS_KEYS}


def _format_distance(meters):
    if meters is None:
        return None
    try:
        v = float(meters)
    except (TypeError, ValueError):
        return None
    if v >= 1000:
        return f"{v / 1000:.2f} km"
    return f"{v:.0f} m"


def _format_meters(value):
    if value is None:
        return None
    try:
        v = float(value)
    except (TypeError, ValueError):
        return None
    return f"{v:.0f} m"


def _format_pct(value):
    if value is None:
        return None
    try:
        v = float(value)
    except (TypeError, ValueError):
        return None
    return f"{v:g}%"


def _normalize_climb_category(value):
    """climb_category 를 분류기 표준형으로 통일.

    'Category2' → '2', 'CategoryHC' → 'HC', 0/None/'NC' → None.
    (pageProps 는 'Category2' 형식으로 내려오므로 '2'/'HC' 로 정규화)
    """
    if value in (None, "", 0, "0"):
        return None
    s = re.sub(r"(?i)^category\s*", "", str(value).strip()).strip().upper()
    if s in ("", "0", "NC"):
        return None
    return s


def _result_from_pageprops(pageprops, segment_id):
    """저장된 pageProps subset 으로부터 legacy result dict 복원 (캐시 hit 용)."""
    result = {"segment_id": str(segment_id)}
    pageprops = pageprops or {}
    metadata = pageprops.get("metadata") or {}
    measurements = pageprops.get("measurements") or {}
    streams = pageprops.get("streams") or {}

    name = (
        metadata.get("name")
        or metadata.get("segmentName")
        or metadata.get("title")
    )
    result["name"] = (
        (name or "Unknown Segment Name").replace("☆", "").strip()
    )

    start, end = _latlng_from_streams(streams)
    result["start_point"] = start
    result["end_point"] = end

    def pick(*keys):
        # measurements 우선, 없으면 metadata 에서도 탐색 (climbCategory 는 metadata 에 있음)
        for src in (measurements, metadata):
            if not isinstance(src, dict):
                continue
            for k in keys:
                if src.get(k) is not None:
                    return src[k]
        return None

    result["distance"] = _format_distance(pick("distance"))
    result["elevation_gain"] = _format_meters(
        pick("elevGain", "elevationGain", "elevation_gain", "totalElevationGain")
    )
    result["avg_grade"] = _format_pct(
        pick("avgGrade", "averageGrade", "average_grade")
    )
    low = pick("elevLow", "elevationLow", "lowestElevation", "elevation_low")
    high = pick("elevHigh", "elevationHigh", "highestElevation", "elevation_high")
    result["lowest_elev"] = _format_meters(low)
    result["highest_elev"] = _format_meters(high)
    diff = pick("elevDifference", "elevationDifference", "elev_difference")
    if diff is None and low is not None and high is not None:
        try:
            diff = float(high) - float(low)
        except (TypeError, ValueError):
            diff = None
    result["elev_difference"] = _format_meters(diff)
    result["climb_category"] = _normalize_climb_category(
        pick("climbCategory", "climb_category")
    )

    for key, _ in STAT_LABEL_MAP:
        result.setdefault(key, None)
    return result


def _segment_cache_path(segment_id):
    """segment_{id}.json 캐시 파일 경로. output/segment/ 폴더 자동 생성."""
    out_dir = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "output", "segment"
    )
    os.makedirs(out_dir, exist_ok=True)
    return os.path.join(out_dir, f"segment_{segment_id}.json")


def get_strava_segment_info(segment_id, no_cache=False):
    """segment 상세 정보 JSON 문자열을 반환.

    - 캐시 파일(output/segment_<id>.json) 이 있으면 그 내용을 그대로 반환
    - no_cache=True 이면 캐시를 무시하고 새로 요청
    - 성공 응답만 캐시에 저장 (에러는 캐시하지 않음)
    """
    cache_path = _segment_cache_path(segment_id)

    if not no_cache and os.path.exists(cache_path):
        try:
            with open(cache_path, "r", encoding="utf-8") as f:
                cached = json.load(f)
            # 신규 포맷: {"props": {"pageProps": {...}}}
            if isinstance(cached, dict) and "props" in cached:
                pageprops = (
                    cached.get("props", {}).get("pageProps", {}) or {}
                )
                result = _result_from_pageprops(pageprops, segment_id)
                return json.dumps(result, ensure_ascii=False, indent=4)
            # 구 포맷: result dict 그대로 저장돼 있는 경우
            if isinstance(cached, dict):
                return json.dumps(cached, ensure_ascii=False, indent=4)
        except Exception:
            pass  # 손상되었으면 다시 요청

    url = f"https://www.strava.com/segments/{segment_id}"
    headers = {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7",
    }
    cookies = load_cookies()

    try:
        response = requests.get(url, headers=headers, cookies=cookies, timeout=15)
        if response.status_code != 200:
            return json.dumps(
                {"error": f"Failed to fetch data. Status code: {response.status_code}"},
                ensure_ascii=False,
            )

        soup = BeautifulSoup(response.text, "html.parser")

        # __NEXT_DATA__ 의 pageProps(JSON) 가 모든 정보의 단일 소스.
        # HTML DOM 을 긁지 않고, 캐시 hit 경로와 동일하게 JSON 으로만 구성한다.
        pageprops = extract_pageprops(soup)
        if not pageprops or not pageprops.get("metadata"):
            return json.dumps(
                {"error": "segment JSON(__NEXT_DATA__)을 찾지 못했습니다. 쿠키 만료/비공개 또는 페이지 레이아웃 변경일 수 있습니다. cookies.json의 _strava4_session 값을 갱신하세요."},
                ensure_ascii=False,
                indent=4,
            )

        result = _result_from_pageprops(pageprops, segment_id)
        result_json = json.dumps(result, ensure_ascii=False, indent=4)

        # 성공 응답만 캐시 저장 — 파일에는 props.pageProps 하위
        # metadata, measurements, streams, mapImages 만 저장한다.
        try:
            payload = {"props": {"pageProps": _pageprops_subset(pageprops)}}
            with open(cache_path, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False, indent=4)
        except Exception as e:
            print(f"⚠️ 캐시 저장 실패({cache_path}): {e}")
        return result_json

    except Exception as e:
        return json.dumps({"error": str(e)}, ensure_ascii=False)


if __name__ == "__main__":
    import sys
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    segment_id = args[0] if args else "9646037"
    no_cache = "--no-cache" in sys.argv
    print(get_strava_segment_info(segment_id, no_cache=no_cache))
