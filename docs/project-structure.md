# Senior Care Family App - 프로젝트 구조

가족(자식)용 앱 (Flutter). 시니어 태블릿에 영상통화 발신 + 사진 업로드 + 복약 알림 + 기기 관리.

---

## 기술 스택

| 분류 | 기술 | 용도 |
|------|------|------|
| **프레임워크** | Flutter (Dart SDK ^3.10.8) | 크로스 플랫폼 (iOS + Android) |
| **영상통화** | WebRTC (flutter_webrtc 1.3.0 로컬 패치) | P2P 영상/음성 |
| **시그널링** | Firebase Realtime Database | offer/answer/ICE 교환 |
| **인증** | Firebase Auth | Google/Apple/카카오/네이버 소셜 로그인 |
| **푸시 알림** | Firebase Cloud Messaging (FCM) | 통화 수신, 복약 미확인 알림 |
| **파일 저장** | Firebase Storage | 사진 업로드 (임시 → Senior 다운로드 후 삭제) |
| **오디오** | just_audio | 벨소리 재생 |
| **에코 제거** | WebRTC AEC3 + RNNoise v0.2 (NDK/JNI) | 에코/노이즈 억제 |

---

## 전체 시스템 구조

```
E:\App\
├── Family\     ← 이 프로젝트 (자식용, Flutter)
└── Senior\     ← 시니어 태블릿용 (Android Native)
```

- **Family 앱**: 로그인, 페어링, 영상통화 발신, 사진 업로드, 복약 알림 설정, 기기 관리
- **Senior 앱**: 영상통화 수신, 얼굴감지 자동응답, 슬라이드쇼, 복약 알림 재생
- **백엔드**: Firebase 공유 (RTDB, FCM, Storage, Auth)

---

## 디렉토리 구조

```
lib/
├── main.dart                              # 앱 진입점 (Firebase + RTDB persistence + 카카오 SDK 초기화)
├── app.dart                               # SeniorCareFamily 위젯 + 인증/페어링 분기 + OfflineOverlay 래핑 + ConnectivityService.start
│
├── config/
│   └── app_config.dart                    # 기기 정보, Firebase 기기 등록 (fire-and-forget), DeviceProfile
│
├── screens/                               # (모든 State는 SafeStateMixin 적용 — safeSetState 사용)
│   ├── login_screen.dart                  # 소셜 로그인 (Google/Apple/카카오/네이버)
│   ├── pairing_screen.dart                # 페어링 코드 입력 / QR 스캔
│   ├── device_list_screen.dart            # 홈 — 가족 목록 (1명이면 자동 상세 진입)
│   ├── family_detail_screen.dart          # 가족 상세 — 기기상태/액션버튼/사진/멤버
│   ├── monitoring_screen.dart             # CCTV 모니터링 + 양방향 통화 (callType 파라미터) + 재연결 오버레이
│   ├── photo_upload_screen.dart           # 사진 선택/촬영 + 업로드 + 그리드 목록
│   └── reminder/
│       ├── reminder_list_screen.dart      # 알림 목록
│       └── reminder_edit_screen.dart      # 알림 생성/수정
│
├── services/                              # (Firebase 핸들 필요 서비스는 FirebaseInstancesMixin 적용 — db/auth/storage getter)
│   ├── auth_service.dart                  # 로그인/로그아웃/프로필 (4종 소셜) — with FirebaseInstancesMixin
│   ├── family_service.dart                # 가족 그룹 참가/탈퇴, 멤버 관리, 가족 이름 설정 — with FirebaseInstancesMixin
│   ├── fcm_service.dart                   # FCM 토큰 관리 + RTDB 저장
│   ├── pairing_helper.dart                # 페어링 후 가족이름/내이름 설정 (공통)
│   ├── photo_transfer_service.dart        # 사진 업로드 (Storage 임시 버퍼) — with FirebaseInstancesMixin
│   ├── connectivity_service.dart          # 전역 네트워크 감시 (connectivity_plus + /.info/connected) — ValueNotifier<bool> isOnline
│   ├── network_guard.dart                 # writeOrTimeout: RTDB 쓰기 5초 타임아웃 + NetworkException
│   ├── firebase_instances_mixin.dart      # Firebase 싱글톤 접근자 mixin (db/auth/storage)
│   ├── call/
│   │   ├── signaling_service.dart         # RTDB 시그널링 (offer/answer/ICE/iceRestartOffer/iceRestartAnswer) — listen* 모두 StreamSubscription 반환
│   │   └── webrtc_service.dart            # WebRTC (makeCall/startMonitoring/startCall/upgradeToCall) + ICE Restart 상태머신 + ValueNotifier<bool> isReconnecting
│   └── reminder/
│       └── reminder_service.dart          # 알림 CRUD + Storage 업로드 — with FirebaseInstancesMixin
│
└── widgets/
    ├── safe_state_mixin.dart              # SafeStateMixin — async 콜백에서 안전한 setState (mounted 체크 자동)
    └── offline_overlay.dart               # 전역 오프라인 블로킹 오버레이 (ConnectivityService.isOnline 구독)
```

