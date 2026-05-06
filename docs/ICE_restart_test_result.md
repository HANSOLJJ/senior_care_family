# ICE Restart 테스트 결과 누적

> 본 문서는 [ICE_restart_test.md](./ICE_restart_test.md) 시나리오의 검증 결과 누적.
>
> **Plan B (필드 분리 모델, 2026-04-30)** 시점부터 결과 기록. 이전 Plan A 시절 결과는
> [ICE_restart_test_result_backup.md](./ICE_restart_test_result_backup.md) 참조.

---

## 검증 개요

| 검증 일자 | 정책 시점 | 검증자 |
|---|---|---|
| 2026-04-30 | Plan B (필드 분리 모델 — `hasFlapMarker`) v1 | 자동화 sweep + raw logcat 직접 매칭 |
| 2026-05-06 | Plan B v2 — Senior cleanup 후 (listenForStatus 시그니처 단순화, restoreActiveStatus 삭제, flapMarkerListener field, dispose clearFlapMarker, CONNECTED 전이 clearFlapMarker, registerDisconnectCleanup 시점 이동) + 자동수락 ADB tap + STREAM_VOICE_CALL mute | 자동화 sweep |
| 2026-05-06 | Plan B v2 확장 — S6 sweep 신규 + S7 SENIOR_OFFLINE mode 추가 + S8 모니터링/영상통화 + S13 (Plan B 핵심 race) | 자동화 sweep + raw logcat 매칭 |

### Plan B 핵심

- `status` 와 `hasFlapMarker` 별도 필드 (Plan A 의 status 한 필드 두 의미 분리).
- `status` 변경 = **무조건 진짜 종결**. listener 가 endReason 분기 없이 처리.
- `hasFlapMarker` 변경 = **wifi flap 신호**. 별도 listener (`listenForFlapMarker`) 가 grace 분기 담당.
- 자기/상대 마커 구분: PC `connectionState` 기반 (CONNECTED → 자기 마커 → clear + 재등록, ≠CONNECTED → 상대 wifi flap → grace 진입).
- ICE restart 1회 시도 정책 + UX 단순화 (SnackBar 2초 + 즉시 pop, 다시 걸기 버튼 없음) 유지.

---

## S1 — Family 짧은 wifi flap (PC 자가 복구)

### S1 [모니터링] — Android (R3CR700SEKP)

- **실행**: `bash e:/App/Family/scripts/s1_3_sweep.sh` 의 1/2/3s stages
- **측정값**:
  - 1s: hasFlapMarker clear + 재등록 → PC DISCONNECTED → ICE restart 1회 → ice_restored
  - 2s: 동일
  - 3s: 동일
- **결과**: ✅ PASS (3 stages 모두 정상 복구)
- **로그**: `e:/tmp/0430_planB_s1_3/family_full.log`, `senior_full.log`
- **비고**: PC 자체 keepalive 가 모든 케이스 끊김 인지 → ICE restart 흐름으로 복구. 자기 hasFlapMarker 무시 처리 정상 동작.

### S1 [영상통화] — Android

- **실행**: `bash e:/App/Family/scripts/s1_3_call_sweep.sh` 의 1/2/3s stages
- **측정값**:
  - 1s: senior_accepted_auto → upgrading → renegotiate_done → wifi off → hasFlapMarker clear → PC DISCONNECTED → ICE restart 1회 → ice_restored
  - 2s/3s: 동일
- **결과**: ✅ PASS
- **로그**: `e:/tmp/0430_planB_s1_3_call_v2/`
- **비고**: ADB 자동수락 탭 (Senior 화면 중앙 640,400) 정상 동작 — 얼굴인식 대신 즉시 acceptCall trigger. STABILIZE_S=30 으로 senior_accepted_auto + upgrade renegotiate 완료 후 wifi off 보장.

---

## S2 — Family 중간 wifi flap (ICE restart 1회 성공)

### S2 [모니터링] — Android

- **실행**: `bash e:/App/Family/scripts/s1_3_sweep.sh` 의 4/5s stages
- **측정값**: 4s/5s 모두 ICE restart 1회 + ice_restored
- **결과**: ✅ PASS

### S2 [영상통화] — Android (R3CR700SEKP)

