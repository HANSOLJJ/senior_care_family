# WebRTC 통합 테스트 시트

> 시나리오 범위: ICE restart (네트워크 복구) + 1:N peer 정책 (capacity, displace) + race (Plan B 필드 분리, 동시 발신 등).
>
> **정책 (Plan B 필드 분리 모델, 2026-04-30 +)**
>
> - `hasFlapMarker` 별도 필드 (status 와 분리). 자기/상대 마커 구분은 PC `connectionState` 기반.
> - ICE restart **1회 시도**, 실패 시 즉시 `networkLost` 종결 (재시도 없음).
> - PC keepalive 자체 reconnect 와 ICE restart NetworkException race 시 PC=CONNECTED 면 networkLost skip.
> - 종결 시 SnackBar **"연결 불안정으로 통화가 종료되었습니다"** 2초 안내 + 즉시 화면 pop.
> - 재발신은 사용자가 family detail 에서 모니터링/통화 버튼 탭.

---

## 1. 정책 요약

### 1.1 ICE restart 트리거

`_onPeerConnectionStateChanged` ([webrtc_service.dart](../lib/services/call/webrtc_service.dart)):

- DISCONNECTED 즉시 → FSM `connected → reconnecting` 전이 (사용자 인지)
- 4초 grace timer → PC keepalive 자가 복구 기회
- 4s 만료 시 ICE restart 1회 시도. answer 10초 미수신 또는 RTDB write 실패 → `hangUp(networkLost)`. 재시도 없음.
- FAILED 즉시 → grace 없이 1회 시도

### 1.2 onDisconnect — hasFlapMarker (Plan B 필드 분리)

```dart
// signaling_service.dart
await _db.child('calls/$callId').onDisconnect().update({
  'hasFlapMarker': true,
});
```

**핵심 원칙**: `status` 와 `hasFlapMarker` 별도 필드.
- `status` 변경 = **무조건 진짜 종결**. listener 가 endReason 분기 없이 처리.
- `hasFlapMarker` 변경 = **wifi flap 신호**. 별도 listener (`listenForFlapMarker`) 가 grace 분기 담당.

**자기/상대 마커 구분**: PC `connectionState` 로:
- PC=CONNECTED → 자기 마커 추정 → `clearFlapMarker` + onDisconnect 재등록
- PC≠CONNECTED → 상대 wifi flap 추정 → grace 진입 (Senior `STOP_DELAY_MS=7s`) 또는 PC keepalive 자체 흐름 위임 (Family)

**왜 Plan A 에서 변경**: Plan A 는 `status="ended"` 한 필드에 wifi flap 마커 + 진짜 종결 두 의미를 담아 모든 listener (`_callEndSub`, `listenForStatus`, `requestUpgrade`, CF cleanup, 1:N) 가 endReason 분기 필요 → race 폭발. 필드 분리로 race 사라짐.

### 1.3 Senior 1-shot sticky

`iceRestartConsumed` (sticky) — 한 번 true 되면 세션 종결까지 유지. second offer 진입 차단.

### 1.4 종결 UX

```dart
ScaffoldMessenger.of(context).showSnackBar(SnackBar(
  content: Text('연결 불안정으로 통화가 종료되었습니다'),
  duration: Duration(seconds: 2),
));
Navigator.of(context).pop();
```

---

## 2. 테스트 환경

| 디바이스 | 시리얼 / UDID | 역할 |
|---|---|---|
| Galaxy S21 SM-G991N | `R3CR700SEKP` | Family Android |
| iPhone "Sol2" | `00008101-001E158A1488001E` | Family iOS (Mac Mini) |
| KEP M10VSA2 | `KEP2024120921` | Senior |

**Mac Mini SSH**: `ssh-mcp-server` connectionName=`macmini`. iOS 로그: `idevicesyslog -u <UDID> -p Runner > ~/iphone_family_sol2.log`.

---

## 3. 시나리오

### S1 — Family 짧은 wifi flap (PC 자가 복구)

**사전 조건**: Family/Senior 양 앱 실행, Family 가 family detail 화면.

#### S1 [모니터링]

**재현 (자동화)**:
```bash
CALL_TYPE=monitor FAMILY_OFF_S=2 bash e:/App/Family/scripts/s1_3_auto.sh
```

