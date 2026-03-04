# AP (SoC) 스펙 비교

## 현재 프로젝트 기기 + 후보 AP

| | **Allwinner A523** | **Rockchip RK3566** | **Snapdragon 662** | **UNISOC T606** | **MediaTek MT8168A** | **Rockchip RK3288** |
|---|---|---|---|---|---|---|
| **탑재 기기** | A20 | rk3566_t, YC-102P | Galaxy Tab A7 | (후보) | (후보) | (후보) |
| **CPU 코어** | Cortex-**A55** x **8** | Cortex-**A55** x **4** | Cortex-A73 x4 + A53 x4 | Cortex-**A75** x2 + **A55** x6 | Cortex-**A53** x **4** | Cortex-**A17** x **4** |
| **클럭** | 2.0GHz (4+4구성) | 1.8GHz | 2.0GHz + 1.8GHz | 1.6GHz + 1.6GHz | 2.0GHz | 1.8GHz |
| **아키텍처** | ARMv8.2-A (64bit) | ARMv8.2-A (64bit) | ARMv8-A (64bit) | ARMv8.2-A (64bit) | ARMv8-A (64bit) | **ARMv7-A (32bit)** |
| **GPU** | Mali-G57 | Mali-G52 MP2 | Adreno 610 | Mali-G57 MP1 | Mali-G52 MP1 | Mali-T760 MP4 |
| **공정** | 12nm | 22nm | 11nm | 12nm | 12nm | **28nm** |
| **NPU** | 없음 | 0.8 TOPS (ML Kit 미사용) | 없음 | 없음 | 없음 | 없음 |
| **AnTuTu** | (미측정) | ~90,000 | ~182,000 | ~227,000 | (미측정) | (미측정) |
| **GB 싱글/멀티** | - | ~155 / ~452 | ~310 / ~1,300 | ~317 / ~1,178 | - | - |
| **출시** | 2023 | 2020 | 2020 | 2021 | 2019 | **2014** |

## CPU 아키텍처 세대 차이

### Cortex-A55 vs A53

A55는 A53의 후속 세대로 다음이 개선됨:

- **IPC ~15% 향상** — Out-of-Order 실행 파이프라인 개선
- **ML 연산 2~3배 빠름** — int8/int16 NEON 명령어 추가
- ML Kit 얼굴감지는 순수 CPU 기반이라 이 차이가 직접적으로 체감됨

### Cortex-A17 (RK3288)

- **ARMv7-A (32bit)** — 나머지 전부 64bit인데 A17만 32bit
- int8/int16 NEON ML 명령어 자체가 없음 → A53보다도 ML 추론 느림
- Flutter arm32 지원은 하지만 arm64 최적화 못 받음
- Android 버전 대부분 7~8에서 멈춤 (업데이트 없음)
- Google Play 2019년부터 64bit 필수 → 32bit only 앱 등록 불가

## 프로젝트 기능별 성능 예상

| 기능 | A523 (8xA55) | RK3566 (4xA55) | Snapdragon 662 (A73+A53) | UNISOC T606 (A75+A55) | MT8168A (4xA53) | RK3288 (4xA17) |
|------|---|---|---|---|---|---|
| **슬라이드쇼** | 여유 | 여유 | 여유 | 여유 | 여유 | 여유 |
| **WebRTC 영상통화** | 여유 | 정상 | 여유 | 여유 | 정상 | 가능 |
| **얼굴감지 (ML Kit)** | 빠름 | 보통 (Release OK) | 빠름 | 빠름 (A75 빅코어) | 느림 (A53 병목) | **실사용 불가 수준** |
| **카메라 워밍업** | 빠름 | 느림 (rk3566_t EXTERNAL) | 빠름 | 기기 의존 (HAL 리스크) | 기기 의존 | 기기 의존 |

## 성능 순위 (얼굴감지 기준)

