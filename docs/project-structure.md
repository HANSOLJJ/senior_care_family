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
| **파일 저장** | Firebase Storage | 사진/영상 업로드 |
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
├── main.dart                              # 앱 진입점 (Firebase 초기화만)
├── app.dart                               # SeniorCareFamily 위젯 + 라우팅
│
├── config/
│   └── app_config.dart                    # 기기 정보, Firebase 기기 등록
│
├── screens/
│   ├── login_screen.dart                  # 소셜 로그인 (Google/Apple/카카오/네이버)
│   ├── pairing_screen.dart                # 페어링 코드 입력 / QR 스캔
│   ├── device_list_screen.dart            # 홈 — 시니어 기기 목록 + 상태
│   ├── outgoing_call_screen.dart          # 발신 대기 + 영상통화
│   ├── video_call_screen.dart             # 영상통화 화면
│   ├── photo_upload_screen.dart           # 사진 선택 + 업로드
│   └── reminder/
│       ├── reminder_list_screen.dart      # 알림 목록 (복약/커스텀)
│       ├── reminder_edit_screen.dart      # 알림 생성/수정 (시간, 반복, 영상 첨부)
│       └── reminder_log_screen.dart       # 복약 확인/미확인 이력
│
├── services/
│   ├── auth_service.dart                  # 로그인/로그아웃/프로필
│   ├── fcm_service.dart                   # FCM 토큰 관리 + RTDB 저장
│   ├── notification_service.dart          # 푸시 알림 수신/처리 (오프라인, 복약 미확인 등)
│   ├── photo_service.dart                 # 사진 업로드/삭제/목록 (Storage + RTDB)
│   │
│   ├── family/
│   │   ├── family_service.dart            # 가족 그룹 생성, 페어링, 초대 코드
│   │   ├── member_service.dart            # 멤버 목록, 역할 관리, 멤버 제거
│   │   └── device_service.dart            # 시니어 기기 상태 조회, 이름 변경, 연결 해제
│   │
│   ├── call/
│   │   ├── signaling_service.dart         # RTDB 시그널링 (offer/answer/ICE)
│   │   ├── webrtc_service.dart            # WebRTC 연결 (makeCall + 끊김감지)
│   │   └── call_history_service.dart      # 통화 기록 (발신/부재중/통화시간)
│   │
│   └── reminder/
│       ├── reminder_service.dart          # 스케줄 CRUD (시간, 반복, 영상 첨부)
│       └── reminder_log_service.dart      # 확인/미확인 기록 조회, 알림 수신
│
└── widgets/                               # 공용 위젯 (필요시)
```

### Android 네이티브

```
android/app/src/main/
├── AndroidManifest.xml                    # 권한 (카메라, 마이크, 인터넷)
├── kotlin/com/seniorcare/family/
│   └── MainActivity.kt                   # FlutterActivity (기본)
└── google-services.json                   # Firebase 설정
```

### 로컬 플러그인

```
plugins/
└── flutter_webrtc/                        # 패치된 flutter_webrtc (AEC3 + RNNoise)
    └── android/src/main/
        ├── java/.../MethodCallHandlerImpl.java   # HW AEC 감지 + RNNoise 등록
        ├── java/.../audio/RNNoiseProcessor.java  # RNNoise Java wrapper
        └── jni/                                   # RNNoise v0.2 NDK 빌드
```

---

## Firebase 구성

- **프로젝트**: `dcom-smart-frame`
- **패키지명**: `com.seniorcare.family`
- **RTDB URL**: `https://dcom-smart-frame-default-rtdb.firebaseio.com`

---

## RTDB 데이터 구조

