# 사진 전송 설계

## 개요

Family 앱 → Firebase Storage (임시 버퍼) → Senior 태블릿 로컬 저장.
RTDB로 전송 큐/상태/썸네일 관리. Senior 다운로드 후 Storage에서 즉시 삭제.
영구 저장은 태블릿 로컬에만. 클라우드 비용 거의 $0.

## 왜 이 방식인가

### Firebase Storage 영구 저장의 문제

- 1000명 × 20GB = 20TB 상시 저장 → 연 200~810만원
- 온프레미스 없는 스타트업에겐 치명적 비용

### P2P 직접 전송 (DataChannel)의 문제

- 양쪽 다 온라인이어야 전송 가능
- iOS 백그라운드에서 WebRTC 유지 불가 (즉시 Suspended)
- 딸이 밤에 보냄 → 태블릿 슬립 → 다음 날 앱 꺼놓음 → 전송 불가

### 임시 버퍼 방식 (채택)

- Storage를 택배 창고처럼 사용: 보관이 아닌 전달 목적
- Senior가 다운로드하면 즉시 삭제 → 상시 저장량 거의 0
- iOS에서도 HTTP 업로드는 백그라운드 가능 (NSURLSession)

| 비교 | 상시 저장량 | 월 비용 |
| ---- | ---------- | ------- |
| 영구 저장 20GB | 20TB | $520 |
| P2P 직접 전송 | 0 | $0 (UX 나쁨) |
| **임시 버퍼** | ~수백 MB | **~$0.01** |

## 아키텍처

```text
Family 앱
  ├─ 사진 선택 (갤러리/카메라)
  ├─ 리사이즈 + JPEG 압축 (디바이스 프로필 기준)
  ├─ 썸네일 생성 (100×100px, base64)
  ├─ Firebase Storage에 업로드 (임시)
  ├─ RTDB에 메타데이터 등록 (status: pending, storageUrl, thumbnail)
  └─ 앱 꺼도 OK (HTTP 업로드는 백그라운드 가능)
       │
       ▼
Senior 태블릿
  ├─ RTDB 감시 → pending 사진 감지
  ├─ Storage에서 다운로드
  ├─ MD5 체크섬 검증
  ├─ 로컬 저장소에 저장
  ├─ Storage 파일 삭제
  ├─ RTDB status: "done" 업데이트
  └─ 슬라이드쇼 자동 반영
```

## RTDB 구조

```text
/families/{familyId}/
  photoSync/
    {photoId}/
      fileName: string           # "photo_001.jpg"
      size: number               # 바이트
      checksum: string           # MD5 해시
      storageUrl: string         # Firebase Storage 임시 URL
      uploadedBy: string         # userId
      uploadedByName: string     # "딸"
      createdAt: timestamp
      status: string             # "pending" | "downloading" | "done" | "expired" | "deleted"
      retryCount: number         # 실패 시 증가
      thumbnail: string          # base64 인코딩된 썸네일 (100×100px, ~2KB)

  presence/
    {deviceId}/
      online: boolean            # onDisconnect → false
      lastSeen: timestamp
      type: string               # "senior" | "family"
```

## 전송 흐름

### 1. Family 앱에서 사진 업로드

```text
사진 선택 → 리사이즈 (긴 변 maxResolution px 이하)
         → JPEG 압축 (quality%)
         → 썸네일 생성 (100×100px, JPEG 60%, base64)
         → MD5 체크섬 계산
         → Firebase Storage 업로드 (families/{familyId}/temp/{photoId}.jpg)
         → RTDB photoSync/{photoId} 메타 등록 (status: "pending")
```

### 2. Senior 태블릿 수신

```text
RTDB photoSync 감시 → status: "pending" 감지
  → status: "downloading" 업데이트
  → storageUrl에서 파일 다운로드
  → MD5 검증
  → 성공: 로컬 저장 → Storage 파일 삭제 → status: "done"
  → 실패: retryCount++ → status: "pending" (재시도)
```

### 3. 만료 처리

```text
Cloud Function (스케줄 또는 RTDB 트리거):
  → 48시간 경과 + status: "pending" → Storage 파일 삭제 → status: "expired"
  → Family 앱에서 "만료" 표시 + 재전송 버튼 제공
```

### 4. 삭제 동기화

```text
Family에서 삭제 요청 → RTDB status: "deleted"
  → Senior가 감지 → 로컬 파일 삭제
```

## 수신 확인 (ACK)

RTDB `photoSync/{photoId}/status`를 Family 앱에서 실시간 감시.
Senior가 상태를 업데이트하면 Family에 즉시 반영.

```text
Family 업로드 → status: "pending"      ← Family가 씀
Senior 수신 시작 → status: "downloading" ← Senior가 씀
Senior 저장 완료 → status: "done"       ← Senior가 씀 (= 도착 확인)
48시간 미수신 → status: "expired"       ← Cloud Function이 씀
```

## 전송 상태 UI

### 상태별 표시

