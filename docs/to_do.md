# Family 앱 TODO

## 완료된 Phase / 주요 작업

| 항목 | 상태 |
|-------|------|
| Phase 1 — 시니어 전용 코드 제거 | ✅ |
| Phase 2 — 코드 구조 정리 + 소셜 로그인 4종 | ✅ |
| Phase 3 — 페어링 시스템 (가족이름/내이름 다이얼로그 포함) | ✅ |
| Phase 4 — 사진 전송 (임시 버퍼 방식) | ✅ |
| Phase 5 — 영상 알림 CRUD + 재생 (기본) | ✅ |
| CCTV 모니터링 + 통화 전환 (startCall/upgradeToCall) | ✅ |
| RTDB 스키마 재설계 + 비정규화 제거 | ✅ |
| Cloud Function 와치독 + RTDB 트리거 | ✅ |
| Storage 삭제 일관성 통일 (Cloud Function only) | ✅ |
| 오프라인 가드 3층 (ConnectivityService + writeOrTimeout + TapGuard) | ✅ |
| WebRTC ICE Restart (grace 4s / 재시도 5회 / 60s 상한) | ✅ |
| WebRTC FSM 정식화 (`CallStateMachine`, `TerminateReason`) | ✅ |
| 좀비 peer 방지 (cleanupCall 10초 지연 + Senior sendAnswer transaction) | ✅ |
| 테마 2축 설계 (Hue 7종 × OS 자동 light/dark) | ✅ |
| iOS 빌드 환경 (Mac Mini) + 실기기 테스트 | ✅ |

---

## 단기 TODO

### UI 보완

- [ ] 사진 전송 진행률 표시 — `downloadedBy` 개수 기반 "N/M 수신" (pending 배지 확장)
- [ ] 알림 편집 화면 `targetDeviceId` 선택 UI (현재 1 family = 1 Senior 전제라 보류 가능)
- [ ] FamilyDetailScreen 멤버 섹션에서 멤버별 `name` 표시 (현재 uid 만 노출되면 추가)

### Cloud Function 실검증

- [ ] 사진 전송 → `downloadedBy` → Storage 자동 삭제 확인 (`onPhotoDownloaded`)
- [ ] 알림 `mediaDownloaded:true` → Storage 자동 삭제 (`onReminderMediaDownloaded`)
- [ ] 알림 삭제 → `onReminderDeleted` → Storage 미디어 삭제
- [ ] `cleanupOrphanedDataManual?aggressive=true` 수동 실행 → 고아 정리 확인

### Senior 앱 연동

- [ ] 카메라/마이크 권한 자동 요청 (`pm clear` 후 첫 부팅)
- [ ] 사진 갤러리 / 알림 목록 관리 메뉴 실기기 테스트

### 1:N × 1:1 정책 검증 (S 시리즈 통합)

[webrtc_integration_test.md](webrtc_integration_test.md) 의 S 시리즈로 통합됨.

**검증 완료** (2026-05-07):

- [x] **S9** Family A wifi off / B 영향 없음 (구 R5)
- [x] **S10** A networkLost 종결 / B 영향 없음 (구 R7)
- [x] **S11** A call 중 → B call/monitor → `remoteBusy` (구 R8 + 확장)
- [x] **S12** Capacity 매트릭스 (`monitor ≤ 3`, `call ≤ 1`, 동시 max peer = 4) (구 NX4)
- [x] **S14** displace 절차 — A monitor → B call → A `endedByOtherCall` (구 R3)

**남은 race 시나리오** (Optional, 시간 날 때):

- [ ] **S15** A·B 동시 call 발신 race → 한쪽만 성공
- [ ] **S16** A·B 동시 wifi off → 병렬 ICE restart (Family 양쪽 Android 필요)
- [ ] **S17** A grace 중 B 신규 합류 → A 복구 + B connected (timing 정밀)
- [ ] **S18** A·B·C·D 동시 발신 후 capacity boundary

**Skip / 코드 review 로 갈음**:

- N3 (LTE 핸드오프): 디바이스 한계
- N7 (Senior 응답 지연 multi-peer answer): 인위적 delay 어려움
- N11 (upgrade fail + monitor 잔존): 인위적 fail 어려움

**기록**: 검증 결과는 [webrtc_integration_test_result.md](webrtc_integration_test_result.md) §S 섹션.

---

## 중기 TODO (Phase 5–6 마무리)

### 알림 로그 시스템 (`reminderLogs`)

- [ ] Senior: 알림 재생 후 확인/미확인 RTDB 기록
- [ ] Family: 로그 조회 UI (`reminder_log_screen.dart`)
- [ ] Cloud Function: 90일 경과 로그 자동 삭제
- [ ] FCM: 미확인 시 Family 앱에 푸시 알림

### 통화 기록 (`callHistory`)

- [ ] 통화 시작/종료 시 자동 기록 (`call_history_service.dart`)
- [ ] Family: 통화 기록 조회 UI
- [ ] Cloud Function: 365일 경과 자동 삭제

### 알림 서비스 (`notification_service.dart`)

- [ ] Senior 기기 오프라인 7일+ 알림
- [ ] 복약 미확인 알림
- [ ] 부재중 통화 알림
- [ ] Family 앱 FCM 토큰 관리 (`/users/{uid}/fcmToken`)

---

## 장기 TODO (Phase 7+)

### 홈화면 개편

- [ ] 하단 네비게이션: 기기 목록 / 사진 / 알림 / 설정
- [ ] 각 기기 카드: 이름·모델·온라인 상태·마지막 접속·사진 수

### 키오스크 모드 (Senior 측 작업)

- [ ] Device Owner 설정 → 런타임 권한 자동 승인
- [ ] 화면 잠금 비활성, 상태바 숨김, 홈/뒤로 버튼 차단
- [ ] 앱 자동 시작 (BOOT_COMPLETED + Lock Task Mode)

### iOS 배포 준비

- [ ] App Store 심사용 아이콘/스크린샷/설명
- [ ] 유료 개발자 계정 (현재 무료 팀 → 7일 서명 만료)

### 얼굴 감지 WebRTC 입력 (Senior)

- [ ] 모니터링 중 WebRTC 비디오 트랙에서 얼굴 감지
- [ ] FaceDetectionService에 WebRTC 프레임 콜백 연동

### 1 Family — N Senior 지원

**현재 한계:** 가족(family) 1개 = Senior 기기 1대 고정. 각 Senior 부팅 시 자기 family 를 `families.push().key` 로 생성. 다른 Senior 가 기존 family 에 join 하는 경로 없음.

**필요한 변경:**

- [ ] Senior `PairingActivity` 에 "기존 가족에 합류" 모드 추가 — pairingCode 입력 → `/families/{fid}/devices/{did}: true`
- [ ] Family 앱 "Senior 기기 추가" 버튼 → 기존 family 의 pairingCode 재생성
- [ ] `performFullReset` → **Leave Family 시맨틱** 으로 변경
  - 내 device 만 `/families/{fid}/devices/{myDid}` 제거
  - `members==0 && devices==0` 일 때만 family 전체 + pairingCode + Storage 삭제
- [ ] 사진/알림 UI 에서 "어느 Senior 에 보낼지" 다중 선택
- [ ] `callStatus` / 모니터링 — Senior N 대 중 대상 기기 명시
- [ ] `downloadedBy` 진행률 — Senior N 대 중 몇 대 완료 표시

**보류 사유:** 현재 1 family = 1 Senior 전제가 UI/UX 전반에 깊게 박혀있음. 시니어 케어 시장 실수요 확인 후 착수.