### Android 네이티브

```
android/app/src/main/
├── AndroidManifest.xml                    # 권한 (카메라, 마이크, 인터넷)
├── kotlin/com/seniorcare/family/
│   ├── MainActivity.kt                   # FlutterActivity (기본)
│   └── NaverLoginHelper.kt               # 네이버 SDK MethodChannel 브릿지
└── google-services.json                   # Firebase 설정
```

### Cloud Functions (서버리스)

```
functions/
├── index.js                              # Cloud Functions 진입점
│   ├── kakaoCustomToken                  # 카카오 로그인 → Firebase Custom Token
│   ├── naverCustomToken                  # 네이버 로그인 → Firebase Custom Token
│   └── cleanupExpiredPhotos              # 만료 사진 정리 (6시간마다 스케줄)
├── package.json                          # 의존성 (firebase-admin, firebase-functions)
└── dcom-smart-frame-firebase-adminsdk-*.json  # 서비스 계정 키 (gitignore)
```

---

## Firebase 구성

- **프로젝트**: `dcom-smart-frame`
- **패키지명**: `com.seniorcare.family`
- **RTDB URL**: `https://dcom-smart-frame-default-rtdb.firebaseio.com`

---

## Firebase 데이터 스키마

RTDB + Storage 스키마는 별도 문서 참조: [RTDB_schema.md](RTDB_schema.md)

---

## 앱 화면 흐름

```
앱 시작 → Firebase 초기화 + RTDB persistence + 기기 등록 (fire-and-forget)
  ↓
Firebase Auth 상태 확인
  ├─ 미로그인 → LoginScreen (Google/Apple/카카오/네이버)
  └─ 로그인됨 → 가족 그룹 확인
      ├─ 미페어링 → PairingScreen (코드 입력 / QR 스캔)
      │              → 페어링 완료 시 가족 이름 입력 다이얼로그
      └─ 페어링됨 → DeviceListScreen
          ├─ [가족 1명] → FamilyDetailScreen 바로 진입
          └─ [가족 2명+] → 가족 목록 → 탭 → FamilyDetailScreen
              ├─ 기기 상태 (온라인/오프라인/통화 중)
              ├─ 영상통화 버튼 → OutgoingCallScreen
              ├─ 사진 보내기 버튼 → PhotoUploadScreen
              ├─ 영상 알림 버튼 (Phase 6 stub)
              ├─ 최근 보낸 사진 썸네일
              ├─ 가족 멤버 목록
              └─ 메뉴 → 가족 추가 / 페어링 해제 / 로그아웃
```

---

## 사진 전송 흐름

```
[Family 앱] 사진 선택 → 리사이즈/압축 → 썸네일 생성 → MD5 체크섬
    ↓
Storage 업로드 (families/{familyId}/temp/{photoId}.jpg)
    ↓
RTDB 메타 등록 (families/{familyId}/photoSync/{photoId}, status: pending)
    ↓
[Senior 앱] PhotoReceiver가 RTDB 감시 → pending 감지
    ↓
status → downloading → Storage에서 다운로드 → MD5 검증
    ↓
status → done → Family 앱이 Storage 임시 파일 삭제
    ↓
[크래시 복구] downloading 상태 + processingIds에 없음 → pending으로 리셋 (최대 3회)
```

