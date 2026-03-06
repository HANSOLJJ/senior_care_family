# Changelog

## 2026-02-23 — 기기 타겟팅 + 세션 정리 + 태블릿 간 발신

### Part A: 기기별 통화 타겟팅
- `AppConfig.deviceId` 추가 (`android.id` 기반, RTDB 금지문자 sanitize)
- 앱 시작 시 RTDB `/devices/{deviceId}` 등록 (model, name, online, lastSeen)
- `onDisconnect().update({online: false})` — 앱 종료/네트워크 끊김 시 자동 offline
- `signaling_service.dart`: `listenForIncomingCalls(myDeviceId:)` — `targetDeviceId` 불일치 통화 무시
- `fcm_service.dart`: FCM 토큰을 `/devices/{deviceId}/fcmToken`에 자동 저장
- `web-test-caller\index.html`: 기기 목록 드롭다운 + `targetDeviceId` 포함 발신

### Part B: 세션 정리 강화
- `webrtc_service.dart`: `onConnectionState` disconnected → 5초 대기 → 자동 hangUp + `onCallEnded` 콜백
- `signaling_service.dart`: `setCallCleanupOnDisconnect()` (비정상 종료 시 RTDB 자동 정리)
- `hangUp()`: `endCall()` 후 2초 지연 → `cleanupCall()` (상대방 감지 시간 확보)
- `answerCall()` + `makeCall()` 모두 `listenForCallEnd()` 추가 — 양쪽 종료 감지
- `cleanupStaleCalls()`: 앱 시작 시 5분+ 잔존 통화 자동 삭제
- `web-test-caller\index.html`: `beforeunload` + `onDisconnect()` + 상대방 종료 감시

### Part C: 기기 ID 표시
- `slideshow_screen.dart`: 좌측 하단에 `모델명 (deviceId)` 반투명 표시 (임시)

### Part D: 태블릿 → 태블릿 영상통화
- `webrtc_service.dart`: `makeCall(targetDeviceId)` — offer 생성 + RTDB 저장 + answer 대기
- `device_list_screen.dart` (신규): 온라인 기기 목록 실시간 표시, 자기 자신 제외
- `outgoing_call_screen.dart` (신규): 발신 대기 UI + 30초 타임아웃 + 영상통화 전환
- `slideshow_screen.dart`: 화면 터치 → 기기 선택 화면 진입

### 버그 수정
- 워밍업 카메라 충돌: `FaceDetectionService.cancelWarmup()` static 메서드 추가
  - RK3566에서 워밍업(7초) 중 통화 수신 시 `No supported surface combination` 에러 발생
  - `incoming_call_screen.dart`에서 카메라 init 전 `cancelWarmup()` 호출로 해결
- `registerDevice()` 타이밍: `main()` → `_SmartFrameAppState.initState()` 이동 (RTDB 플러그인 초기화 대기)
- FCM/시그널링 초기화를 RTDB 등록보다 먼저 실행 (등록 실패해도 통화 수신 가능)
- 10초 타임아웃 추가 (RTDB 연결 느린 기기 대응)

### 배포 상태
- RK3566: 정상 (기기 등록 + FCM 토큰 저장 확인)
- Galaxy Tab A7: 정상
- YC-102P: WiFi 미연결 → RTDB 타임아웃 (인터넷 연결 필요)
- A20: USB 미연결 (설치 필요)

---

## 2026-02-22 — 초기 구현

### 핵심 기능
- 슬라이드쇼 (assets/images/ 자동 로드, 10초 전환)
- FCM + RTDB 시그널링 기반 영상통화 수신
- 얼굴 감지 자동 응답 (카운트다운 → 영상통화 전환)
- WebRTC 양방향 영상통화
- 웹 테스트 발신 페이지

### 기기별 최적화
- AppConfig 런타임 감지 (model, board 기반 분기)
- 카메라 + ML Kit 워밍업 (첫 통화 속도 개선)
- Release 빌드 배포 (AOT 컴파일로 성능 향상)
