# Smart Frame - Project Context

## Overview
Android 태블릿 4대에서 동작하는 디지털 액자 + 영상통화 앱 (Flutter).
슬라이드쇼 → 전화 수신 → 얼굴 감지 → 자동 영상통화 연결.

## Architecture
- **시그널링**: Firebase Realtime Database (`/calls/{callId}/`)
- **영상통화**: WebRTC (flutter_webrtc)
- **알림**: Firebase Cloud Messaging (FCM)
- **기기 등록**: RTDB `/devices/{deviceId}/` (online 상태 + onDisconnect 자동 offline)
- **발신자**: 웹 테스트 페이지 (`E:\App\web-test-caller\index.html`) 또는 태블릿 간 직접 발신

## Key Files
```
lib/
├── main.dart                      # AppConfig (deviceId, 기기등록), 앱 진입점
├── screens/
│   ├── slideshow_screen.dart      # 슬라이드쇼 + 기기ID 표시 + 터치→기기선택
│   ├── incoming_call_screen.dart  # 수신 화면 (벨소리 + 얼굴감지 → 자동응답)
│   ├── video_call_screen.dart     # 영상통화 화면 (수신측)
│   ├── device_list_screen.dart    # 기기 선택 화면 (발신용)
│   └── outgoing_call_screen.dart  # 발신 대기 + 영상통화 화면
├── services/
│   ├── signaling_service.dart     # RTDB 시그널링 (targetDeviceId 필터링)
│   ├── webrtc_service.dart        # WebRTC (answerCall + makeCall + 끊김감지)
│   ├── fcm_service.dart           # FCM 토큰 관리 + RTDB 저장
│   └── face_detection_service.dart # 얼굴감지 + 워밍업 (cancelWarmup 지원)
└── widgets/
    └── photo_frame_view.dart      # 사진 표시 위젯
```

## Target Devices
| 모델 | deviceId (Build.ID sanitized) | 특이사항 |
|------|-------------------------------|----------|
| Galaxy Tab A7 (SM-T500) | RP1A_200720_012 | Snapdragon 662, 정상 |
| A20 | (미확인, USB 미연결) | Allwinner A523, 정상 |
| RK3566 (rk3566_t) | TQ3C_230805_001_B2 | 카메라 EXTERNAL 인식, 워밍업 느림 |
| YC-102P (rk3566_r) | RD2A_211001_002 | WiFi 필요, RTDB 타임아웃 시 FCM만 동작 |

## Build & Deploy
```bash
# 빌드
flutter build apk --release

# 설치 (패키지명: com.example.senior_win)
adb -s <serial> install -r build/app/outputs/flutter-apk/app-release.apk

# 앱 시작
adb -s <serial> shell monkey -p com.example.senior_win -c android.intent.category.LAUNCHER 1

# 로그 확인
adb -s <serial> shell logcat --pid=$(adb -s <serial> shell pidof com.example.senior_win) | grep flutter
```

## Known Issues
- YC-102P: WiFi 미연결 시 RTDB 타임아웃 (10초) → FCM/시그널링은 정상 동작
- RK3566 (rk3566_t): 카메라 EXTERNAL 인식 → CameraX 검증 지연 (~7초 워밍업)
- 워밍업 중 통화 수신 시 카메라 충돌 → `cancelWarmup()` 으로 해결됨
- `android.id` (Build.ID)에 `.` 포함 가능 → `replaceAll(RegExp(r'[.#$\[\]]'), '_')` 로 sanitize

## Call Flow
```
[발신자] offer 생성 → /calls/{callId} (targetDeviceId 포함)
    ↓
[수신 태블릿] targetDeviceId 일치 확인 → 벨소리 + 얼굴감지
    ↓ (얼굴 감지됨)
answer 생성 → /calls/{callId}/answer
    ↓
ICE candidate 교환 → WebRTC P2P 연결
    ↓
양방향 영상통화
    ↓ (한쪽 종료)
status='ended' → 2초 후 노드 삭제 (상대방 감지 시간 확보)
```

## Session Cleanup
- **정상 종료**: hangUp() → status='ended' → 2초 후 cleanupCall()
- **비정상 종료**: onDisconnect().remove() (RTDB 자동 정리)
- **WebRTC 끊김**: onConnectionState disconnected → 5초 대기 → 자동 hangUp
- **잔존 통화**: 앱 시작 시 5분+ 경과 통화 자동 삭제
