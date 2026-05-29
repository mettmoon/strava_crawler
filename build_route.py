"""routeID 하나로 다음 과정을 모두 수행하는 통합 스크립트.

    1) Strava route 의 TCX 다운로드   (download_route_tcx.py)
    2) route 페이지에서 route_<id>_segments.json 생성 (extract_segments.py)
    3) cache 기반으로 TCX 에 CoursePoint(CueSheet) 추가 (add_cuesheet_to_tcx.py)

사용법:
    python3 build_route.py <routeID>

옵션:
    --tcx PATH          기존 TCX 가 있으면 다운로드 단계를 건너뛰고 재사용
    --out PATH          최종 CoursePoint 추가된 TCX 출력 경로
    --min-category N    포함할 최소 카테고리 (4|3|2|1|HC)
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from download_route_tcx import download_route_tcx  # noqa: E402
from extract_segments import extract_to_cache  # noqa: E402


def run_cuesheet(tcx_path, cache_path, out_path, min_category=None):
    cmd = [
        sys.executable,
        os.path.join(HERE, "add_cuesheet_to_tcx.py"),
        "--tcx", tcx_path,
        "--out", out_path,
        "--cache", cache_path,
    ]
    if min_category:
        cmd += ["--min-category", str(min_category)]
    print("▶ CoursePoint 추가:", " ".join(cmd))
    subprocess.check_call(cmd)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("route_id")
    ap.add_argument("--tcx", default=None, help="기존 TCX (다운로드 생략)")
    ap.add_argument("--out", default=None, help="최종 CoursePoint 포함 TCX 경로")
    ap.add_argument("--sleep", type=float, default=1.2)
    ap.add_argument(
        "--min-category",
        default=None,
        help="포함할 최소 카테고리 (4|3|2|1|HC). 미지정 시 전체 포함.",
    )
    args = ap.parse_args()

    route_dir = os.path.join(HERE, "output", "route")
    seg_dir = os.path.join(HERE, "output", "route_segments")
    os.makedirs(route_dir, exist_ok=True)
    os.makedirs(seg_dir, exist_ok=True)

    tcx_raw = args.tcx or os.path.join(route_dir, f"route_{args.route_id}.tcx")
    if not args.tcx:
        print("=" * 60)
        print("1) TCX 다운로드")
        print("=" * 60)
        download_route_tcx(args.route_id, tcx_raw)
    else:
        print(f"⏭️  TCX 다운로드 생략 - 기존 파일 사용: {tcx_raw}")

    cache_path = os.path.join(seg_dir, f"route_{args.route_id}_segments.json")

    print("\n" + "=" * 60)
    print(f"2) route_{args.route_id}_segments.json 생성")
    print("=" * 60)
    extract_to_cache(args.route_id, tcx_raw, cache_path, args.sleep)

    out_path = args.out or os.path.join(route_dir, f"route_{args.route_id}_cued.tcx")
    print("\n" + "=" * 60)
    print("3) TCX 에 CoursePoint(Summit/Sprint/Category) 추가")
    print("=" * 60)
    run_cuesheet(tcx_raw, cache_path, out_path, args.min_category)

    print("\n🎉 완료!")
    print(f"   - TCX (원본):       {tcx_raw}")
    print(f"   - segments json:    {cache_path}")
    print(f"   - TCX (CueSheet):   {out_path}")


if __name__ == "__main__":
    main()