**재현 (수동)**:
1. Family 가 모니터링 버튼 탭 → CONNECTED 확인
2. 5초 안정화
3. `adb -s R3CR700SEKP shell svc wifi disable`
4. 2초 대기
5. `adb -s R3CR700SEKP shell svc wifi enable`
6. 25초 관찰

#### S1 [영상통화]

**재현 (자동화)**:
```bash
CALL_TYPE=call STABILIZE_S=30 FAMILY_OFF_S=2 bash e:/App/Family/scripts/s1_3_auto.sh
```

**핵심 차이**: `STABILIZE_S=30` 으로 senior_accepted_auto + upgrade renegotiate 완료까지 충분히 대기 후 wifi off. 이 경계가 짧으면 1→2 전이 race 발생 (S13 참조).

**재현 (수동)**: 모니터링과 동일하되 영상통화 버튼으로 시작 + Senior 화면에서 자동수락 + 양방향 영상 진입 후 30초 정도 대기 후 wifi off.

**기대 로그 (Family)** (양 모드 공통):
```
시그널링: onDisconnect 마커 설정 callId=...                     ← 통화 시작 시
시그널링: 상대방이 통화 종료 endReason=familyDisconnect          ← 자기 마커 받음
WebRTC: 자기 familyDisconnect 마커 무시 (PC CONNECTED — 통화 유지)
시그널링: wifi flap 후 active 복원 + onDisconnect 재등록 callId=...
[FSM] reconnecting 진입 없음 또는 즉시 connected 복귀
```

**PASS 판정**:
- ICE restart 시도 로그 (`WebRTC: ICE restart 1회 시도 시작`) **없음**
- `hangup:networkLost` / `hangup:noAcceptance` 종결 **없음**
- 통화 유지 (화면 그대로)

---

### S2 — Family 중간 wifi flap (ICE restart 1회 성공)

#### S2 [모니터링]

**재현 (자동화)**:
```bash
CALL_TYPE=monitor FAMILY_OFF_S=5 bash e:/App/Family/scripts/s1_3_auto.sh
```

**재현 (수동)**: S1 [모니터링] 과 동일하되 wifi off 5초.

#### S2 [영상통화]

**재현 (자동화)**:
```bash
CALL_TYPE=call STABILIZE_S=30 FAMILY_OFF_S=5 bash e:/App/Family/scripts/s1_3_auto.sh
```

**재현 (수동)**: S1 [영상통화] 과 동일하되 wifi off 5초.

**기대 로그 (Family)**:
```
WebRTC: 연결 상태 = RTCPeerConnectionStateDisconnected
[FSM] connected → reconnecting (reason: pc_disconnected)
WebRTC: [DEBUG] _disconnectTimer fired (grace 4000ms 만료) → _triggerIceRestart 호출
WebRTC: ICE restart 1회 시도 시작
시그널링: ICE restart offer 전송 callId=...
WebRTC: ICE restart offer 전송 성공
WebRTC: 연결 상태 = RTCPeerConnectionStateConnected
[FSM] reconnecting → connected (reason: ice_restored)
WebRTC: ICE restart answer 적용 완료
```

**기대 로그 (Senior)**:
```
ICE restart offer 수신 → 재협상 (1-shot)
ICE restart answer 전송 완료
연결 상태: CONNECTED (RESTARTING → CONNECTED)
stopPeer 예약 취소
```

**PASS 판정**:
- `ICE restart 1회 시도 시작` 1회만
- `ice_restored` 전이 발생
- `hangup:networkLost` 종결 **없음**
- 통화 유지

---

### S3 — Family 긴 wifi off (networkLost 종결)

#### S3 [모니터링]

**재현 (자동화)**:
```bash
CALL_TYPE=monitor FAMILY_OFF_S=15 bash e:/App/Family/scripts/s1_3_auto.sh
# 또는 70초 (영구 끊김 가까움)
CALL_TYPE=monitor FAMILY_OFF_S=70 bash e:/App/Family/scripts/s1_3_auto.sh
```

#### S3 [영상통화]

**재현 (자동화)**:
```bash
CALL_TYPE=call STABILIZE_S=30 FAMILY_OFF_S=15 bash e:/App/Family/scripts/s1_3_auto.sh
CALL_TYPE=call STABILIZE_S=30 FAMILY_OFF_S=70 bash e:/App/Family/scripts/s1_3_auto.sh
```

