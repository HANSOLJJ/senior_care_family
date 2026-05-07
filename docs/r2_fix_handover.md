# R2 — Senior wifi flap + Family hangUp race (documented limitation)

> **읽는 사람**: Senior 측 코드 수정 중인 다른 작업 세션 / 향후 본 race 를 다루게 될 사람
> **작성**: 2026-04-29

## TL;DR

1. **S16 옵션 2 (Senior `onDisconnect` 임시 마커 + Family `_seniorDisconnectGraceTimer`) 는 이미 commit `955e0d7` 로 배포 완료**. "Family 측 미작업" 으로 알고 있다면 outdated.
2. **R2 race 자동화로 검증됨** — 영상통화 중 Senior wifi flap + 동시 Family hangUp 시 Senior 측 ~10-12초 좀비 통화 화면 발생.
3. **R2 race 는 본질적으로 Senior 의 RTDB SDK 재연결 시간 (1~30s) 에 의존**. Family 측 어떻게 잘 보내도 Senior 가 offline 이면 못 받음. 따라서 **완전 차단 fix 는 현실적으로 어려움**.
4. **현재 결정**: 기존 PC keepalive + STOP_DELAY 메커니즘이 ~10초 안에 자연 cleanup → **documented limitation 으로 수용**. fix 는 한 가지만 추가 — Family endCall 이 endReason="remoteEnded" 명시 (semantic 정합성).

---

## R2 race 분석

### 검증된 시퀀스

자동화 스크립트 [r2_call_auto.sh](e:\App\Family\scripts\r2_call_auto.sh) 영상통화 케이스 (2026-04-29 측정):

```text
T+0      Senior wifi off
T+0.5    Senior server-side onDisconnect 발화
         → /calls/{cid}: { status="ended", endReason="seniorDisconnect" }
T+1      Senior 잠깐 reconnect (브리핑 transitional window)
         → status=ended listener fire → endReason 읽어 "seniorDisconnect"
         → cancelDisconnectCleanup + restoreActiveStatus
         → /calls/{cid}: { status="answered", endReason=null }  ← 좀비 시작
T+1.2    Senior 다시 RTDB offline (.info/connected=false)
T+1.5    Family hangUp tap → endCall fires (fire-and-forget)
T+2      Family endCall update commits server: { status="ended", endReason="remoteEnded" }
T+1.2~+10  Senior offline 상태 — Family 의 update 못 받음
T+10+    Senior PC keepalive timeout → FSM CONNECTED → RESTARTING + STOP_DELAY 7s
T+12     Senior FSM ENDED (자연 cleanup)
```

### 실측 UX 영향

- Family `cleanup_done` 후 Senior FSM ENDED 까지: **약 10-12초**
- Senior 측: "통화 중" 화면 + Family 영상 frozen + 카메라/마이크 활성
- Family 측: 즉시 종결, 영향 없음
- 데이터 무결성: 손상 없음 (Family `cleanupCall` 의 10s 지연 후 RTDB 노드 정리)

---

## 왜 fix 가 어려운가

### 시도했던 fix layer 들 (모두 race fix 효과 0~marginal)

| Layer | 시도 내용 | 결과 |
|---|---|---|
| Family endCall + endReason="remoteEnded" | Family hangUp 시 RTDB 에 endReason 명시 | Senior 가 offline 인 동안 못 받음 → race fix 효과 0. semantic 정합성만 유지 |
| Senior `restoreActiveStatus` runTransaction 가드 | atomic re-read 로 commit 직전 검증 | Senior 가 stale local cache 로 doTransaction 실행 → guard 통과 → race 그대로 |
| Family `hangUp` 첫줄 early endCall | RTDB write 빨리 fire | Senior offline 동안 못 받음 → 효과 0 |
| Senior endReason path real-time `ValueEventListener` | endReason 변경 즉시 감지 | Senior offline 동안 listener fire 안 함 (server push 못 받음) |
| Senior 1~2.5s delay 후 fresh `.get()` | local cache 우회하고 server fetch | `.get()` 도 persistence cache 의 stale 값 반환 (Firebase RTDB 문서와 다름) |

### 근본 원인

- **Senior wifi off 후 RTDB SDK 재연결 시간이 ~9초** (실측, 2.3초 wifi flap 케이스). Firebase RTDB SDK 의 exponential backoff reconnect 패턴 — 우리 통제 밖.
- 그 9초 동안 Senior 는 Family 의 update 를 못 받음. `restoreActiveStatus` 결정이 stale 정보 기반.
- **Family 측이 무엇을 어떻게 보내도 Senior 가 못 받으면 fix 불가**.

### 가능한 근본 fix (defer)

- Senior 가 `.info/connected=true` 로 RTDB 재연결 감지 후 결정 — 단 재연결 시간만큼 (1~30s) S16 정상 흐름 통화 유지 복귀가 지연. UX 손해 큼.
- `FirebaseDatabase.goOnline()` 강제 호출로 빠른 재연결 시도 — 효과 불확실.
- Family 가 별도 sentinel (`/calls/{cid}/familyEnded: true`) — 스키마 추가 + 양쪽 코드 변경. 본 plan 외.

---

## 적용된 변경

