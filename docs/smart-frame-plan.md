# Smart Photo Frame App 구현 계획

## Context
현재 Flutter 기본 카운터 앱(`senior_win`)을 **스마트 액자 앱**으로 변환한다.
주 타겟은 Android. assets에 번들된 사진들을 10초 간격으로 슬라이드쇼로 보여주며, 화면이 절대 꺼지지 않아야 한다.

## 구현 접근법
- **StatefulWidget + Timer.periodic + AnimatedSwitcher** 조합
- `Timer.periodic`으로 10초마다 인덱스 변경 → `AnimatedSwitcher`가 페이드 전환 처리
- `wakelock_plus` 패키지로 화면 꺼짐 방지
- `SystemChrome.setEnabledSystemUIMode(immersiveSticky)`로 전체화면

## 파일 변경 목록

### 1. `assets/images/` 디렉토리 생성 + 플레이스홀더 이미지
- 디렉토리 생성
- 테스트용 컬러 플레이스홀더 PNG 3장 생성 (핑크, 블루, 그린 / 800x600)

### 2. `pubspec.yaml` 수정
- `wakelock_plus: ^1.4.0` 의존성 추가
- `assets/images/` 에셋 선언 추가

### 3. `android/app/src/main/AndroidManifest.xml` 수정
- `<uses-permission android:name="android.permission.WAKE_LOCK"/>` 추가

### 4. `lib/widgets/photo_frame_view.dart` 신규 생성
- `AnimatedSwitcher` + `Image.asset` 표시 위젯
- 검정 배경, `BoxFit.contain`, 페이드 전환 (800ms)

### 5. `lib/screens/slideshow_screen.dart` 신규 생성
- 이미지 경로 리스트 관리
- `Timer.periodic` (10초) → `_currentIndex` 순환
- `initState`: WakelockPlus.enable(), immersive fullscreen 설정
- `dispose`: timer cancel, wakelock disable, UI 복원

### 6. `lib/main.dart` 전면 재작성
- `SmartFrameApp` → `MaterialApp(dark theme)` → `SlideshowScreen`
- `debugShowCheckedModeBanner: false`

### 7. `test/widget_test.dart` 업데이트
- 기존 MyApp 참조 → SmartFrameApp으로 변경

## 구현 순서
1. `assets/images/` 디렉토리 생성 + 플레이스홀더 이미지 3장 생성
2. `pubspec.yaml` 수정 (의존성 + 에셋)
3. `flutter pub get` 실행
4. `AndroidManifest.xml` 수정 (WAKE_LOCK 권한)
5. `lib/widgets/photo_frame_view.dart` 생성
6. `lib/screens/slideshow_screen.dart` 생성
7. `lib/main.dart` 재작성
8. `flutter run` 으로 테스트

---

## 검증 결과 (2026-02-06)

### 환경
- Flutter 3.38.9 (stable), Dart 3.10.8
- 에뮬레이터: Medium Phone API 36.1 (Android 16, API 36)

### 빌드 검증
| 항목 | 결과 |
|------|------|
| `flutter pub get` | 성공 (wakelock_plus 1.4.0 설치) |
| `flutter analyze` | **No issues found!** |
| `flutter run -d emulator-5554` | APK 빌드 및 설치 성공 (739ms) |

### 기능 검증
| 항목 | 결과 |
|------|------|
| 전체화면 몰입 모드 | 상태바/네비게이션바 숨김 확인 (`immersiveSticky`) |
| 슬라이드쇼 전환 | 10초 간격 페이드 전환 작동 확인 |
| Wake Lock 활성화 | `SCREEN_BRIGHT_WAKE_LOCK` 활성 확인 (`adb shell dumpsys power`) |
| Wake Lock 테스트 | 화면 타임아웃 15초 설정 후 앱 실행 중 화면 안 꺼짐 확인 |
| Wake Lock 해제 테스트 | 홈으로 나간 후 15초 뒤 화면 꺼짐 확인 |

