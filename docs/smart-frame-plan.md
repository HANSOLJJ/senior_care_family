# Senior Care Family App - 구현 계획

## 개요

Senior Care 시스템의 가족(자식)용 앱.
시니어 태블릿에 영상통화 발신 + 사진 업로드 + 복약 알림 설정 + 기기 관리.

Senior 앱(Android Native, Kotlin)과 Firebase를 공유하며,
페어링 시스템으로 가족 그룹을 형성한다.

---

## Phase 1: 시니어 전용 코드 제거 — **완료**

### 완료 항목
- [x] `lib/services/face_detection_service.dart` 삭제
- [x] `lib/screens/slideshow_screen.dart` 삭제
- [x] `lib/screens/incoming_call_screen.dart` 삭제
- [x] `android/.../BootReceiver.kt` 삭제
- [x] `pubspec.yaml`에서 `camera`, `google_mlkit_face_detection`, `flutter_tts` 제거
- [x] `AndroidManifest.xml`에서 HOME intent-filter, BootReceiver, BOOT_COMPLETED 권한 제거
- [x] `MainActivity.kt` 간소화 (화면 켜기/잠금해제 코드 제거)
- [x] `main.dart` 재작성 (SeniorCareFamily, DeviceListScreen 홈)
- [x] 패키지명 변경: `com.seniorcare.family`
- [x] 빌드 + 설치 + 동작 확인 완료

### 현재 lib/ 구조
```text
lib/
├── main.dart                    # AppConfig + SeniorCareFamily
├── screens/
│   ├── device_list_screen.dart  # 홈 (기기 목록)
│   ├── outgoing_call_screen.dart
│   └── video_call_screen.dart
├── services/
│   ├── signaling_service.dart
│   ├── webrtc_service.dart
│   └── fcm_service.dart
└── widgets/
    └── photo_frame_view.dart    # 시니어 잔재 → 제거 예정
```

---

## Phase 2: 코드 구조 정리 + 소셜 로그인

### 2-1. 코드 구조 정리

#### AppConfig 분리
- `lib/config/app_config.dart` 생성 ← `main.dart`에서 AppConfig 이동
- `main.dart`는 진입점만 (Firebase 초기화 + runApp)
- `lib/app.dart` 생성 ← SeniorCareFamily 위젯 + 라우팅

#### 잔재 제거
- `lib/widgets/photo_frame_view.dart` 삭제 (시니어 슬라이드쇼 전용)

#### 서비스 디렉토리 구조화
```text
services/
├── auth_service.dart
├── fcm_service.dart
├── notification_service.dart
├── photo_service.dart
├── family/
│   ├── family_service.dart
│   ├── member_service.dart
│   └── device_service.dart
├── call/
│   ├── signaling_service.dart
│   ├── webrtc_service.dart
│   └── call_history_service.dart
└── reminder/
    ├── reminder_service.dart
    └── reminder_log_service.dart
```

### 2-2. Firebase Auth + 소셜 로그인

#### pubspec.yaml 추가
```yaml
firebase_auth: ^5.x
google_sign_in: ^6.x
sign_in_with_apple: ^6.x
kakao_flutter_sdk_user: ^1.x
flutter_naver_login: ^1.x
```

#### 새 파일
- `lib/services/auth_service.dart`
  - `signInWithGoogle()`
  - `signInWithApple()`
  - `signInWithKakao()` → Firebase Custom Token
  - `signInWithNaver()` → Firebase Custom Token
  - `signOut()`
  - `getCurrentUser()`

- `lib/screens/login_screen.dart`
  - 4개 소셜 로그인 버튼 (Google, Apple, 카카오, 네이버)

#### 카카오/네이버 추가 설정
- Kakao Developers 앱 등록 + 네이티브 앱 키
- Naver Developers 앱 등록 + Client ID/Secret
- **Cloud Functions 필요**: 카카오/네이버 OAuth 토큰 → Firebase Custom Token 변환

