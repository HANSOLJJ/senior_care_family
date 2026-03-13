# 모니터링 + 영상통화 통합 설계

## 배경

현재 "모니터링"과 "영상통화"가 별도 플로우로 존재.
- 모니터링: 일방향 (Senior 카메라 → Family)
- 영상통화: 양방향 (얼굴 인식 자동응답)

이 둘을 통합하여 **모니터링을 영상통화의 진입점**으로 사용하는 방안 검토.

---

## 핵심 문제

1. 기존 영상통화는 Senior의 **얼굴 인식 자동응답**에 의존 → 시니어가 카메라 앞에 없으면 전화 못 받음
2. 모니터링은 **즉시 연결** 가능 → 이걸 활용하면 대기 시간 제거
3. 1:N 통신 — 여러 Family 멤버가 동시 접속 가능해야 함

---

## 제안 플로우

### Family 화면: 버튼 2개

| 버튼 | 동작 |
|------|------|
| **모니터링** | 일방향 무음 CCTV (현재와 동일) |
| **통화** | 모니터링 즉시 연결 + 오디오 양방향 즉시 ON |

### "통화" 버튼 플로우

```
Phase 1: 즉시 연결 (0~1초)
├── Family → Senior: 모니터링 연결 (recvonly video)
├── Family → Senior: 오디오는 양방향 (sendrecv audio)
├── Family 화면: Senior 카메라 영상 + 소리 들림
├── Senior 화면: 변화 없음 (슬라이드쇼 그대로)
└── Senior 스피커: ON → Family 목소리 나옴

Phase 2: 시니어 호출
├── Family가 스피커로 "할머니~" 호출
└── 시니어가 소리 듣고 태블릿 앞으로 이동

Phase 3: 얼굴 감지 → 영상 UI 전환 (Senior 측)
├── Senior에서 FaceDetection 백그라운드 실행 중
├── 시니어 얼굴 감지됨
├── → MonitorCallActivity 뜸 (Family 얼굴 표시)
├── → 비디오도 양방향 전환 (sendrecv video)
└── → 완전한 양방향 영상통화 성립
```

### "모니터링" 버튼 플로우

```
현재와 동일:
├── 일방향 무음 (Senior 카메라+마이크 → Family)
├── Senior 화면 변화 없음
├── 수동 "통화 전환" 버튼으로 양방향 전환 가능
└── 여러 Family 동시 모니터링 가능
```

---

## 대안 비교

### 방안 A: 버튼 2개 분리 (위 제안)

```
"모니터링" → 무음 CCTV
"통화"     → 모니터링 + 오디오 양방향 + 얼굴감지 시 영상 UI
```

**장점**: 용도별 명확한 분리. 조용히 보기 vs 말 걸기
**단점**: 버튼 2개 관리

### 방안 B: 3단계 (모니터링 → 통화전환 버튼 → 얼굴감지)

```
"통화" → 모니터링 → 모니터링 화면에서 "통화 전환" 버튼 → 오디오 양방향 → 얼굴감지 시 영상 UI
```

**장점**: 단계별 제어 가능. Family가 상황 보고 판단
**단점**: 말 걸기까지 한 단계 더 필요

### 방안 C: 순수 수동 (얼굴 인식 없이)

```
"통화" → 모니터링 + 오디오 양방향 즉시 + Senior에 바로 영상 UI 표시
```

**장점**: 가장 단순. 전화기 동작과 동일
**단점**: 시니어가 안 보여도 영상 UI 뜸 (낭비)

---

## 1:N 동시 접속 규칙

| 상황 | 처리 |
|------|------|
| 여러 명 동시 모니터링 | OK (최대 3명, 카메라 트랙 공유) |
| 1명 통화 중 + 나머지 모니터링 | OK (통화 1명만, 나머지는 모니터링 유지) |
| 2명 이상 동시 통화 | 불가 — 먼저 신청한 1명만 통화, 나머지는 모니터링 |
| 통화 중인 사람이 끊으면 | 다른 사람이 통화 전환 가능 |

---

## 얼굴 인식의 역할 변화

| | 기존 | 새로운 |
|---|------|--------|
| **역할** | 자동 수신 (전화 받기) | 영상 UI 표시 트리거 |
| **트리거** | 전화 수신 시 | "통화" 연결 후 상시 |
| **실패 시** | 전화 못 받음 | Family가 스피커로 호출 가능 |
| **코드** | IncomingCallActivity | MonitoringSession 내부 |

기존 `IncomingCallActivity`의 얼굴 인식 로직을 `MonitoringSession`으로 이전.
`IncomingCallActivity`는 제거 또는 단순화.

---

## Senior 측 기술 구현 포인트

### 오디오만 양방향으로 시작

"통화" 모드일 때 MonitoringSession에서:
- 비디오: sendonly (Senior → Family)
- 오디오: sendrecv (양방향)
- Senior 스피커: AudioManager MODE_IN_COMMUNICATION + speakerphone ON

### 얼굴 감지 후 비디오 양방향 전환

1. FaceDetectionService가 CameraX 프리뷰 대신 **WebRTC 카메라 프레임**에서 얼굴 감지
   (또는 별도 CameraX 세션 — 카메라 충돌 주의)
2. 얼굴 감지 → renegotiate: 비디오도 sendrecv로 변경
3. MonitorCallActivity 실행 → Family 얼굴 표시

### 카메라 충돌 이슈

- WebRTC가 카메라 점유 중 → CameraX로 얼굴 감지 불가
- 해결 방안:
  1. WebRTC 비디오 프레임을 가로채서 ML Kit에 전달 (VideoProcessor)
  2. 또는 WebRTC 카메라를 CameraX로 교체하여 프레임 공유
  3. 또는 근접 센서/모션 감지로 대체 (얼굴 인식 대신)

---

## 미결정 사항

- [ ] 방안 A vs B vs C 최종 선택
- [ ] 카메라 충돌 해결 방법 (WebRTC 프레임 가로채기 vs CameraX 공유)
- [ ] 얼굴 감지 없이 근접 센서 등 대안 검토 여부
- [ ] Senior 영상 UI 디자인 (전체 화면 vs 오버레이)
- [ ] 통화 중 모니터링 동시 허용 범위

---

## 현재 관련 코드

| 파일 | 역할 |
|------|------|
| `Family: monitoring_screen.dart` | 모니터링 UI + 통화 전환 버튼 |
| `Family: webrtc_service.dart` | startMonitoring, upgradeToCall |
| `Family: signaling_service.dart` | callType, renegotiation 시그널링 |
| `Family: family_detail_screen.dart` | 모니터링/통화 버튼 |
| `Senior: MonitoringSession.kt` | 다중 peer 관리 + 통화 전환 |
| `Senior: MonitorCallActivity.kt` | 통화 전환 시 영상 UI |
| `Senior: FaceDetectionService.kt` | 얼굴 감지 (현재 IncomingCallActivity용) |
| `Senior: IncomingCallActivity.kt` | 기존 얼굴 인식 자동응답 (제거/이전 대상) |
