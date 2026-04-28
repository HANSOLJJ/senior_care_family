# 모니터링 + 영상통화 통합 설계

## 배경

현재 "모니터링"과 "영상통화"가 별도 플로우로 존재.
- 모니터링: 일방향 (Senior 카메라 → Family)
- 영상통화: 양방향 (얼굴 인식 자동응답)

**문제점:**
1. 기존 영상통화는 Senior의 **얼굴 인식 자동응답**에 의존 → 시니어가 카메라 앞에 없으면 전화 못 받음
2. 근처에 있어도 얼굴 인식만 안 되면 통화 불가
3. 모니터링 중이면 다른 사람이 통화 불가 (1:1 제한)
4. 영상통화를 걸면 상대방 화면을 볼 수 없어서 답답함

**핵심 인사이트:**
- 모니터링 기능이 있으므로 Family가 직접 Senior 근처에 있는지 확인 가능 → 얼굴 인식의 "자동 수신" 역할 불필요
- 다만 시니어 입장에서 "전화가 온다"는 느낌은 있어야 함 (다짜고짜 소리 들리면 놀람)

---

## 최종 결정: 모니터링 기반 통화 (방안 D)

### 원칙

- **모니터링과 통화는 WebRTC 연결이 동일** — 차이는 Senior에 알림을 주느냐 안 주느냐
- **통화 = 모니터링 + 벨소리 + 양방향 전환** — 기술적으로 모니터링의 확장
- **버튼 2개 유지** — "모니터링"과 "통화" 분리 (조용히 보기 vs 말 걸기)
- **얼굴 인식은 수락 수단 중 하나** — 필수가 아닌 선택 (터치/타임아웃으로 대체 가능)

---

## Family 앱 (발신 측) 동작 비교

|  | 모니터링 | 통화 |
|---|---|---|
| **버튼** | "모니터링" | "통화" |
| **연결** | WebRTC 즉시 연결 | WebRTC 즉시 연결 (동일) |
| **화면** | Senior 카메라 영상 보임 | Senior 카메라 영상 (큰 화면) + 내 카메라 프리뷰 (PIP) + 수락 대기 UI |
| **카메라 프리뷰** | OFF (카메라 안 씀) | 로컬 프리뷰 ON (자기 모습 확인, 상대방에게는 아직 안 보냄) |
| **오디오 수신** | Senior 마이크 ON (주변 소리 들림) | Senior 마이크 ON (주변 소리 + 벨소리 들림) |
| **오디오 송신** | OFF (무음, Senior 모름) | 수락 전: OFF / 수락 후: ON (양방향) |
| **비디오 송신** | OFF (Family 카메라 안 씀) | 수락 전: 로컬 프리뷰만 / 수락 후: ON (Family 얼굴 보냄) |
| **1:N** | 여러 명 동시 가능 (최대 3명) | 1명만 |

## Senior 태블릿 (수신 측) 동작 비교

|  | 모니터링 | 통화 |
|---|---|---|
| **화면** | 슬라이드쇼 그대로 (변화 없음) | 수락 전: 벨소리 + "전화가 왔어요" UI + 카메라 프리뷰(자기 모습) / 수락 후: Family 얼굴 (큰 화면) + 내 카메라 프리뷰 (PIP) |
| **카메라** | WebRTC로 Family에 전송 (시니어 모름) | 동일 (WebRTC로 전송) + 수락 전부터 로컬 프리뷰 표시 |
| **마이크** | ON (주변 소리 Family에 전달) | 수락 전: ON / 수락 후: ON (양방향) |
| **스피커** | OFF (무음) | 수락 전: 벨소리 / 수락 후: Family 목소리 |
| **수락 방식** | 없음 (시니어 인지 불필요) | 얼굴 감지 / 화면 터치 |
| **수락 후 화면** | — | Family 얼굴 (큰 화면) + 내 카메라 프리뷰 (PIP, MonitorCallActivity) |

**공통점**: 둘 다 WebRTC 연결은 동일. Senior 카메라 → Family로 영상 전송.
**차이점**: Senior에 알림을 주느냐(통화) 안 주느냐(모니터링), 양방향 전환 여부.

---

## "통화" 버튼 플로우

