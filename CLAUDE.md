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

Mac Mini (`~/projects/Family/`) — iOS 빌드 + 테스트 전용 (git pull → flutter run)

- **Family 앱**: 로그인, 페어링, 영상통화 발신, CCTV 모니터링, 사진 업로드, 복약 알림 설정, 기기 관리
- **Senior 앱**: 영상통화 수신, 얼굴감지 자동응답, 슬라이드쇼, 복약 알림 재생, CCTV 모니터링 수신
- **백엔드**: Firebase 공유 (RTDB, FCM, Storage, Auth) + Cloud Functions

## 현재 상태

- Phase 1 완료: 시니어 전용 코드 제거
- Phase 2 완료: 소셜 로그인 4종 (Google, Apple, Kakao, Naver)
- Phase 3 완료: 페어링 시스템
- RTDB 스키마 재설계 완료: ANDROID_ID, 비정규화 제거, _label, 고아 방지
- CCTV 모니터링 + 영상 알림 구현 완료
- Cloud Function RTDB 트리거 (Storage 자동 정리) 구현 완료
- iOS 빌드 환경 셋업 완료 (Mac Mini)

## Architecture

- **인증**: Firebase Auth (Google/Apple/카카오/네이버)
- **시그널링**: Firebase RTDB (`/calls/{callId}/`)
- **영상통화**: WebRTC (flutter_webrtc)
- **CCTV 모니터링**: WebRTC 단방향 (Senior→Family 영상만)
- **푸시 알림**: FCM
- **파일 저장**: Firebase Storage (임시 버퍼 — Senior 다운로드 후 Cloud Function이 삭제)
- **가족 그룹**: RTDB `/families/{familyId}/` (페어링)
- **복약 알림**: RTDB `/families/{familyId}/reminders/`
- **기기 관리**: RTDB `/devices/{deviceId}/` (Senior만 등록, Family는 `/users/{uid}`로 식별)
- **고아 방지**: Cloud Function 와치독 + RTDB 트리거 + onCreate familyId 검증

### RTDB 핵심 설계 원칙

- **비정규화 최소화**: `/families/{fid}/devices/{did}: true` (목록만), 상세정보는 `/devices/{did}`에서만
- **Family 기기 미등록**: `/devices/`에 Family 폰 안 씀. 사용자는 `/users/{uid}`로만 식별
- **Storage 삭제는 Cloud Function만**: 앱에서 Storage 직접 삭제 안 함 (Senior는 Auth 없음)
- **`_label` 필드**: 모든 RTDB 노드에 Console 가독성용 라벨

## 디렉토리 구조 (현재)

```text
lib/
├── main.dart                              # 진입점 (Firebase 초기화)
├── app.dart                               # SeniorCareFamily 위젯 + 라우팅 + PairingGate
├── config/
│   └── app_config.dart                    # 기기 정보 (Platform 분기: Android/iOS)
├── screens/
│   ├── login_screen.dart                  # 소셜 로그인 (Google/Apple/Kakao/Naver)
│   ├── pairing_screen.dart                # 페어링 코드 입력
│   ├── device_list_screen.dart            # 홈 (가족별 기기 목록)
│   ├── family_detail_screen.dart          # 가족 상세 (기기 상태, 사진, 알림)
│   ├── monitoring_screen.dart             # CCTV 모니터링 + 양방향 통화 (callType 파라미터)
│   ├── photo_upload_screen.dart           # 사진 업로드
│   └── reminder/
│       ├── reminder_list_screen.dart      # 알림 목록
│       └── reminder_edit_screen.dart      # 알림 생성/수정
├── services/
│   ├── auth_service.dart                  # 로그인/로그아웃
│   ├── family_service.dart                # 가족 그룹 CRUD + 멤버 관리
│   ├── fcm_service.dart                   # FCM 토큰
│   ├── pairing_helper.dart                # 페어링 후 가족이름/내이름 설정 (공통 모듈)
│   ├── photo_transfer_service.dart        # 사진 업로드 (Storage 임시 버퍼)
│   ├── call/
│   │   ├── signaling_service.dart         # RTDB 시그널링
│   │   └── webrtc_service.dart            # WebRTC (makeCall, startMonitoring)
│   └── reminder/
│       └── reminder_service.dart          # 알림 CRUD + Storage 업로드
```

## Build & Deploy

### Android (Windows)

```bash
flutter build apk --debug
adb -s <serial> install -r build/app/outputs/flutter-apk/app-debug.apk
```

테스트 기기:
- **SM-G991N** (Galaxy S21, `R3CR700SEKP`) → Family 앱 테스트
- **SM-T500** (Galaxy Tab A7, `R9TT903QE5V`) → Senior 앱. **절대 Family 앱 설치 금지**
- **A20** (`31f75915d0414881c94`) → Senior 앱

### iOS (Mac Mini — SSH/Parsec)

