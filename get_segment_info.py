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

# 값으로 인식할 수 있는 단위 (숫자 + 단위 또는 카테고리 숫자)
VALUE_PATTERN = re.compile(
    r"^-?[\d,]+\.?\d*\s*(?:km|mi|m|ft|%|°|°)?$|^[0-9]$"
)


def match_stat_key(label_text):
    if not label_text:
        return None
    cleaned = label_text.strip().rstrip(":").strip()
    for key, labels in STAT_LABEL_MAP:
        for lbl in labels:
            if lbl.lower() == cleaned.lower():
                return key
    # 부분 매칭 (라벨이 더 큰 텍스트 안에 있는 경우)
    for key, labels in STAT_LABEL_MAP:
        for lbl in labels:
            if lbl in cleaned:
                return key
    return None


def find_value_near(label_node, label_text):
    """라벨 노드 주변에서 수치 값을 찾는다."""
    parent = label_node.find_parent()
    if not parent:
        return None

    # 1) 같은 부모 안에 strong/b/span.value 등 강조 태그
    for tag in parent.find_all(["strong", "b"]):
        v = tag.get_text(strip=True)
        if v and v != label_text:
            return v

    # 2) dt → dd 패턴 (다음 형제)
    if parent.name == "dt":
        sib = parent.find_next_sibling("dd")
        if sib:
            return sib.get_text(strip=True)

    # 3) td 라벨 → 다음 td 값
    if parent.name == "td":
        sib = parent.find_next_sibling("td")
        if sib:
            return sib.get_text(strip=True)

    # 4) li 안에 라벨과 값이 함께 (전체 텍스트 - 라벨)
    full_text = parent.get_text(separator=" ", strip=True)
    leftover = full_text.replace(label_text, "").strip(": \t")
    if leftover and VALUE_PATTERN.match(leftover.split()[0] if leftover.split() else ""):
        return leftover

    # 5) 부모의 부모 단위까지 확장하여 형제에서 수치 검색
    grand = parent.parent
    if grand:
        sib = parent.find_next_sibling()
        if sib:
            v = sib.get_text(strip=True)
            if v:
                return v
        sib2 = grand.find_next_sibling()
        if sib2:
            v = sib2.get_text(strip=True)
            if v and len(v) < 30:
                return v

    return leftover or None


def parse_stats(soup, result):
    """모든 stat 항목 파싱 (신규 레이아웃 + 구 레이아웃 모두 대응)."""

    # A. 구 레이아웃: inline-stats / segment-stats ul
    stats_lists = soup.find_all(
        "ul", class_=re.compile(r"inline-stats|segment-stats")
    )
    for stats_list in stats_lists:
        for item in stats_list.find_all("li"):
            text_content = item.get_text(separator=" ", strip=True)
            strong_tag = item.find(["strong", "b"])
            val = strong_tag.get_text(strip=True) if strong_tag else ""
            key = match_stat_key(text_content)
            if key and val and not result.get(key):
                result[key] = val

    # B. 일반 라벨 텍스트 → 값
    all_labels = []
    for _key, labels in STAT_LABEL_MAP:
        all_labels.extend(labels)
    label_re = re.compile(
        r"^\s*(?:" + "|".join(re.escape(l) for l in all_labels) + r")\s*:?\s*$"
    )

    for node in soup.find_all(string=label_re):
        label_text = str(node).strip().rstrip(":").strip()
        key = match_stat_key(label_text)
        if not key or result.get(key):
            continue
        val = find_value_near(node, label_text)
        if val:
            val = val.strip().strip(":").strip()
            if val and val != label_text:
                result[key] = val

    # C. 라벨이 본문에 섞여있는 경우 (예: "Distance 5.04 km")
    if not all(result.get(k) for k, _ in STAT_LABEL_MAP):
        text = soup.get_text(separator="\n")
        patterns = {
            "distance": r"(?:Distance|거리)[\s:]*([\d,]+\.?\d*\s*(?:km|mi|m))",
            "elevation_gain": r"(?:Elevation\s*Gain|획득\s*고도)[\s:]*([\d,]+\.?\d*\s*(?:m|ft))",
            "avg_grade": r"(?:Avg\s*Grade|Average\s*Grade|평균\s*경사도)[\s:]*([\-\d.]+\s*%)",
            "lowest_elev": r"(?:Lowest\s*Elev(?:ation)?|최저\s*고도)[\s:]*([\d,]+\.?\d*\s*(?:m|ft))",
            "highest_elev": r"(?:Highest\s*Elev(?:ation)?|최고\s*고도)[\s:]*([\d,]+\.?\d*\s*(?:m|ft))",
            "elev_difference": r"(?:Elev(?:ation)?\s*Difference|고도\s*차이)[\s:]*([\d,]+\.?\d*\s*(?:m|ft))",
            "climb_category": r"(?:Climb\s*Category|등반\s*카테고리)[\s:]*([0-9HC]+)",
        }
        for key, pat in patterns.items():
            if result.get(key):
                continue
            m = re.search(pat, text, flags=re.IGNORECASE)
            if m:
                result[key] = m.group(1).strip()


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


def parse_latlng(soup):
    """기존 호환용. 내부적으로 extract_pageprops 를 사용."""
    pageprops = extract_pageprops(soup)
    if not pageprops:
        return None, None
    return _latlng_from_streams(pageprops.get("streams"))


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
        for k in keys:
            if isinstance(measurements, dict) and measurements.get(k) is not None:
                return measurements[k]
        return None

    result["distance"] = _format_distance(pick("distance"))
    result["elevation_gain"] = _format_meters(
        pick("elevationGain", "elevation_gain", "totalElevationGain")
    )
    result["avg_grade"] = _format_pct(
        pick("averageGrade", "avgGrade", "average_grade")
    )
    result["lowest_elev"] = _format_meters(
        pick("elevationLow", "lowestElevation", "elevation_low")
    )
    result["highest_elev"] = _format_meters(
        pick("elevationHigh", "highestElevation", "elevation_high")
    )
    result["elev_difference"] = _format_meters(
        pick("elevationDifference", "elev_difference")
    )
    cc = pick("climbCategory", "climb_category")
    if cc is not None:
        result["climb_category"] = str(cc)

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
        result = {"segment_id": str(segment_id)}

        # 이름
        title_heading = soup.find("h1")
        result["name"] = (
            title_heading.get_text().replace("☆", "").strip()
            if title_heading
            else "Unknown Segment Name"
        )

        if "Log in to see" in result["name"]:
            return json.dumps(
                {"error": "쿠키가 만료되었거나 올바르지 않아 로그인 페이지로 리다이렉트되었습니다. cookies.json의 _strava4_session 값을 갱신하세요."},
                ensure_ascii=False,
                indent=4,
            )

        # __NEXT_DATA__ pageProps 1회 추출 (좌표/저장 양쪽에서 사용)
        pageprops = extract_pageprops(soup) or {}

        # 좌표
        start_point, end_point = _latlng_from_streams(pageprops.get("streams"))
        result["start_point"] = start_point
        result["end_point"] = end_point

        # 스탯 (HTML 파싱)
        parse_stats(soup, result)

        # 누락 키 채우기
        for key, _ in STAT_LABEL_MAP:
            result.setdefault(key, None)

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
