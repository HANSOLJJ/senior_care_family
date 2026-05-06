<!-- markdownlint-disable MD024 MD036 -->

# Firebase 데이터 스키마 v4

## RTDB

**URL**: `https://dcom-smart-frame-default-rtdb.firebaseio.com`

### 핵심 원칙

- **비정규화 금지**: 같은 데이터를 두 곳에 쓰지 않음
- `/devices/{did}` — Senior 기기의 모든 정보 (유일한 출처)
- `/families/{fid}/devices/{did}: true` — 소속 목록만 (상세 정보 없음)
- `/users/{uid}` — Family 사용자 정보 (기기 등록 안 함)
- **onDisconnect는 `/devices/` 와 `/calls/` 에만** — `/families/` 경로엔 onDisconnect 없음 → 고아 부활 불가능

### deviceId 생성 규칙

| 플랫폼 | 소스 | 설명 |
| --- | --- | --- |
| Android (Senior) | `Settings.Secure.ANDROID_ID` | 기기별 고유 16자 hex, Factory Reset 시 변경 |
| Family 앱 | 없음 | `/devices/`에 등록하지 않음. `/users/{uid}`로만 식별 |

### `_label` 규칙

- ~~모든 비-리프 노드에 `_label` 필드 추가~~ → **`/families/{fid}/_label` 만 유지**
- 나머지 경로(devices, calls, members, photoSync, reminders)의 `_label` 은 DEPRECATED
- `_`가 알파벳 순 최상위 → Firebase Console에서 노드 열면 첫 번째로 보임

### 전체 트리

```text
Firebase RTDB
├── /devices/{deviceId}              # Senior 기기 레지스트리
├── /calls/{callId}                  # 영상통화 시그널링 (임시)
├── /pairingCodes/{code}             # 페어링 코드 → familyId 역조회
├── /users/{userId}                  # Family 사용자 프로필
└── /families/{familyId}             # 가족 그룹
    ├── callStatus                   # 통화중 인디케이터
    ├── devices                      # 소속 기기 목록
    ├── members                      # 멤버 목록
    ├── photoSync                    # 사진 동기화
    ├── reminders                    # 영상 알림
    ├── reminderLogs                 # 알림 응답 로그 (2차)
    └── callHistory                  # 통화 이력 (2차)
```

---

## `/devices/{deviceId}`

Senior 기기의 모든 정보를 담는 유일한 출처 (single source of truth). Family 폰은 등록하지 않음.

**책임**

- **Writer**: Senior 앱만
- **Reader**: Family 앱 (기기 상세 정보), Cloud Functions
- **onDisconnect**: `connections/{sessionId}` → `removeValue()`, `lastSeen` → `ServerValue.TIMESTAMP`
- **Presence 판정 (Family)**: `connections.hasChildren() == true`

### 필드

| 필드 | 타입 | 설명 |
| --- | --- | --- |
| `_label` | string | ⚠️ DEPRECATED — 신규 미생성. 기존 데이터만 잔존 |
| `role` | "senior" | 항상 "senior" (Family 는 등록 안 함) |
| `model` | string | ⚠️ DEPRECATED — `name` 으로 통일. 기존 데이터만 잔존 |
| `name` | string | 표시 이름 (기기 모델명) |
| `lastSeen` | timestamp | `onDisconnect` 가 `ServerValue.TIMESTAMP` 로 갱신 |
| `connections/{sessionId}` | true | Connection List. Senior register 시 UUID 생성. `onDisconnect().removeValue()` 로 자기 child 만 제거 → 타 세션 간섭 불가 |
| `familyId` | string \| null | 소속 가족 (페어링 시 설정) |
| `fcmToken` | string | FCM 푸시 토큰 |
| `appVersion` | string | "1.0" 등 |
| `createdAt` | timestamp | 최초 등록 시각 |
| `storageTotal` | number | 전체 용량 (bytes) |
| `storageAvailable` | number | 가용 용량 (bytes) |
| `photoCount` | number | 저장된 사진 수 |
| `storageUpdatedAt` | timestamp | 스토리지 정보 갱신 시각 |

---

## `/calls/{callId}`

영상통화/모니터링 시그널링용 임시 노드. 통화 종료 후 Family 가 10초 지연 후 삭제.

**책임**

