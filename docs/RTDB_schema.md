# Firebase 데이터 스키마 v3

## RTDB

**URL**: `https://dcom-smart-frame-default-rtdb.firebaseio.com`

### 핵심 원칙

- **비정규화 금지**: 같은 데이터를 두 곳에 쓰지 않음
- `/devices/{did}` — Senior 기기의 모든 정보 (유일한 출처)
- `/families/{fid}/devices/{did}: true` — 소속 목록만 (상세 정보 없음)
- `/users/{uid}` — Family 사용자 정보 (기기 등록 안 함)
- **onDisconnect는 `/devices/` 에만** — `/families/` 경로에 onDisconnect 없음 → 고아 부활 불가능

### deviceId 생성 규칙

| 플랫폼 | 소스 | 설명 |
| --- | --- | --- |
| Android (Senior) | `Settings.Secure.ANDROID_ID` | 기기별 고유 16자 hex, Factory Reset 시 변경 |
| Family 앱 | 없음 | `/devices/`에 등록하지 않음. `/users/{uid}`로만 식별 |

### `_label` 규칙

- 모든 비-리프 노드에 `_label` 필드 추가
- `_`가 알파벳 순 최상위 → Firebase Console에서 노드 열면 첫 번째로 보임
- 각 앱이 노드 생성/수정 시 함께 업데이트

---