#### 앱 진입 흐름 변경
```text
main.dart → Firebase.initializeApp()
  → app.dart → AuthState 확인
    ├─ 미로그인 → LoginScreen
    ├─ 로그인 + 미페어링 → PairingScreen
    └─ 로그인 + 페어링됨 → DeviceListScreen
```

#### RTDB 사용자 프로필
```text
/users/{userId}/
  name: string
  email: string
  photoUrl: string
  provider: "google" | "apple" | "kakao" | "naver"
  familyIds/
    {familyId}: true
```

---

## Phase 3: 페어링 시스템

### 3-1. Senior 앱 (Kotlin) — 페어링 코드/QR 생성

#### 새 파일
- `PairingActivity.kt` — QR + 6자리 코드 표시, 연결 대기
- `res/layout/pairing_activity.xml` — 레이아웃

#### 코드 생성 규칙
- 6자리 영숫자 (0/O, 1/I/L 제외)
- 문자셋: `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`

#### 흐름
```text
Senior 앱 시작 → SharedPreferences에서 familyId 확인
  ├─ 없음 → PairingActivity
  │   1. familyId 생성 (RTDB push key)
  │   2. 6자리 코드 생성
  │   3. RTDB 저장:
  │      /pairingCodes/{code} = familyId
  │      /families/{familyId}/pairingCode = code
  │      /families/{familyId}/devices/{deviceId} = { name, model }
  │   4. QR + 코드 화면 표시
  │   5. /families/{familyId}/members/ 감시 → 멤버 추가 시 페어링 완료
  └─ 있음 → MainActivity (기존 흐름)
```

#### 패키지 추가
```kotlin
implementation("com.journeyapps:zxing-android-embedded:4.3.0")
```

### 3-2. Family 앱 (Flutter) — 코드 입력/QR 스캔

#### 새 파일
- `lib/screens/pairing_screen.dart`
  - 수동 코드 입력 텍스트필드
  - QR 스캔 버튼 (카메라 → 코드 자동 입력)
  - `/pairingCodes/{code}` 조회 → familyId 획득
  - `/families/{familyId}/members/{userId}` 추가 (role: admin)

- `lib/services/family/family_service.dart`
  - `joinFamily(pairingCode)` — 페어링 코드로 가족 참여
  - `createInviteCode(familyId)` — 가족 초대 코드 생성
  - `joinByInvite(inviteCode)` — 초대 코드로 참여
  - `getMyFamilies()` — 내 가족 그룹 목록
  - `getFamilyDevices(familyId)` — 시니어 기기 목록

- `lib/services/family/member_service.dart`
  - `getMembers(familyId)` — 멤버 목록
  - `updateRole(familyId, userId, role)` — 역할 변경
  - `removeMember(familyId, userId)` — 멤버 제거

- `lib/services/family/device_service.dart`
  - `getDeviceStatus(familyId, deviceId)` — 기기 상태 (배터리, 온라인)
  - `renameDevice(familyId, deviceId, name)` — 이름 변경
  - `removeDevice(familyId, deviceId)` — 기기 연결 해제

#### pubspec.yaml 추가
```yaml
mobile_scanner: ^5.x    # QR 스캔
```

### 3-3. 가족 초대 (추가 멤버)

```text
딸(최초) → 시니어 기기 페어링 코드 입력 → 가족 그룹 생성 (admin)
    ↓
딸 → "가족 초대" 버튼 → 초대 코드 생성 → 카톡/문자로 공유
    ↓
아들 → 앱 설치 → 로그인 → 초대 코드 입력 → 같은 가족 그룹 참여 (member)
```

#### RTDB
```text
/inviteCodes/{code}: familyId
/families/{familyId}/inviteCode: code
```

### 3-4. DeviceListScreen 수정
- 전체 기기 목록 → 내 가족 그룹의 기기만 표시
- `/families/{familyId}/devices/` 기반 조회

### 3-5. Senior DeviceRegistration 수정
- 기기 등록 시 `familyId` 포함
- `/families/{familyId}/devices/{deviceId}` 에도 등록

---

## Phase 4: 사진 업로드

### pubspec.yaml 추가
```yaml
firebase_storage: ^12.x
image_picker: ^1.x
```