**기대 로그 (Family)**:
```
WebRTC: ICE restart 1회 시도 시작
WebRTC: ICE restart 실패 → networkLost 종결: NetworkException
또는 WebRTC: ICE restart answer 미수신 (10000ms) → networkLost 종결
[FSM] reconnecting → terminating (reason: hangup:networkLost)
[FSM] terminating → terminated (reason: cleanup_done)
시그널링: 통화 종료
```

**기대 동작 (UI)**:
- SnackBar **"연결 불안정으로 통화가 종료되었습니다"** 2초 표시 후 자동 dismiss
- MonitoringScreen 즉시 pop → family detail 화면
- SnackBar 가 family detail 에 잔존하지 **않음**

**PASS 판정**:
- `hangup:networkLost` 종결
- SnackBar 표시 + 2초 후 자동 dismiss
- family detail 화면 진입 시 SnackBar 없음

---

### S4 — Senior wifi flap (KEP 자발적 drop 떠받침)

#### S4 [모니터링]

**재현 (자동화)**:
```bash
CALL_TYPE=monitor SENIOR_OFF_S=3 bash e:/App/Family/scripts/s4_5_auto.sh
```

**재현 (수동)**:
1. Family 모니터링 시작 → CONNECTED
2. 5초 안정화
3. `adb -s KEP2024120921 shell svc wifi disable`
4. 3초 대기
5. `adb -s KEP2024120921 shell svc wifi enable`
6. 30초 관찰

#### S4 [영상통화]

**재현 (자동화)**:
```bash
CALL_TYPE=call STABILIZE_S=30 SENIOR_OFF_S=3 bash e:/App/Family/scripts/s4_5_auto.sh
```

**재현 (수동)**: S4 [모니터링] 과 동일하되 영상통화 발신 + Senior 자동수락 후 양방향 영상 진입 후 30초 안정화 후 Senior wifi off.

**기대 로그 (Senior)**:
```
자기 onDisconnect 결과 무시 → 통화 유지 + 복구
onDisconnect cleanup 취소
active status 복원 완료
```

**기대 로그 (Family)**:
```
시그널링: 상대방이 통화 종료 endReason=seniorDisconnect
WebRTC: Senior 일시 단절 감지 → grace 15000ms 대기
WebRTC: 연결 상태 = Disconnected → Connected (자가 또는 ICE restart)
[FSM] reconnecting → connected (ice_restored)
```

**PASS 판정**:
- Family `hangup` 종결 **없음** (grace 안 복구)
- Senior `restoreActiveStatus` 호출
- 통화 유지

---

### S5 — Senior 긴 wifi off

#### S5 [모니터링]

**재현 (자동화)**:
```bash
CALL_TYPE=monitor SENIOR_OFF_S=15 bash e:/App/Family/scripts/s4_5_auto.sh
CALL_TYPE=monitor SENIOR_OFF_S=70 bash e:/App/Family/scripts/s4_5_auto.sh
```

#### S5 [영상통화]

**재현 (자동화)**:
```bash
CALL_TYPE=call STABILIZE_S=30 SENIOR_OFF_S=15 bash e:/App/Family/scripts/s4_5_auto.sh
CALL_TYPE=call STABILIZE_S=30 SENIOR_OFF_S=70 bash e:/App/Family/scripts/s4_5_auto.sh
```

**기대 동작**: Senior wifi 미복귀 → Family grace 15s 만료 → `hangUp(remoteEnded)` 또는 ICE restart 시도 후 `networkLost`. 종결 SnackBar 표시 후 family detail.

**PASS 판정**: 종결 사유 중 하나 (`remoteEnded` / `networkLost`), SnackBar 정상 표시 + dismiss.

---

### S6 — Monitor → Call upgrade 도중 wifi flap

**재현 (자동화)**:
```bash
bash e:/App/Family/scripts/s6_auto.sh
```

**기대 동작**: monitor → call upgrade renegotiate 진행 중 wifi off → ICE restart 1회 시도 → 성공 시 `IN_CALL` 정상 진입, 실패 시 `networkLost`.

