# Family 앱 TODO

## 완료된 Phase

| Phase | 내용 | 상태 |
|-------|------|------|
| 1 | 시니어 전용 코드 제거 | ✅ 완료 |
| 2 | 코드 구조 정리 + 소셜 로그인 4종 | ✅ 완료 |
| 3 | 페어링 시스템 (기본) | ✅ 완료 |
| 4 | 사진 전송 (임시 버퍼 방식) | ✅ 완료 |
| 5 | 영상 알림 CRUD + 재생 | ✅ 완료 (기본) |
| — | CCTV 모니터링 + 통화 전환 | ✅ 완료 |
| — | RTDB 스키마 재설계 + 비정규화 제거 | ✅ 완료 |
| — | Cloud Function 와치독 + RTDB 트리거 | ✅ 완료 |
| — | Storage 삭제 일관성 통일 | ✅ 완료 |

---

## 즉시 수정 필요 (버그)

### 두 번째 가족 추가 시 무한 로딩
- `PairingHelper` 콜백이 `PairingScreen` dispose 후 실행되는 문제
- `onPairedWithId` 타입이 `void Function`이라 async await 불가
- 첫 번째 페어링은 app.dart에서 정상 동작, 두 번째부터 문제

### 첫 페어링 시 가족 이름 설정 다이얼로그
- app.dart에서 `_promptFamilyName` 임시 제거한 상태
- 복구 필요 — 가족 `_label` 설정에 필요

---

## 단기 TODO

### Family 앱 UI 개선
- [ ] 가족 상세 화면에서 기기 online 상태 실시간 표시 (이미 구현, 테스트 필요)
- [ ] 사진 전송 시 downloadedBy 진행률 표시 (pending 상태에서 "2/3 수신")
- [ ] 알림 편집 화면에서 대상 기기(targetDeviceId) 선택 UI
- [ ] Senior 멤버 관리에 이름 표시 (현재 이름 안 보임)

### Cloud Function 테스트
- [ ] 사진 전송 → downloadedBy → Storage 자동 삭제 확인
- [ ] 알림 생성 → mediaDownloaded: true → Storage 자동 삭제 확인
- [ ] 알림 삭제 → onReminderDeleted → Storage 삭제 확인
- [ ] 와치독 수동 실행 → 고아 정리 확인

### Senior 앱
- [ ] 카메라/마이크 권한 자동 요청 테스트 (pm clear 후)
- [ ] 사진 갤러리 / 알림 목록 관리 메뉴 테스트

---

## 중기 TODO (Phase 5-6 마무리)

### 알림 로그 시스템 (reminderLogs)
- [ ] Senior: 알림 재생 후 확인/미확인 RTDB 기록
- [ ] Family: 로그 조회 UI (`reminder_log_screen.dart`)
- [ ] Cloud Function: 90일 경과 로그 자동 삭제
- [ ] FCM: 미확인 시 Family 앱에 푸시 알림

### 통화 기록 (callHistory)
- [ ] 통화 시작/종료 시 자동 기록 (`call_history_service.dart`)
- [ ] Family: 통화 기록 조회 UI
- [ ] Cloud Function: 365일 경과 자동 삭제

### 알림 서비스 (notification_service.dart)
- [ ] Senior 기기 오프라인 알림 (7일 이상)
- [ ] 복약 미확인 알림
- [ ] 부재중 통화 알림
- [ ] Family 앱 FCM 토큰 관리 (`/users/{uid}/fcmToken`)

---

## 장기 TODO (Phase 7+)

### 홈화면 개편
- [ ] 하단 네비게이션: 기기 목록 / 사진 / 알림 / 설정
- [ ] 각 기기 카드: 이름, 모델, 온라인 상태, 마지막 접속, 사진 수

### 키오스크 모드 (Senior)
- [ ] Device Owner 설정 → 런타임 권한 자동 승인
- [ ] 화면 잠금 비활성, 상태바 숨김, 홈/뒤로 버튼 차단
- [ ] 앱 자동 시작 (BOOT_COMPLETED + Lock Task Mode)

### iOS 빌드
- [ ] Mac Mini에서 Family 앱 iOS 빌드 환경 설정
- [ ] Apple 로그인 구현 (iOS 필수)
- [ ] iOS 테스트 + App Store 심사 준비

### 얼굴 감지 WebRTC 입력 (Senior)
- [ ] 모니터링 중 WebRTC 비디오 트랙에서 얼굴 감지
- [ ] FaceDetectionService에 WebRTC 프레임 콜백 연동

### 복수 Senior 기기 관리
- [ ] Family 앱에서 알림 생성 시 대상 기기 선택 UI
- [ ] 기기별 사진 앨범 분리 옵션 (선택적)

### 1 Family - N Senior Device 지원 (Phase 7+, 복잡도 높음)

**현재 한계:** 가족(family) 1개 = Senior 기기 1대 고정. 각 Senior가 부팅 시 자기 family를 `families.push().key`로 생성함. 다른 Senior가 기존 family에 join하는 경로 없음 (PairingActivity 최초 페어링 / 멤버 추가 모드 둘 다 Family 앱 유저 추가 용도).

**필요한 변경:**

- [ ] Senior PairingActivity에 "기존 가족에 합류" 모드 추가 (pairingCode 입력 → 해당 family의 `/devices/{myDid}: true` 등록)
- [ ] Family 앱에서 "Senior 기기 추가" 버튼 → 기존 family의 pairingCode 재생성 → 새 Senior가 해당 코드로 join
- [ ] `performFullReset`을 **Leave Family 시맨틱**으로 변경:
  - 내 device만 `/families/{fid}/devices/{myDid}` 에서 제거
  - `members=0 && devices=0` (나 제외)일 때만 family 전체 + pairingCode + Storage 삭제
  - 그 외에는 family 유지 (다른 Senior/멤버 보호)
- [ ] 사진/알림 UI에서 "어느 Senior에 보낼지" 다중 선택 가능하게 변경 (현재는 family 하나 = 기기 하나 전제)
- [ ] `callStatus`/모니터링 — Senior 여러 대 중 어느 기기 대상인지 명시 필요
- [ ] `downloadedBy` 진행률 — Senior N대 중 몇 대 완료인지 표시
- [ ] RTDB 스키마 영향 검토 (`/families/{fid}/devices/`는 이미 여러 device 수용 가능하게 설계됨 → 큰 변경 없을 듯)

**결정 보류 사유:** 현재는 1 family = 1 Senior 구조가 UI/UX 전반에 깊게 녹아있음 (영상통화 대상, 사진 업로드 대상, 알림 대상이 모두 "그 가족의 단일 Senior"). 이 전제를 풀면 화면 전반에 영향. 시니어 케어 시장에서 실수요 확인된 뒤 착수 권장.