### 새 파일
- `lib/screens/photo_upload_screen.dart`
  - 갤러리에서 선택 (다중 선택)
  - 카메라 촬영
  - 업로드 진행률 표시
  - 업로드 완료 피드백

- `lib/services/photo_service.dart`
  - `uploadPhoto(familyId, imageFile)` → Storage 업로드 + RTDB 메타데이터
  - `deletePhoto(familyId, photoId)` → Storage + RTDB 삭제
  - `getPhotos(familyId)` → 사진 목록 스트림

### Storage 경로
```text
/families/{familyId}/photos/{photoId}.jpg
/families/{familyId}/thumbnails/{photoId}_thumb.jpg
```

### RTDB 메타데이터
```text
/families/{familyId}/photos/{photoId}/
  url: "https://..."
  thumbnailUrl: "https://..."
  uploadedBy: userId
  uploadedByName: "딸"
  timestamp: ServerValue.TIMESTAMP
```

### Senior 앱 연동
- `SlideshowManager.kt` 수정: assets → Firebase Storage에서 사진 로드
- `/families/{familyId}/photos/` 실시간 감시
- 사진 없을 때: 대기 화면 ("가족이 사진을 보내면 여기에 표시됩니다")

---

## Phase 5: 복약 알림 (리마인더)

### Family 앱 (설정 측)

#### 새 파일
- `lib/screens/reminder/reminder_list_screen.dart` — 알림 목록
- `lib/screens/reminder/reminder_edit_screen.dart` — 생성/수정
  - 타입: 복약 / 커스텀
  - 시간 설정 (TimePicker)
  - 반복: 매일 / 평일 / 커스텀 요일
  - 영상/음성 첨부 (녹화 or 갤러리)
  - 활성/비활성 토글
- `lib/screens/reminder/reminder_log_screen.dart` — 확인/미확인 이력

- `lib/services/reminder/reminder_service.dart`
  - `createReminder(familyId, reminder)`
  - `updateReminder(familyId, reminderId, data)`
  - `deleteReminder(familyId, reminderId)`
  - `getReminders(familyId)` → 스트림
  - `toggleReminder(familyId, reminderId, enabled)`

- `lib/services/reminder/reminder_log_service.dart`
  - `getLogs(familyId, reminderId)` → 이력 조회
  - `getRecentMissed(familyId)` → 최근 미확인 목록

### Senior 앱 (실행 측)
- 설정된 시간에 영상 재생 ("할머니 약 드세요")
- 영상 재생 후 얼굴 감지로 사람 유무 확인
- 감지됨 → `reminderLogs`에 "confirmed"
- 미감지 → `reminderLogs`에 "missed" → FCM으로 Family에 알림

### RTDB
```text
/families/{familyId}/reminders/{reminderId}/
  type: "medication" | "custom"
  title: "혈압약"
  message: "할머니 약 드세요"
  mediaUrl: "gs://..."
  schedule:
    time: "08:00"
    repeat: "daily" | "weekdays" | "custom"
    days: [1,3,5]
  enabled: true
  createdBy: userId
  createdByName: "딸"

/families/{familyId}/reminderLogs/{logId}/
  reminderId: "..."
  scheduledAt: timestamp
  status: "confirmed" | "missed" | "pending"
  detectedAt: timestamp | null
  notifiedAt: timestamp | null
```

### Storage
```text
/families/{familyId}/reminders/{reminderId}/media.mp4
```

---

## Phase 6: 통화 기록 + 알림

### 통화 기록
- `lib/services/call/call_history_service.dart`
  - 통화 시작/종료 시 자동 기록
  - 발신자, 수신 기기, 시간, 통화 시간, 상태

### 알림 서비스
- `lib/services/notification_service.dart`
  - 시니어 기기 오프라인 알림
  - 복약 미확인 알림
  - 새 가족 멤버 참여 알림
  - 부재중 통화 알림

---

## Phase 7: 홈화면 개편 + 설정