**PASS 판정**: 둘 중 하나 — IN_CALL 정상 진입 또는 networkLost 종결.

---

### S7 — Connecting phase 도중 wifi off

**재현 (자동화)**:
```bash
bash e:/App/Family/scripts/s7_auto.sh
```

**기대 동작**:
- Phase 1 (5s) timeout → `unreachable` 종결 (Senior 도달 못 함)
- Phase 2 (20s) timeout → `noAcceptance` 종결 (Senior 수락 못 받음)

**PASS 판정**: 적절한 timeout reason 으로 종결.

---

### S8 — 사용자 hangUp 도중 race (R2)

**재현 (자동화)**:
```bash
bash e:/App/Family/scripts/s8_auto.sh         # 모니터링 케이스
bash e:/App/Family/scripts/s8_call_auto.sh    # 영상통화 케이스
```

**기대 동작**: Family endCall + Senior server-side onDisconnect race. plan A 후 양방향 마커 (`familyDisconnect` / `seniorDisconnect`) + grace 처리. 좀비 통화 발생 안 함.

**PASS 판정**:
- Senior `restoreActiveStatus` 잘못 발화 안 함
- Family `cleanup_done` 시점부터 Senior FSM ENDED 까지 < 3초

---

### S9 — Family A wifi off + Family B 모니터링 (1:N 독립성)

**사전 조건**: Family A (R3CR700SEKP) + Family B (다른 Family 디바이스 또는 iOS Sol2) 모두 같은 Senior 모니터링 중.

**재현 (수동)**:
1. Family A, B 둘 다 모니터링 시작 → 둘 다 CONNECTED
2. Family A wifi off 15초
3. Family A wifi on
4. 30초 관찰

**기대 동작**:
- Family A 만 `networkLost` 종결 (위 S3 흐름)
- Family B 영향 없음 — 모니터링 유지
- Senior 가 A 의 `familyDisconnect` 마커만 처리, B peer 는 영향 없음

**PASS 판정**:
- Family B 의 PC `connectionState` Disconnected 진입 없음
- Family B 의 통화 유지

---

### S10 — Family A networkLost 종결 + Family B 영향 없음

**사전 조건**: S9 와 동일.

**재현 (수동)**: S9 의 wifi off 시간을 70초+ 로 하여 A 가 ICE restart 실패 + networkLost 종결되도록 강제.

**기대 동작**: A networkLost 종결 + family detail 복귀, B 영향 없음.

**PASS 판정**: B 모니터링 그대로 유지.

---

### S11 — Call 진행 중 신규 peer 전체 차단 (remoteBusy)

**사전 조건**: Family A 가 이미 영상통화 중 (callType="call", INCOMING 또는 IN_CALL).

**재현 (수동)**:

1. Family A 가 영상통화 시작 → IN_CALL
2. Family B 가 같은 Senior 에 **영상통화 또는 모니터링** 시도

**기대 동작**:

- Family B `endReason="remoteBusy"` 즉시 받음 (call/monitor 둘 다)
- Family B "Senior 가 통화 중입니다" 다이얼로그 → pop
- Family A 통화 영향 없음

**PASS 판정**: A 통화 유지, B 거절 (call + monitor 모두).

> 정책: call 진행 중에는 신규 peer 전체 차단 — 자세한 배경은 [call-scenarios.md §10-2](./call-scenarios.md).

---

### S12 — Capacity 매트릭스 (MAX_PEERS=3 + call 별개)

**사전 조건**: Family A, B, C 가 같은 Senior 모니터링 중 (`monitor peers=3, MAX_PEERS`).

**재현 (수동)**:

1. Family D 가 **모니터링** 시도 → `capacityExceeded` 거절
2. Family D 가 **영상통화** 시도 → 허용 (일시 peer=4, INCOMING 단계 max 30s)
3. peer=4 상태에서 5번째 시도 → `remoteBusy` (S11 정책)

**기대 동작**:

- 4번째 monitor → `endReason="capacityExceeded"`
- 4번째 call → 허용 (peer=4 일시) → 수락 시 `displaceOtherMonitors()` → 기존 monitor 3개 `otherCallStarted` 거절 → peer=1 (call only)
- 미수락 30s 타임아웃 → call 노드 status="ended" → peer=3 (monitor 그대로)