```
UNISOC T606 (A75 big코어) ≈ Snapdragon 662 (A73 big코어) ≈ A523 (8xA55) > RK3566 (4xA55) > MT8168A (4xA53) > RK3288 (4xA17) ❌
```

## 후보 AP 결론

### UNISOC T606 — 성능 충분, CameraX 호환성만 확인 필요
- A75 빅코어 2개 + A55 리틀코어 6개의 big.LITTLE 구성으로 싱글스레드 성능이 Snapdragon 662급
- AnTuTu ~227,000으로 RK3566 대비 **2.5배**, Snapdragon 662 대비 **24% 높음**
- 12nm 공정, 8코어로 Flutter AOT + WebRTC + ML Kit 모두 여유
- **리스크**: UNISOC 칩 탑재 태블릿은 저가 중국산이 대부분이라 카메라 HAL 품질이 제조사마다 편차가 큼
  - rk3566_t에서 겪은 `EXTERNAL` 인식 문제 재현 가능성 있음
  - 구매 전 카메라 `FRONT` 정상 인식, Android 11+, WiFi 안정성 확인 필수

### MT8168A — 가능하지만 가장 느림
- RK3566(A55 4코어)이 현재 가장 느린데, MT8168A는 한 세대 아래인 A53 4코어
- RK3566도 Release 빌드에서 얼굴감지 동작하므로, MT8168A도 Release 빌드 기준 **사용 가능할 가능성 높음**
- 단, 워밍업이 더 오래 걸릴 수 있고, 카메라 드라이버 호환성(CameraX FRONT/EXTERNAL)은 실제 기기 연결 필요

### RK3288 — 비추
- 2014년 SoC, 32bit ARMv7 아키텍처로 현 프로젝트에 부적합
- MT8168A(A53)보다도 한 세대 더 아래, 28nm 공정이라 발열/전력도 불리
- ML Kit 얼굴감지가 실사용 불가 수준으로 느릴 가능성 높음
- 얼굴감지 OFF로 운용할 경우 슬라이드쇼 + 영상통화만은 가능할 수 있음

## 참고 자료

- [UNISOC T606 Specs - NotebookCheck](https://www.notebookcheck.net/Unisoc-Tiger-T7200-T606-Processor-Benchmarks-and-Specs.582689.0.html)
- [UNISOC T606 vs Snapdragon 662 - cpu-monkey](https://www.cpu-monkey.com/en/compare_cpu-unisoc_t606-vs-qualcomm_snapdragon_662)
- [UNISOC T606 Benchmark - cpubenchmark.net](https://www.cpubenchmark.net/cpu.php?cpu=Unisoc+T606&id=4974)
- [MediaTek MT8168 Specs - NotebookCheck](https://www.notebookcheck.net/MediaTek-MT8168-Processor-Benchmarks-and-Specs.483534.0.html)
- [Rockchip RK3288 Specs - NotebookCheck](https://www.notebookcheck.net/Rockchip-RK3288-SoC-Benchmarks-and-Specs.148374.0.html)
- [Allwinner A523 vs RK3566 - CNX Software](https://shorts.cnx-software.com/2023/07/06/allwinner-a523-vs-rockchip-rk3566-rk3568/)
- [RK3566 vs RK3288 - Gadgetversus](https://gadgetversus.com/processor/rockchip-rk3566-vs-rockchip-rk3288/)
- [RK3288 vs MT8168 - NotebookCheck](https://www.notebookcheck.net/RK3288-vs-MT8168_6984_12645.247596.0.html)
- [Cortex-A53 vs A55 - ARM Based Solutions](https://armbasedsolutions.com/info-detail/comparison-between-arm-cortex-a53-and-cortex-a55-processors)
- [ARM Cortex-A Series Comparison - Forlinx](https://www.forlinx.net/industrial-news/arm-cortex-a-series-processor-performance-344.html)
- [Allwinner A523 vs MT8168 - NotebookCheck](https://www.notebookcheck.net/A523-vs-MT8168_17339_12645.247596.0.html)