```
Firebase RTDB
│
├── /devices/{deviceId}/                     # 기기 등록 (Senior + Family 공용)
│   ├── online: boolean
│   ├── model: string
│   ├── familyId: string
│   ├── fcmToken: string
│   └── lastSeen: timestamp
│
├── /calls/{callId}/                         # 영상통화 시그널링
│   ├── offer: { sdp, type }
│   ├── answer: { sdp, type }
│   ├── targetDeviceId: string
│   ├── status: "waiting" | "answered" | "ended"
│   ├── callerCandidates/
│   └── calleeCandidates/
│
├── /pairingCodes/{code}: familyId           # 시니어 기기 페어링 코드 역조회
│
├── /inviteCodes/{code}: familyId            # 가족 멤버 초대 코드 역조회
│
├── /families/{familyId}/
│   ├── pairingCode: string                  # 시니어 기기 페어링 코드
│   ├── inviteCode: string                   # 가족 멤버 초대 코드
│   ├── createdAt: timestamp
│   ├── devices/
│   │   └── {deviceId}: { name, model, addedAt }
│   ├── members/
│   │   └── {userId}: { name, role, joinedAt }   # role: "admin" | "member"
│   ├── photos/
│   │   └── {photoId}: { url, thumbnailUrl, uploadedBy, uploadedByName, timestamp }
│   ├── reminders/
│   │   └── {reminderId}/
│   │       ├── type: "medication" | "custom"
│   │       ├── title: string
│   │       ├── message: string
│   │       ├── mediaUrl: string             # 가족이 녹화한 영상/음성
│   │       ├── schedule: { time, repeat, days }
│   │       ├── enabled: boolean
│   │       ├── createdBy: userId
│   │       └── createdByName: string
│   ├── reminderLogs/
│   │   └── {logId}/
│   │       ├── reminderId: string
│   │       ├── scheduledAt: timestamp
│   │       ├── status: "confirmed" | "missed" | "pending"
│   │       ├── detectedAt: timestamp | null
│   │       └── notifiedAt: timestamp | null
│   └── callHistory/
│       └── {callId}/
│           ├── callerId: string
│           ├── callerName: string
│           ├── targetDeviceId: string
│           ├── startedAt: timestamp
│           ├── endedAt: timestamp
│           ├── duration: number (seconds)
│           └── status: "completed" | "missed" | "no_answer"
│
├── /users/{userId}/                         # Family 앱 사용자
│   ├── name: string
│   ├── email: string
│   ├── photoUrl: string
│   ├── provider: "google" | "apple" | "kakao" | "naver"
│   └── familyIds/
│       └── {familyId}: true
│
└── /fcmTokens/{deviceId}: string            # FCM 토큰
```

### Firebase Storage 경로

```
/families/{familyId}/photos/{photoId}.jpg
/families/{familyId}/thumbnails/{photoId}_thumb.jpg
/families/{familyId}/reminders/{reminderId}/media.mp4   # 복약 알림 영상
```

---

## 앱 화면 흐름

```
앱 시작 → Firebase Auth 상태 확인
  ├─ 미로그인 → LoginScreen (Google/Apple/카카오/네이버)
  └─ 로그인됨 → 가족 그룹 확인
      ├─ 미페어링 → PairingScreen (코드 입력 / QR 스캔)
      └─ 페어링됨 → DeviceListScreen (홈)
          ├─ 기기 탭 → OutgoingCallScreen (영상통화 발신)
          ├─ 사진 업로드 → PhotoUploadScreen
          ├─ 복약 알림 → ReminderListScreen
          └─ 설정 (로그아웃, 기기 관리, 가족 초대)
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
  3. /families/{familyId}/members/{userId} 추가 (role: admin)
  4. Senior 감지 → 페어링 완료 → 슬라이드쇼 전환

[Family 앱 - 추가 멤버]
  1. 소셜 로그인
  2. 기존 멤버가 공유한 초대 코드 입력
  3. /families/{familyId}/members/{userId} 추가 (role: member)
```

---

## 복약 알림 흐름

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

## 빌드 & 배포

```bash
# 빌드
flutter build apk --release

# 설치
adb -s <serial> install -r build/app/outputs/flutter-apk/app-release.apk

# 로그 확인
adb -s <serial> shell logcat --pid=$(adb -s <serial> shell pidof com.seniorcare.family)
```

---

## 주요 의존성

| 패키지 | 용도 |
|--------|------|
| `flutter_webrtc` (로컬) | WebRTC 영상통화 |
| `firebase_core` | Firebase 초기화 |
| `firebase_database` | RTDB 시그널링/기기등록/가족관리 |
| `firebase_messaging` | FCM 푸시 알림 |
| `firebase_auth` | 소셜 로그인 (Phase 2) |
| `firebase_storage` | 사진/영상 업로드 (Phase 4) |
| `google_sign_in` | Google 로그인 (Phase 2) |
| `sign_in_with_apple` | Apple 로그인 (Phase 2) |
| `kakao_flutter_sdk_user` | 카카오 로그인 (Phase 2) |
| `flutter_naver_login` | 네이버 로그인 (Phase 2) |
| `mobile_scanner` | QR 스캔 (Phase 3) |
| `image_picker` | 사진 선택 (Phase 4) |
| `just_audio` | 벨소리 재생 |
| `wakelock_plus` | 화면 꺼짐 방지 |
| `permission_handler` | 런타임 권한 |
| `device_info_plus` | 기기 ID 추출 |
