# Senior Care Family App - Project Context

## Overview

Senior Care 시스템의 **가족(자식)용 앱** (Flutter).
시니어 태블릿에 영상통화 발신 + 사진 업로드 + 복약 알림 설정 + 기기 관리.
iOS + Android 크로스 플랫폼.

## 전체 시스템 구조

```text
E:\App\
├── Family\     ← 이 프로젝트 (자식용, Flutter)
└── Senior\     ← 시니어 태블릿용 (Android Native)
```

- **Family 앱**: 로그인, 페어링, 영상통화 발신, 사진 업로드, 복약 알림 설정, 기기 관리
- **Senior 앱**: 영상통화 수신, 얼굴감지 자동응답, 슬라이드쇼, 복약 알림 재생
- **백엔드**: Firebase 공유 (RTDB, FCM, Storage, Auth)

## 현재 상태

- Phase 1 완료: 시니어 전용 코드 제거 (얼굴감지, 슬라이드쇼, 수신화면, 부팅자동실행)
- 리브랜딩 완료: `com.seniorcare.family`, 앱명 `Senior Care Family`
- 다음: Phase 2 (코드 구조 정리 + 소셜 로그인)

## Architecture

- **인증**: Firebase Auth (Google/Apple/카카오/네이버)
- **시그널링**: Firebase RTDB (`/calls/{callId}/`)
- **영상통화**: WebRTC (flutter_webrtc, 로컬 패치 플러그인)
- **푸시 알림**: FCM
- **파일 저장**: Firebase Storage (사진/영상)
- **가족 그룹**: RTDB `/families/{familyId}/` (페어링 + 초대)
- **복약 알림**: RTDB `/families/{familyId}/reminders/`

## Key Files (현재)

```text
lib/
├── main.dart                      # AppConfig + SeniorCareFamily 앱 위젯
├── screens/
│   ├── device_list_screen.dart    # 홈 — 시니어 기기 목록
│   ├── outgoing_call_screen.dart  # 발신 대기 + 영상통화
│   └── video_call_screen.dart     # 영상통화 화면
├── services/
│   ├── signaling_service.dart     # RTDB 시그널링
│   ├── webrtc_service.dart        # WebRTC (makeCall + 끊김감지)
│   └── fcm_service.dart           # FCM 토큰 관리
└── widgets/
    └── photo_frame_view.dart      # 시니어 잔재 → 제거 예정
```

## 목표 디렉토리 구조 (Phase 2~7 완료 후)

```text
lib/
├── main.dart                              # 진입점만
├── app.dart                               # SeniorCareFamily 위젯 + 라우팅
├── config/
│   └── app_config.dart                    # 기기 정보, Firebase 등록
├── screens/
│   ├── login_screen.dart                  # 소셜 로그인
│   ├── pairing_screen.dart                # 페어링 코드 / QR 스캔
│   ├── device_list_screen.dart            # 홈 (기기 목록)
│   ├── outgoing_call_screen.dart          # 발신 + 영상통화
│   ├── video_call_screen.dart             # 영상통화
│   ├── photo_upload_screen.dart           # 사진 업로드
│   └── reminder/                          # 복약 알림
│       ├── reminder_list_screen.dart
│       ├── reminder_edit_screen.dart
│       └── reminder_log_screen.dart
├── services/
│   ├── auth_service.dart                  # 로그인/로그아웃
│   ├── fcm_service.dart                   # FCM 토큰
│   ├── notification_service.dart          # 푸시 알림 수신/처리
│   ├── photo_service.dart                 # 사진 업로드/삭제
│   ├── family/
│   │   ├── family_service.dart            # 그룹 생성, 페어링, 초대
│   │   ├── member_service.dart            # 멤버 관리
│   │   └── device_service.dart            # 기기 상태/관리
│   ├── call/
│   │   ├── signaling_service.dart         # RTDB 시그널링
│   │   ├── webrtc_service.dart            # WebRTC
│   │   └── call_history_service.dart      # 통화 기록
│   └── reminder/
│       ├── reminder_service.dart          # 스케줄 CRUD
│       └── reminder_log_service.dart      # 확인/미확인 조회
└── widgets/
```

## Build & Deploy

```bash
flutter build apk --release
adb -s <serial> install -r build/app/outputs/flutter-apk/app-release.apk
```

## 주요 문서

- `docs/project-structure.md` — 프로젝트 구조 + RTDB 스키마 + 화면 흐름
- `docs/smart-frame-plan.md` — 전체 구현 계획 (Phase 1~7)
- `E:\App\Senior\docs\family-integration-plan.md` — Senior 앱 연동 수정 가이드

## 기술 결정 이력

- Flutter 유지: 크로스 플랫폼(iOS+Android), UI 중심, 기존 코드 재활용
- Senior 앱 Native: flutter_webrtc 한계, HW 직접 제어
- Firebase 선택: onDisconnect, 실시간 동기화, FCM 통합
- 소셜 로그인 4종: Google + Apple + 카카오 + 네이버 (한국 시장)
- 카카오/네이버: Firebase Custom Token via Cloud Functions