---

## 통화 흐름 (발신측)

```
[Family 앱] 기기 목록 → 대상 선택 → offer 생성
    ↓
/calls/{callId} (targetDeviceId) → RTDB 저장
    ↓
[Senior 태블릿] 수신 → answer 전송
    ↓
ICE candidate 교환 → WebRTC P2P 연결
    ↓
양방향 영상통화
    ↓
종료 → callHistory 기록
```

### WebRTC 연결 끊김 복구 (ICE Restart)

KEP M10VSA2 등 일부 Senior 기기의 WiFi 드라이버 quirk로 IN_CALL 중 2~3초 WiFi drop 발생 시 통화가 끊기지 않도록 ICE Restart로 자동 재협상.

```
peer DISCONNECTED 감지 (webrtc_service._onPeerConnectionStateChanged)
    ↓
4초 grace 대기 → CONNECTED 복귀 시 cancel
    ↓ (복귀 안 하면)
_triggerIceRestart() — pc.restartIce() + createOffer() + setLocalDescription()
    ↓
RTDB calls/{cid}/iceRestartOffer 에 SDP 기록 (signaling.sendIceRestartOffer)
    ↓
[Senior] iceRestartOffer 감지 → setRemote → createAnswer → calls/{cid}/iceRestartAnswer 기록
    ↓
[Family] iceRestartAnswer 수신 (signaling.listenForIceRestartAnswer) → setRemoteDescription
    ↓
새 ICE candidate 교환 → CONNECTED 복귀 → 통화 유지
```

상한:
- **5회 재시도** 초과 → hangUp
- **최초 disconnect 이후 60초** 지속 → 강제 hangUp
- CONNECTED 5초 안정 시 카운터 리셋

UI: `WebRtcService.isReconnecting` (`ValueNotifier<bool>`) → MonitoringScreen이 ValueListenableBuilder로 구독 → "연결이 불안정해요" 오버레이 표시.

---

## 오프라인 가드 (전역)

오프라인 상태에서 사용자가 버튼 연타 시 Firebase 로컬 큐에 쌓인 쓰기가 복구 시점에 한꺼번에 flush되어 중복 통화/사진 업로드 발생하던 문제 해결.

### Layer 1 — 전역 오프라인 오버레이

`ConnectivityService` (`lib/services/connectivity_service.dart`):
- `connectivity_plus` (OS 네트워크 인터페이스) + Firebase `/.info/connected` (RTDB WebSocket) **OR 게이트**
- 둘 중 하나라도 offline → 3초 debounce 후 `isOnline.value = false`
- 앱 lifecycle resume 시 5초 grace period (RTDB 재연결 대기)

`OfflineOverlay` (`lib/widgets/offline_overlay.dart`):
- MaterialApp.builder에서 전역 래핑
- `isOnline=false` 동안 반투명 블로킹 오버레이 표시

### Layer 2 — 쓰기 타임아웃 가드

`writeOrTimeout` (`lib/services/network_guard.dart`):
- 모든 RTDB 쓰기 진입점에 5초 타임아웃 적용
- 타임아웃 시 `onTimeoutCleanup` 콜백으로 큐의 노드 즉시 remove → 복구 시 flush 방지
- `NetworkException` throw → caller가 SnackBar로 사용자에게 통지

적용 진입점: `signaling_service.createCall`, `photo_transfer_service.uploadPhoto`, `reminder_service.createReminder`, `family_service.joinFamily`.

---

## 페어링 흐름

```
[Senior 태블릿]
  1. familyId 생성 → 6자리 코드 생성
  2. RTDB에 /pairingCodes/{code} = familyId 저장
  3. 화면에 QR + 코드 표시 → 대기

[Family 앱 - 최초 멤버]
  1. 소셜 로그인
  2. 코드 입력 or QR 스캔 → familyId 획득
  3. /families/{familyId}/members/{userId} 추가 (role: family)
  4. 가족 이름 입력 (예: 부모님, 장인어른)
  5. Senior 감지 → 페어링 완료 → 슬라이드쇼 전환

[Family 앱 - 추가 가족]
  1. DeviceListScreen 메뉴 → "가족 추가"
  2. 새 시니어 기기의 코드 입력 or QR 스캔
  3. 가족 이름 입력 → 다중 가족 탭에 추가
```