- **라이프사이클**: `ringing` → `answered` → `connected` → `ended` → Family 가 10s 후 노드 삭제
- **정리**: 10초 내 Family 앱 종료 시 고아 노드 잔존 → `cleanupOrphanedData` CF 가 매일 정리
- **1:N × 1:1 정책 (Senior 측 강제)**:
  - monitor N개 동시 허용 (상한 `MAX_PEERS=3`, 초과 시 `endReason=capacityExceeded`)
  - call 은 1개 배타 (기존 call 이 있으면 `endReason=remoteBusy`)
  - call 수락 시 기존 monitor peer 들 자동 displace (`endReason=otherCallStarted`)
  - 상세: [docs/call-scenarios.md §13](call-scenarios.md)

### Writer 매트릭스

| Writer | 쓰는 필드 |
| --- | --- |
| **Family** | `offer`, `callerCandidates`, `status` (ringing\|ended), `endReason` (remoteEnded), `upgradeRequest`, `renegotiateOffer`, `iceRestartOffer`, `callerUid`, `callerName`, `targetDeviceId`, `targetFamilyId`, `callType`, `createdAt` |
| **Senior** | `answer`, `calleeCandidates`, `status` (answered), `endReason` (normal\|remoteBusy\|capacityExceeded\|otherCallStarted), `seniorAccepted`, `renegotiateAnswer`, `iceRestartAnswer` |
| **Server-side onDisconnect** (Plan B 필드 분리) | `hasFlapMarker=true` (Family/Senior wifi 끊김 시 Firebase 서버가 자동 기록. **status 는 건드리지 않음** — 라이프사이클은 정상 종결만 status="ended") |

> ⚠️ Family 내부 `TerminateReason.iceFailed` / `unreachable` / `noAcceptance` 등은 **Dart enum 값이며 RTDB endReason 에 도달하지 않음** (Family UX 매핑 전용). RTDB 에 실제로 쓰이는 Family endReason 은 `"remoteEnded"` 한 가지 (R2 fix 이후 도입). 매핑 상세는 [call-scenarios.md §10](call-scenarios.md).

### 필드 명세

| 필드 | 타입 | 설명 |
| --- | --- | --- |
| `_label` | string | ⚠️ DEPRECATED — 신규 미생성 |
| `callerUid` | string | 발신자 Firebase Auth UID |
| `callerName` | string | 발신자 표시 이름 |
| `callerDeviceId` | string | ⚠️ DEPRECATED — `callerUid` 로 충분. 신규 미생성 |
| `targetDeviceId` | string | 수신 기기 ID (Senior) |
| `targetFamilyId` | string | 수신 가족 ID (Security Rules 용) |
| `callType` | "call" \| "monitor" | call=양방향, monitor=일방향 CCTV |
| `status` | "ringing" \| "answered" \| "connected" \| "ended" | 라이프사이클 — 별도 표 참조 |
| `endReason` | string \| null | 종결 사유 — 별도 매트릭스 참조 |
| `seniorAccepted` | boolean \| null | Senior 수락 여부 (call 타입) |
| `createdAt` | timestamp | |
| `offer` | { sdp, type } | SDP offer (Family → Senior) |
| `answer` | { sdp, type } | SDP answer (Senior → Family) |
| `callerCandidates/{pushId}` | { candidate, sdpMid, sdpMLineIndex } | Family 측 ICE candidate |
| `calleeCandidates/{pushId}` | { candidate, sdpMid, sdpMLineIndex } | Senior 측 ICE candidate |
| `upgradeRequest` | "call" \| null | 모니터링 → 통화 전환 요청 (Family writer) |
| `renegotiateOffer` | { sdp, type } \| null | 양방향 전환 시 renegotiate offer (Family writer) |
| `renegotiateAnswer` | { sdp, type } \| null | renegotiate answer (Senior writer) |
| `iceRestartOffer` | { sdp, type } \| null | ICE restart offer (Family writer) |
| `iceRestartAnswer` | { sdp, type } \| null | ICE restart answer (Senior writer) |
| `hasFlapMarker` | true \| null | wifi flap 신호 — Server-side onDisconnect 가 자동 set, 자기 wifi 복귀 후 client 가 clear (Plan B 필드 분리) |

### `status` 라이프사이클

| 전이 | Writer | 트리거 | 비고 |
| --- | --- | --- | --- |
| `null → "ringing"` | Family | `createCall` | 초기값 |
| `"ringing" → "answered"` | Senior | `sendAnswer` | LWW 주의: 이미 "ended" 면 덮어쓰지 않음 (Senior 측 status 사전 검사 필요) |
| `"*" → "ended"` (Family) | Family | `hangUp` → `endCall` | `endReason="remoteEnded"` 동반 set (R2 fix) |
| `"*" → "ended"` (Senior) | Senior | `hangUp` / `markEnded` | `endReason` 동반 set (normal/remoteBusy/...) |
| `"*" → "ended"` (Senior 강제) | Senior | STOP_DELAY 만료 → `stopPeer` | wifi flap 종결 시 Senior 가 status="ended" 강제 set (Plan B — server-side onDisconnect 는 status 안 건드림) |

