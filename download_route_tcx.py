"""Strava route 의 TCX 파일을 다운로드 합니다.

사용법:
    python3 download_route_tcx.py <routeID> [output.tcx]

cookies.json 에 _strava4_session 쿠키가 있어야 합니다.
"""
import json
import os
import sys
import requests


def load_cookies(file_path=None):
    if file_path is None:
        file_path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "cookies.json"
        )
    if not os.path.exists(file_path):
        print(f"⚠️  {file_path} 없음 - 비로그인 상태로 시도합니다.", file=sys.stderr)
        return {}
    with open(file_path, "r", encoding="utf-8") as f:
        return json.load(f)


def download_route_tcx(route_id, output_path=None, cookies=None):
    """routeID 를 받아 TCX 파일을 다운로드 합니다."""
    if cookies is None:
        cookies = load_cookies()

    url = f"https://www.strava.com/routes/{route_id}/export_tcx"
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        ),
        "Accept": "application/vnd.garmin.tcx+xml, application/xml, */*",
        "Accept-Language": "ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7",
        "Referer": f"https://www.strava.com/routes/{route_id}",
    }

    r = requests.get(url, headers=headers, cookies=cookies, timeout=30, allow_redirects=True)

    if r.status_code != 200:
        raise RuntimeError(
            f"TCX 다운로드 실패: HTTP {r.status_code} (URL={r.url})"
        )

    # 로그인 페이지로 redirect 되었는지 검사
    body = r.text[:4096]
    if "<TrainingCenterDatabase" not in body and "TrainingCenterDatabase" not in r.text:
        raise RuntimeError(
            "TCX 응답이 아닙니다. 쿠키 만료 또는 라우트가 비공개일 수 있습니다."
        )

    if output_path is None:
        out_dir = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "output", "route"
        )
        os.makedirs(out_dir, exist_ok=True)
        output_path = os.path.join(out_dir, f"route_{route_id}.tcx")
    else:
        os.makedirs(os.path.dirname(os.path.abspath(output_path)) or ".", exist_ok=True)

    with open(output_path, "wb") as f:
        f.write(r.content)

    print(f"✅ TCX 다운로드 완료 → {output_path}")
    return output_path


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 download_route_tcx.py <routeID> [output.tcx]")
        sys.exit(1)
    route_id = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else None
    download_route_tcx(route_id, out)