```text
Firebase RTDB
│
├── /devices/{deviceId}/                        # Senior 기기 전용 레지스트리
│   ├── _label: string                          # "SM-T500 (senior)"
│   ├── role: "senior"                          # 항상 senior (Family는 등록 안 함)
│   ├── model: string                           # "SM-T500"
│   ├── name: string                            # 표시 이름 (기본값 = model)
│   ├── lastSeen: timestamp                     # onDisconnect → ServerValue.TIMESTAMP
│   ├── connections/                            # Connection List (race-free presence)
│   │   └── {sessionId}: true                   # Senior가 register 시 UUID 생성.
│   │                                             onDisconnect().removeValue() 예약 → 끊김 시
│   │                                             자기 child만 제거 → 타 세션 간섭 불가.
│   │                                             online 판정: hasChildren() == true
│   ├── familyId: string | null                 # 소속 가족 (페어링 시 설정)
│   ├── fcmToken: string                        # FCM 푸시 토큰
│   ├── appVersion: string                      # "1.0"
│   ├── createdAt: timestamp                    # 최초 등록 시각
│   ├── storageTotal: number                    # 전체 용량 (bytes)
│   ├── storageAvailable: number                # 가용 용량 (bytes)
│   ├── photoCount: number                      # 저장된 사진 수
│   └── storageUpdatedAt: timestamp             # 스토리지 정보 갱신 시각
│
│   Writer: Senior 앱만
│   Reader: Family 앱 (기기 상세 정보), Cloud Functions
│   onDisconnect: connections/{sessionId} → remove, lastSeen → timestamp
│   Presence 판정 (Family): connections.hasChildren()
│
├── /calls/{callId}/                            # 영상통화 시그널링 (임시, 통화 종료 후 삭제)
│   ├── _label: string                          # "홍길동 → SM-T500 (call) ringing"
│   ├── callerUid: string                       # 발신자 Firebase Auth UID
│   ├── callerName: string                      # 발신자 표시 이름
│   ├── callerDeviceId: string                  # 발신 기기 ID
│   ├── targetDeviceId: string                  # 수신 기기 ID (Senior)
│   ├── targetFamilyId: string                  # 수신 가족 ID (Security Rules용)
│   ├── callType: "call" | "monitor"            # call=양방향, monitor=일방향 CCTV
│   ├── status: "ringing"|"connected"|"ended"   # 통화 상태
│   ├── createdAt: timestamp
│   ├── offer: { sdp: string, type: string }    # SDP offer (Family → Senior)
│   ├── answer: { sdp: string, type: string }   # SDP answer (Senior → Family)
│   ├── callerCandidates/
│   │   └── {pushId}: { candidate, sdpMid, sdpMLineIndex }
│   ├── calleeCandidates/
│   │   └── {pushId}: { candidate, sdpMid, sdpMLineIndex }
│   ├── upgradeRequest: "call" | null           # 모니터링 → 통화 전환 요청
│   ├── renegotiateOffer: { sdp, type } | null
│   └── renegotiateAnswer: { sdp, type } | null
│
│   Writer: Family (offer), Senior (answer)
│   정리: 통화 종료 후 Senior가 2초 뒤 삭제
│
├── /pairingCodes/{code}: familyId              # 페어링 코드 → 가족 ID 역조회
│
│   Writer: Senior (페어링 시작 시)
│   Reader: Family (페어링 참여 시)
│
├── /users/{userId}/                            # Family 앱 사용자 프로필
│   ├── _label: string                          # "홍길동 (kakao:487707844)"
│   ├── name: string                            # 표시 이름
│   ├── email: string                           # 이메일
│   ├── photoUrl: string                        # 프로필 사진 URL
│   ├── provider: "google"|"apple"|"kakao"|"naver"
│   ├── createdAt: timestamp                    # 최초 가입 시각
│   ├── lastLoginAt: timestamp                  # 최근 로그인 시각
│   ├── familyIds/
│   │   └── {familyId}: true                    # 소속 가족 목록
│   └── familyNames/
│       └── {familyId}: string                  # 가족별 별칭 ("부모님")
│
│   Writer: Family 앱 (자기 프로필만)
│   Reader: Family 앱
│   ※ Family 기기는 /devices/에 등록하지 않음
│
└── /families/{familyId}/                       # 가족 그룹
    ├── _label: string                          # "부모님" (사용자 지정 이름)
    ├── pairingCode: string                     # 현재 활성 페어링 코드 (6자리)
    ├── createdAt: timestamp
    │
    ├── callStatus/                             # 실시간 통화 상태 (UI 인디케이터용)
    │   ├── active: boolean
    │   ├── type: "call" | "monitor"
    │   ├── callerName: string
    │   ├── callerUid: string
    │   ├── callId: string
    │   └── startedAt: timestamp
    │
    │   Writer: Senior
    │   Reader: Family
    │
    ├── devices/
    │   └── {deviceId}: true                    # 소속 기기 목록 (상세 정보 없음!)
    │                                           # 상세 정보는 /devices/{deviceId}에서 읽기
    │   Writer: Senior (페어링 시)
    │   Reader: Family (deviceId 목록 조회 → /devices/{did}에서 상세)
    │
    ├── members/
    │   └── {userId}/
    │       ├── _label: string                  # "홍길동 (kakao:487707844)"
    │       ├── name: string                    # 표시 이름 (사용자 지정)
    │       ├── role: "family"
    │       ├── provider: "google"|"apple"|"kakao"|"naver"
    │       ├── photoUrl: string
    │       └── joinedAt: timestamp
    │
    │   Writer: Family 앱 (joinFamily 시)
    │   Reader: Family 앱, Senior (멤버 수 감지)
    │
    ├── photoSync/
    │   └── {photoId}/
    │       ├── _label: string                  # "photo_abc.jpg (pending, 홍길동)"
    │       ├── fileName: string
    │       ├── size: number
    │       ├── checksum: string
    │       ├── storageUrl: string              # 원본 임시 Storage URL (done 후 삭제)
    │       ├── storagePath: string | null      # 원본 임시 Storage 경로
    │       ├── thumbUrl: string                # 썸네일 Storage URL (영구)
    │       ├── thumbPath: string               # 썸네일 Storage 경로 (삭제용)
    │       ├── uploadedBy: string
    │       ├── uploadedByName: string
    │       ├── createdAt: timestamp
    │       ├── status: string                  # "pending"|"done"|"expired"
    │       ├── retryCount: number
    │       └── downloadedBy/                   # 각 Senior 다운로드 완료 기록
    │           └── {deviceId}: true
    │
    │   Writer: Family (업로드/삭제), Senior (downloadedBy), Cloud Function (만료/Storage)
    │   ※ thumbnail(base64) 필드 제거 → thumbUrl(Storage URL)로 교체
    │   ※ "deleted" 상태 제거 → Family가 RTDB 노드를 즉시 remove()
    │   ※ Family 앱: onValue 구독 + setPersistenceEnabled(true)
    │   ※   persistence delta sync: 변경분만 수신, 앱 재시작 시 즉시 표시
    │   ※   로컬 SQLite 캐시: /data/data/com.seniorcare.family/databases/
    │   ※ Senior 앱: ValueEventListener + setPersistenceEnabled(true)
    │   ※   onDataChange: RTDB 파일목록 vs 로컬 비교 → 고아 파일 자동 삭제
    │
    ├── reminders/
    │   └── {reminderId}/
    │       ├── _label: string                  # "혈압약 08:00 매일 [ON]"
    │       ├── title: string
    │       ├── mediaUrl: string
    │       ├── mediaType: "video" | "audio"
    │       ├── mediaDuration: number
    │       ├── schedule/
    │       │   ├── time: string                # "HH:mm"
    │       │   ├── repeat: "daily"|"weekdays"|"weekend"|"custom"|"test_5min"
    │       │   └── days: [number]              # custom일 때만
    │       ├── enabled: boolean
    │       ├── createdBy: string
    │       ├── createdByName: string
    │       ├── targetDeviceId: string | null   # 대상 Senior (null=전체, 2차 구현)
    │       ├── targetDeviceName: string | null
    │       ├── createdAt: timestamp
    │       └── updatedAt: timestamp
    │
    │   Writer: Family (CRUD)
    │   Reader: Senior (스케줄링 + 미디어 다운로드)
    │
    ├── reminderLogs/                           # 스키마만 확정, 구현은 2차
    │   └── {logId}/
    │       ├── _label: string
    │       ├── reminderId: string
    │       ├── reminderTitle: string
    │       ├── scheduledAt: timestamp
    │       ├── triggeredAt: timestamp
    │       ├── status: "pending"|"confirmed"|"missed"
    │       ├── confirmedAt: timestamp | null
    │       ├── missedAt: timestamp | null
    │       ├── notifiedFamilyAt: timestamp | null
    │       └── detectionMethod: "face"|"manual"|null
    │
    │   Writer: Senior
    │   Reader: Family
    │   보존: 90일 (Cloud Function)
    │
    └── callHistory/                            # 스키마만 확정, 구현은 2차
        └── {historyId}/
            ├── _label: string
            ├── callId: string
            ├── callerUid: string
            ├── callerName: string
            ├── targetDeviceId: string
            ├── targetDeviceName: string
            ├── callType: "call" | "monitor"
            ├── startedAt: timestamp
            ├── endedAt: timestamp
            ├── duration: number
            ├── endReason: string
            └── result: string

        Writer: Senior, Family
        Reader: Family
        보존: 365일 (Cloud Function)
```