### `endReason` 매트릭스

| 값 | Writer | 트리거 | Family UX 매핑 (TerminateReason) |
| --- | --- | --- | --- |
| `"normal"` | Senior | Senior 사용자 명시적 hangUp | `remoteEnded` |
| `"remoteBusy"` | Senior | Senior 가 이미 다른 call 진행 중 → 신규 call 거절 | `remoteBusy` |
| `"capacityExceeded"` | Senior | monitor `MAX_PEERS=3` 초과 → 신규 monitor 거절 | `capacityExceeded` |
| `"otherCallStarted"` | Senior | call 수락 → 기존 monitor peer 들 displace | `endedByOtherCall` |
| `"remoteEnded"` | **Family** (R2 fix) | `endCall` (사용자 hangUp 등 모든 Family-측 종결) | `remoteEnded` (자기 콜백은 `_isEnding` 가드로 무시) |

> **Plan B 필드 분리 이후**: `familyDisconnect` / `seniorDisconnect` 마커 없어짐. wifi flap 신호는 별도 `hasFlapMarker` 필드로 분리. status 는 정상 종결만 표현.

### Plan B (필드 분리) 보충

- **wifi flap 신호 (`hasFlapMarker=true`)**: Family 또는 Senior wifi 끊김 시 Firebase server-side onDisconnect 가 자동 set. 상대 측은 `listenForFlapMarker` 로 받아서 PC connectionState 기반 자기/상대 마커 구분 — PC=CONNECTED 면 자기 마커로 추정 후 clear + onDisconnect 재등록, PC≠CONNECTED 면 상대 wifi flap 으로 grace 진입.
- **race 해결**: Plan A 에서 `status="ended"` 한 필드에 wifi flap 마커 + 진짜 종결 두 의미를 담아 모든 listener 가 endReason 분기 → 영상통화 1→2 전이 race 등 폭발. 필드 분리로 status 변경 = 무조건 진짜 종결 → 분기 사라짐.
- **R2 (Family `remoteEnded`)**: Plan B 에서도 유지 — Senior 가 받은 endReason 으로 UX 매핑.

---

## `/pairingCodes/{code}`

페어링 코드 → familyId 역조회.

**책임**

- **Writer**: Senior (페어링 시작 시)
- **Reader**: Family (페어링 참여 시)

### 필드

| 필드 | 타입 | 설명 |
| --- | --- | --- |
| 노드 자체 | string | familyId 값 (예: `"f-abc123"`) |

---

## `/users/{userId}`

Family 앱 사용자 프로필.

**책임**

- **Writer**: Family 앱 (`familyIds` / `familyNames` 만 active)
- **Reader**: Family 앱
- ※ Family 기기는 `/devices/` 에 등록하지 않음
- ※ 프로필 정보 (name/email/photoUrl) 는 Firebase Auth 에서 직접 조회

### 필드

| 필드 | 타입 | 설명 |
| --- | --- | --- |
| `provider` | string | ⚠️ DEPRECATED — 레거시 잔존. 신규 미생성 |
| `updatedAt` | timestamp | ⚠️ DEPRECATED — 레거시 잔존. 신규 미생성 |
| `familyIds/{familyId}` | true | 소속 가족 목록 |
| `familyNames/{familyId}` | string | 가족별 별칭 (예: "부모님") |

---

## `/families/{familyId}`

가족 그룹 메타 + 하위 컬렉션.

**책임** (루트 필드)

- **Writer**: Family (생성/별칭 갱신)
- **Reader**: Family, Senior

### 필드 (루트)

| 필드 | 타입 | 설명 |
| --- | --- | --- |
| `_label` | string | "부모님" 등 사용자 지정 이름 |
| `pairingCode` | string | 현재 활성 페어링 코드 (6자리) |
| `createdAt` | timestamp | |

---

### `/families/{fid}/callStatus`

실시간 통화 상태 (UI 인디케이터용).

**책임**

- **Writer**: Senior (유일 writer — `active=true` 설정 + `onDisconnect → null`)
- **Reader**: Family (`family_detail_screen` 통화중 표시)