| # | 파일 | 변경 |
|---|---|---|
| 1 | [signaling_service.dart:265](e:\App\Family\lib\services\call\signaling_service.dart#L265) `endCall` | `status="ended"` + **`endReason="remoteEnded"`** 두 필드 동시 `update()` |

**왜 이것만 적용**:

- Family 가 RTDB 에 명시적 endReason writer 가 됨 — 스키마 doc ([RTDB_schema.md v4](RTDB_schema.md)) 와 코드 정합성 확보
- Senior online 일 때는 listener 가 정확한 종결 사유 수신 (race 외 정상 케이스)
- Race fix 효과는 0 이지만 semantic 정합성 차원에서 유지 가치
- 변경 한 줄, 복잡도 0

**다른 layer 들은 race fix 효과가 의심스럽거나 코드 복잡도만 추가하므로 모두 revert** (Senior `restoreActiveStatus` runTransaction, hangUp early endCall, endReason watch + delay 등 — 모든 변경 원래 상태로 복원).

---

## TerminateReason vs RTDB endReason — 헷갈리지 말기

다른 세션이 헷갈렸던 부분:

| 레이어 | 무엇 | 값 종류 |
|---|---|---|
| **Family Dart enum (`TerminateReason`)** | Family 메모리 안에서만 사는 enum. UI 분기, 로깅, 재시도 정책. | 10종: `iceFailed`, `unreachable`, `noAcceptance`, `userHangup`, `networkOffline`, `upgradeFailed`, `remoteBusy`, `capacityExceeded`, `endedByOtherCall`, `remoteEnded` |
| **RTDB `/calls/{cid}/endReason` (string)** | Family ↔ Senior 통신 채널 | 6종: `normal`, `remoteBusy`, `capacityExceeded`, `otherCallStarted`, `remoteEnded`, `seniorDisconnect` |

**RTDB 에 실제로 도달하는 Family endReason 은 `"remoteEnded"` 한 가지** (R2 fix 후 도입). `iceFailed`/`unreachable`/`noAcceptance` 등은 Family `TerminateReason` enum 일 뿐 RTDB 에 안 닿음.

`endCall(callId)` 가 Family 의 모든 hangUp 경로의 single chokepoint. `endReason="remoteEnded"` hardcoded — 호출자 reason 무관.

---

## RTDB Write 권한 — Family 도 광범위 writer

다른 세션이 "Senior 만 `/calls` 에 write" 라고 잘못 기억했던 부분 — 사실 확인:

1. **RTDB Rules** ([database.rules.json](e:\App\Family\database.rules.json)): 시간 제한 외 인증/권한 체크 0 — Family/Senior/Cloud Function 모두 write 가능
2. **코드 검증** ([signaling_service.dart](e:\App\Family\lib\services\call\signaling_service.dart) grep): Family 가 `/calls/{cid}` 의 다음 필드 명시 write
   - `offer`, `callerCandidates`, `status` (ringing/ended), `endReason` (remoteEnded — R2 fix), `upgradeRequest`, `renegotiateOffer`, `iceRestartOffer`, `callerUid`, `callerName`, `targetDeviceId`, `targetFamilyId`, `callType`, `createdAt`
3. **Schema doc** ([RTDB_schema.md v4 `/calls` Writer 매트릭스](RTDB_schema.md)): Family 명시적 writer

→ Family 가 endReason 을 RTDB 에 쓰는 것은 권한/스키마 모두 자연스러움.

---

## 자동화 검증 결과

| 스크립트 | 시나리오 | 결과 |
|---|---|---|
| [r2_call_auto.sh](e:\App\Family\scripts\r2_call_auto.sh) | 영상통화 + Senior wifi off + Family hangUp + Senior wifi on | Race 발생 (~10-12s 좀비), Senior PC keepalive 가 자연 cleanup |
| [r2_auto.sh](e:\App\Family\scripts\r2_auto.sh) | 모니터링 동일 race | Race 발생, 단 모니터링은 Senior UI 없어 사용자 인지 0 |
| [s16_auto_sweep.sh](e:\App\Family\scripts\s16_auto_sweep.sh) | Senior wifi flap (Family hangUp 없음) | 1s/3s/6s `ice_restored` PASS — S16 의도 유지 |

검증 로그: `e:/tmp/r2_call_auto/`, `e:/tmp/r2_auto/`, `e:/tmp/s16_auto/`.

---

## 결정 요약

**R2 race 는 documented limitation 으로 수용**:

- 발생 조건: Senior wifi flap (자체 wifi 자발적 drop) 동시 Family 사용자 hangUp
- 영향 범위: Senior 측 UI 약 10-12초 잔존 ("통화 중" 화면 + Family 영상 frozen)
- 자동 정리: Senior PC keepalive (5s) + STOP_DELAY (7s) 가 자연 cleanup
- 데이터 무결성: 손상 없음 (Family cleanupCall 가 10s 후 RTDB 노드 정리)
- Family 측 UX: 영향 없음 (즉시 종결)
- 빈도: 영상통화 중 Senior wifi flap + Family 자발 hangUp 의 동시 발생 — 드문 케이스

**향후 관측 빈도가 높아지면 재검토 항목**:

- `.info/connected` 기반 reconnect 대기 + endReason 재조회
- Family sentinel (`/calls/{cid}/familyEnded: true`) 도입
- Senior `FirebaseDatabase.goOnline()` 강제 재연결

---

## 참고

- [RTDB_schema.md v4](RTDB_schema.md) — Family endReason writer 명시 (테이블 기반 재구성)
- [call-scenarios.md §10](call-scenarios.md) — endReason 매트릭스 (RTDB 도달 컬럼)
- [webrtc_integration_test_result.md §S8](webrtc_integration_test_result.md) — R2 race 검증 시퀀스 (S8 으로 통합)
- [Senior `kep_wifi_suspend_presence.md` §"연관 이슈 1"](e:\App\Senior\docs\kep_wifi_suspend_presence.md) — S16 본 의도
- Commit `955e0d7` — S16 옵션 2 배포 (R2 race 의 직전 단계)
