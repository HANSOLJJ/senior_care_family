# 미디어 전송 설계 (사진 + 알림 미디어)

## 개요

Family 앱 → Firebase Storage (임시 버퍼) → Senior 태블릿 로컬 저장.
RTDB로 전송 큐/상태 관리. 모든 Senior 다운로드 완료 시 Cloud Function이 Storage 자동 삭제.
영구 저장은 태블릿 로컬에만. 클라우드 비용 거의 $0.

**사진과 알림 미디어 모두 동일한 임시 버퍼 패턴 사용.**

- **사진**: 가족 단위 — 같은 가족의 모든 Senior가 수신
- **알림 미디어**: 기기 단위 — targetDeviceId로 지정된 Senior만 수신

## 왜 임시 버퍼 방식인가

### Firebase Storage 영구 저장의 문제

- 1000명 × 20GB = 20TB 상시 저장 → 연 200~810만원
- 온프레미스 없는 스타트업에겐 치명적 비용

### P2P 직접 전송 (DataChannel)의 문제

- 양쪽 다 온라인이어야 전송 가능
- iOS 백그라운드에서 WebRTC 유지 불가 (즉시 Suspended)
- 딸이 밤에 보냄 → 태블릿 슬립 → 전송 불가

### 임시 버퍼 방식 (채택)

- Storage를 택배 창고처럼 사용: 보관이 아닌 전달 목적
- Senior가 다운로드하면 Cloud Function이 Storage에서 삭제 → 상시 저장량 거의 0
- iOS에서도 HTTP 업로드는 백그라운드 가능 (NSURLSession)

| 비교 | 상시 저장량 | 월 비용 |
| ---- | ---------- | ------- |
| 영구 저장 20GB | 20TB | $520 |
| P2P 직접 전송 | 0 | $0 (UX 나쁨) |
| **임시 버퍼** | ~수백 MB | **~$0.01** |

---

## 아키텍처

### 사진 (가족단위)

```mermaid
sequenceDiagram
    participant F as Family 앱
    participant S as Firebase Storage
    participant R as RTDB
    participant Sr as Senior 태블릿
    participant CF as Cloud Function

    F->>F: 사진 선택 + 리사이즈 + 압축
    F->>F: 썸네일 생성 (200x200px)
    F->>S: 업로드 (families/fid/temp/)
    F->>R: photoSync/photoId 등록 (pending)
    Note over F: 앱 꺼도 OK

    Sr->>R: pending 감지 (RTDB 감시)
    Sr->>R: status: downloading
    Sr->>S: 파일 다운로드
    Sr->>Sr: MD5 검증 + 로컬 저장
    Sr->>R: downloadedBy/deviceId: true

    CF->>R: 트리거: downloadedBy 변경
    CF->>R: Senior 기기 수 확인
    Note over CF: 전체 Senior 완료?
    CF->>S: Storage 파일 삭제
    CF->>R: status: done
```

### 알림 미디어 (기기단위)

```mermaid
sequenceDiagram
    participant F as Family 앱
    participant S as Firebase Storage
    participant R as RTDB
    participant Sr as Senior 태블릿
    participant CF as Cloud Function

    F->>F: 영상/음성 녹화
    F->>S: 업로드 (families/fid/reminders/rid/)
    F->>R: reminder 등록 (mediaDownloaded: false)
    Note over F: 앱 꺼도 OK

    Sr->>R: 새 알림 감지 (targetDeviceId 일치)
    Sr->>S: 미디어 다운로드
    Sr->>Sr: 로컬 저장 저장
    Sr->>R: mediaDownloaded: true

    CF->>R: 트리거: mediaDownloaded 변경
    CF->>S: Storage 미디어 삭제
    Note over Sr: AlarmManager 스케줄 등록

    F->>R: 알림 삭제
    CF->>R: 트리거: reminder 삭제 감지
    CF->>S: Storage 잔여 파일 삭제
    Note over Sr: Senior 감지 → 로컬 저장 삭제
```

---

## Firebase Storage 경로

```text
families/{familyId}/
  temp/
    photo_{생성자}_{날짜시간}.jpg         # 사진 (임시, 다운로드 후 삭제)
  reminders/
    {reminderId}/
      {제목}_{생성자}_{날짜}.mp4          # 알림 영상 (임시, 다운로드 후 삭제)
      {제목}_{생성자}_{날짜}.m4a          # 알림 음성 (임시, 다운로드 후 삭제)
```

파일명 예시:
- `photo_딸_20260317_143052.jpg`
- `혈압약오전_딸_20260317.mp4`