#### 필드

| 필드 | 타입 | 설명 |
| --- | --- | --- |
| `active` | boolean | 통화 중 여부 |
| `type` | "call" \| "monitor" | 통화 종류 |
| `callerName` | string | 발신자 표시 이름 |
| `count` | number | Senior peers.size |
| `startedAt` | timestamp | |

---

### `/families/{fid}/devices`

소속 기기 목록 (상세 정보 없음 — 상세는 `/devices/{did}` 에서 조회).

**책임**

- **Writer**: Senior (페어링 시)
- **Reader**: Family (deviceId 목록 조회 → `/devices/{did}` 에서 상세)

#### 필드

| 필드 | 타입 | 설명 |
| --- | --- | --- |
| `{deviceId}` | true | 소속 기기 플래그 (상세 정보 없음!) |

---

### `/families/{fid}/members`

가족 멤버 목록.

**책임**

- **Writer**: Family 앱 (`joinFamily` 시)
- **Reader**: Family 앱, Senior (멤버 수 감지)

#### 필드 (`/{userId}` 하위)

| 필드 | 타입 | 설명 |
| --- | --- | --- |
| `_label` | string | ⚠️ DEPRECATED — 신규 미생성 |
| `name` | string | 표시 이름 (사용자 지정) |
| `role` | "family" | |
| `provider` | "google" \| "apple" \| "kakao" \| "naver" | 로그인 제공자 |
| `photoUrl` | string | |
| `joinedAt` | timestamp | |

---

### `/families/{fid}/photoSync`

사진 동기화 메타.

**책임**

- **Writer**: Family (업로드/삭제), Senior (`downloadedBy`), Cloud Function (만료/Storage)
- **Reader**: Family, Senior
- ※ thumbnail (base64) 필드 제거 → `thumbUrl` (Storage URL) 로 교체
- ※ "deleted" 상태 제거 → Family 가 RTDB 노드를 즉시 `remove()`
- ※ Family 앱: `onValue` 구독 + `setPersistenceEnabled(true)` (delta sync)
- ※ Senior 앱: `ValueEventListener` + `setPersistenceEnabled(true)` (고아 파일 자동 삭제)

#### 필드 (`/{photoId}` 하위)

| 필드 | 타입 | 설명 |
| --- | --- | --- |
| `_label` | string | ⚠️ DEPRECATED — 신규 미생성 |
| `fileName` | string | |
| `size` | number | bytes |
| `checksum` | string | |
| `storageUrl` | string | 원본 임시 Storage URL (done 후 삭제) |
| `storagePath` | string \| null | 원본 임시 Storage 경로 |
| `thumbUrl` | string | 썸네일 Storage URL (영구) |
| `thumbPath` | string | 썸네일 Storage 경로 (삭제용) |
| `uploadedBy` | string | 업로더 UID |
| `uploadedByName` | string | ⚠️ DEPRECATED — 신규 미생성. 빈 문자열 잔존 |
| `createdAt` | timestamp | |
| `completedAt` | timestamp \| null | 모든 Senior 다운로드 완료 시각 |
| `status` | "pending" \| "done" \| "expired" | |
| `retryCount` | number | |
| `downloadedBy/{deviceId}` | true | 각 Senior 다운로드 완료 기록 |

---

### `/families/{fid}/reminders`

영상/오디오 알림 스케줄.

**책임**

- **Writer**: Family (CRUD)
- **Reader**: Senior (스케줄링 + 미디어 다운로드)

#### 필드 (`/{reminderId}` 하위)

| 필드 | 타입 | 설명 |
| --- | --- | --- |
| `_label` | string | ⚠️ DEPRECATED — 신규 미생성 |
| `title` | string | |
| `mediaUrl` | string | |
| `mediaType` | "video" \| "audio" | |
| `mediaDuration` | number | |
| `mediaDownloaded` | boolean | Senior 미디어 다운로드 완료 여부 |
| `schedule.time` | string | "HH:mm" |
| `schedule.repeat` | "daily" \| "weekdays" \| "weekend" \| "custom" \| "test_5min" | |
| `schedule.days` | [number] | custom 일 때만 |
| `enabled` | boolean | |
| `createdBy` | string | 작성자 UID |
| `createdByName` | string | ⚠️ DEPRECATED — 신규 미생성. 빈 문자열 잔존 |
| `targetDeviceId` | string \| null | ⚠️ DEPRECATED — 미구현 placeholder. 신규 미생성 |
| `targetDeviceName` | string \| null | ⚠️ DEPRECATED — 미구현 placeholder. 신규 미생성 |
| `createdAt` | timestamp | |
| `updatedAt` | timestamp | |