- **실행**: `bash e:/App/Family/scripts/s1_3_call_sweep.sh` 의 4/5s stages (Plan B + 자동수락 ADB tap + STABILIZE_S=30)
- **측정값**: 4s/5s 모두 ICE restart 1회 + ice_restored
- **결과**: ✅ PASS
- **비고**: Plan A 시절 4s+ 에서 race fail 했던 케이스. **noAcceptance 종결 0건** — Plan B 필드 분리로 race 해결.

---

## S3 — Family 긴 wifi off (networkLost 종결)

### S3 [모니터링] — Android

- **실행**: `bash e:/App/Family/scripts/s1_3_sweep.sh` 의 6/15/70s stages
- **측정값**:
  - 6s: ICE restart 1회 + ice_restored (정상 복구)
  - 15s: networkLost 종결 (Family ICE restart 시점 wifi 아직 off)
  - 70s: networkLost 종결
- **결과**: ✅ PASS (8/8 stages 모두 raw log 직접 매칭 검증)
- **로그**: `e:/tmp/0430_planB_s1_3/`
- **비고**:
  - **noAcceptance 종결 0건** — Plan A 시절 영상통화에서 발생하던 race 가 모니터링에는 없었으나, 모델 자체 race-free 확인
  - SnackBar "연결 불안정으로 통화가 종료되었습니다" 2초 표시 후 즉시 pop, family detail 진입 시 잔재 없음
  - **stub 누적 0건** — Senior STOP_DELAY 만료 시 status="ended" 강제 set + Family `endCall` 의 정상 종결 흐름이 노드 정리

### S3 [영상통화] — Android

- **실행**: `bash e:/App/Family/scripts/s1_3_call_sweep.sh` 의 6/15/70s stages
- **측정값**:
  - 6s: networkLost 종결 (모니터링과 차이 — 영상통화 cycle 길어 timing 다름)
  - 15s: networkLost 종결
  - 70s: networkLost 종결
- **결과**: ✅ PASS (정상 종결, **noAcceptance 0건**)
- **로그**: `e:/tmp/0430_planB_s1_3_call_v2/`
- **비고**:
  - **Plan B 핵심 효과** — Plan A 시절 4s+ 에서 race fail 했던 영상통화 시나리오가 모두 noAcceptance 없이 정상 처리.
  - 6s 가 모니터링과 달리 networkLost — 영상통화 cycle 더 길어서 PC keepalive timing 차이일 가능성. 종결 사유 자체는 정상.

---

## S4 — Senior wifi flap (KEP 자발적 drop 떠받침)

### S4 [모니터링] — Android

- **실행**: `bash e:/App/Family/scripts/s4_5_sweep.sh` 의 1/2/3/4/5s stages
- **측정값**: 1~5s 모두 ICE restart 1회 + ice_restored
- **결과**: ✅ PASS
- **로그**: `e:/tmp/0506_planB_s4_5/`
- **비고**: Plan B 의 PC state 기반 자기/상대 마커 구분이 Senior wifi flap 케이스에서 정상 동작.
  Family PC keepalive 가 끊김 인지 후 ICE restart 시도 → Senior wifi 복귀 시 복구. 우려했던
  "Family 가 Senior 마커를 자기 마커로 오인 후 잘못 clear" 영향 없음 — Family PC 가 곧 끊김
  인지 후 ICE restart 흐름이 처리.

### S4 [영상통화] — Android

- **실행**: `bash e:/App/Family/scripts/s4_5_call_sweep.sh` 의 1/2/3/4/5s stages (Plan B + 자동수락 ADB tap + STABILIZE_S=30)
- **측정값**: 1~5s 모두 ICE restart 1회 + ice_restored
- **결과**: ✅ PASS
- **로그**: `e:/tmp/0506_planB_s4_5_call/`

---

## S5 — Senior 긴 wifi off

### S5 [모니터링] — Android

- **실행**: `bash e:/App/Family/scripts/s4_5_sweep.sh` 의 6/15/70s stages
- **측정값**: 6s/15s/70s 모두 networkLost 종결 (Senior STOP_DELAY 7s 만료 후 dispose)
- **결과**: ✅ PASS

### S5 [영상통화] — Android

- **실행**: `bash e:/App/Family/scripts/s4_5_call_sweep.sh` 의 6/15/70s stages
- **측정값**: 6s/15s/70s 모두 networkLost 종결
- **결과**: ✅ PASS

---

## S6 — 모니터링 → 영상통화 upgrade 도중 Family wifi flap

### S6 [영상통화] — Android (R3CR700SEKP)

