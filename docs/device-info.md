# Smart Frame 장치 정보

## 연결 기기 목록

| 기기명 | 시리얼 | AP (SoC) | 보드 | 플랫폼 | Android | 얼굴인식 |
|--------|--------|----------|------|--------|---------|----------|
| Galaxy Tab A7 (SM-T500) | R9TT903QE5V | Qualcomm SM6115 (Snapdragon 662) | bengal | qcom | - | ON |
| A20 | 31f75915d0414881c94 | Allwinner A523 | exdroid | saturn | - | ON |
| RK3566 (rk3566_t) | ADT36E26010101 | Rockchip RK3566 | rk30sdk | rk30board | - | ON (Release 빌드로 해결) |
| YC-102P (rk3566_r) | a1fcf68098659f13 | Rockchip RK3566 | rk30sdk | rk356x | 11 (SDK 30) | ON (카메라 FRONT 정상, 빠름) |

## 상세 스펙

### Galaxy Tab A7 (SM-T500)
- **모델**: SM-T500
- **AP**: Qualcomm SM6115 (Snapdragon 662)
- **CPU**: 4x Cortex-A73 2.0GHz + 4x Cortex-A53 1.8GHz (8코어)
- **보드**: bengal
- **하드웨어**: qcom
- **카메라**: FRONT 정상 인식 (CameraX 호환)
- **얼굴인식**: ON

### A20 (Allwinner A523)
- **모델**: A20
- **AP**: Allwinner A523
- **CPU**: 8x Cortex-A55 2.0GHz (8코어)
- **보드**: exdroid
- **하드웨어**: sun55iw3p1
- **플랫폼**: saturn
- **카메라**: FRONT 정상 인식 (CameraX 호환)
- **얼굴인식**: ON

### RK3566 (rk3566_t)
- **모델**: rk3566_t
- **AP**: Rockchip RK3566
- **CPU**: 4x Cortex-A55 1.8GHz (4코어)
- **NPU**: 0.8 TOPS (RKNN) - ML Kit 미사용
- **보드**: rk30sdk
- **하드웨어**: rk30board
- **카메라**: EXTERNAL로 인식 (CameraX 검증 실패, ~10초 지연)
- **얼굴인식**: ON (Release 빌드에서 속도 개선, Debug 빌드에서만 느림)

### YC-102P (rk3566_r)
- **모델**: YC-102P
- **AP**: Rockchip RK3566
- **CPU**: 4x Cortex-A55 1.8GHz (4코어)
- **보드**: rk30sdk
- **하드웨어**: rk30board
- **플랫폼**: rk356x
- **Android**: 11 (SDK 30)
- **카메라**: FRONT 정상 인식 (CameraX 호환, 빠름)
- **얼굴인식**: ON (같은 RK3566이지만 카메라 드라이버가 달라 CameraX 정상 동작)

## RK3566이 느린 이유

### 1. CPU 성능 차이
- RK3566: **4코어** Cortex-A55 @ 1.8GHz
- A523: **8코어** Cortex-A55 @ 2.0GHz
- Snapdragon 662: **8코어** (A73+A53) @ 2.0GHz
- ML Kit 얼굴감지는 CPU 기반이라 코어 수/클럭 차이가 직접 체감됨

### 2. CameraX 호환성 문제 (주 병목) — rk3566_t 기기 한정
- rk3566_t 기기의 카메라가 `EXTERNAL`로 인식됨 (FRONT가 아님)
- CameraX `LENS_FACING_FRONT` 검증 실패 → 재시도 루프에서 ~10초 소요
- **같은 RK3566인 YC-102P는 카메라 FRONT 정상 인식 → 빠르게 동작**
- **결론: SoC 문제가 아니라 rk3566_t의 카메라 드라이버/HAL 문제**

### 3. NPU 활용 불가
- RK3566에 NPU (0.8 TOPS)가 있지만 Google ML Kit는 Rockchip RKNN을 사용하지 않음
- ML Kit는 CPU만 사용하므로 NPU는 무용지물

## AppConfig 장치 분기 로직

```dart
// main.dart의 AppConfig.initialize()
// 현재 전 기기 얼굴 감지 ON (Release 빌드에서 충분히 빠름)
// rk3566_t만 카메라 드라이버 문제 있으나 Release에서 체감 감소
enableFaceDetection = true;
```

**현재 상태**: Release 빌드 + 워밍업으로 전 기기 얼굴인식 ON.
필요 시 `deviceModel.toLowerCase().contains('rk3566')` 조건으로 특정 기기만 OFF 가능.

## 첫 통화 속도 개선 (워밍업)

### 문제
첫 통화만 느리고 두 번째부터 빠른 현상 발생.

### 원인
1. **카메라 HAL 초기화** — 첫 카메라 열기 시 드라이버 로딩 (~2-3초)
2. **ML Kit 모델 로딩** — 첫 `processImage()` 호출 시 얼굴감지 모델을 메모리에 로드 (~1-2초)
3. **CameraX 초기화** — 첫 연결 시 내부 검증/설정 (~1-2초)

이후엔 드라이버/모델이 캐시되어 즉시 동작.

### 해결: 앱 시작 시 백그라운드 워밍업

```
앱 시작 → 슬라이드쇼 표시
         ↓ (백그라운드)
         카메라 열기 → 프레임 1장 캡처 → ML Kit 분석 → 즉시 해제
         ↓
         카메라 HAL + ML Kit 모델 캐시됨
         ↓
전화 수신 → 카메라 열기 (빠름) → 얼굴감지 (빠름)
```

### 구현 위치
- `face_detection_service.dart` — `warmUp()` 메서드 추가
- `slideshow_screen.dart` — 이미지 로드 후 `FaceDetectionService().warmUp()` 호출

### 주의사항
- 워밍업은 `AppConfig.enableFaceDetection`이 true일 때만 실행
- 최대 5초 타임아웃 (실패해도 앱 동작에 영향 없음)
- 워밍업 실패 시 첫 통화만 느려질 뿐, 기능에는 문제 없음

## 빌드 모드별 성능 차이

| | Debug | Release |
|---|---|---|
| **앱 시작** | 느림 (3-8초) | 빠름 (1-2초) |
| **얼굴감지** | 느림 (Dart JIT) | 빠름 (AOT 네이티브) |
| **로그 출력** | print() 보임 | print() 안 보임 |
| **용도** | 개발/디버깅 | 배포/실사용 |

Release에서 Dart 코드가 AOT 컴파일되어 카메라 프레임 처리, InputImage 변환, 콜백 등이 2-5배 빨라짐.

## 프로비저닝 스크립트

```bash
# 사용법
./scripts/provision_tablet.sh [시리얼번호]

# 예시
./scripts/provision_tablet.sh R9TT903QE5V          # Galaxy Tab A7
./scripts/provision_tablet.sh 31f75915d0414881c94   # A20
./scripts/provision_tablet.sh ADT36E26010101        # RK3566
./scripts/provision_tablet.sh a1fcf68098659f13      # YC-102P
```
