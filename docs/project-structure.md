# Senior Care Family App - 프로젝트 구조

가족(자식)용 앱 (Flutter). 시니어 태블릿에 영상통화 발신 + CCTV 모니터링 + 사진 업로드 + 복약 알림 + 기기 관리.

---

## 기술 스택

| 분류 | 기술 | 용도 |
|------|------|------|
| **프레임워크** | Flutter (Dart SDK ^3.10.8) | 크로스 플랫폼 (iOS + Android) |
| **영상통화** | WebRTC (flutter_webrtc 1.3.1) | P2P 영상/음성 + ICE Restart |
| **시그널링** | Firebase Realtime Database | offer/answer/ICE/iceRestart 교환 |
| **인증** | Firebase Auth | Google/Apple/카카오/네이버 소셜 로그인 |
| **푸시 알림** | Firebase Cloud Messaging (FCM) | 통화 수신, 복약 미확인 알림 |
| **파일 저장** | Firebase Storage | 사진 업로드 (임시 → Senior 다운로드 후 Cloud Function 삭제) |
| **오디오** | just_audio | 벨소리 재생 |
| **테마** | 자체 구현 (`ThemeHue` + `ThemePreset` + `ThemeController`) | 7 hue 런타임 스왑 (앰버/민트/오션/로즈/라벤더/세이지/모노) × OS 자동 light/dark + Pretendard |

---

## 전체 시스템 구조

```
E:\App\
├── Family\     ← 이 프로젝트 (자식용, Flutter)
└── Senior\     ← 시니어 태블릿용 (Android Native)
```

- **Family 앱**: 로그인, 페어링, 영상통화 발신, CCTV 모니터링, 사진 업로드, 복약 알림 설정, 기기 관리
- **Senior 앱**: 영상통화 수신, 얼굴감지 자동응답, 슬라이드쇼, 복약 알림 재생, CCTV 모니터링 송신
- **백엔드**: Firebase 공유 (RTDB, FCM, Storage, Auth) + Cloud Functions

---

## 디렉토리 구조