---

## Firebase Storage

**버킷**: `gs://dcom-smart-frame.firebasestorage.app`

```text
families/
  {familyId}/
    temp/                                       # 사진 원본 임시 버퍼 (Senior 다운로드 후 삭제)
      {photoId}.jpg
    thumbs/                                     # 사진 썸네일 영구 저장 (400×400px, ~100KB)
      {photoId}.jpg
    reminders/
      {reminderId}/
        media.mp4                               # 영상 알림 미디어
```

### 만료 정책

| 대상 | 조건 | 경과 시간 | 처리 |
| --- | --- | --- | --- |
| photoSync | `status: "pending"` | 7일 | Storage 삭제 + `status: "expired"` |
| photoSync | `status: "expired"` | 37일 | RTDB 항목 삭제 |
| reminderLogs | - | 90일 | RTDB 항목 삭제 |
| callHistory | - | 365일 | RTDB 항목 삭제 |

---

## Cloud Functions 와치독 (cleanupOrphanedData)

매일 새벽 3시 (KST) 실행. 수동: `cleanupOrphanedDataManual` HTTP 호출.

```text
Step 1: 유령 디바이스 정리
  /devices/ → !hasConnections + lastSeen 7일 경과 → 삭제
  → 해당 /families/{fid}/devices/{did}도 삭제
  (connections: Senior register 시 /devices/{did}/connections/{sessionId} 기록,
   끊김 시 onDisconnect().removeValue()로 자동 제거)

Step 2: 가족 내 유령 디바이스 정리
  /families/{fid}/devices/{did} → /devices/{did} 없거나 familyId 불일치 → 삭제

Step 3: 고아 가족 정리
  /families/{fid} → members 0명 + devices 0명 → 삭제 (pairingCode도)

Step 4: 고아 페어링 코드 정리
  /pairingCodes/{code} → familyId가 /families/에 없음 → 삭제

Step 5: 고아 유저 참조 정리
  /users/{uid}/familyIds/{fid} → familyId가 /families/에 없음 → familyIds + familyNames 삭제
```