### 검증에 사용한 ADB 명령어
```bash
# 화면 타임아웃 15초로 설정
adb shell settings put system screen_off_timeout 15000

# 현재 타임아웃 확인
adb shell settings get system screen_off_timeout

# Wake Lock 활성 상태 확인
adb shell dumpsys power | grep -A 5 "Wake Locks: size"

# 홈 버튼 (immersive 모드에서 네비바 안 보일 때)
adb shell input keyevent KEYCODE_HOME

# 화면 깨우기
adb shell input keyevent KEYCODE_WAKEUP
```

### 참고 사항
- Kotlin 증분 컴파일 캐시 경고 발생 (C: vs E: 드라이브 차이) — 빌드/기능에 영향 없음
- `immersiveSticky` 모드에서 하단 스와이프로 네비게이션바 일시 표시 가능
- Windows에서 `SystemChrome.setEnabledSystemUIMode`는 no-op (정상)

---

## 키오스크 모드 추가 (2026-02-20)

### 방식: 홈 런처 등록 + 부팅 자동실행

**홈 런처**로 등록하면 홈 버튼을 눌러도 이 앱으로 돌아오고,
**부팅 자동실행**으로 태블릿이 켜지면 바로 앱이 뜬다.

### 변경 파일

#### 1. `android/app/src/main/AndroidManifest.xml`
- `RECEIVE_BOOT_COMPLETED` 권한 추가
- 홈 런처 intent-filter 추가 (`HOME` + `DEFAULT` 카테고리)
- `BootReceiver` BroadcastReceiver 선언

#### 2. `android/app/src/main/kotlin/.../BootReceiver.kt` (신규)
- `BOOT_COMPLETED` 인텐트 수신 시 `MainActivity` 자동 실행

### 동작 방식
1. **부팅 완료** → Android가 `BOOT_COMPLETED` 브로드캐스트 발송
2. **BootReceiver** 수신 → `MainActivity` 시작 (FLAG_ACTIVITY_NEW_TASK)
3. **홈 버튼** → HOME 카테고리로 등록되어 있으므로 이 앱으로 복귀
4. 첫 설치 시 "홈 앱 선택" 다이얼로그 → 이 앱을 "항상"으로 선택

### 해제 방법
- 태블릿 설정 > 앱 > 기본 앱 > 홈 앱 → 다른 런처로 변경
- 또는 앱 삭제 시 자동 해제

### 빌드 검증
- `flutter analyze` — 에러 없음 (print 경고만 존재, 디버깅용)

---

## Privacy-Safe Auto Answer (사생활 보호 자동 수신) 추가 (2026-02-23)

### Context
슬라이드쇼 + 키오스크 모드에 **영상 통화 자동 수신** 기능을 추가한다.
가족용 별도 모바일 앱에서 전화를 걸면, 스마트 액자가 전방 얼굴을 감지한 후에만 영상을 송출하여
어르신의 사생활을 보호한다. 백엔드 경험이 없으므로 **Firebase로 통합 처리**한다.

### 전체 흐름

```
[평상시] 슬라이드쇼 실행 중 (화면 항상 켜짐)
    ↓
[1. FCM 수신] 가족 앱에서 통화 요청 → FCM 푸시 도착
    ↓
[2. 벨소리] 화면 깨우기 + 벨소리 재생
    ↓
[3. 검증 (Buffer Zone)] 전면 카메라 ON (영상 송출 X)
    → On-device AI로 얼굴 감지 (15초 타임아웃)
    ↓
[4-A. 얼굴 감지 O] → 3초 대기 → 양방향 영상 통화 시작
[4-B. 얼굴 감지 X] → "지금은 연결할 수 없습니다" TTS 안내 → 종료 or 음성모드
```

### 기술 스택