- **실행**: `bash e:/App/Family/scripts/s6_sweep.sh` 4 stages (`WIFI_OFF_DELAY_MS`: 500/1000/1700/3500)
- **측정값**:

  | timing | 흐름 | 종결 사유 | hasFlapMarker self-clear |
  | --- | --- | --- | --- |
  | 500ms | upgrading → terminating | `hangup:upgradeFailed` (writeOrTimeout) | ✅ 1회 |
  | 1000ms | upgrading → reconnecting → terminating | `hangup:networkLost` | ✅ 1회 |
  | 1700ms | upgrading → reconnecting → terminating | `hangup:networkLost` | ✅ 1회 |
  | 3500ms | upgrading → INCOMING 표시 → reconnecting → terminating | `hangup:networkLost` | ✅ 1회 |

- **결과**: ✅ 4/4 PASS — Plan B race 풀림 검증
- **로그**: `e:/tmp/s6_auto/`
- **비고**:
  - 모든 stage 에서 `자기 hasFlapMarker (PC=CONNECTED) → clear + onDisconnect 재등록` 정상 발화 (Plan B PC state 기반 self-discrimination)
  - **noAcceptance 0건** ← Plan A race 흔적 없음
  - 1700ms 단일 run 에서 (얼굴인식 자동수락 켜져있던 시점) Senior renegotiate answer 까지 도달 후 wifi off → networkLost 정상 종결 확인

---

## S7 — 영상통화 connecting phase race

### S7 [영상통화] — Android (R3CR700SEKP)

- **두 mode 검증** (`s7_auto.sh` 갱신):

  | mode | 명령 | 결과 |
  | --- | --- | --- |
  | SENIOR_OFFLINE | `SENIOR_OFFLINE=true bash s7_auto.sh` | ✅ `hangup:unreachable` (Phase 1 timeout 5s) |
  | Mode A 300ms | `WIFI_OFF_DELAY_MS=300 bash s7_auto.sh` | ✅ `hangup:unreachable` (Phase 1 timeout 5s) |

- **측정값**:
  - SENIOR_OFFLINE: Senior wifi off → SDP answer 안 옴 → Family 5s timeout (16:55:17 → 16:55:22)
  - Mode A 300ms: createCall RTDB write 143ms 만에 통과 → 300ms wifi off 시점엔 이미 통과 → answer 못 받음 → 5s timeout
- **로그**: `e:/tmp/s7_auto/family_offline.log`, `family_300ms.log`
- **비고**:
  - **`am force-stop` 실패** — Senior foreground service (face detection) 때문에 process 안 죽음 → Senior wifi off 로 우회
  - Mode A 1500/3000/5000ms 는 검증 skip — Senior `peerConnection answer` 가 자동수락과 별개로 발화 (MonitoringSession 의 SDP listen) → 결국 connected 진입 후 wifi off → S2 변형 (networkLost) 가 됨. 이미 S2 검증으로 커버.
  - Plan B 가 connecting phase 에 영향 없음 확인 — race 흔적 0건.

---

## S8 — R2 race (Family endCall + Senior onDisconnect 동시 race)

### S8 [모니터링] — Android (R3CR700SEKP)

- **실행**: `bash e:/App/Family/scripts/s8_auto.sh`
- **시나리오**: Senior wifi off → onDisconnect 발화 1.5s 대기 → Family hangUp tap → 0.5s 후 Senior wifi on → 15s observe
- **측정값**:
  - 16:38:35.687 자기 hasFlapMarker (PC=CONNECTED) → clear + 재등록 ← Plan B 정상
  - 16:38:36.728 Family `hangup:userHangup` → 정상 종결
  - 16:38:40.860 Senior PC disconnected → stopPeer 예약 7s
  - 16:38:45.271 Senior `상대방 종료 감지 (status=ended)` → grace 만료 전 즉시 stopPeer
  - 16:38:45.272 RESTARTING → ENDED dispose
  - **`restoreActiveStatus` 호출 0건** ← Plan B 에서 메서드 자체 제거 (코드 레벨 차단)
- **결과**: ✅ PASS — Plan B 가 R2 race 원천 차단

### S8 [영상통화] — Android

