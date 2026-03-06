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
│   └── web-test-caller\ # 웹 테스트 페이지 (발신 + 사진 업로드)
└── Caller/              # 가족 앱 (발신측 - Phase 4에서 생성)
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
- `E:\App\Senior\web-test-caller\index.html` — 브라우저 발신 테스트 페이지

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

---

## Firebase 사진 관리 기능 (2026-03-05)

### Context

현재 슬라이드쇼 사진은 **APK에 빌드 시 포함된 정적 에셋** (`assets/images/`).
사진 변경하려면 코드에 파일 추가 → 빌드 → 재설치 필요.
Firebase Storage + RTDB를 활용해 **원격으로 사진을 관리**하고 **실시간 동기화**하는 기능 추가.

### 사용자 구분 (향후)

| 역할 | 기기 | 로그인 | 기능 |
|------|------|--------|------|
| **시니어** | 태블릿 (키오스크 모드) | 불필요 | 사진 표시 + 영상통화 수신 |
| **자식** | 핸드폰 (여러명) | 필요 | 사진 업로드 + 영상통화 발신 |

현재 단계: 테스트용 웹 페이지로 업로드

### 아키텍처

```
[자식 핸드폰/웹]                    [Firebase]                    [시니어 태블릿]
     │                                │                                │
     │  사진 업로드                    │                                │
     ├──→ Firebase Storage ──────────┤                                │
     │    /photos/{deviceId}/        │                                │
     │                                │                                │
     │  메타데이터 저장               │   실시간 리스너                │
     ├──→ RTDB /photos/{deviceId}/ ──┼──────────────────────────────→ │
     │    {url, name, timestamp}     │                                │
     │                                │    새 사진 감지 → 다운로드     │
     │                                │    → 로컬 캐시 → 슬라이드쇼   │
```

### 동작 흐름

```
1. 자식이 사진 업로드
   → Firebase Storage에 파일 저장
   → RTDB /photos/{deviceId}/{photoId}에 메타데이터 저장

2. 시니어 태블릿 (실시간 리스너)
   → RTDB 변경 감지
   → Storage에서 다운로드 → 로컬 캐시 저장
   → 슬라이드쇼에 즉시 반영

3. 사진 삭제 시
   → RTDB에서 메타데이터 삭제
   → 태블릿이 감지 → 로컬 캐시에서도 삭제
   → 슬라이드쇼에서 즉시 제거
```

### RTDB 데이터 구조

```
Firebase RTDB
├── /devices/{deviceId}/     ← 기존 (기기 등록/온라인 상태)
├── /calls/{callId}/         ← 기존 (영상통화 시그널링)
└── /photos/{deviceId}/      ← 신규 (사진 메타데이터)
      └── {photoId}/
            ├── url: "https://firebasestorage.googleapis.com/..."
            ├── name: "family_photo.jpg"
            ├── size: 2048000
            ├── uploadedBy: "child_user_uid"
            ├── uploadedAt: 1709654400000  (ServerValue.timestamp)
            └── order: 1  (슬라이드쇼 순서, optional)
```

### 구현 단계

#### Step 1: Firebase Storage 설정 + 패키지 추가
- `pubspec.yaml`에 `firebase_storage`, `path_provider` 추가
- Firebase Console에서 Storage 활성화 + 규칙 설정

#### Step 2: PhotoService 신규 작성

```dart
// lib/services/photo_service.dart
class PhotoService {
  // RTDB /photos/{deviceId}/ 실시간 리스너
  void listenForPhotos(String deviceId, Function(List<PhotoItem>) onUpdate);

  // Firebase Storage에서 다운로드 → 로컬 캐시
  Future<File> downloadAndCache(String url, String photoId);

  // 로컬 캐시된 사진 목록 반환
  Future<List<File>> getCachedPhotos();

  // 캐시 정리 (삭제된 사진)
  Future<void> cleanupCache(List<String> activePhotoIds);

  void dispose();
}
```

#### Step 3: SlideshowScreen 수정

```
앱 시작 → PhotoService.listenForPhotos()
  ├── Firebase 사진 있음 → 다운로드/캐시 → 슬라이드쇼
  └── Firebase 사진 없음 → 기존 assets/images/ 폴백
```

#### Step 4: PhotoFrameView 수정

```dart
// 로컬 캐시 파일이면 Image.file(), 에셋이면 Image.asset()
child: isAsset
  ? Image.asset(imagePath, fit: BoxFit.contain, ...)
  : Image.file(File(imagePath), fit: BoxFit.contain, ...)
```

#### Step 5: 테스트 업로드 웹 페이지