| status | 아이콘 | 색상 | 텍스트 | 액션 |
| ------ | ------ | ---- | ------ | ---- |
| `pending` | `Icons.schedule` | 회색 | 대기 중 | - |
| `downloading` | `CircularProgressIndicator` | 파랑 | 수신 중 | - |
| `done` | `Icons.check_circle` | 초록 | 완료 | 삭제 가능 |
| `expired` | `Icons.error_outline` | 빨강 | 만료 | 재전송 버튼 |
| `deleted` | - | - | 목록에서 제거 | - |

### 보낸 사진 목록 화면

```text
┌────────────────────────────────────────┐
│  보낸 사진                              │
├────────────────────────────────────────┤
│ [thumb] 딸 · 3월 10일 14:30      ✓ 완료│
│ [thumb] 아들 · 3월 9일 09:15    ↓ 수신중│
│ [thumb] 딸 · 3월 8일 20:00     ⏳ 대기 │
│ [thumb] 엄마 · 3월 7일 11:45   ✗ 만료  │
│                              [재전송]   │
│                                        │
│           [+ 사진 보내기]               │
└────────────────────────────────────────┘
```

### 상태 위젯 코드

```dart
Widget _statusIcon(String status) {
  switch (status) {
    case 'pending':
      return const Icon(Icons.schedule, color: Colors.grey, size: 20);
    case 'downloading':
      return const SizedBox(
        width: 20, height: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
      );
    case 'done':
      return const Icon(Icons.check_circle, color: Colors.green, size: 20);
    case 'expired':
      return const Icon(Icons.error_outline, color: Colors.red, size: 20);
    default:
      return const Icon(Icons.help_outline, color: Colors.grey, size: 20);
  }
}
```

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
    "jpegQuality": 80,
    "chunkSize": 16384
  },
  "storage": {
    "maxPhotos": 500,
    "maxTotalMB": 5000
  }
}
```

## 썸네일

### 목적

- 가족 구성원 누구나 "어떤 사진이 보내졌는지" 확인 가능
- 원본은 Senior 태블릿 로컬에만 존재, 썸네일은 RTDB에 공유

### 생성 (Family 앱, 업로드 시)

```text
원본 사진 → 100×100px 리사이즈 → JPEG quality 60% → base64 인코딩 → RTDB 저장
```

- `flutter_image_compress`로 처리
- 결과: ~2KB/장 (base64 문자열)

### 썸네일 비용

| 규모 | 썸네일 용량 | RTDB 무료 한도 |
| ---- | ---------- | -------------- |
| 1가족 × 500장 | ~1MB | - |
| 1000가족 × 500장 | ~1GB | 1GB (무료) |

무료 범위 안에서 운영 가능. 초과해도 $5/GB/월 수준.

### 표시 (Family 앱)

```dart
// RTDB에서 base64 문자열 읽어서 바로 위젯으로
Image.memory(base64Decode(photoData['thumbnail']))
```

## 이미지 압축 전략

| 원본 | 리사이즈 | JPEG 압축 후 | 절감률 |
| ---- | -------- | ------------ | ------ |
| 4000×3000 (5MB) | 2000×1500 | ~300KB | 94% |
| 3000×2000 (3MB) | 2000×1333 | ~250KB | 92% |
| 1920×1080 (2MB) | 그대로 | ~200KB | 90% |

- 태블릿 해상도보다 작은 이미지는 리사이즈 생략
- JPEG 이미 압축 포맷이라 gzip 추가 압축은 효과 없음

## 오프라인 대응

1. Family 앱: Storage 업로드 + RTDB pending 등록 → 앱 꺼도 OK
2. Senior 오프라인: 다음 온라인 시 RTDB에서 pending 목록 자동 감지 → 다운로드
3. 48시간 초과 미수신: Cloud Function이 Storage 삭제 + status: "expired"
4. Family에서 재전송 버튼으로 다시 업로드 가능

## 비용

| 항목 | 비용 |
| ---- | ---- |
| RTDB 메타+썸네일 (1000명 × 500장) | ~$0 (무료 1GB) |
| Firebase Storage (임시 버퍼) | ~$0.01/월 |
| 다운로드 (Senior) | ~$0.01/월 |
| **합계** | **~$0/월** |

### Cloudflare R2 대안

egress $0이라 더 저렴하지만, Firebase 생태계 밖이라 서비스 관리 포인트 증가.
임시 버퍼 용도로는 Firebase Storage도 충분히 저렴하므로 Firebase 유지.

## 구현 파일

### Family 앱 (Flutter)

- `lib/services/photo_transfer_service.dart` — 압축 + Storage 업로드 + RTDB 메타 등록
- `lib/screens/photo_upload_screen.dart` — 사진 선택 UI + 전송 상태 목록
- `lib/config/app_config.dart` — DeviceProfile 로드
- `assets/device_profiles/SM-T500.json` — 태블릿 스펙

### Senior 앱 (Kotlin)

- `PhotoReceiver.kt` — RTDB 감시 + Storage 다운로드 + 로컬 저장 + Storage 삭제
- `SlideshowManager.kt` — 로컬 사진 로드 (기존 assets → 내부 저장소)

### Cloud Functions

- `cleanupExpiredPhotos` — 48시간 초과 pending 사진 Storage 삭제 + status: "expired"
