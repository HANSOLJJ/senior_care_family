# Senior Care Family

시니어 케어 시스템의 **가족용 앱** (Flutter)

시니어 태블릿에 영상통화를 걸고, 사진을 업로드하고, 복약 알림을 설정하고, 기기를 관리하는 앱입니다.

## 시스템 구성

```text
Senior Care System
├── Family App (이 프로젝트) - 가족용, Flutter (iOS + Android)
├── Senior App              - 시니어 태블릿용, Android Native (Kotlin)
└── Firebase                - RTDB, FCM, Storage, Auth (공유)
```

## 주요 기능

### 구현 완료

- 시니어 기기 목록 조회 (온라인/오프라인 상태)
- 시니어 태블릿에 영상통화 발신 (WebRTC P2P)

### 구현 예정

- 소셜 로그인 (Google / Apple / 카카오 / 네이버)
- 페어링 시스템 (시니어 기기 QR코드/6자리 코드)
- 가족 초대 (초대 코드로 추가 가족 멤버 참여)
- 사진 업로드 (Firebase Storage → 시니어 슬라이드쇼)
- 복약 알림 설정 (시간/반복/영상 첨부 → 시니어 기기에서 재생)
- 복약 확인 모니터링 (얼굴 감지 기반 확인/미확인 알림)
- 통화 기록 (발신/부재중/통화시간)
- 기기 관리 (이름 변경, 상태 모니터링, 연결 해제)

## 기술 스택

- **Flutter** — 크로스 플랫폼 (iOS + Android)
- **WebRTC** — flutter_webrtc (로컬 패치 플러그인, AEC3 + RNNoise)
- **Firebase Auth** — 소셜 로그인
- **Firebase Realtime Database** — 시그널링, 기기 상태, 가족 그룹, 알림
- **Firebase Cloud Messaging** — 푸시 알림
- **Firebase Storage** — 사진/영상 업로드

## 빌드

```bash
# 의존성 설치
flutter pub get

# 릴리즈 APK 빌드
flutter build apk --release

# 기기에 설치
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## 패키지 정보

- **Dart 패키지명**: `senior_care_family`
- **Android Application ID**: `com.seniorcare.family`
- **iOS Bundle ID**: `com.seniorcare.family`

## 문서

- [프로젝트 구조](docs/project-structure.md) — 디렉토리 구조, RTDB 스키마, 화면 흐름
- [구현 계획](docs/smart-frame-plan.md) — Phase 1~7 상세 계획