```
lib/
├── main.dart                              # 앱 진입점 (Firebase + RTDB persistence + 카카오 SDK 초기화)
├── app.dart                               # SeniorCareFamily 위젯 + ThemeController 구독 + 인증/페어링 분기 + OfflineOverlay 래핑 + ConnectivityService.start
│
├── config/
│   └── app_config.dart                    # 기기 정보, Firebase 기기 등록 (fire-and-forget), DeviceProfile
│
├── screens/                               # (모든 State는 SafeStateMixin 적용 — safeSetState 사용)
│   ├── login_screen.dart                  # 소셜 로그인 (Google/Apple/카카오/네이버)
│   ├── pairing_screen.dart                # 페어링 코드 입력 / QR 스캔
│   ├── device_list_screen.dart            # 홈 — 가족 목록 (1명이면 자동 상세 진입)
│   ├── family_detail_screen.dart          # 가족 상세 — Hero 카드(시니어 이름/저장/사진수/알림수) + 2×2 액션 그리드 + 사진 + 멤버
│   ├── monitoring_screen.dart             # CCTV 모니터링 + 양방향 통화 (callType 파라미터) + 재연결 오버레이 (FSM phase==reconnecting)
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
│   ├── network_guard.dart                 # writeOrTimeout: RTDB 쓰기 타임아웃 + onTimeoutCleanup + NetworkException
│   ├── firebase_instances_mixin.dart      # Firebase 싱글톤 접근자 mixin (db/auth/storage)
│   ├── presence_util.dart                 # Senior 온라인 판정 유틸 (connections 자식 1개 이상 = online)
│   ├── call/
│   │   ├── call_state_machine.dart        # CallPhase FSM (idle→connecting→connected→{upgrading|reconnecting}→terminating→terminated) + TerminateReason
│   │   ├── signaling_service.dart         # RTDB 시그널링 (offer/answer/ICE/iceRestartOffer/iceRestartAnswer) — listen* 모두 StreamSubscription 반환
│   │   └── webrtc_service.dart            # WebRTC (makeCall/startMonitoring/startCall/upgradeToCall) + ICE Restart 상태머신 + FSM 통합
│   └── reminder/
│       └── reminder_service.dart          # 알림 CRUD + Storage 업로드 — with FirebaseInstancesMixin
│
├── theme/
│   ├── app_theme.dart                     # ThemePreset 추상 (brightness/onSurface/onPrimary 포함) + ThemeHue + AppColorExt + buildTheme(preset) — light/dark 동일 빌더
│   ├── theme_controller.dart              # ValueNotifier<ThemeHue> — 런타임 hue 스왑 (MaterialApp 자동 재빌드)
│   └── theme_presets.dart                 # 7 hue × 2 베리언트 (Amber/Mint/Ocean/Rose/Lavender/Sage/Mono × Light/Dark) + allHues 리스트
│
└── widgets/
    ├── safe_state_mixin.dart              # SafeStateMixin — async 콜백에서 안전한 setState (mounted 체크 자동)
    ├── offline_overlay.dart               # 전역 오프라인 블로킹 오버레이 (ConnectivityService.isOnline 구독)
    ├── theme_switcher_button.dart         # AppBar actions 용 팔레트 아이콘 (탭 → 프리셋 팝업)
    ├── tap_guard.dart                     # 비동기 액션 중복 호출 방지 + busy 상태 ValueNotifier (버튼별 1개)
    ├── async_action_button.dart           # TapGuard 통합 버튼 (햅틱 피드백 강도 선택, busy 시 스피너)
    └── press_scale.dart                   # 탭 시 살짝 줄어드는 scale 애니메이션 래퍼
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

### Assets

```
assets/
├── fonts/                                 # Pretendard (Regular/Medium/SemiBold/Bold)
├── images/                                # 슬라이드쇼/페어링 안내 이미지
├── sounds/                                # ringtone.mp3 (벨소리)
└── device_profiles/                       # SM-T500.json 등 시니어 기기 프로파일
```

### Cloud Functions (서버리스)

```
functions/
├── index.js                              # 11개 함수 진입점
│   ├── kakaoCustomToken                  # 카카오 로그인 → Firebase Custom Token (HTTP Callable)
│   ├── naverCustomToken                  # 네이버 로그인 → Firebase Custom Token (HTTP Callable)
│   ├── onPhotoDownloaded                 # RTDB downloadedBy/{did} create → 모든 Senior 다운로드 완료 시 Storage 삭제 + status:done
│   ├── onPhotoDeleted                    # RTDB photoSync/{photoId} delete → 썸네일 Storage 즉시 삭제
│   ├── onReminderMediaDownloaded         # RTDB mediaDownloaded update → targetDevice 다운로드 완료 시 Storage 삭제
│   ├── onReminderDeleted                 # RTDB reminders/{rid} delete → Storage 미디어 삭제
│   ├── cleanupExpiredPhotos              # 만료 사진 정리 (스케줄 6시간)
│   ├── cleanupExpiredPhotosManual        # 수동 트리거 (HTTP)
│   ├── cleanupOrphanedData               # 고아 RTDB + Storage 정리 (스케줄 매일 3시)
│   └── cleanupOrphanedDataManual         # 수동 트리거 (HTTP, ?aggressive=true 모드 지원)
├── package.json                          # 의존성 (firebase-admin, firebase-functions)
└── dcom-smart-frame-firebase-adminsdk-*.json  # 서비스 계정 키 (gitignore)
```

---

## Firebase 구성

- **프로젝트**: `dcom-smart-frame`
- **패키지명**: `com.seniorcare.family` (Android + iOS Bundle ID 통일)
- **RTDB URL**: `https://dcom-smart-frame-default-rtdb.firebaseio.com`

---

## Firebase 데이터 스키마

RTDB + Storage 스키마는 별도 문서 참조: [RTDB_schema.md](RTDB_schema.md)

---

## 앱 화면 흐름