---

## 복약 알림 흐름 (Phase 6 예정)

```
[Family 앱] 스케줄 등록 (시간, 반복, 영상 첨부)
    ↓
/families/{familyId}/reminders/{reminderId}/ → RTDB 저장
    ↓
[Senior 태블릿] 설정 시간에 영상 재생 ("할머니 약 드세요")
    ↓
얼굴 감지로 사람 유무 확인 (일정 시간 모니터링)
  ├─ 감지됨 → reminderLogs에 "confirmed" 기록
  └─ 미감지 → reminderLogs에 "missed" → Family에 푸시 알림
```

---

## 코드 컨벤션

### Mixin 두 종류 (보일러플레이트 제거)

- **`SafeStateMixin`** (`lib/widgets/safe_state_mixin.dart`)
  - 모든 `StatefulWidget`의 `State`에 적용
  - `if (mounted) setState(...)` → `safeSetState(...)` 한 줄로
  - async 콜백에서 dispose 후 호출돼도 안전 (no-op)

- **`FirebaseInstancesMixin`** (`lib/services/firebase_instances_mixin.dart`)
  - Firebase 핸들 필요한 Service에 `with FirebaseInstancesMixin`
  - `db` (`FirebaseDatabase.instance`), `auth` (`FirebaseAuth.instance`), `storage` (`FirebaseStorage.instance`) getter 제공
  - Service당 `final FirebaseDatabase _db = FirebaseDatabase.instance;` 같은 보일러 제거

신규 화면/서비스 추가 시 위 두 mixin 우선 검토.

### Service 분류

| 유형 | 예시 | 특징 |
|---|---|---|
| Stateless wrapper | `FamilyService`, `PhotoTransferService`, `ReminderService`, `AuthService` | Firebase 핸들 외 필드 없음. dispose 없음. |
| Stateful w/ dispose | `SignalingService`, `WebRtcService` | 상태 보유. hangUp/dispose에서 모든 `StreamSubscription` cancel. |
| Singleton (start-once) | `ConnectivityService`, `FcmService` | 앱 전역 1개 인스턴스. `instance.start()` 후 평생 유지. |
| Static helper | `PairingHelper`, `network_guard.dart` | 함수 모음. |

공통 base class 안 만듦 (각 유형 라이프사이클 다름 → LSP 위반 방지).

---

## 빌드 & 배포

```bash
# 빌드
flutter build apk --release

# 설치
adb -s <serial> install -r build/app/outputs/flutter-apk/app-release.apk

# 로그 확인
adb -s <serial> logcat --pid=$(adb -s <serial> shell pidof com.seniorcare.family)
```

---

## 주요 의존성

| 패키지 | 용도 |
|--------|------|
| `flutter_webrtc` (로컬) | WebRTC 영상통화 |
| `firebase_core` | Firebase 초기화 |
| `firebase_database` | RTDB 시그널링/기기등록/가족관리/사진동기화 |
| `firebase_messaging` | FCM 푸시 알림 |
| `firebase_auth` | 소셜 로그인 |
| `firebase_storage` | 사진 업로드 |
| `google_sign_in` | Google 로그인 |
| `sign_in_with_apple` | Apple 로그인 |
| `kakao_flutter_sdk_user` | 카카오 로그인 |
| `mobile_scanner` | QR 스캔 |
| `image_picker` | 사진 선택/촬영 |
| `flutter_image_compress` | 사진 리사이즈/압축 |
| `crypto` | MD5 체크섬 |
| `just_audio` | 벨소리 재생 |
| `wakelock_plus` | 화면 꺼짐 방지 |
| `permission_handler` | 런타임 권한 |
| `device_info_plus` | 기기 ID 추출 |
| `connectivity_plus` | OS 네트워크 인터페이스 감시 (오프라인 가드) |
| `cached_network_image` | Storage 사진 썸네일 캐싱 |