### DeviceListScreen 개편
- 내 가족 그룹의 시니어 기기 목록
- 각 기기: 이름, 모델, 온라인/오프라인 상태
- 탭 → 영상통화 발신
- 하단 네비게이션 or FAB:
  - 사진 업로드
  - 복약 알림
  - 설정

### 설정 화면
- 내 프로필 (이름, 사진)
- 가족 그룹 관리 (멤버 목록, 초대, 기기 관리)
- 알림 설정 (on/off)
- 로그아웃

---

## 구현 순서 (추천)

| 순서 | 내용 | 앱 |
|------|------|-----|
| 1 | ~~Phase 1: 시니어 코드 제거~~ | Family — **완료** |
| 2 | Phase 2-1: 코드 구조 정리 | Family |
| 3 | Phase 3-1: 페어링 코드/QR 생성 | Senior |
| 4 | Phase 2-2: 소셜 로그인 | Family |
| 5 | Phase 3-2: 코드 입력/QR 스캔 + 페어링 | Family |
| 6 | Phase 4: 사진 업로드 | Family |
| 7 | Phase 4 연동: Storage에서 사진 로드 | Senior |
| 8 | Phase 5: 복약 알림 설정 | Family |
| 9 | Phase 5 연동: 복약 알림 재생 + 감지 | Senior |
| 10 | Phase 3-3: 가족 초대 | Family |
| 11 | Phase 6: 통화 기록 + 알림 | Family |
| 12 | Phase 7: 홈화면 + 설정 | Family |

---

## 수정 대상 파일 요약

### Family 앱 (E:\App\Family\)

| 작업 | 파일 | Phase |
|------|------|-------|
| ~~삭제~~ | ~~face_detection_service.dart~~ | ~~1~~ 완료 |
| ~~삭제~~ | ~~slideshow_screen.dart~~ | ~~1~~ 완료 |
| ~~삭제~~ | ~~incoming_call_screen.dart~~ | ~~1~~ 완료 |
| ~~삭제~~ | ~~BootReceiver.kt~~ | ~~1~~ 완료 |
| 삭제 | `widgets/photo_frame_view.dart` | 2-1 |
| 수정 | `main.dart` → 진입점만 | 2-1 |
| 생성 | `app.dart` | 2-1 |
| 생성 | `config/app_config.dart` | 2-1 |
| 생성 | `services/auth_service.dart` | 2-2 |
| 생성 | `screens/login_screen.dart` | 2-2 |
| 생성 | `services/family/family_service.dart` | 3 |
| 생성 | `services/family/member_service.dart` | 3 |
| 생성 | `services/family/device_service.dart` | 3 |
| 생성 | `screens/pairing_screen.dart` | 3 |
| 수정 | `screens/device_list_screen.dart` | 3, 7 |
| 생성 | `services/photo_service.dart` | 4 |
| 생성 | `screens/photo_upload_screen.dart` | 4 |
| 생성 | `services/reminder/reminder_service.dart` | 5 |
| 생성 | `services/reminder/reminder_log_service.dart` | 5 |
| 생성 | `screens/reminder/reminder_list_screen.dart` | 5 |
| 생성 | `screens/reminder/reminder_edit_screen.dart` | 5 |
| 생성 | `screens/reminder/reminder_log_screen.dart` | 5 |
| 생성 | `services/call/call_history_service.dart` | 6 |
| 생성 | `services/notification_service.dart` | 6 |

### Senior 앱 (E:\App\Senior\)

| 작업 | 파일 | Phase |
|------|------|-------|
| 생성 | `PairingActivity.kt` | 3 |
| 생성 | `res/layout/pairing_activity.xml` | 3 |
| 수정 | `MainActivity.kt` | 3 |
| 수정 | `DeviceRegistration.kt` | 3 |
| 수정 | `build.gradle.kts` (ZXing 추가) | 3 |
| 수정 | `AndroidManifest.xml` | 3 |
| 수정 | `SlideshowManager.kt` | 4 |
| 수정 | `build.gradle.kts` (Coil 추가) | 4 |
| 생성 | `ReminderManager.kt` | 5 |
| 수정 | `CallListener.kt` (선택) | 3 |