```
앱 시작 → Firebase 초기화 + RTDB persistence + 기기 등록 (fire-and-forget) + ConnectivityService.start
  ↓
ThemeController 구독 → MaterialApp 빌드 (현재 프리셋 적용)
  ↓
Firebase Auth 상태 확인
  ├─ 미로그인 → LoginScreen (Google/Apple/카카오/네이버)
  └─ 로그인됨 → 가족 그룹 확인
      ├─ 미페어링 → PairingScreen (코드 입력 / QR 스캔)
      │              → 페어링 완료 시 가족 이름 입력 다이얼로그
      └─ 페어링됨 → DeviceListScreen
          ├─ [가족 1명] → FamilyDetailScreen 바로 진입
          └─ [가족 2명+] → 가족 목록 → 탭 → FamilyDetailScreen
              ├─ Hero 카드 (시니어 이름 / 온라인 / 사진 N장 / 알림 N개 / 저장 바)
              ├─ 2×2 액션 그리드 (영상통화 / 모니터링 / 사진 / 영상 알림)
              ├─ 최근 보낸 사진 그리드
              ├─ 가족 멤버 목록
              └─ AppBar (테마 스위처 + 메뉴: 가족 추가 / 페어링 해제 / 로그아웃)
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
[Senior] downloadedBy/{did}=true 기록
    ↓
[Cloud Function onPhotoDownloaded] 모든 Senior 완료 확인 → Storage 원본 삭제 + status:done
    ↓
[Family 사진 삭제] photoSync 노드 remove → [Cloud Function onPhotoDeleted] 썸네일 즉시 삭제
```

---

## 통화 / 모니터링 흐름

### 발신 종류

| 메서드 | RTDB callType | 트랙 방향 | 용도 |
|---|---|---|---|
| `makeCall` | `call` | 양방향 SendRecv | 일반 영상통화 (현재 미사용 — startCall로 대체) |
| `startMonitoring` | `monitor` | RecvOnly (Family는 받기만) | CCTV 모니터링 (Senior 단방향 송신) |
| `startCall` | `call` | RecvOnly로 시작 | 통화 발신 — Senior 수락 후 upgradeToCall로 양방향 전환 |
| `upgradeToCall` | (renegotiate) | SendRecv 추가 | 모니터→통화 업그레이드 (renegotiate offer/answer) |

### FSM (call_state_machine.dart)

```
idle ─┬─→ connecting ─→ connected ─┬─→ upgrading ──→ connected
      │                              │
      │                              ├─→ reconnecting ──→ connected
      │                              │
      └─→ terminating ─→ terminated  └─→ terminating ─→ terminated
                                       (모든 phase에서 terminating 진입 가능)
```

- 진입점: `_fsm.to(phase, reason:)` — 위반 시 false 반환 + 콘솔 경고
- MonitoringScreen 이 `webrtc.phase` ValueNotifier 구독 → 배너/오버레이/pop 분기
- `TerminateReason`: normal / iceFailed / userHangup / remoteBusy / cancelled / timeout 등

### WebRTC 연결 끊김 복구 (ICE Restart)

KEP M10VSA2 등 Senior 기기 WiFi 드라이버 quirk + 일반적 모바일 핸드오프 대응.

```
peer DISCONNECTED 감지 (webrtc_service._onPeerConnectionStateChanged)
    ↓
4초 grace 대기 → CONNECTED 복귀 시 cancel
    ↓ (복귀 안 하면)
_triggerIceRestart() — pc.restartIce() + createOffer() + setLocalDescription()
    ↓
FSM connected/upgrading → reconnecting (MonitoringScreen 오버레이 표시)
    ↓
RTDB calls/{cid}/iceRestartOffer 에 SDP 기록 (signaling.sendIceRestartOffer)
    ↓
[Senior] iceRestartOffer 감지 → setRemote → createAnswer → calls/{cid}/iceRestartAnswer 기록
                                (answer 쓰기 직전 iceRestartOffer 노드 선제 삭제 — stale 방지)
    ↓
[Family] iceRestartAnswer 수신 → setRemoteDescription
    ↓
새 ICE candidate 교환 → CONNECTED 복귀 → FSM reconnecting → connected (ice_restored)
```

상한:
- **5회 재시도** 초과 → `hangUp(iceFailed)`
- **최초 disconnect 이후 60초** 지속 → 강제 `hangUp(iceFailed)`
- **answer 10초 미수신** → `_iceRestartInProgress` 리셋 후 자동 재시도
- CONNECTED **5초 안정 유지** 시 attempts/flapWindow 리셋
- `_iceRestartInProgress` 가드로 중복 트리거 방지

테스트 시트: [ICE_restart_test.md](ICE_restart_test.md) · 시퀀스 다이어그램: [call-scenarios.md §6-7](call-scenarios.md)