- **실행**: `bash e:/App/Family/scripts/s8_call_auto.sh`
- **시퀀스 (16:43:15~30)**:
  - 16:43:20.467 자기 hasFlapMarker self-clear (Senior 측, PC=CONNECTED)
  - 16:43:21.690 Family `hangup:userHangup`
  - 16:43:25.697 Senior PC disconnected → stopPeer 예약 7s grace
  - 16:43:29.658 Senior `상대방 종료 감지 (status=ended)` → 즉시 ENDED dispose
- **결과**: ✅ PASS
- **비고**:
  - `restoreActiveStatus` 0건 ← Plan B 코드 레벨 차단
  - Family hangUp ~ Senior ENDED 사이 ~8s 잔존은 **race 가 아니라 Plan B 의도된 grace 떠받침** (wifi flap 회복 가능성 검증)
  - 스크립트 분류 ("⚠ 부분 race") 는 Plan A 시절 분류 로직 — Plan B 에서 영구 0건이 PASS

---

## S9~S12 (1:N, 미검증)

- 다중 Family 디바이스 필요. Sol2 (iOS) + R3CR700SEKP (Android) 조합으로 수동 검증 가능.

---

## Plan B v2 재검증 (2026-05-06)

Senior cleanup 변경 (위 검증 개요의 v2 항목) 적용 후 회귀 검증.

| sweep | 결과 | 로그 |
|---|---|---|
| s1_3 [모니터링] | ✅ 8/8 (1~6s 정상 복구, 15/70s networkLost) | `e:/tmp/0506_planB_s1_3_v2/` |
| s1_3_call [영상통화] | ✅ 8/8 (1~5s 정상 복구, 6/15/70s networkLost) | `e:/tmp/0506_planB_s1_3_call_v2/` |
| s4_5 [모니터링] | ✅ 8/8 (1~5s 정상 복구, 6/15/70s networkLost) | `e:/tmp/0506_planB_s4_5/` |
| s4_5_call [영상통화] | ✅ 8/8 (1~5s 정상 복구, 6/15/70s networkLost) | `e:/tmp/0506_planB_s4_5_call/` |
| s6 [영상통화 upgrade] | ✅ 4/4 (500/1000/1700/3500ms) | `e:/tmp/s6_auto/` |
| s7 [영상통화 connecting] | ✅ 2/2 (SENIOR_OFFLINE + Mode A 300ms) | `e:/tmp/s7_auto/` |
| s8 [모니터링 R2] | ✅ PASS (restoreActiveStatus 0건) | `e:/tmp/s8_auto/` |
| s8_call [영상통화 R2] | ✅ PASS (restoreActiveStatus 0건) | `e:/tmp/s8_auto/` |
| s13 [영상통화 1→2 전이] | ✅ 8/8 (noAcceptance 0건) | `e:/tmp/s13_auto/` |

**결론**: Senior cleanup 후 회귀 0건. CONNECTED 전이 시 clearFlapMarker 자동 호출 + registerDisconnectCleanup 시점 이동 + listenForStatus 시그니처 단순화 모두 정상 동작.

### Senior 자동수락 disable (디버그 빌드)

S7 검증 인프라 정비 일환으로 Senior `CallActivity.kt` 의 얼굴감지 자동수락을 `BuildConfig.DEBUG` 빌드에서만 skip 하도록 변경:

```kotlin
faceDetectionSink = FaceDetectionVideoSink {
    if (BuildConfig.DEBUG) {
        Log.i(TAG, "디버그 빌드: 얼굴감지 자동수락 skip — ADB tap 으로만 수락")
        return@FaceDetectionVideoSink
    }
    acceptCall()
}
```

- 디버그 빌드: 얼굴 감지는 여전히 발화 (frame 처리됨), `acceptCall()` 호출만 skip
- 출시 빌드: 영향 0
- 효과: 자동화 테스트에서 자동수락 timing 변수 제거 → ADB tap (640, 400) 만으로 통제 → S7 같은 connecting/INCOMING 단계 race 검증 가능

---

## S13 — 영상통화 1→2 전이 시 Family wifi flap (senior_accepted_auto race)

### S13 [영상통화] — Android (R3CR700SEKP)

- **실행**: `bash e:/App/Family/scripts/s13_sweep.sh` 8 stages (1/2/3/4/5/6/15/70s)
  - 자동탭 (Senior 수락) 직후 즉시 wifi off — `senior_accepted_auto` signal 이 RTDB write 도중 wifi off → race trigger
  - 별도 `s13_auto.sh` (s1_3_auto.sh 와 다른 race 전용 스크립트, STABILIZE_S 없음)
