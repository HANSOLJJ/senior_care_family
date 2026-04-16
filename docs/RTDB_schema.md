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

- ~~모든 비-리프 노드에 `_label` 필드 추가~~ → **`/families/{fid}/_label` 만 유지**
- 나머지 경로(devices, calls, members, photoSync, reminders)의 `_label` 은 DEPRECATED
- `_`가 알파벳 순 최상위 → Firebase Console에서 노드 열면 첫 번째로 보임

---

```text
Firebase RTDB
│
├── /devices/{deviceId}/                        # Senior 기기 전용 레지스트리
│   ├── _label: string                          # ⚠️ DEPRECATED — 신규 미생성. 기존 데이터만 잔존.
│   ├── role: "senior"                          # 항상 senior (Family는 등록 안 함)
│   ├── model: string                           # ⚠️ DEPRECATED — name 으로 통일. 기존 데이터만 잔존.
│   ├── name: string                            # 표시 이름 (기기 모델명)
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
│   ├── _label: string                          # ⚠️ DEPRECATED — 신규 미생성.
│   ├── callerUid: string                       # 발신자 Firebase Auth UID
│   ├── callerName: string                      # 발신자 표시 이름
│   ├── callerDeviceId: string                  # ⚠️ DEPRECATED — callerUid 로 충분. 신규 미생성.
│   ├── targetDeviceId: string                  # 수신 기기 ID (Senior)
│   ├── targetFamilyId: string                  # 수신 가족 ID (Security Rules용)
│   ├── callType: "call" | "monitor"            # call=양방향, monitor=일방향 CCTV
│   ├── status: "ringing"|"answered"|"connected"|"ended"
│   │                                           # ringing: Family 가 call 생성 시 초기값 (Family writer)
│   │                                           # answered: Senior 가 sendAnswer 시 덮어씀 (Senior writer)
│   │                                           # connected: Family 가 sendAnswer 시 덮어씀 (Family 가 receiver 일 때만 — 현재 미사용)
│   │                                           # ended: Family 가 hangUp 시 덮어씀 (Family writer)
│   │                                           # ⚠️ LWW 주의: 빠른 hangUp 시나리오에서 Senior 의 answered 가 Family 의 ended 를 뒤늦게 덮어쓸 수 있음.
│   │                                           #    Senior 는 sendAnswer 전에 현재 status 확인 필요 (ended 면 answered 쓰지 않음).
│   ├── endReason: string | null                # "normal"/"remoteBusy"/"capacityExceeded"/"otherCallStarted"
│   ├── seniorAccepted: boolean | null           # Senior 수락 여부 (call 타입)
│   ├── createdAt: timestamp
│   ├── offer: { sdp: string, type: string }    # SDP offer (Family → Senior)
│   ├── answer: { sdp: string, type: string }   # SDP answer (Senior → Family)
│   ├── callerCandidates/
│   │   └── {pushId}: { candidate, sdpMid, sdpMLineIndex }
│   ├── calleeCandidates/
│   │   └── {pushId}: { candidate, sdpMid, sdpMLineIndex }
│   ├── upgradeRequest: "call" | null           # 모니터링 → 통화 전환 요청
│   ├── renegotiateOffer: { sdp, type } | null
│   ├── renegotiateAnswer: { sdp, type } | null
│   ├── iceRestartOffer: { sdp, type } | null   # ICE restart offer (Family → Senior)
│   └── iceRestartAnswer: { sdp, type } | null  # ICE restart answer (Senior → Family)
│
│   Writer: Family (offer/candidates/upgradeRequest/renegotiateOffer/iceRestartOffer/status=ringing|ended),
│           Senior (answer/candidates/seniorAccepted/renegotiateAnswer/iceRestartAnswer/endReason/status=answered)
│   정리: 통화 종료 후 Family 가 10초 지연 후 삭제 (Senior 가 status=ended 또는 노드 삭제로 dispose 할 시간 확보).
│         10초 내 Family 앱 종료 시 고아 노드 남음 → cleanupOrphanedData CF 가 매일 정리.
│
├── /pairingCodes/{code}: familyId              # 페어링 코드 → 가족 ID 역조회
│
│   Writer: Senior (페어링 시작 시)
│   Reader: Family (페어링 참여 시)
│
├── /users/{userId}/                            # Family 앱 사용자 프로필
│   ├── provider: string                        # ⚠️ DEPRECATED — 레거시 잔존. 신규 미생성.
│   ├── updatedAt: timestamp                    # ⚠️ DEPRECATED — 레거시 잔존. 신규 미생성.
│   ├── familyIds/
│   │   └── {familyId}: true                    # 소속 가족 목록
│   └── familyNames/
│       └── {familyId}: string                  # 가족별 별칭 ("부모님")
│
│   Writer: Family 앱 (familyIds/familyNames만 active)
│   Reader: Family 앱
│   ※ Family 기기는 /devices/에 등록하지 않음
│   ※ 프로필 정보(name/email/photoUrl)는 Firebase Auth 에서 직접 조회
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
    │   ├── count: number                       # Senior peers.size
    │   └── startedAt: timestamp
    │
    │   Writer: Senior (유일 writer — active=true 설정 + onDisconnect→null)
    │   Reader: Family (family_detail_screen 통화중 표시)
    │
    ├── devices/
    │   └── {deviceId}: true                    # 소속 기기 목록 (상세 정보 없음!)
    │                                           # 상세 정보는 /devices/{deviceId}에서 읽기
    │   Writer: Senior (페어링 시)
    │   Reader: Family (deviceId 목록 조회 → /devices/{did}에서 상세)
    │
    ├── members/
    │   └── {userId}/
    │       ├── _label: string                  # ⚠️ DEPRECATED — 신규 미생성.
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
    │       ├── _label: string                  # ⚠️ DEPRECATED — 신규 미생성.
    │       ├── fileName: string
    │       ├── size: number
    │       ├── checksum: string
    │       ├── storageUrl: string              # 원본 임시 Storage URL (done 후 삭제)
    │       ├── storagePath: string | null      # 원본 임시 Storage 경로
    │       ├── thumbUrl: string                # 썸네일 Storage URL (영구)
    │       ├── thumbPath: string               # 썸네일 Storage 경로 (삭제용)
    │       ├── uploadedBy: string              # 업로더 UID
    │       ├── uploadedByName: string          # ⚠️ DEPRECATED — 신규 미생성. 빈 문자열 잔존.
    │       ├── createdAt: timestamp
    │       ├── completedAt: timestamp | null   # 모든 Senior 다운로드 완료 시각
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
    │       ├── _label: string                  # ⚠️ DEPRECATED — 신규 미생성.
    │       ├── title: string
    │       ├── mediaUrl: string
    │       ├── mediaType: "video" | "audio"
    │       ├── mediaDuration: number
    │       ├── mediaDownloaded: boolean        # Senior 미디어 다운로드 완료 여부
    │       ├── schedule/
    │       │   ├── time: string                # "HH:mm"
    │       │   ├── repeat: "daily"|"weekdays"|"weekend"|"custom"|"test_5min"
    │       │   └── days: [number]              # custom일 때만
    │       ├── enabled: boolean
    │       ├── createdBy: string               # 작성자 UID
    │       ├── createdByName: string           # ⚠️ DEPRECATED — 신규 미생성. 빈 문자열 잔존.
    │       ├── targetDeviceId: string | null   # ⚠️ DEPRECATED — 미구현 placeholder. 신규 미생성.
    │       ├── targetDeviceName: string | null  # ⚠️ DEPRECATED — 미구현 placeholder. 신규 미생성.
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