---

## RTDB 구조

### 사진

```text
/families/{familyId}/photoSync/
  {photoId}/
    _label: string              # "photo_딸_20260317.jpg (pending, 딸)"
    fileName: string            # "photo_딸_20260317_143052.jpg"
    size: number                # 바이트
    checksum: string            # MD5 해시
    storageUrl: string          # Firebase Storage 다운로드 URL
    storagePath: string         # Storage 경로 (삭제용)
    uploadedBy: string          # userId
    uploadedByName: string      # "딸"
    createdAt: timestamp
    status: string              # "pending" | "downloading" | "done" | "expired" | "deleted"
    retryCount: number          # 실패 시 증가
    thumbnail: string           # base64 인코딩된 썸네일 (200×200px, ~4KB)
    downloadedBy/               # 각 Senior 다운로드 완료 기록
      {deviceId}: true
```

### 알림

```text
/families/{familyId}/reminders/
  {reminderId}/
    _label: string              # "혈압약오전 (매일 08:00)"
    title: string
    mediaUrl: string            # Storage 다운로드 URL
    mediaType: "video" | "audio"
    mediaDuration: number       # 초
    mediaDownloaded: boolean    # Senior 다운로드 완료 여부
    targetDeviceId: string      # 대상 Senior 기기 (null = 전체)
    schedule:
      time: "08:00"
      repeat: "daily" | "weekdays" | "weekend" | "custom" | "test_5min"
      days: [1,3,5]
    enabled: boolean
    createdBy: string
    createdByName: string
    createdAt: timestamp
    updatedAt: timestamp
```

---

## Storage 삭제 흐름

### 원칙

- **앱에서 Storage 직접 삭제하지 않음** (Senior는 Auth 없어서 권한 없음)
- **Cloud Function이 RTDB 트리거로 자동 삭제** (일관성)
- **와치독이 보험으로 정리** (트리거 실패, 비정상 종료 등 대비)

```mermaid
flowchart TD
    A[Storage 파일 존재] --> B{어떤 이벤트?}

    B -->|사진 done| C[RTDB 트리거: onPhotoAllDownloaded]
    C --> D{모든 Senior 다운로드?}
    D -->|Yes| E[Storage 삭제 + status done]
    D -->|No| F[대기]

    B -->|알림 미디어 done| G[RTDB 트리거: onReminderMediaDownloaded]
    G --> H[Storage 삭제]

    B -->|알림 삭제| I[RTDB 트리거: onReminderDeleted]
    I --> J[Storage 삭제]

    B -->|7일 pending| K["와치독: cleanupExpiredPhotos"]
    K --> L[Storage 삭제 + status expired]

    B -->|고아 family| M["와치독: cleanupOrphanedData"]
    M --> N[Storage 전체 삭제]

    B -->|전체 초기화| O["Senior: performFullReset"]
    O --> P["Storage families/fid/ 전체 삭제"]
```

- 사진: Senior 1대 가족이면 1대 done → 즉시 삭제. 2대면 2대 모두 done → 삭제.
- 알림 미디어: targetDevice 1대 다운로드 완료 → 즉시 삭제.
- 전체 초기화: Storage + 로컬 + RTDB 전부 삭제.

---

## 전송 흐름

### 1. Family 앱에서 사진 업로드

```text
사진 선택 → 리사이즈 (긴 변 maxResolution px 이하)
         → JPEG 압축 (quality%)
         → 썸네일 생성 (200×200px, JPEG 75%, base64)
         → MD5 체크섬 계산
         → Firebase Storage 업로드 (families/{fid}/temp/photo_딸_20260317_143052.jpg)
         → RTDB photoSync/{photoId} 메타 등록 (status: "pending")
```

### 2. Senior 태블릿 수신 (복수대 지원)

```text
RTDB photoSync 감시 → status: "pending" 감지
  → downloadedBy/{자기 deviceId} 존재 확인
  → 이미 있으면 → 무시 (이미 받음)
  → 없으면 → storageUrl에서 파일 다운로드
  → MD5 검증
  → 성공: 로컬 저장 → downloadedBy/{deviceId}: true 기록
  → 실패: retryCount++ (재시도)

※ status를 "downloading"으로 변경하지 않음 — 복수 Senior가 동시에 다운로드 가능
※ Cloud Function(onPhotoDownloaded)이 모든 Senior 완료 확인 후 status: "done" + Storage 삭제
```

### 3. 만료 처리