### 좀비 peer 방지 (cleanupCall 10초 지연)

`signaling_service.cleanupCall(callId)` 은 `Future.delayed(10s)` 후 노드 remove.
즉시 삭제하면 Senior 가 status=ended 를 받기 전에 노드가 사라져 통화 종료 신호를 놓치고 zombie 상태로 남는 문제 (다음 발신 시 remoteBusy) 방지.

병행으로 Senior `sendAnswer` 는 `runTransaction` 으로 `status==ended` 시 abort — Family 의 hangUp 이후 도착한 Senior answered 가 ended 를 LWW로 덮어쓰는 race 차단.

### 1:N × 1:1 정책 (multi-Family)

Senior 1대에 여러 Family 가 **monitor 동시 가능** (상한 `MAX_PEERS=3`), **call 은 1개 배타**. Senior 측 `MonitoringSession` 이 강제:

- **Call 수락 시 기존 monitor 들 자동 displace** → `endReason="otherCallStarted"` → displace 당한 Family 는 "모니터링이 종료되었습니다" 다이얼로그 → pop
- **Call 중 다른 call 시도** → `endReason="remoteBusy"` → "통화 중입니다" 다이얼로그
- **4번째 monitor 시도** → `endReason="capacityExceeded"` → "모니터링 한도 초과" 다이얼로그

Family 측 UX:

- `family_detail_screen.dart:148` `_isInCall = active && type=='call'` → call 버튼 활성화 제어 (monitor 중이어도 다른 사람 call 가능)
- `monitoring_screen.dart:156-170` `_callActiveByOther` → 다른 Family 의 call 감지 시 "통화 전환" 버튼 숨김
- `monitoring_screen.dart:395-399` `endedByOtherCall` → displace 당한 시 다이얼로그 + pop

상세 시퀀스: [call-scenarios.md §13](call-scenarios.md)

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
- RTDB 쓰기 진입점에 타임아웃 적용
- 타임아웃 시 `onTimeoutCleanup` 콜백으로 큐의 노드 즉시 remove → 복구 시 flush 방지
- `NetworkException` throw → caller가 SnackBar로 사용자에게 통지

적용 진입점: `signaling_service.createCall` / `sendIceRestartOffer`, `photo_transfer_service.uploadPhoto`, `reminder_service.createReminder`, `family_service.joinFamily`.

### Layer 3 — 비동기 버튼 가드

`TapGuard` + `AsyncActionButton` (`lib/widgets/`):
- 버튼별 가드 객체 1개 → action 실행 중 중복 호출 ignore + isBusy ValueNotifier
- AsyncActionButton 이 ValueListenableBuilder 로 disabled/스피너 자동 처리

---

## 테마 시스템

### 2축 설계 (Hue × Brightness)

- **Hue 축** (사용자 선택): 7개 색상 계열 — AppBar 팔레트 아이콘에서 선택
- **Brightness 축** (OS 자동): `ThemeMode.system` — Android/iOS 설정의 다크/라이트 모드 따라감

`ThemeHue` 는 light/dark 두 `ThemePreset` 인스턴스를 들고 있고, `MaterialApp` 이 `theme` + `darkTheme` 둘 다 빌드해두면 OS 가 알아서 선택.

### 토큰 체계

`ThemePreset` 추상 클래스 (lib/theme/app_theme.dart):
- `brightness`, `primary`, `background`, `surface`, `error`, `success`, `warning`
- `textSecondary`, `onSurface`, `onPrimary`, `snackBarBackground`
- ColorScheme 에 없는 토큰(`success`/`warning`/`textSecondary`)은 `AppColorExt` ThemeExtension 으로 주입

`AppTheme.build(ThemePreset)` 는 light/dark 동일 빌더 — `p.brightness` 분기로 `ColorScheme.light()` / `ColorScheme.dark()` 자동 선택, 모든 위젯 테마(AppBar/SnackBar/Dialog/Button/Chip/Card 등)가 토큰에서 도출.

### Hue 7종 (lib/theme/theme_presets.dart)