```
Phase 1: 즉시 모니터링 연결 (0~1초)
├── WebRTC 연결 (모니터링과 동일)
├── Family 화면: Senior 카메라 영상 (큰 화면) + 내 카메라 프리뷰 (PIP) + 수락 대기 UI
├── Senior: 벨소리 + "전화가 왔어요" UI + 카메라 프리뷰 (자기 모습)
├── Family 카메라: 로컬 프리뷰만 (상대방에게 아직 안 보냄)
└── Family 오디오 송신: OFF (아직 양방향 아님)

Phase 2: 시니어 수락 (얼굴 감지 / 터치)
├── 얼굴 감지: WebRTC 프레임 → ML Kit (카메라 충돌 없음)
├── 터치: Senior 화면 터치
├── 무응답: Family가 끊거나 일정 시간 후 통화 자동 종료
└── → 수락 시 양방향 전환

Phase 3: 양방향 영상통화
├── Family: Senior 얼굴 (큰 화면) + 내 카메라 (PIP) — 송신 시작
├── Senior: Family 얼굴 (큰 화면) + 내 카메라 (PIP, MonitorCallActivity)
├── 오디오: 양방향
└── → 완전한 양방향 영상통화
```

## "모니터링" 버튼 플로우

```
├── WebRTC 즉시 연결
├── Senior 화면 변화 없음 (슬라이드쇼 그대로)
├── Family: Senior 카메라 영상 + 주변 소리
├── 여러 Family 동시 접속 가능 (최대 3명)
└── Senior는 모니터링 사실을 모름
```

---

## 1:N 동시 접속 규칙

| 상황 | 처리 |
|------|------|
| 여러 명 동시 모니터링 | OK (최대 3명, 카메라 트랙 공유) |
| 1명 통화 중 + 나머지 모니터링 | OK (통화 1명만, 나머지는 모니터링 유지) |
| 2명 이상 동시 통화 | 불가 — 먼저 1명만 통화, 나머지는 모니터링 |
| 통화 중인 사람이 끊으면 | 다른 사람이 통화 전환 가능 |

---

## 얼굴 인식의 역할 변화

| | 기존 | 새로운 |
|---|------|--------|
| **역할** | 자동 수신 (전화 받기 — 필수) | 수락 수단 중 하나 (선택적) |
| **실패 시** | 전화 못 받음 | 터치로 대체 |
| **카메라** | CameraX 전용 | WebRTC 프레임 → ML Kit (VideoSink) |
| **코드** | IncomingCallActivity | MonitoringSession 내부 |

기존 `IncomingCallActivity`의 얼굴 인식 로직을 `MonitoringSession`으로 이전.

---

## Senior 측 기술 구현 포인트

### 얼굴 감지: WebRTC 프레임 가로채기 (VideoSink)

Senior는 Android Native이므로 WebRTC 프레임 접근 자유:
1. `VideoSink` 인터페이스로 WebRTC 카메라 프레임 수신
2. `VideoFrame` → `Bitmap` 변환
3. ML Kit `FaceDetector`에 전달
4. 카메라 하나로 WebRTC 송출 + 얼굴 감지 동시 가능 (카메라 충돌 없음)

### 다중 peer 관리

현재 `MonitoringSession`은 1:1. 다중 peer 지원 필요:
```
MonitoringSession
  ├── peers: Map<callId, PeerConnection>
  ├── 공유 카메라 트랙 (모든 peer에 동일한 video track)
  ├── 오디오: 통화 전환된 peer만 양방향, 나머지 일방향
  └── 최대 동시 연결: 3~4개 (태블릿 성능 제한)
```

### 통화 수락 후 양방향 전환

1. RTDB `callType`이 "call"인 경우 벨소리 + 알림 UI
2. 수락(얼굴/터치/타임아웃) → renegotiate: 오디오+비디오 양방향
3. MonitorCallActivity 실행 → Family 얼굴 표시

---

## 미결정 사항 (결정됨)

- [x] 방안 A vs B vs C → **방안 D (모니터링 기반 통화)** 채택
- [x] 카메라 충돌 → **VideoSink로 WebRTC 프레임 가로채기** (Native이므로 문제 없음)
- [x] 얼굴 감지 → **수락 수단 중 하나** (터치로 대체 가능)
- [x] 통화 중 모니터링 동시 → **OK** (다중 peer, 통화 1명 + 모니터링 N명)

---

## 관련 코드

| 파일 | 역할 |
|------|------|
| `Family: monitoring_screen.dart` | 모니터링 UI + 통화 전환 버튼 |
| `Family: webrtc_service.dart` | startMonitoring, upgradeToCall |
| `Family: signaling_service.dart` | callType, renegotiation 시그널링 |
| `Family: family_detail_screen.dart` | 모니터링/통화 버튼 |
| `Senior: call/MonitoringSession.kt` | 다중 peer 관리 + 통화 전환 |
| `Senior: call/CallActivity.kt` | 통화 전환 시 영상 UI |
| `Senior: facedetection/FaceDetectionService.kt` | 얼굴 감지 (ML Kit) |
| `Senior: facedetection/FaceDetectionVideoSink.kt` | WebRTC 프레임 → ML Kit 전달 |
