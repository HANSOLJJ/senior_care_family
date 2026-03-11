# Firebase 데이터 스키마

## RTDB

**URL**: `https://dcom-smart-frame-default-rtdb.firebaseio.com`

```
Firebase RTDB
│
├── /devices/{deviceId}/                     # 기기 등록 (Senior + Family 공용)
│   ├── online: boolean                      # onDisconnect → false
│   ├── model: string
│   ├── name: string
│   ├── lastSeen: timestamp                  # onDisconnect → ServerValue.timestamp
│   ├── familyId: string                     # (Senior가 설정)
│   └── fcmToken: string                     # (FCM 토큰)
│
├── /calls/{callId}/                         # 영상통화 시그널링
│   ├── offer: { sdp, type }
│   ├── answer: { sdp, type }
│   ├── targetDeviceId: string
│   ├── callerUid: string                    # 발신자 userId
│   ├── callerName: string                   # 발신자 이름
│   ├── createdAt: timestamp
│   ├── status: "ringing" | "connected" | "ended"
│   ├── callerCandidates/                    # ICE candidates (발신자)
│   └── calleeCandidates/                    # ICE candidates (수신자)
│
├── /pairingCodes/{code}: familyId           # 시니어 기기 페어링 코드 역조회
│
├── /families/{familyId}/
│   ├── pairingCode: string                  # 시니어 기기 페어링 코드
│   ├── createdAt: timestamp
│   │
│   ├── devices/
│   │   └── {deviceId}/
│   │       ├── name: string                 # 기기 이름
│   │       ├── model: string                # "SM-T500"
│   │       ├── addedAt: timestamp
│   │       ├── lastSeen: timestamp
│   │       └── online: boolean
│   │
│   ├── members/
│   │   └── {userId}/
│   │       ├── name: string                 # "딸", "아들"
│   │       ├── role: string                 # "family"
│   │       └── joinedAt: timestamp
│   │
│   ├── photoSync/                           # 사진 전송 큐 (Family↔Senior)
│   │   └── {photoId}/
│   │       ├── fileName: string             # "{photoId}.jpg"
│   │       ├── size: number                 # 압축 후 바이트
│   │       ├── checksum: string             # MD5 해시
│   │       ├── storageUrl: string           # Storage 다운로드 URL
│   │       ├── storagePath: string          # Storage 경로 (Family가 정리 후 삭제됨)
│   │       ├── uploadedBy: string           # userId
│   │       ├── uploadedByName: string       # "딸"
│   │       ├── createdAt: timestamp
│   │       ├── status: string               # "pending"|"downloading"|"done"|"expired"|"deleted"
│   │       ├── retryCount: number           # 실패 시 증가 (max 3)
│   │       └── thumbnail: string            # base64 (100×100px, ~2KB)
│   │
│   ├── reminders/                           # (미구현)
│   │   └── {reminderId}/
│   │       ├── type: "medication" | "custom"
│   │       ├── title: string
│   │       ├── message: string
│   │       ├── mediaUrl: string             # 가족이 녹화한 영상/음성
│   │       ├── schedule: { time, repeat, days }
│   │       ├── enabled: boolean
│   │       ├── createdBy: userId
│   │       └── createdByName: string
│   │
│   ├── reminderLogs/                        # (미구현)
│   │   └── {logId}/
│   │       ├── reminderId: string
│   │       ├── scheduledAt: timestamp
│   │       ├── status: "confirmed" | "missed" | "pending"
│   │       ├── detectedAt: timestamp | null
│   │       └── notifiedAt: timestamp | null
│   │
│   └── callHistory/                         # (미구현)
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

## Firebase Storage

**버킷**: `gs://dcom-smart-frame.firebasestorage.app`

```
families/
  {familyId}/
    temp/                                    # 사진 임시 버퍼 (전송 완료 후 삭제)
      {photoId}.jpg                          # Family 업로드 → Senior 다운로드 → Family 삭제
    reminders/                               # (미구현)
      {reminderId}/
        media.mp4                            # 복약 알림 영상
```

### Storage Rules

- `families/{familyId}/temp/{fileName}`
  - **read**: 누구나 (Senior는 Firebase Auth 없음)
  - **write**: 인증된 사용자만 (`request.auth != null`)
- **삭제 주체**: Family 앱 — Senior가 `status: done` 설정 후, Family가 감지하여 Storage 임시 파일 삭제
- **미수신 파일**: Cloud Function (`cleanupExpiredPhotos`)이 6시간마다 정리

### 만료 정책

| 조건 | 경과 시간 | 처리 |
|------|-----------|------|
| `status: "pending"` | 7일 | Storage 삭제 + `status: "expired"` + `storagePath` 제거 |
| `status: "expired"` | 37일 (만료 후 30일) | RTDB 항목 자체 삭제 (썸네일 포함) |

- **실행 주기**: 6시간마다 (Cloud Functions 스케줄)
- **만료 기간 7일 근거**: 주말, 병원 입원, 충전 깜빡 등 현실적 시나리오 고려
- **RTDB 30일 정리 근거**: 썸네일(base64) 무한 축적 방지
- **Family UI**: `expired` 항목은 `deleted`와 동일하게 목록에서 숨김

### 사진 전송 라이프사이클

```
Family 업로드     → storagePath 생성, status: "pending"
Senior 수신 시작  → status: "downloading"
Senior 저장 완료  → status: "done"
Family 정리       → Storage 파일 삭제, storagePath 필드 제거
만료 (7일)       → status: "expired" (Cloud Function, Storage 삭제)
RTDB 정리 (37일) → RTDB 항목 완전 삭제 (Cloud Function)
Family 삭제 요청  → status: "deleted" → Senior 로컬 파일 삭제
```