```bash
# Mac Mini 접속 방법
# SSH: ssh JHS@100.104.120.76 (Tailscale) / password: 1231
# MCP: connectionName=macmini (ssh-mcp-server에 등록됨)
# Parsec: GUI 필요 시 (시뮬레이터 화면, Xcode 설정 등)

# Mac Mini에서 빌드 + 실행
cd ~/projects/Family
git pull                    # Windows에서 push한 코드 받기
security unlock-keychain ~/Library/Keychains/login.keychain-db   # Keychain 잠금 해제 (pw: 1231)
flutter run -d 00008110-000C48390ADA801E 2>&1 | tee ~/projects/Family/tmp/flutter.log

# 로그 확인 (SSH로)
tail -f ~/projects/Family/tmp/flutter.log
```

- **Mac Mini**: Apple M4, 16GB, macOS 26.2, Tailscale IP `100.104.120.76`
- **프로젝트 경로**: `~/projects/Family/` (git clone)
- Xcode 26.3, Flutter 3.41.4, CocoaPods 1.16.2
- iOS Podfile: `platform :ios, '15.0'`
- Apple Developer: 개인 계정 (roxm1234@naver.com), Team ID: 85UGG849SL
- Bundle ID: `com.seniorcare.family` (Android와 동일, 무료 개인 팀 — 7일 서명 만료)
- **코드 수정은 반드시 Windows에서** → push → Mac Mini에서 pull (충돌 방지)
- **Mac Mini에서 코드 수정 금지** (git 충돌 원인)
- iOS 테스트 기기: **Sol** (iPhone, `00008110-000C48390ADA801E`)

## Cloud Functions

```bash
cd functions
npm install              # 최초 1회
firebase deploy --only functions
```

- Firebase 서버에서 실행되는 Node.js 함수 (앱과 독립)
- 서비스 계정 키: `functions/dcom-smart-frame-firebase-adminsdk-fbsvc-592311d9ff.json`
  - **절대 git에 올리면 안 됨** (.gitignore 처리됨)
- Firebase Console → 호스팅, 서버리스 → Functions 에서 로그/상태 확인

### Cloud Functions 목록

| 함수명 | 트리거 | 역할 |
|--------|--------|------|
| `kakaoCustomToken` | HTTP | 카카오 로그인 → Firebase Custom Token |
| `naverCustomToken` | HTTP | 네이버 로그인 → Firebase Custom Token |
| `onPhotoDownloaded` | RTDB `downloadedBy/{did}` create | 모든 Senior 다운로드 완료 → Storage 삭제 + status: done |
| `onPhotoDeleted` | RTDB `photoSync/{photoId}` delete | photoSync 노드 삭제 → 썸네일 Storage 즉시 삭제 |
| `onReminderMediaDownloaded` | RTDB `mediaDownloaded` update | targetDevice 다운로드 완료 → Storage 삭제 |
| `onReminderDeleted` | RTDB `reminders/{rid}` delete | 알림 삭제 → Storage 파일 삭제 |
| `cleanupExpiredPhotos` | 스케줄 6시간 | 만료 사진 정리 |
| `cleanupExpiredPhotosManual` | HTTP | 수동 트리거 |
| `cleanupOrphanedData` | 스케줄 매일 3시 | 고아 RTDB + Storage 정리 |
| `cleanupOrphanedDataManual` | HTTP | 수동 트리거 |

수동 테스트 URL:
- `https://us-central1-dcom-smart-frame.cloudfunctions.net/cleanupOrphanedDataManual`
- `https://us-central1-dcom-smart-frame.cloudfunctions.net/cleanupExpiredPhotosManual`

## 주요 문서

- `docs/RTDB_schema.md` — RTDB 전체 스키마
- `docs/datachannel-photo-transfer.md` — 미디어 전송 설계 (사진 + 알림, 임시 버퍼 패턴)
- `docs/smart-frame-plan.md` — 전체 구현 계획 (Phase 1~7)
- `docs/to_do.md` — 현재 TODO
- `E:\App\Senior\docs\family-integration-plan.md` — Senior 앱 연동 수정 가이드
- `E:\App\Senior\docs\chg.md` — Senior 변경 이력

## 기술 결정 이력

- Flutter 유지: 크로스 플랫폼(iOS+Android), UI 중심, 기존 코드 재활용
- Senior 앱 Native: flutter_webrtc 한계, HW 직접 제어
- Firebase 선택: onDisconnect, 실시간 동기화, FCM 통합
- 소셜 로그인 4종: Google + Apple + 카카오 + 네이버 (한국 시장)
- 카카오/네이버: Firebase Custom Token via Cloud Functions
- Naver 로그인: flutter_naver_login 플러그인 버림 → MethodChannel + 네이티브 SDK 직접 사용
- Device ID: `Build.ID` → `Settings.Secure.ANDROID_ID` (iOS는 `identifierForVendor`)
- RTDB 비정규화 제거: `/families/{fid}/devices/{did}: true`만, 상세는 `/devices/`에서
- Storage 삭제: Cloud Function RTDB 트리거로 일원화 (앱에서 직접 삭제 안 함)
- 개발 환경: Windows(Android) + Mac Mini(iOS), 코드 수정은 Windows에서만

## Git 커밋 규칙

- `Co-Authored-By: Claude` 등 co-author 태그 커밋 메시지에 **절대 포함하지 말 것**