| Hue | Dark primary | Light primary | 컨셉 |
|---|---|---|---|
| **앰버** | `#FBBF24` | `#D97706` | 따뜻한 오렌지 (기본값) |
| **민트** | `#2DD4BF` | `#0D9488` | 차분한 청록 — 헬스케어 |
| **오션** | `#60A5FA` | `#2563EB` | 신뢰감 있는 파랑 |
| **로즈** | `#F472B6` | `#DB2777` | 부드러운 핑크 |
| **라벤더** | `#A78BFA` | `#7C3AED` | 차분한 보라 — Discord/Linear 감성 |
| **세이지** | `#34D399` | `#059669` | 자연 초록 — Notion/Things 감성 |
| **모노** | `#FFFFFF` | `#000000` | 무채색 미니멀 — Planfit 스타일 |

원칙:
- 액션 버튼 4개 모두 `primary` 사용 (아이콘/라벨로 구분, 4색 토큰 없음)
- 의미색(error/success/warning) 만 hue 별 톤 차이, 모노만 success/warning 도 무채색 컨셉 유지
- `textSecondary` 는 모든 hue 에서 회색 무채색 통일 (가독성 우선). 라이트는 `#6B7280`, 다크는 `#9CA3AF` 계열
- 라이트모드 primary 는 다크보다 한 단계 진한 톤 (예: amber-400 → amber-600) — 라이트 배경 위 대비
- `onPrimary` 는 대부분 hue dark 에서 검정, light 에서 흰색. 단 모노만 반대 (dark primary=흰색 → onPrimary=검정, light primary=검정 → onPrimary=흰색)

### 런타임 스왑

`ThemeController.currentHue` (`ValueNotifier<ThemeHue>`) → MaterialApp 자동 재빌드.
AppBar 의 `ThemeSwitcherButton` 탭 → hue 팝업 → 즉시 전환. 다크/라이트 선택 UI 는 없음 (OS 가 결정).

### 의도적 하드코딩 (테마 무관)

라이트/다크 무관하게 검정/흰색 유지하는 곳 — 영상/카메라/브랜드 배경 위 오버레이:
- `monitoring_screen.dart` Scaffold 검정 + 영상 위 배지/오버레이 `black54` + 텍스트 흰색 (영상 배경이 어두우므로)
- `pairing_screen.dart` QR 스캐너 Scaffold 검정 + 안내 텍스트 흰색
- `login_screen.dart` 소셜 버튼 브랜드 색 (카카오 노랑/구글 흰색/네이버 초록) + 텍스트 고정
- `photo_upload_screen.dart` 사진 썸네일 위 status 배지 `black.alpha(0.5)` (미디어 위 오버레이)

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

## 복약 알림 흐름

```
[Family 앱] 스케줄 등록 (시간, 반복, 영상/이미지/오디오 첨부)
    ↓
Storage 업로드 (families/{familyId}/reminders/{reminderId}/media)
    ↓
/families/{familyId}/reminders/{reminderId}/ → RTDB 저장
    ↓
[Senior 태블릿] 설정 시간에 미디어 재생 ("할머니 약 드세요")
    ↓
얼굴 감지로 사람 유무 확인 (일정 시간 모니터링)
    ↓
[Cloud Function onReminderMediaDownloaded] 다운로드 완료 → Storage 삭제
    ↓
[Family 알림 삭제] reminder 노드 remove → [onReminderDeleted] Storage 미디어 삭제
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
| Stateful w/ dispose | `SignalingService`, `WebRtcService` | 상태 보유 (`CallStateMachine` 포함). hangUp/dispose에서 모든 `StreamSubscription` cancel. |
| Singleton (start-once) | `ConnectivityService`, `FcmService` | 앱 전역 1개 인스턴스. `instance.start()` 후 평생 유지. |
| Static helper | `PairingHelper`, `network_guard.dart`, `presence_util.dart` | 함수 모음. |

공통 base class 안 만듦 (각 유형 라이프사이클 다름 → LSP 위반 방지).

---

## 빌드 & 배포

### Android (Windows)

```bash
flutter build apk --debug
adb -s R3CR700SEKP install -r build/app/outputs/flutter-apk/app-debug.apk