---

## v2 → v3 변경 요약

| 변경 | 내용 |
| --- | --- |
| `/families/{fid}/devices/{did}` | 상세 정보 제거 → `true` (목록 플래그만) |
| `/devices/{did}` | storageTotal/Available/photoCount 이동 (기존 families에서) |
| onDisconnect | `/families/` 경로에서 완전 제거 → `/devices/`에만 |
| Family 기기 등록 | `/devices/`에 등록하지 않음 → `/users/{uid}`로만 관리 |
| `registerDevice()` | Family `app_config.dart`에서 삭제 |
| Senior `onCreate()` | RTDB familyId 검증 추가 (고아 방지) |

## v3 → v4 변경 요약 (Connection List 도입, `online` 필드 제거)

| 변경 | 내용 |
| --- | --- |
| `/devices/{did}/connections/{sessionId}` | 신규. Senior 앱 프로세스 세션별 entry. `onDisconnect().removeValue()`로 자기 child만 제거 → onDisconnect race 해소. |
| `/devices/{did}/online` | **REMOVED**. 단일 boolean + `onDisconnect().setValue(false)` 구조가 stale ghost onDisconnect race에 취약. Family는 `connections.hasChildren()` 으로 판정. |
| Cloud Functions `cleanupOrphanedData` | orphan 판정 조건을 `!hasConnections && lastSeen 7일`로 전환 (기존 `!online && lastSeen 7일`). |
| Senior `DeviceRegistration.register()` | `sessionId = UUID.randomUUID()` 매번 생성 / `.info/connected=true` 콜백에서 atomic `updateChildren`으로 `connections` 서브트리 통째 교체 + lastSeen 동반 갱신 / onDisconnect를 data write 이전에 등록 (Firebase 공식 가이드). |

**Family 앱 마이그레이션 이력**: [presence_migration_handover.md](presence_migration_handover.md) — 본 v4 배포로 마이그레이션 완료.

### 사진 전송 라이프사이클

```text
Family 업로드     → 원본: families/{fid}/temp/{photoId}.jpg (임시)
                  → 썸네일: families/{fid}/thumbs/{photoId}.jpg (영구, 400×400px)
                  → RTDB: thumbUrl + status: "pending"
Senior 저장 완료  → downloadedBy/{deviceId}: true
Cloud Function    → 모든 Senior 완료 → temp Storage 삭제 + status: "done"
                  → thumbPath/storagePath 필드 제거 (thumbUrl은 유지)
만료 (7일)       → status: "expired" + temp Storage 삭제 (Cloud Function)
                  → thumbs Storage도 삭제
RTDB 정리 (37일) → RTDB 항목 완전 삭제 (Cloud Function)
Family 삭제 요청  → RTDB 노드 즉시 remove()
                  → Cloud Function(onPhotoDeleted, onDelete 트리거): thumbs Storage 삭제
                  → Senior: onDataChange → 로컬 파일 자동 삭제 (오프라인 중이어도 재연결 시)
```
