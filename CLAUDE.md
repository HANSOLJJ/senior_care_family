# Smart Frame Family - Project Context

## Overview
Smart Frame 시스템의 **자식(가족)용 앱** (Flutter).
시니어 태블릿에 영상통화 발신 + 사진 업로드 + 기기 관리.
iOS + Android 크로스 플랫폼 지원 목표.

## 프로젝트 구조 (Smart Frame 전체)
```
E:\App\
├── Family\     ← 이 프로젝트 (자식용, Flutter)
├── Senior\     ← 시니어 태블릿용 (Android Native 전환 예정)
```
- **Family 앱**: 영상통화 발신, 사진 업로드, 기기 관리 (UI 중심)
- **Senior 앱**: 영상통화 수신, 얼굴감지 자동응답, 슬라이드쇼 (HW 제어 중심)
- **백엔드**: Firebase 공유 (RTDB 시그널링, FCM, Storage)

## 현재 상태
Senior 앱에서 복사됨 (2026-03-05). 아직 자식앱 전용 기능(사진 업로드 등) 미구현.
기존 코드는 시니어 태블릿용으로 동작하며, 자식앱으로 리브랜딩 + 기능 전환 필요.

## Architecture
- **시그널링**: Firebase Realtime Database (`/calls/{callId}/`)
- **영상통화**: WebRTC (flutter_webrtc)
- **알림**: Firebase Cloud Messaging (FCM)
- **기기 등록**: RTDB `/devices/{deviceId}/` (online 상태 + onDisconnect 자동 offline)
- **발신 테스트**: `web-test-caller\index.html`

## Key Files
```
lib/
├── main.dart                      # AppConfig (deviceId, 기기등록), 앱 진입점
├── screens/
│   ├── slideshow_screen.dart      # 슬라이드쇼 (시니어용 → 제거/변경 예정)
│   ├── incoming_call_screen.dart  # 수신 화면 (시니어용 → 제거/변경 예정)
│   ├── video_call_screen.dart     # 영상통화 화면
│   ├── device_list_screen.dart    # 기기 선택 화면 (발신용)
│   └── outgoing_call_screen.dart  # 발신 대기 + 영상통화 화면
├── services/
│   ├── signaling_service.dart     # RTDB 시그널링 (targetDeviceId 필터링)
│   ├── webrtc_service.dart        # WebRTC (answerCall + makeCall + 끊김감지)
│   ├── fcm_service.dart           # FCM 토큰 관리 + RTDB 저장
│   └── face_detection_service.dart # 얼굴감지 (시니어용 → 제거 예정)
└── widgets/
    └── photo_frame_view.dart      # 사진 표시 위젯
```

## Build & Deploy
```bash
# 빌드
flutter build apk --release

# 설치 (패키지명: 변경 예정, 현재 com.example.senior_win)
adb -s <serial> install -r build/app/outputs/flutter-apk/app-release.apk
```

## 향후 계획
1. **리브랜딩**: 패키지명, 앱 이름 변경 (senior_win → smart_frame_family)
2. **자식앱 기능 추가**: 사진 업로드 (Firebase Storage), 기기 관리
3. **시니어 전용 기능 제거**: 얼굴감지, 슬라이드쇼 등
4. **Senior 앱**: 별도 Android Native (Kotlin) 프로젝트로 새로 개발

## Call Flow (발신측)
```
[Family 앱] 기기 목록 조회 → 대상 선택 → offer 생성
    ↓
/calls/{callId} (targetDeviceId 포함) → RTDB 저장
    ↓
[Senior 태블릿] 수신 → answer 전송
    ↓
ICE candidate 교환 → WebRTC P2P 연결
    ↓
양방향 영상통화
```

## 기술 결정 이력
- Flutter 유지 이유: 크로스 플랫폼(iOS+Android), UI 중심 기능, 이미 동작하는 코드 재활용
- Senior 앱 Native 전환 이유: flutter_webrtc 한계, HW 직접 제어 필요
- Firebase 선택 이유: onDisconnect, 실시간 동기화, FCM 통합 (Supabase 대비 유리)
