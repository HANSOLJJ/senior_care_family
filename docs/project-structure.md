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
├── app.dart                               # SeniorCareFamily 위젯 + 인증/페어링 분기 라우팅
│
├── config/
│   └── app_config.dart                    # 기기 정보, Firebase 기기 등록 (fire-and-forget), DeviceProfile
│
├── screens/
│   ├── login_screen.dart                  # 소셜 로그인 (Google/Apple/카카오/네이버)
│   ├── pairing_screen.dart                # 페어링 코드 입력 / QR 스캔
│   ├── device_list_screen.dart            # 홈 — 다중 가족 탭 + 기기 목록 + 스토리지바
│   ├── outgoing_call_screen.dart          # 발신 대기 + 영상통화
│   ├── video_call_screen.dart             # 영상통화 화면
│   └── photo_upload_screen.dart           # 사진 선택/촬영 + 업로드 + 그리드 목록
│
├── services/
│   ├── auth_service.dart                  # 로그인/로그아웃/프로필 (4종 소셜)
│   ├── family_service.dart                # 가족 그룹 참가/탈퇴, 멤버 관리, 가족 이름 설정
│   ├── fcm_service.dart                   # FCM 토큰 관리 + RTDB 저장
│   ├── photo_transfer_service.dart        # 사진 업로드/삭제/Storage 정리/실시간 목록
│   └── call/
│       ├── signaling_service.dart         # RTDB 시그널링 (offer/answer/ICE)
│       └── webrtc_service.dart            # WebRTC 연결 (makeCall + 끊김감지)
│
└── widgets/                               # 공용 위젯 (필요시)
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
      └─ 페어링됨 → DeviceListScreen (홈)
          ├─ [다중 가족] 탭으로 전환 (롱프레스로 이름 변경)
          ├─ 기기 탭 → OutgoingCallScreen (영상통화 발신)
          ├─ 사진 아이콘 → PhotoUploadScreen (갤러리/카메라 선택)
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
