# Cloud Functions 만료 처리 — 테스트 기록

Function URL (naverCallback(us-central1)): https://us-central1-dcom-smart-frame.cloudfunctions.net/naverCallback
Function URL (cleanupExpiredPhotosManual(us-central1)): https://us-central1-dcom-smart-frame.cloudfunctions.net/cleanupExpiredPhotosManual

## 테스트 일시

2026-03-11

## 테스트 환경

- Firebase 프로젝트: `dcom-smart-frame`
- Cloud Functions: `cleanupExpiredPhotos` (스케줄) + `cleanupExpiredPhotosManual` (HTTP)
- Family 앱: SM-G991N (Galaxy S21)

---

## 테스트 1: 만료 처리 (pending → expired)

### 준비

Firebase Console RTDB에 테스트 데이터 수동 생성:

```
families/{familyId}/photoSync/test_expired_001/
  status: "pending"
  createdAt: 1740700800000  (2025-02-28, 7일 훨씬 경과)
  fileName: "test.jpg"
  uploadedByName: "테스트"
  thumbnail: ""
  size: 1000
```

### 실행

브라우저에서 `cleanupExpiredPhotosManual` URL 호출

### 결과

```json
{ "success": true, "expired": 1, "cleaned": 0, "timestamp": "..." }
```

### 검증

- RTDB: `test_expired_001`의 `status`가 `"expired"`로 변경됨
- RTDB: `storagePath`가 `null`로 설정됨 (원래 없었으므로 변화 없음)

---

## 테스트 2: RTDB 완전 삭제 (expired → 삭제)

### 준비

Firebase Console RTDB에 테스트 데이터 수동 생성:

```
families/{familyId}/photoSync/test_cleanup_001/
  status: "expired"
  createdAt: 1735689600000  (2025-01-01, 37일 훨씬 경과)
  fileName: "test2.jpg"
  uploadedByName: "테스트"
  thumbnail: ""
  size: 1000
```

### 실행

브라우저에서 `cleanupExpiredPhotosManual` URL 호출

### 결과

```json
{
  "success": true,
  "expired": 0,
  "cleaned": 2,
  "timestamp": "2026-03-11T02:00:52.510Z"
}
```

cleaned: 2인 이유:

- `test_expired_001` — 테스트 1에서 expired 처리됨 + createdAt이 37일 경과 → 삭제 대상
- `test_cleanup_001` — 처음부터 expired + 37일 경과 → 삭제 대상

### 검증

- RTDB: `test_expired_001`, `test_cleanup_001` 모두 완전 삭제됨

---

## 테스트 3: Family 앱 expired 숨김

### 준비

`photo_upload_screen.dart`에서 `expired` 필터링 추가 후 빌드 + 설치

### 검증

- 사진 보내기 화면에서 expired 상태 항목이 목록에 표시되지 않음

---

## 요약

| 테스트    | 조건                | 예상           | 실제           | 결과 |
| --------- | ------------------- | -------------- | -------------- | ---- |
| 만료 처리 | pending + 7일 경과  | expired로 변경 | expired로 변경 | PASS |
| RTDB 삭제 | expired + 37일 경과 | 항목 완전 삭제 | 항목 완전 삭제 | PASS |
| UI 숨김   | expired 항목        | 목록 미표시    | 목록 미표시    | PASS |
