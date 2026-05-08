#!/usr/bin/env python3
"""스크린샷 평균 luminance 검사 — 검은 화면 의심 감지.

사용:
    python check_brightness.py <screenshot.png> [threshold]

threshold 기본 50 (0~255). 평균 luminance 가 threshold 미만이면 "BLACK" 보고 + exit 1.

출력 형식: "OK mean=N region_top=N" 또는 "BLACK mean=N region_top=N"

Region check:
- 전체 화면 평균 + 상단 60% (보통 video view 영역) 평균 둘 다 측정.
- 어느 쪽이라도 임계 미만이면 BLACK.
- UI 요소 (하단 종료 버튼 등) 가 평균 끌어올리는 거 보정.
"""
import sys
from PIL import Image


def main():
    if len(sys.argv) < 2:
        print("Usage: check_brightness.py <png> [threshold]", file=sys.stderr)
        sys.exit(2)

    threshold = float(sys.argv[2]) if len(sys.argv) > 2 else 50.0

    try:
        img = Image.open(sys.argv[1]).convert('L')
        w, h = img.size

        data_full = img.tobytes()
        mean_full = sum(data_full) / len(data_full)

        top = img.crop((0, 0, w, int(h * 0.6)))
        data_top = top.tobytes()
        mean_top = sum(data_top) / len(data_top)

        verdict = "BLACK" if (mean_full < threshold or mean_top < threshold) else "OK"
        print(f"{verdict} mean={mean_full:.1f} region_top={mean_top:.1f}")
        sys.exit(1 if verdict == "BLACK" else 0)
    except Exception as e:
        print(f"ERR {e}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