# 로그
adb -s R3CR700SEKP logcat --pid=$(adb -s R3CR700SEKP shell pidof com.seniorcare.family)
```

테스트 기기:
- **SM-G991N** (Galaxy S21, `R3CR700SEKP`) → Family 앱 (주 테스트)
- **Lenovo M10VSA2** (`KEP2024120921`) → Senior 앱. **절대 Family 앱 설치 금지** (기존 SM-T500 에서 교체)
- 1:N 회귀 테스트용 Family B 기기는 `adb devices` 로 식별자 확정 후 사용

### iOS (Mac Mini SSH/Parsec)

```bash
ssh JHS@100.104.120.76      # Tailscale (pw: 1231)
cd ~/projects/Family
git pull
security unlock-keychain ~/Library/Keychains/login.keychain-db
flutter run -d 00008110-000C48390ADA801E 2>&1 | tee ~/projects/Family/tmp/flutter.log
```

- 코드 수정은 **Windows 에서만** → push → Mac Mini pull (충돌 방지)
- Bundle ID: `com.seniorcare.family` (Team ID: 85UGG849SL, 무료 개인 팀 → 7일 서명 만료)
- iOS 테스트 기기: **Sol** iPhone (`00008110-000C48390ADA801E`)

### Cloud Functions

```bash
cd functions
npm install              # 최초 1회
firebase deploy --only functions
```

수동 트리거:
- `https://us-central1-dcom-smart-frame.cloudfunctions.net/cleanupOrphanedDataManual`
- `https://us-central1-dcom-smart-frame.cloudfunctions.net/cleanupExpiredPhotosManual`

---

## 주요 의존성

| 패키지 | 버전 | 용도 |
|---|---|---|
| `flutter_webrtc` | ^1.3.1 | WebRTC 영상통화 |
| `firebase_core` | ^4.4.0 | Firebase 초기화 |
| `firebase_database` | ^12.1.3 | RTDB 시그널링/기기등록/가족관리/사진동기화 |
| `firebase_messaging` | ^16.1.1 | FCM 푸시 알림 |
| `firebase_auth` | ^6.2.0 | 소셜 로그인 |
| `firebase_storage` | ^13.0.0 | 사진/알림 미디어 업로드 |
| `cloud_functions` | ^6.0.7 | 카카오/네이버 Custom Token 호출 |
| `google_sign_in` | ^6.3.0 | Google 로그인 |
| `sign_in_with_apple` | ^6.1.4 | Apple 로그인 |
| `kakao_flutter_sdk_user` | ^1.9.6 | 카카오 로그인 |
| `mobile_scanner` | ^7.2.0 | QR 스캔 |
| `image_picker` | ^1.1.2 | 사진 선택/촬영 |
| `flutter_image_compress` | ^2.4.0 | 사진 리사이즈/압축 |
| `crypto` | ^3.0.6 | MD5 체크섬 |
| `just_audio` | ^0.10.5 | 벨소리 재생 |
| `wakelock_plus` | ^1.4.0 | 화면 꺼짐 방지 |
| `permission_handler` | ^12.0.1 | 런타임 권한 |
| `device_info_plus` | ^12.3.0 | 기기 ID 추출 (ANDROID_ID / identifierForVendor) |
| `connectivity_plus` | ^6.0.0 | OS 네트워크 인터페이스 감시 (오프라인 가드) |
| `cached_network_image` | ^3.4.1 | Storage 사진 썸네일 캐싱 |

---

## 관련 문서

- [RTDB_schema.md](RTDB_schema.md) — RTDB 전체 스키마
- [call-scenarios.md](call-scenarios.md) — 통화/모니터링 FSM · 시퀀스 다이어그램 · 1:N × 1:1 정책 흐름
- [ICE_restart_test.md](ICE_restart_test.md) — ICE Restart 테스트 시트 (S1~S17 + R1~R8 회귀)
- [ICE_restart_test_result.md](ICE_restart_test_result.md) — ICE Restart 테스트 실측 결과
- [datachannel-photo-transfer.md](datachannel-photo-transfer.md) — 미디어 전송 설계
- [smart-frame-plan.md](smart-frame-plan.md) — 전체 구현 계획 (Phase 1~7)
- [to_do.md](to_do.md) — 현재 TODO
- [presence_migration_handover.md](presence_migration_handover.md) — Senior presence 마이그레이션 배경
- [monitoring_videocall_unify.md](monitoring_videocall_unify.md) — 모니터링/통화 통합 설계
- [AP spec.md](AP%20spec.md) — Family-Senior 앱 간 프로토콜 명세