---

### `/families/{fid}/reminderLogs` (2차 — 스키마만 확정)

알림 응답 로그.

**책임**

- **Writer**: Senior
- **Reader**: Family
- **보존**: 90일 (Cloud Function)

#### 필드 (`/{logId}` 하위)

| 필드 | 타입 | 설명 |
| --- | --- | --- |
| `_label` | string | |
| `reminderId` | string | |
| `reminderTitle` | string | |
| `scheduledAt` | timestamp | |
| `triggeredAt` | timestamp | |
| `status` | "pending" \| "confirmed" \| "missed" | |
| `confirmedAt` | timestamp \| null | |
| `missedAt` | timestamp \| null | |
| `notifiedFamilyAt` | timestamp \| null | |
| `detectionMethod` | "face" \| "manual" \| null | |

---

### `/families/{fid}/callHistory` (2차 — 스키마만 확정)

통화 이력.

**책임**

- **Writer**: Senior, Family
- **Reader**: Family
- **보존**: 365일 (Cloud Function)

#### 필드 (`/{historyId}` 하위)

| 필드 | 타입 | 설명 |
| --- | --- | --- |
| `_label` | string | |
| `callId` | string | |
| `callerUid` | string | |
| `callerName` | string | |
| `targetDeviceId` | string | |
| `targetDeviceName` | string | |
| `callType` | "call" \| "monitor" | |
| `startedAt` | timestamp | |
| `endedAt` | timestamp | |
| `duration` | number | |
| `endReason` | string | |
| `result` | string | |

---

## Firebase Storage

**버킷**: `gs://dcom-smart-frame.firebasestorage.app`

```text
families/
  {familyId}/
    temp/                            # 사진 원본 임시 버퍼 (Senior 다운로드 후 삭제)
      {photoId}.jpg
    thumbs/                          # 사진 썸네일 영구 저장 (400×400px, ~100KB)
      {photoId}.jpg
    reminders/
      {reminderId}/
        media.mp4                    # 영상 알림 미디어
```

### 만료 정책

| 대상 | 조건 | 경과 시간 | 처리 |
| --- | --- | --- | --- |
| photoSync | `status: "pending"` | 7일 | Storage 삭제 + `status: "expired"` |
| photoSync | `status: "expired"` | 37일 | RTDB 항목 삭제 |
| reminderLogs | - | 90일 | RTDB 항목 삭제 |
| callHistory | - | 365일 | RTDB 항목 삭제 |

---

## Cloud Functions 와치독 — `cleanupOrphanedData`

매일 새벽 3시 (KST) 실행. 수동: `cleanupOrphanedDataManual` HTTP 호출.

| Step | 대상 | 조건 | 처리 |
| --- | --- | --- | --- |
| 1 | `/devices/{did}` | `!hasConnections` + `lastSeen` 7일 경과 | 삭제 + `/families/{fid}/devices/{did}` 삭제 |
| 2 | `/families/{fid}/devices/{did}` | `/devices/{did}` 없거나 `familyId` 불일치 | 삭제 |
| 3 | `/families/{fid}` | members 0명 + devices 0명 | 삭제 (pairingCode 도) |
| 4 | `/pairingCodes/{code}` | `familyId` 가 `/families/` 에 없음 | 삭제 |
| 5 | `/users/{uid}/familyIds/{fid}` | `familyId` 가 `/families/` 에 없음 | `familyIds` + `familyNames` 삭제 |

---

## 사진 전송 라이프사이클

```text
Family 업로드     → 원본: families/{fid}/temp/{photoId}.jpg (임시)
                  → 썸네일: families/{fid}/thumbs/{photoId}.jpg (영구, 400×400px)
                  → RTDB: thumbUrl + status: "pending"
Senior 저장 완료  → downloadedBy/{deviceId}: true
Cloud Function    → 모든 Senior 완료 → temp Storage 삭제 + status: "done"
                  → thumbPath/storagePath 필드 제거 (thumbUrl 은 유지)
만료 (7일)       → status: "expired" + temp Storage 삭제 (Cloud Function)
                  → thumbs Storage 도 삭제
RTDB 정리 (37일) → RTDB 항목 완전 삭제 (Cloud Function)
Family 삭제 요청  → RTDB 노드 즉시 remove()
                  → Cloud Function (onPhotoDeleted, onDelete 트리거): thumbs Storage 삭제
                  → Senior: onDataChange → 로컬 파일 자동 삭제 (오프라인 중이어도 재연결 시)
```