```text
Cloud Function (와치독, 매일):
  → 7일 경과 + status: "pending" → Storage 파일 삭제 → status: "expired"
  → Family 앱에서 "만료" 표시 + 재전송 버튼 제공
```

### 4. 사진 삭제 (Family → Senior)

```mermaid
sequenceDiagram
    participant F as Family 앱
    participant R as RTDB
    participant Sr as Senior 태블릿 (모든 기기)

    F->>R: status: "deleted"
    Sr->>R: 감지 (onDataChange)
    Sr->>Sr: 로컬 사진 파일 삭제
    Note over R: Storage는 이미 삭제됨 (done 시점에)
    Note over R: RTDB 노드는 와치독이 37일 후 정리
```

- Family는 RTDB `status`만 변경 — Storage 직접 삭제 안 함
- 모든 Senior가 각자 감지해서 로컬 파일 삭제

---

## 알림 미디어 전송 흐름

### 1. Family 앱에서 알림 생성

```text
영상/음성 녹화 → Firebase Storage 업로드
  (families/{fid}/reminders/{rid}/{rid}.mp4)
→ RTDB에 알림 등록 (mediaUrl, mediaDownloaded: false, targetDeviceId)
```

### 2. Senior 태블릿 수신

```text
RTDB reminders 감시 → 새 알림 + enabled + mediaDownloaded == false
  → mediaUrl에서 다운로드 → 로컬 저장 (filesDir/reminders/{rid}.mp4)
  → mediaDownloaded: true 기록 → Cloud Function 트리거 → Storage 삭제
  → AlarmManager 스케줄 등록
```

### 3. 알림 삭제 (Family → Senior)

```mermaid
sequenceDiagram
    participant F as Family 앱
    participant R as RTDB
    participant CF as Cloud Function
    participant S as Firebase Storage
    participant Sr as Senior 태블릿

    F->>R: reminder 노드 .remove()
    CF->>R: 트리거: onReminderDeleted
    CF->>S: Storage 파일 삭제 (미디어 미다운로드 시)
    Sr->>R: 감지 (onDataChange - 목록 비교)
    Sr->>Sr: AlarmManager 취소
    Sr->>Sr: 로컬 미디어 삭제
```

- Family는 RTDB 노드만 삭제 — Storage 직접 삭제 안 함
- Cloud Function이 Storage 정리 (이미 다운로드됐으면 Storage에 없으므로 무시)
- Senior는 이전 목록과 비교해서 사라진 알림 감지 → 알람 취소 + 로컬 삭제

### 4. 알림 비활성/활성 토글

```text
Family에서 enabled: false → Senior 감지 → 알람만 취소 (로컬 미디어 유지)
Family에서 enabled: true  → Senior 감지 → 알람 재등록 (로컬 미디어 재사용)
```

- 비활성 시 미디어를 삭제하지 않음 — 재활성 시 재다운로드 불필요
- Storage에서 이미 삭제된 상태라 재다운로드도 불가능

---

## 수신 확인 (ACK)

### 사진 상태 전이

```mermaid
stateDiagram-v2
    [*] --> pending: Family 업로드

    pending --> done: 모든 Senior 완료 (트리거)
    pending --> expired: 7일 경과 (와치독)

    expired --> pending: Family 재전송

    done --> deleted: Family 삭제 요청
    expired --> deleted: Family 삭제 요청

    deleted --> [*]: Senior 로컬 삭제 완료
```

| status | 누가 씀 | 설명 |
|--------|---------|------|
| `pending` | Family | 업로드 완료, Senior 다운로드 대기 |
| `done` | Cloud Function | 모든 Senior의 downloadedBy 확인 후 설정 |
| `expired` | Cloud Function | 7일 경과 미수신 (와치독) |
| `deleted` | Family | 삭제 요청 |

※ `downloading` 상태는 더 이상 사용하지 않음 — 복수 Senior 동시 다운로드를 위해
※ 각 Senior의 다운로드 상태는 `downloadedBy/{deviceId}: true`로 개별 추적

### 알림 미디어

| 상태 | 누가 씀 |
|------|---------|
| `mediaDownloaded: false` | Family |
| `mediaDownloaded: true` | Senior |

---

## 전송 상태 UI (사진)

| status | 아이콘 | 색상 | 텍스트 | 액션 |
| ------ | ------ | ---- | ------ | ---- |
| `pending` | `Icons.schedule` | 회색 | 대기 중 (2/3 수신) | - |
| `done` | `Icons.check_circle` | 초록 | 완료 | 삭제 가능 |
| `expired` | `Icons.error_outline` | 빨강 | 만료 | 재전송 버튼 |
| `deleted` | - | - | 목록에서 제거 | - |