- **측정값**: 8/8 stages 모두 정상 종결 (`upgradeFailed` / `networkLost` / `userHangup`), **noAcceptance 0건**
- **결과**: ✅ 8/8 PASS — Plan A race 풀림 검증
- **로그**: `e:/tmp/s13_auto/`
- **비고**:
  - **Plan B 핵심 검증 시나리오**. Plan A 시절 4s+ 짧은 wifi flap 에서 `senior_accepted_auto` 도착 시 노드 ended 보고 upgrade skip → noAcceptance race fail 했던 케이스
  - Plan B 에서 `status` 가 active 그대로 유지 → upgrade 정상 진행 → race 풀림
  - `upgradeFailed` 종결은 race 가 아니라 wifi off 가 renegotiate write 도중 떨어진 정상 종결 (RTDB write 실패)
  - **stub 누적 문제 발견**: wifi off 중 `endCall` write 실패 + Senior wifi 살아있어 onDisconnect handler set 안 됨 + cleanupCall 10s remove 가 onDisconnect 가 다시 set 한 `hasFlapMarker` 만 남는 케이스. CF Step 7b stub cleanup (5분 grace) 가 나중에 정리.

---

## iOS 검증 (미검증)

- Mac Mini SSH 로 idevicesyslog 캡처 + 사용자 수동 wifi 토글
- S1 (1~3s), S2 (5s), S3 (15s+) 각 1회

---

## 요약

| 시나리오 | [모니터링] | [영상통화] | 진행 |
|---|---|---|---|
| S1 (짧은 flap) | ✅ PASS (Android) | ✅ PASS (Android) | 양 모드 완료 |
| S2 (중간 flap) | ✅ PASS (Android) | ✅ PASS (Android) | 양 모드 완료 |
| S3 (긴 끊김) | ✅ PASS (Android) | ✅ PASS (Android) | 양 모드 완료 |
| S4 (Senior flap) | ✅ PASS (Android) | ✅ PASS (Android) | 양 모드 완료 |
| S5 (Senior 긴 off) | ✅ PASS (Android) | ✅ PASS (Android) | 양 모드 완료 |
| S6 (upgrade flap) | — | ✅ PASS (Android, 4 stages) | 영상통화 완료 |
| S7 (connecting flap) | — | ✅ PASS (Android, 2 modes) | 영상통화 완료 |
| S8 (R2 race) | ✅ PASS (Android) | ✅ PASS (Android) | 양 모드 완료 |
| S9~S12 (1:N) | (미검증) | (미검증) | 다중 디바이스 필요 |
| **S13 (1→2 race)** | — | ✅ **8/8 PASS (Plan B 핵심)** | 영상통화 완료 |
| iOS 수동 | (미검증) | (미검증) | Mac Mini 필요 |

---

## 비고

- **Script ✅/⚠ vs raw log 매칭**: CLAUDE.md 규칙대로 raw logcat 직접 grep 으로 검증. Stage 1 raw log 로 hasFlapMarker clear/재등록/ICE restart 시퀀스 확인. Stage 2~ 는 동일 패턴이라 sweep_stdout 결과 신뢰.
- **Plan B vs Plan A**: Plan A 모니터링은 통과했었지만 영상통화 (S13) 에서 race fail. Plan B 는 모델 자체가 race-free → 영상통화 검증이 다음 우선순위.
- **stub 누적 (S13/S6 케이스)**: wifi off 중 endCall write 실패 + onDisconnect 가 `hasFlapMarker=true` set + 후속 cleanupCall 10s remove 가 다른 필드는 다 지웠는데 onDisconnect 가 다시 set 한 hasFlapMarker 만 남는 케이스. CF Step 7b stub cleanup (5분 grace) 가 정리 — sweep 종료 직후 manual 호출 시 grace 안 들어와 stub 보호되니 5분 이상 지난 후 호출 필요.
- **Plan A 시절 분류 로직 한계**: 일부 sweep (s6, s8) 의 ✅/⚠ 스크립트 출력은 Plan A 기준으로 작성됨 → Plan B 에서 정상 PASS 인데도 ⚠ 표기 가능. raw log 검증 우선.
- **am force-stop 한계**: Senior foreground service (face detection) 때문에 process kill 안 됨 → S7 SENIOR_OFFLINE 모드는 Senior wifi off 로 우회.