---

## 버전 변경 이력

### v2 → v3

| 변경 | 내용 |
| --- | --- |
| `/families/{fid}/devices/{did}` | 상세 정보 제거 → `true` (목록 플래그만) |
| `/devices/{did}` | `storageTotal/Available/photoCount` 이동 (기존 families 에서) |
| onDisconnect | `/families/` 경로에서 완전 제거 → `/devices/` 에만 |
| Family 기기 등록 | `/devices/` 에 등록하지 않음 → `/users/{uid}` 로만 관리 |
| `registerDevice()` | Family `app_config.dart` 에서 삭제 |
| Senior `onCreate()` | RTDB familyId 검증 추가 (고아 방지) |

### v3 → v4 (Connection List 도입, `online` 필드 제거)

| 변경 | 내용 |
| --- | --- |
| `/devices/{did}/connections/{sessionId}` | 신규. Senior 앱 프로세스 세션별 entry. `onDisconnect().removeValue()` 로 자기 child 만 제거 → onDisconnect race 해소 |
| `/devices/{did}/online` | **REMOVED**. 단일 boolean + `onDisconnect().setValue(false)` 가 stale ghost onDisconnect race 에 취약. Family 는 `connections.hasChildren()` 으로 판정 |
| `cleanupOrphanedData` | orphan 판정을 `!hasConnections && lastSeen 7일` 로 전환 |
| Senior `DeviceRegistration.register()` | `sessionId = UUID.randomUUID()` 매번 생성 / `.info/connected=true` 콜백에서 atomic `updateChildren` 으로 `connections` 서브트리 통째 교체 + `lastSeen` 동반 갱신 / onDisconnect 를 data write 이전에 등록 (Firebase 공식 가이드) |

**Family 앱 마이그레이션 이력**: [presence_migration_handover.md](presence_migration_handover.md) — 본 v4 배포로 마이그레이션 완료.

### v4 → Plan A (S16 + R2 fix)

| 변경 | 내용 |
| --- | --- |
| `/calls/{cid}` server-side onDisconnect | (S16) 노드 삭제 → `status="ended"` + `endReason="seniorDisconnect"` 임시 마커. Senior wifi 자발적 drop 시 통화 떠받치기 |
| `/calls/{cid}` Senior `restoreActiveStatus` | (S16) wifi 복구 후 자기 마커 무시 + `status="answered"`/`endReason=null` 복원 |
| `/calls/{cid}` Family `endCall` | (R2) `status="ended"` 만 → `status="ended"` + `endReason="remoteEnded"` 동반 set. Family 가 endReason RTDB writer 로 첫 도입 |
| `/calls/{cid}` Senior `restoreActiveStatus` | (R2) `updateChildren` → `runTransaction` 가드. status/endReason 이 자기 마커와 일치할 때만 복원 |
| `/calls/{cid}` Family `setCallCleanupOnDisconnect` | (Plan A) `.remove()` → `.update({status:"ended", endReason:"familyDisconnect"})` 마커 정책 |

### Plan A → Plan B (필드 분리, 현재)

| 변경 | 내용 |
| --- | --- |
| `/calls/{cid}/hasFlapMarker` 필드 신규 | wifi flap 신호 전용 별도 필드. server-side onDisconnect 가 자동 set, 자기 wifi 복귀 후 client 가 clear |
| `/calls/{cid}` server-side onDisconnect | Family/Senior 양측 모두 `hasFlapMarker=true` set (status 안 건드림). Plan A 의 `endReason="familyDisconnect"`/`"seniorDisconnect"` 마커 폐기 |
| Family `_callEndSub` / Senior `listenForStatus` | endReason 분기 모두 제거. `status="ended"` = 무조건 진짜 종결로 처리 |
| Family `_flapMarkerSub` / Senior `listenForFlapMarker` 신규 | hasFlapMarker 변경 listener. PC connectionState 기반 자기/상대 마커 구분 (CONNECTED → 자기 마커 clear + onDisconnect 재등록, ≠CONNECTED → 상대 wifi flap → grace 진입) |
| Senior `restoreActiveStatus` 호출 제거 | status 자체 안 건드리니 복원 불필요 |
| CF Step 7b stub cleanup | `endReason="familyDisconnect"` 조건 → `hasFlapMarker=true && status!="ended"` 조건으로 변경 |