**PASS 판정**:

- monitor `capacityExceeded` ✅
- call 허용 (peer=4) ✅
- 5번째 모두 `remoteBusy` ✅
- 불변량: `monitor peer ≤ 3`, `call peer ≤ 1`

> 자세한 매트릭스: [call-scenarios.md §10-3-1](./call-scenarios.md).

---

### S13 — 영상통화 1→2 전이 시 Family wifi flap (senior_accepted_auto race)

> S7 (connecting phase wifi off) 의 후속 시나리오. 영상통화 전용 — 모니터링은 1→2 전이가 없어 발생 불가.

**시나리오 본질**:
- 영상통화 발신 → Senior answer (1단계 모니터링 모드 CONNECTED) 받은 직후 ~ Senior 의 `senior_accepted_auto` (얼굴인식 자동수락) signal + Family 의 upgrade renegotiate 완료 **전** 시점에 Family wifi flap.
- 짧은 안정화 (~5초) + 영상통화 의 face detect 가 wifi 복귀 후에야 발화하는 timing 에서 가장 자주 발생.

**Plan A (이전) 의 race fail 메커니즘**:
- onDisconnect 가 `status="ended"` set → Family 의 자기 마커 무시 + `restoreActiveAfterFlap` 비동기 호출.
- wifi off 동안 RTDB write 막힘 → 복귀 후 도달까지 수 초 지연.
- 그 사이 senior_accepted_auto 가 도착 → Family 가 upgrade 시도 → 노드 status 여전히 ended → upgradeToCall 안의 RTDB write fail → `noAcceptance` 종결.

**Plan B (필드 분리, 현재) 의 race 해결**:
- onDisconnect 가 `hasFlapMarker=true` 만 set (별도 필드). `status` 는 active 그대로 유지.
- senior_accepted_auto 도착 시 Family 가 upgrade 시도 → 노드 status="active" 그대로 → 정상 진행.
- `requestUpgrade` / `sendRenegotiateOffer` 가 status 만 검사하므로 hasFlapMarker 잔존 무관.

**사전 조건**: 영상통화 안정화 시간이 senior_accepted_auto 발화보다 짧은 상태에서 wifi flap 발생.

**재현 (자동화)**:
```bash
# 5초 안정화 (default) + 4s wifi flap — Plan A 시절 race 가장 자주 발생했던 케이스
CALL_TYPE=call STABILIZE_S=5 FAMILY_OFF_S=4 bash e:/App/Family/scripts/s1_3_auto.sh

# 또는 sweep 로 race window 매핑
bash e:/App/Family/scripts/s13_sweep.sh
```

**기대 로그 — Plan B 정상 케이스 (Family)**:
```
시그널링: onDisconnect hasFlapMarker 등록
WebRTC: 자기 hasFlapMarker (PC=CONNECTED) → clear + onDisconnect 재등록
[FSM] reconnecting → connected (reason: ice_restored)
[FSM] connected → upgrading (reason: senior_accepted_auto)
WebRTC: 모니터링 → 통화 전환
[FSM] upgrading → connected (reason: renegotiate_done)
```

**PASS 판정**:
- `hangup:noAcceptance` 종결 **없음**
- 양방향 영상통화로 정상 upgrade
- 사용자가 hangup 누를 때까지 통화 유지

**비고**:
- 본 race 의 fix 는 `signaling_service.dart` 의 `requestUpgrade` / `sendRenegotiateOffer` 에 endReason 분기 추가 (마커 받으면 active 복원 후 진행) + `webrtc_service.dart` 자기 마커 무시 분기에서 `restoreActiveAfterFlap` 호출.
- 4s+ wifi off 에서 race window 가 가장 좁아 fail 빈도 높음. 짧은 (~1s) 에서는 active 복원이 빨라 race 안 일어남.

---

## 4. 자동화 스크립트

### 모드 분기 환경변수

`s1_3_auto.sh` / `s4_5_auto.sh` 가 받는 환경변수:

| 변수 | 기본값 | 의미 |
|---|---|---|
| `CALL_TYPE` | `monitor` | `monitor` (모니터링) 또는 `call` (영상통화) |
| `STABILIZE_S` | `5` | wifi off 전 안정화 시간. 영상통화 + S1~S5 검증 시 senior_accepted_auto + upgrade 완료 보장 위해 **30 권장** |
| `FAMILY_OFF_S` | `3` | Family wifi off 시간 (s1_3 만) |
| `SENIOR_OFF_S` | `6` | Senior wifi off 시간 (s4_5 만) |
| `OBSERVE_S` | `30` | wifi 복귀 후 관찰 시간 |

### 스크립트 목록

| 스크립트 | 역할 | 매핑 시나리오 |
|---|---|---|
| [scripts/s1_3_auto.sh](../scripts/s1_3_auto.sh) | 단일 사이클 — Family wifi off N초. `CALL_TYPE=call` 시 영상통화 모드. | S1~S3 (모드별) |
| [scripts/s1_3_sweep.sh](../scripts/s1_3_sweep.sh) | sweep — 1/2/3/4/5/6/15/70s × 8 stages (모니터링) | S1~S3 [모니터링] |
| [scripts/s13_sweep.sh](../scripts/s13_sweep.sh) | sweep — 영상통화 + Family wifi flap. `STABILIZE_S=5` 기본 | **S13** (1→2 전이 race) |
| [scripts/s1_3_call_sweep.sh](../scripts/s1_3_call_sweep.sh) (예정) | sweep — 영상통화 양방향 진행 후 wifi flap. `STABILIZE_S=30` | S1~S3 [영상통화] |
| [scripts/s4_5_auto.sh](../scripts/s4_5_auto.sh) | 단일 사이클 — Senior wifi off. `CALL_TYPE` 분기 | S4~S5 (모드별) |
| [scripts/s4_5_sweep.sh](../scripts/s4_5_sweep.sh) | sweep — Senior wifi (모니터링) | S4~S5 [모니터링] |
| [scripts/s4_5_call_sweep.sh](../scripts/s4_5_call_sweep.sh) (예정) | sweep — 영상통화 + Senior wifi. `STABILIZE_S=30` | S4~S5 [영상통화] |
| [scripts/s6_auto.sh](../scripts/s6_auto.sh) | upgrade + ICE flap | S6 |
| [scripts/s7_auto.sh](../scripts/s7_auto.sh) | connecting phase + wifi off | S7 |
| [scripts/s8_auto.sh](../scripts/s8_auto.sh), [scripts/s8_call_auto.sh](../scripts/s8_call_auto.sh) | R2 race | S8 |

---

## 5. iOS 검증 (수동)

iPhone wifi 토글은 외부 도구 제어 불가. Mac Mini SSH 로 로그 캡처 + 사용자 수동 wifi 토글:

```bash
# Mac Mini 에서:
idevicesyslog -u 00008101-001E158A1488001E -p Runner > ~/iphone_family_sol2.log &
tail -f ~/iphone_family_sol2.log | grep -E "flutter|FSM|networkLost|familyDisconnect"
```

수동 검증 시나리오: S1 (1~3s), S2 (5s), S3 (15s+) 각 1회.

---

## 6. 알려진 한계

- **iOS wifi 토글 자동화 불가** — §5 대로 수동 검증
- **iOS background suspension** — 30s 후 OS socket close 자동. plan A 마커가 동일 매커니즘으로 set.
- **KEP MTK WiFi 자발적 drop** ([kep_wifi_suspend_presence.md](../../Senior/docs/kep_wifi_suspend_presence.md) §"연관 이슈 1") — plan A 양방향 마커 + 1회 ICE restart 로 떠받침
- **Race A 거울** — Family endCall 직후 onDisconnect 발화 race. 좀비 통화 ✗ (영향 작음, 받아들이기)

---

## 7. 결과 누적

[webrtc_integration_test_result.md](./webrtc_integration_test_result.md) — 시나리오별 PASS/FAIL + 측정값 + iOS/Android 분리.

---

## 8. 기록 양식

```text
## S<번호> — <시나리오 명> (<날짜>)
- 디바이스: Family Android / iOS / Senior KEP
- 실행: <자동화 명령 또는 수동 절차>
- 측정값: <시간, 카운트>
- 결과: ✅ PASS / ⚠ FAIL / ❌ ERROR
- 로그: <위치 또는 핵심 라인>
- 비고: <특이사항>
```