| 기능 | 패키지 | 역할 |
|------|--------|------|
| FCM 푸시 | `firebase_core` + `firebase_messaging` | 통화 요청 수신 |
| 시그널링 | Firebase Realtime DB | WebRTC 연결 중개 (별도 서버 불필요) |
| 얼굴 감지 | `google_mlkit_face_detection` | On-device AI, 프라이버시 보장 |
| 카메라 | `camera` | 전면 카메라 프리뷰 + 프레임 스트리밍 |
| 영상 통화 | `flutter_webrtc` | P2P 양방향 영상/음성 |
| 벨소리 | `just_audio` | 알림음 재생 |
| 안내 음성 | `flutter_tts` | "연결할 수 없습니다" 등 TTS |
| 권한 관리 | `permission_handler` | 카메라/마이크 런타임 권한 |

### 프로젝트 구조 (분리형)

```
E:\App\
├── Senior/              # Smart Frame 앱 (수신측 - 현재 프로젝트)
├── Caller/              # 가족 앱 (발신측 - Phase 4에서 생성)
└── web-test-caller/     # 웹 테스트 페이지 (Phase 3 개발용, 임시)
```

### 구현 Phase

#### Phase 1: Firebase 기본 설정 + FCM 수신
- `pubspec.yaml` — firebase_core, firebase_messaging, just_audio, permission_handler 추가
- `android/app/build.gradle` — Google Services 플러그인 적용
- `android/app/google-services.json` — Firebase 콘솔에서 다운로드
- `AndroidManifest.xml` — INTERNET, CAMERA, RECORD_AUDIO 권한 추가
- `lib/services/fcm_service.dart` (신규) — FCM 토큰 관리 + 메시지 수신 핸들러
- 검증: Firebase 콘솔에서 테스트 푸시 → 벨소리 재생 확인

#### Phase 2: 카메라 + 얼굴 감지 (Buffer Zone)
- `lib/services/face_detection_service.dart` (신규) — 카메라 프레임 → ML Kit 얼굴 감지
- `lib/screens/incoming_call_screen.dart` (신규) — 수신 UI (카메라 프리뷰 + 벨소리 + 타이머)
- 15초 타임아웃 → TTS "연결할 수 없습니다" 안내

#### Phase 3: WebRTC 영상 통화 + 웹 테스트 페이지
- `lib/services/webrtc_service.dart` (신규) — WebRTC 피어 연결
- `lib/services/signaling_service.dart` (신규) — Firebase Realtime DB 시그널링
- `lib/screens/video_call_screen.dart` (신규) — 양방향 영상 통화 UI
- `E:\App\web-test-caller\index.html` — 브라우저 발신 테스트 페이지

#### Phase 4: 가족 앱 (발신측 - 최종)
- `E:\App\Caller\` — 별도 Flutter 프로젝트
- 전화 걸기 버튼 + FCM 발송 + WebRTC 발신

#### Phase 5: 통합 테스트 + 폴리싱
- E2E 전체 흐름 테스트
- 에러 핸들링, 음성모드 폴백

### 최종 파일 구조

```
lib/
├── main.dart                          # 앱 진입점, Firebase 초기화
├── screens/
│   ├── slideshow_screen.dart          # 슬라이드쇼 (기존)
│   ├── incoming_call_screen.dart      # 수신 UI (벨소리 + 카메라 + 얼굴감지)
│   └── video_call_screen.dart         # 양방향 영상 통화
├── widgets/
│   └── photo_frame_view.dart          # 사진 표시 (기존)
└── services/
    ├── fcm_service.dart               # FCM 토큰/메시지 관리
    ├── face_detection_service.dart     # 카메라 + ML Kit 얼굴 감지
    ├── webrtc_service.dart            # WebRTC 피어 연결
    └── signaling_service.dart         # Firebase Realtime DB 시그널링
```

### 추가 Android 권한

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
```

### 추가 의존성

```yaml
firebase_core: ^2.24.0
firebase_messaging: ^14.7.0
firebase_database: ^10.4.0
google_mlkit_face_detection: ^0.11.0
camera: ^0.10.5
flutter_webrtc: ^0.9.28
just_audio: ^0.9.36
flutter_tts: ^0.67.0
permission_handler: ^11.4.0
```