※ pending 상태에서 `downloadedBy` 수를 표시하여 수신 진행률 확인 가능

---

## Cloud Functions 목록

| 함수명 | 트리거 | 역할 |
| ------ | ------ | ---- |
| `onPhotoAllDownloaded` | RTDB `downloadedBy/{did}` write | 모든 Senior 다운로드 완료 → Storage 삭제 + status: done |
| `onReminderMediaDownloaded` | RTDB `mediaDownloaded` update | targetDevice 다운로드 완료 → Storage 삭제 |
| `onReminderDeleted` | RTDB `reminders/{rid}` delete | 알림 삭제 → Storage 파일 삭제 |
| `cleanupExpiredPhotos` | 스케줄 6시간 | 만료/done 정리 |
| `cleanupOrphanedData` | 스케줄 매일 3시 | 고아 RTDB + Storage 정리 |

---

## 디바이스 프로필

`assets/device_profiles/{model}.json`으로 태블릿별 스펙 관리.

```json
{
  "model": "SM-T500",
  "name": "Galaxy Tab A7",
  "display": {
    "width": 2000,
    "height": 1200,
    "density": 224
  },
  "photo": {
    "maxResolution": 2000,
    "jpegQuality": 80
  },
  "storage": {
    "maxPhotos": 500,
    "maxTotalMB": 5000
  }
}
```

---

## 썸네일

### 목적

- 가족 구성원 누구나 "어떤 사진이 보내졌는지" 확인 가능
- 원본은 Senior 태블릿 로컬에만 존재, 썸네일은 RTDB에 공유

### 생성 (Family 앱, 업로드 시)

```text
원본 사진 → 200×200px 리사이즈 → JPEG quality 75% → base64 인코딩 → RTDB 저장
```

- `flutter_image_compress`로 처리
- 결과: ~4KB/장 (base64 문자열)

---

## 이미지 압축 전략

| 원본 | 리사이즈 | JPEG 압축 후 | 절감률 |
| ---- | -------- | ------------ | ------ |
| 4000×3000 (5MB) | 2000×1500 | ~300KB | 94% |
| 3000×2000 (3MB) | 2000×1333 | ~250KB | 92% |
| 1920×1080 (2MB) | 그대로 | ~200KB | 90% |

---

## 오프라인 대응

1. Family 앱: Storage 업로드 + RTDB pending 등록 → 앱 꺼도 OK
2. Senior 오프라인: 다음 온라인 시 RTDB에서 pending 목록 자동 감지 → 다운로드
3. 7일 초과 미수신: Cloud Function이 Storage 삭제 + status: "expired"
4. Family에서 재전송 버튼으로 다시 업로드 가능

---

## 비용

| 항목 | 비용 |
| ---- | ---- |
| RTDB 메타+썸네일 (1000명 × 500장) | ~$0 (무료 1GB) |
| Firebase Storage (임시 버퍼) | ~$0.01/월 |
| 다운로드 (Senior) | ~$0.01/월 |
| Cloud Functions 트리거 | ~$0 (무료 200만 호출/월) |
| **합계** | **~$0/월** |

---

## 구현 파일

### Family 앱 (Flutter)

- `lib/services/photo_transfer_service.dart` — 압축 + Storage 업로드 + RTDB 메타 등록
- `lib/services/reminder/reminder_service.dart` — 알림 CRUD + Storage 업로드
- `lib/screens/photo_upload_screen.dart` — 사진 선택 UI + 전송 상태 목록
- `lib/config/app_config.dart` — DeviceProfile 로드
- `assets/device_profiles/SM-T500.json` — 태블릿 스펙

### Senior 앱 (Kotlin)

- `PhotoReceiver.kt` — RTDB 감시 + Storage 다운로드 + 로컬 저장 + downloadedBy 기록
- `SlideshowManager.kt` — 로컬 사진 로드
- `ReminderManager.kt` — RTDB 감시 + 미디어 다운로드 + mediaDownloaded 기록

### Cloud Functions

- `onPhotoAllDownloaded` — RTDB 트리거: 모든 Senior 다운로드 → Storage 삭제
- `onReminderMediaDownloaded` — RTDB 트리거: 미디어 다운로드 → Storage 삭제
- `onReminderDeleted` — RTDB 트리거: 알림 삭제 → Storage 삭제
- `cleanupExpiredPhotos` — 스케줄: 만료/done 정리
- `cleanupOrphanedData` — 스케줄: 고아 RTDB + Storage 정리