```
E:\App\Senior\web-test-caller\photo-upload.html
  ├── 기기 선택 (RTDB /devices/ 에서 온라인 기기 목록)
  ├── 사진 파일 선택 (multiple)
  ├── Firebase Storage 업로드 → URL 획득
  └── RTDB /photos/{deviceId}/ 에 메타데이터 저장
```

### 수정 파일 요약

| 파일 | 작업 | 설명 |
|------|------|------|
| `pubspec.yaml` | 수정 | firebase_storage, path_provider 추가 |
| `lib/services/photo_service.dart` | 신규 | 사진 동기화 서비스 (RTDB 리스너 + Storage 다운로드 + 로컬 캐시) |
| `lib/models/photo_item.dart` | 신규 | 사진 메타데이터 모델 클래스 |
| `lib/screens/slideshow_screen.dart` | 수정 | PhotoService 연동, Firebase/에셋 분기 |
| `lib/widgets/photo_frame_view.dart` | 수정 | Image.file() 지원 추가 |
| `web-test-caller\photo-upload.html` | 신규 | 테스트용 웹 업로드 페이지 |

### Firebase Storage 규칙

```
// 테스트 단계 (인증 없이 누구나 읽기/쓰기)
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /photos/{deviceId}/{allPaths=**} {
      allow read: if true;
      allow write: if true;
    }
  }
}

// 프로덕션 (인증된 사용자만 쓰기)
// allow write: if request.auth != null;
```

### 비용 분석

#### 4대 (현재 개발/테스트) — 무료 (Spark Plan)

| 항목 | 무료 한도 | 예상 사용량 |
|------|-----------|------------|
| Storage 저장 | 5GB | ~300MB |
| Storage 다운로드 | 1GB/일 | ~1.2GB (최초 1회) |
| RTDB 동시연결 | 100개 | 4개 |
| FCM | 무제한 | 수 회/주 |

#### 1000대 양산 (Blaze Plan) — ~$15/월 (~20,000원)

가정: 가정당 100장(평균 3MB), 주 5장 신규, 영상통화 주 2~3회(5분)

| 항목 | 계산 | 월 비용 |
|------|------|---------|
| Storage 저장 | 1000 × 300MB = 300GB | $7.80 |
| Storage 다운로드 (신규) | 1000 × 60MB = 60GB/월 | $7.20 |
| RTDB 저장 | ~20MB (메타데이터) | $0 |
| RTDB 다운로드 | ~200MB (메타 + 시그널링) | $0 |
| RTDB 동시연결 | 1000개 (Blaze 200K 무료) | $0 |
| 영상통화 (WebRTC P2P) | Firebase 안 거침 | $0 |
| FCM 푸시 | 10,000회/월 | $0 |
| **월 합계** | | **~$15** |

최초 배포 시 1000대 일괄 다운로드: +$36 (1회성)

**대당 월 20원. 핵심은 로컬 캐시 관리** (캐시 깨지면 재다운로드 비용 발생).

#### 비용 리스크

| 시나리오 | 추가 비용 |
|---------|----------|
| 캐시 전부 깨짐 (1000대 × 300MB) | +$36/회 |
| 사진 1000장으로 증가 | 저장 $26/월 |
| 영상통화 빈도 증가 | 영향 없음 (P2P) |

### Firebase vs Supabase 비교

| 항목 | Firebase | Supabase |
|------|----------|----------|
| 실시간 DB | RTDB (매우 빠름) | Realtime (Postgres 기반) |
| onDisconnect | 네이티브 지원 (사용 중) | 없음 |
| 오프라인 동기화 | RTDB 자동 캐시 | 없음 |
| FCM 푸시 | 기본 내장 (사용 중) | 별도 서비스 필요 |
| 시그널링 속도 | ms 단위 | 상대적 느림 |
| 1000대 비용 | ~$15/월 | ~$25/월 (Pro 고정) |

**결론: Firebase 유지.** 시그널링/FCM/onDisconnect 모두 Firebase 기반 구현 완료.
향후 자식 앱이 복잡해지면 자식 앱 백엔드만 Supabase 하이브리드 가능.

### 검증 방법

1. `flutter build apk --release` 빌드 성공
2. 웹 업로드 페이지에서 사진 업로드
3. 태블릿 앱 시작 → 실시간으로 새 사진 슬라이드쇼 추가 확인
4. Firebase Console에서 사진 삭제 → 슬라이드쇼에서 제거 확인
5. Firebase 사진 전부 삭제 → 기존 에셋 이미지 폴백 확인
6. 앱 재시작 → 캐시된 사진 즉시 표시 (재다운로드 없이)
