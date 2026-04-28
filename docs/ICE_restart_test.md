# ICE Restart 테스트 시트

> WebRTC ICE Restart 기능 검증용 시나리오 모음. 906e52d (`feat: WebRTC ICE Restart`) + c2e8bd6 (FSM 재설계) + c33d770 (좀비 peer fix) 통합 후 회귀 테스트 기준.

---

## 1. 기능 요약

### 트리거 조건 (Family 측)
| 조건 | 동작 |
|---|---|
| `RTCPeerConnectionStateDisconnected` | grace **4초** 후 `_triggerIceRestart()` |
| `RTCPeerConnectionStateFailed` | **즉시** `_triggerIceRestart()` |
| `RTCPeerConnectionStateConnected` (복구) | grace 타이머 cancel + 5초 안정 유지 시 attempts=0 / flapWindowStart=null 리셋 |

### 한도 / 가드
| 상수 | 값 | 의미 |
|---|---|---|
| `_graceMs` | 4000 ms | DISCONNECTED → restart 트리거 대기 |
| `_iceRestartAnswerTimeoutMs` | 10000 ms | offer 전송 후 answer 대기, 만료 시 재시도 |
| `_maxIceRestartAttempts` | 5 | 누적 시도 한도. 초과 시 `hangUp(iceFailed)` |
| `_maxFlapWindowMs` | 60000 ms | 첫 disconnect 이후 세션 상한. 초과 시 `hangUp(iceFailed)` |
| `_stableResetMs` | 5000 ms | CONNECTED 안정 유지 시 attempts/flapWindow 리셋 |
| `_iceRestartInProgress` | bool | 중복 트리거 방지 가드. setRemote(answer) 완료 finally에서 reset |

### 시그널링 채널
| RTDB 경로 | Writer | Reader | 비고 |
|---|---|---|---|
| `calls/{cid}/iceRestartOffer` | Family | Senior | `pc.restartIce() + createOffer()` SDP. `writeOrTimeout(3s) + onTimeoutCleanup` 가드 적용 |
| `calls/{cid}/iceRestartAnswer` | Senior | Family | answer 쓰기 직전 Senior 가 `iceRestartOffer` 노드 선제 삭제 → stale answer 재수신 방지 |

### FSM 전이
- `connected | upgrading` → `reconnecting` (restart 진입 시, MonitoringScreen 배너용)
- `reconnecting` → `connected` (CONNECTED 복귀 시, `ice_restored`)
- 한도 초과 시 → `terminating(iceFailed)` → `terminated`

---

## 2. 테스트 환경

- **Family 앱 (A, 주 테스트 기기)**: SM-G991N (Galaxy S21, `R3CR700SEKP`) — Wi-Fi/LTE 전환 가능
- **Family 앱 (B, 1:N 회귀 테스트용)**: 사용자 보유 2번째 기기 (식별자는 실행 시 `adb devices` 로 확정)
- **Senior 앱**: Lenovo M10VSA2 (`KEP2024120921`) — 고정 Wi-Fi (기존 SM-T500 `R9TT903QE5V` 에서 교체됨)
- **Firebase 프로젝트**: `dcom-smart-frame`
- **빌드**: `flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk`
- **로그**: `adb -s R3CR700SEKP logcat -v time *:S flutter:V` (Family A)
- **로그**: `adb -s KEP2024120921 logcat -v time SignalingClient:V WebRTC:V MonitoringSession:V *:S` (Senior)
- **유의**: 매 시나리오 시작 전 `adb logcat -c` 로 로그 클리어. Senior/Family 둘 다 IN_CALL 또는 MONITORING 상태에서 시작.

---

## 3. 시나리오

각 시나리오는 **준비 → 실행 → 기대 결과 → 검증 로그 → 통과 기준** 순.

---

### S1. Wi-Fi 일시 단절 (grace 4초 내 복구)

**가설**: 짧은 끊김은 ICE restart 트리거 없이 자체 복구되어야 한다. 불필요한 SDP 재교환 비용 회피.

**준비**: Family 모니터링 시작 → CONNECTED 5초 이상 유지 (안정 카운터 리셋된 상태).

**실행**:
1. Family Wi-Fi off (퀵 패널)
2. **3초 후** Wi-Fi on

**기대 결과**:
- `_disconnectTimer` 발동 전 CONNECTED 복귀
- restart offer 전송 안 됨
- 영상 멈춤 ≤ 1초, 자동 복구
- 재연결 오버레이 안 뜸 (FSM 은 connected 유지)

**검증 로그 (Family)**:
```
WebRTC: 연결 상태 = RTCPeerConnectionStateDisconnected
WebRTC: 연결 상태 = RTCPeerConnectionStateConnected
(WebRTC: ICE restart offer 전송 ← 절대 나오면 안 됨)
```

**통과 기준**: restart offer 로그 0회. 영상 자동 복구.

---

### S2. Wi-Fi 단절 → grace 초과 → 복구 (1회 restart 성공)

**가설**: grace 4초를 넘기면 restart 1회로 복구 가능해야 한다.

**준비**: S1 과 동일.

**실행**:
1. Family Wi-Fi off
2. **6초 대기** (grace 4초 초과 → restart 트리거)
3. Wi-Fi on (즉시)

**기대 결과**:
- DISCONNECTED 4초 후 `_triggerIceRestart()` 호출
- FSM `connected → reconnecting` 전이 → 화면에 "연결이 불안정해요" 오버레이 표시
- offer 전송 → Senior answer → setRemote → CONNECTED 복귀
- FSM `reconnecting → connected` (`reason: ice_restored`)
- `_iceRestartAttempts` = 1

**검증 로그 (Family)**:
```
WebRTC: 연결 상태 = RTCPeerConnectionStateDisconnected
WebRTC: 연결 상태 = RTCPeerConnectionStateConnected  ← 만약 4초 내 복귀하면 이게 먼저
WebRTC: ICE restart offer 전송 (attempt=1)
시그널링: ICE restart offer 전송 callId=...
WebRTC: ICE restart answer 적용 완료
WebRTC: 연결 상태 = RTCPeerConnectionStateConnected
FSM: connected ← reconnecting (ice_restored)
```

**검증 로그 (Senior)**:
```
ICE restart offer 수신
ICE restart answer 전송 완료
```

**통과 기준**: 오버레이 표시 → 사라짐. 한도 카운터 1.

---

### S3. Wi-Fi → LTE 핸드오프 (NAT 전환)

**가설**: 네트워크 인터페이스 변경 시 새 ICE candidate 수집 + 새 경로로 복구 가능해야 한다. (가장 실전적인 케이스)

**준비**: Family Wi-Fi + 모바일 데이터 둘 다 활성. CONNECTED 안정.

**실행**:
1. Family **비행기 모드 OFF 상태에서** Wi-Fi off (모바일 데이터만 남김)

**기대 결과**:
- DISCONNECTED → grace → restart 트리거
- offer 의 새 candidate (LTE 공인 IP) 가 Senior 에 전달됨
- TURN relay 통해 복구 (대부분 STUN p2p 실패 → relay)
- 5~10초 내 CONNECTED

**검증 로그 (Family)**:
```
WebRTC: 연결 상태 = RTCPeerConnectionStateDisconnected
WebRTC: ICE restart offer 전송 (attempt=1)
WebRTC: 연결 상태 = RTCPeerConnectionStateConnected
```

**통과 기준**: LTE 환경에서 영상 복구 (해상도 자동 다운 가능).

---

### S4. Wi-Fi 완전 단절 (5회 재시도 후 종결)

**가설**: 복구 불가능한 상황에서 5회까지만 시도하고 정리.

**준비**: S1 과 동일. **모바일 데이터 끔** (Wi-Fi 만 의존).

**실행**:
1. Family Wi-Fi off (계속 off 유지)
2. 약 60~70초 대기

**기대 결과**:
- 첫 grace 4초 → restart 1
- answer 미수신 → 10초 후 재시도 → restart 2
- ... restart 5
- 한도 초과 → `hangUp(iceFailed)` → `onCallEnded` → 화면 pop
- 또는 flapWindow 60초 초과로 종결 (둘 중 먼저 발생)

**검증 로그 (Family)**:
```
WebRTC: ICE restart offer 전송 (attempt=1)
WebRTC: ICE restart answer 미수신 (10000ms) → 재시도 트리거
WebRTC: ICE restart offer 전송 (attempt=2)
... (3, 4, 5)
WebRTC: ICE restart 한도(5) 초과 → iceFailed 종결
또는
WebRTC: flap window(60000 ms) 초과 → iceFailed 종결
FSM: terminating ← reconnecting (hangup:iceFailed)
```

**통과 기준**:
- attempts ≤ 5
- 종결 사유 `iceFailed`
- Family 화면 자동 pop, RTDB `calls/{cid}` 노드 정리됨 (10초 지연 후)
- Senior 도 `ended` 수신하여 정리

---

### S5. flap window 60초 초과 (반복 disconnect)

**가설**: disconnect/connect 가 반복되면 attempts 5 미만이라도 60초 상한으로 종결.

**준비**: S1 과 동일.

**실행**: Family Wi-Fi 를 **6초 off → 6초 on** 사이클 반복 (각 사이클마다 attempts +1, CONNECTED 5초 유지 못해서 카운터 리셋 안됨).

**기대 결과**: 약 50~60초 시점에 flap window 초과로 종결.

**통과 기준**: `flap window(60000 ms) 초과 → iceFailed 종결` 로그 확인.

**예상 함정**: 사이클 중 CONNECTED 5초 이상 유지되면 `_stableTimer` 가 `_iceRestartAttempts=0` + `_flapWindowStart=null` 로 리셋해버림. 시나리오 의도대로 가려면 CONNECTED 유지 시간 < 5초로 통제.

---

### S6. ICE restart 진행 중 사용자 hangUp

**가설**: restart 도중 hangUp 호출 시 깨끗하게 종결되어야 함 (orphan offer 노드 없음, FSM stuck 없음).

**준비**: S2 와 동일.

**실행**:
1. Wi-Fi off (6초)
2. restart offer 전송 직후 → Family **종료 버튼 누름**
3. (이 시점 `_iceRestartInProgress=true`, answer timer 살아있음)
4. Wi-Fi on

**기대 결과**:
- `hangUp` 진입 → `_isEnding=true`
- `_triggerIceRestart` 다음 await 지점에서 `if (_isEnding) return` 으로 조기 종료
- answer timer 가 만료되어도 `if (_isEnding) return` (또는 `_peerConnection==null` 가드) 로 재호출 안됨
- RTDB `iceRestartOffer` 노드 잔존 — Senior 가 무시? 또는 Family cleanupCall 10초 후 노드 전체 삭제로 정리

**검증 포인트**:
- `_iceRestartAnswerTimer` 가 hangUp 에서 cancel 되는지 코드 확인 필요
- (현재 cleanupCall 에서 `_disconnectTimer/_stableTimer/_iceRestartAnswerTimer` cancel 명시 여부 확인)

**통과 기준**: hangUp 후 추가 RTDB 쓰기 없음. 다음 발신 정상 동작.

---

### S7. Senior 측 무응답 (10초 answer timeout → 재시도)

**가설**: Senior 가 ICE restart offer 를 받았으나 answer 못 보내는 경우 (Senior CPU/네트워크 일시 부하).

**준비**: Senior 디버거 attach 로 `listenForIceRestartOffer` 콜백에 breakpoint 잡고 Family restart 트리거.

**실행**:
1. Family Wi-Fi off 6초 → on
2. Senior breakpoint hit → 의도적으로 12초 멈춰놓기
3. Senior breakpoint 해제

**기대 결과**:
- 10초 시점에 `WebRTC: ICE restart answer 미수신 (10000ms) → 재시도 트리거`
- attempt=2 로 재전송
- Senior 가 (지연된) 첫 answer 를 보내면 stable 상태에서 받음 → setRemote 거절 (`signalingState != HaveLocalOffer` 또는 `Stable` 체크) → `WebRTC: ICE restart answer 무시 (stable, 이미 적용됨)`

**통과 기준**: 재시도 동작 + stale answer 무시 로그.

---

### S8. ICE restart 도중 Senior 앱 강제 종료

**가설**: Senior 가 죽으면 Family 는 5회 시도 후 정리.

**준비**: S2 와 동일.

**실행**:
1. Family Wi-Fi off → on (restart 트리거)
2. restart offer 전송 직후 → Senior 앱 **강제 종료** (`adb shell am force-stop com.seniorcare.senior`)

**기대 결과**:
- answer 미수신 → 10초 후 재시도 → ... → 한도 초과 → 종결
- Senior 의 `onDisconnect` 가 RTDB `calls/{cid}` 정리 (단, Senior 는 onDisconnect 안 거는 듯 — 확인 필요)
- Family `cleanupCall` 10초 후 노드 삭제

**통과 기준**: `iceFailed` 종결 후 Senior 재시작 시 RTDB 잔존 통화 노드 0개.

---

### S9. CONNECTED 안정 5초 유지 → 카운터 리셋 검증

**가설**: 1회 restart 성공 후 안정 유지되면 다음 disconnect 가 다시 attempts=1 로 시작.

**준비**: S2 시나리오 1회 완료 (`_iceRestartAttempts=1` 상태).

**실행**:
1. CONNECTED **10초 이상** 유지
2. 다시 Wi-Fi off 6초 → on (S2 반복)

**기대 결과**:
- `_stableTimer` 5초 만료 → `_iceRestartAttempts=0` + `_flapWindowStart=null` 리셋
- 두 번째 trigger 시 `attempt=1` (누적이 아니라 1)

**검증 로그**:
```
WebRTC: ICE restart offer 전송 (attempt=1)  ← 두 번째 사이클에서도 1
```

**통과 기준**: 두 번째 사이클의 attempt 번호 = 1.

---

### S10. ~~양방향 통화 (call) vs 모니터링 (monitor) 동일 동작~~ (폐기)

**⚠ 폐기됨 (2026-04-24)** — 정책 변경으로 폐기

### S11. 모니터링→통화 업그레이드 도중 ICE failure

**1:N displace 정책 영향**: **부분적**. displace 는 upgrade **성공 후** `handleUpgradeRequest` 끝에서 발동 → upgrading 중 ICE failure 로 upgrade 실패 시 monitor 상태로 복귀 → 다른 Family 의 call 수락은 여전히 가능. upgrade 성공 직후 ICE failure 는 이미 displace 가 실행된 뒤라 다른 monitor 들은 모두 종결된 상태.

**가설**: `upgrading` phase 에서도 ICE restart 가 트리거되며 (`upgrading → reconnecting`), 복구 후 `reconnecting → connected` 로 빠짐 (upgrading 상태 손실).

**준비**: 모니터링 중 → "통화 시작" 버튼 → Senior 수락 후 renegotiation 진행 중.

**실행**: renegotiation 중 Family Wi-Fi off 6초.

**기대 결과**:
- `connecting/upgrading → reconnecting` 전이
- restart 복구 → `connected` 진입
- 양방향 통화 정상 동작 여부 확인

**검증 포인트**:
- upgrading 중 트랙 추가가 완료된 상태였는지에 따라 음성/영상 결과 달라짐
- renegotiateAnswer 와 iceRestartAnswer 가 충돌하지 않는지 (별개 RTDB 노드)

**통과 기준**: 복구 후 양방향 음성/영상 OK 또는 깨끗한 종결.

**기록할 만한 케이스**: 만약 업그레이드 진행 중 restart 가 업그레이드를 깨뜨린다면 별도 이슈 등록.

---

### S12. 발신 중 (connecting phase) ICE 실패

**1:N displace 정책 영향**: 없음 (connecting phase 는 아직 peer 가 Senior peers 목록에 등록되지 않은 단계, displace 대상 아님).

**상태**: ✅ 명세 정정 완료 (2026-04-28, 자동화 [scripts/s12_auto.sh](../scripts/s12_auto.sh) 실측).

**준비**: FamilyDetailScreen 위치 + Senior 자동수락 (얼굴인식) ON 가정.

**실행**: Family "영상통화" 버튼 탭 → `WIFI_OFF_DELAY_MS` 후 Wi-Fi off.

#### Race window 매핑 (4가지 timing 별 다른 종결 경로)

| WIFI_OFF | 시점 | 종결 사유 | 의미 |
|---|---|---|---|
| 500ms | createCall RTDB write 통과 직후 — Senior answer 미도달 | `hangup:unreachable` | Phase 1 timeout 5s |
| 1500ms | answer 받음 + Senior 수락 전 — Wi-Fi off 영향으로 PC ICE failure | `hangup:noAcceptance` | reconnecting 상태에서도 Phase 2 timeout 20s 발동 (발견) |
| 3000ms | Senior 자동수락 → upgrade 시도 → renegotiate offer 도중 | `hangup:upgradeFailed` | sendRenegotiateOffer NetworkException → Bug #1-B catch |
| 5000ms | 자동수락 + renegotiate_done (IN_CALL 진입 후) → ICE failure | `hangup:iceFailed` | flap window 60s 초과 (S2 변형) |

**통과 기준**: 4가지 timing 모두 깨끗한 종결 + FSM stuck 0건. ✅ 모두 PASS.

**핵심 발견**:
- S12 의 본질 ≈ **S11 + 초기 Phase 1/2 timeout 단계 추가** — Senior 자동수락 시 monitor→call upgrade 자동 경로 (`senior_accepted_auto`) 가 발동되어 그 후는 S11 동일
- **Phase 2 timeout 이 reconnecting 상태에서도 발동** — startCall 시점 30s 타이머가 FSM 상태와 무관하게 fire (Test 2). 의도된 설계 (acceptance grace 우선) 인지 별도 검토 필요

**상세 결과**: [ICE_restart_test_result.md §S12](ICE_restart_test_result.md#s12--발신-call-타입-connecting-phase-도중-ice-failure)

---

### S13. 다중 disconnect 동안 중복 트리거 방지

**1:N displace 정책 영향**: 없음 (한 peer 내부 ICE restart race 방지 가드, multi-Family 와 무관).

**가설**: `_iceRestartInProgress` 가드로 중복 offer 전송 방지.

**준비**: S2 와 동일.

**실행**:
1. Wi-Fi off 6초 → on
2. restart offer 전송 직후 → 즉시 다시 Wi-Fi off → on
3. (첫 restart 의 answer 도착 전에 두 번째 disconnect 발생)

**기대 결과**:
- 두 번째 disconnect 의 `_onPeerConnectionStateChanged` 진입 시 `if (_iceRestartInProgress) return` 으로 grace timer 도 안 걸림
- 첫 restart 의 answer 도착 → setRemote → finally 에서 `_iceRestartInProgress=false`
- 그 시점에 여전히 disconnect 면 다음 사이클에서 다시 trigger

**검증 로그**: `attempt=1` 만 보이고 그 직후 `attempt=2` 안 나와야 함 (중복 방지).

**통과 기준**: offer 전송 횟수 = 실제 의도한 횟수.

---

### S14. Stale answer 재수신 (Senior 가 offer 노드 선제 삭제로 방어)

**1:N displace 정책 영향**: 없음 (한 callId 내부 stale answer reject 가드, multi-Family 와 무관).

**가설**: Firebase RTDB persistence 캐시로 인해 구 answer 가 재발화되더라도 무시.

**준비**: S2 1회 완료.

**실행**: 인위적 재현 어려움 — Family 앱 강제 종료 후 재시작 → 동일 callId 통화에 재참여 시도 (실제로는 callId 가 새로 발급되므로 발생 어려움). 대신 코드 리뷰로 검증.

**검증 코드**:
- Senior `sendIceRestartAnswer` 가 `callRef.child("iceRestartOffer").removeValue()` 선제 호출 (E:\App\Senior\app\src\main\java\com\seniorcare\senior\webrtc\SignalingClient.kt:330)
- Family `_iceRestartAnswerSub` 의 `signalingState == Stable` 체크로 중복 setRemote 거절 (E:\App\Family\lib\services\call\webrtc_service.dart:_registerSignalingListeners)

**통과 기준**: 코드 가드 존재. 실 환경에서 stale answer 로그가 보이면 `WebRTC: ICE restart answer 무시 (stable, 이미 적용됨)` 발생 후 정상.

---

### S15. Family 앱 백그라운드 → foreground 복귀

**1:N displace 정책 영향**: 없음 (단일 Family 기기의 lifecycle 이슈, multi-Family 와 무관).

**가설**: Android Doze 모드에서 PC 가 SUSPENDED 상태가 되었다가 복귀 시 ICE restart 트리거.

**준비**: 모니터링 시작 → CONNECTED.

**실행**:
1. Family 홈 버튼 → 백그라운드 (5분 이상)
2. 다시 앱으로 복귀

**기대 결과**:
- 백그라운드 중 PC 가 DISCONNECTED/FAILED 가능성
- 복귀 시 restart 트리거 또는 이미 종결되어 화면 pop 됨

**통과 기준**: 정상 복구 또는 깨끗한 종결. 화면 깨짐/검은 화면 없음 (FSM 가드).

**유의**: Android 버전/OEM 별 Doze 동작 다름. SM-G991N 기준 기록.

---

### S16. Senior 측 Wi-Fi 단절 (반대 방향)

**1:N displace 정책 영향**: **간접적**. Senior Wi-Fi 단절 시 모든 Family peer 가 동시 영향 → 각자 ICE restart 시도. 1:N 환경에서 Senior 복구 후 peer 들이 각각 복구되는 양상은 [R6](#r6-1n--senior-wi-fi-off) 에서 별도 검증.

**가설**: Family 가 아닌 Senior 가 끊긴 경우, Family PC 도 keepalive timeout 으로 DISCONNECTED 진입 → grace 4s 후 ICE restart 트리거. Senior 가 RTDB 재연결되면 ICE restart offer 받아 answer 회신 → 복구.

**준비**: S1 과 동일 (Family 모니터링 CONNECTED).

**실행**: Senior Wi-Fi off `N`초 → on (`SENIOR_OFF_S` 변수).

**기대 결과**:
- Senior 단절 짧은 경우 (1~4s): `seniorDisconnect` 마커 → Family grace + ICE restart 자연 진입 → ice_restored 복구
- Senior 단절 긴 경우 (60s+): flap window 60s 초과 → iceFailed 자동 종결

**검증 코드**: Senior `MonitoringSession` 의 `onIceConnectionChange` 는 비어있음 → ICE restart 트리거는 Family 측 책임. Senior 측은 수신만 (`listenForIceRestartOffer` / `handleIceRestartOffer` / `sendIceRestartAnswer`).

**통과 기준**: 짧은 단절 (1~4s) ICE restart 로 복구, 긴 단절 (60s+) 깨끗한 iceFailed 종결.

#### 본 의도와 구현 이력

[Senior `kep_wifi_suspend_presence.md` §"연관 이슈 1"](../../Senior/docs/kep_wifi_suspend_presence.md) — KEP MTK WiFi 자발적 2~3초 drop 떠받치기가 ICE restart 도입 본 의도.

| 시점 | 항목 | 비고 |
|---|---|---|
| 원 명세 (~2026-04 이전) | 가설 정의 | "Family ICE restart 로 복구". 단 Senior `onDisconnect` 정책 (즉시 노드 삭제) 와 Family grace 미구현으로 실 동작 안 됨 |
| 2026-04-28 자동화 시도 1 | 실측 부합 안 함 | 8 stages 모두 `remoteEnded` 즉시 종결 — Senior `onDisconnect` 가 너무 빨리 노드 삭제하여 ICE restart 발화 못함 |
| 2026-04-28 fix | Senior + Family 양쪽 변경 | Senior `onDisconnect` updateChildren (`endReason="seniorDisconnect"`) + 자기 결과 무시 + 복구 / Family `_callEndSub` 의 seniorDisconnect 분기 + grace timer 15s |
| 2026-04-28 자동화 시도 2 | 1~4s PASS, 70s PASS | 본 의도 (KEP WiFi flap 떠받치기) 실현. 5~15s 구간은 별도 한계 (ICE restart 1~2회만 시도) — 추가 분석 필요 |

명세 자체는 처음부터 옳았고, 그동안 코드가 미완성이었던 것. 2026-04-28 fix 로 본 의도 달성.

**상세 결과**: [ICE_restart_test_result.md §S16](ICE_restart_test_result.md#s16--senior-측-wi-fi-단절)

---

### S17. RTDB 쓰기 타임아웃 (오프라인 가드)

**1:N displace 정책 영향**: 없음 (오프라인 가드는 단일 Family 기기의 RTDB write 처리, multi-Family 와 무관).

**가설**: ICE restart offer 쓰기 자체가 오프라인으로 hang 되면 `writeOrTimeout(3s) + onTimeoutCleanup` 으로 정리.

**준비**: S2 직전 상태.

**실행**: Family Wi-Fi off → 6초 후 restart 트리거 → **Wi-Fi 계속 off 유지**.

**기대 결과**:
- `sendIceRestartOffer` 의 RTDB write 가 3초 내 ACK 못 받음 → timeout 발생
- onTimeoutCleanup 으로 큐에 쌓인 `iceRestartOffer` 노드 즉시 remove → 복구 시 flush 방지
- 이후 answer 미수신 → 10초 후 재시도

**검증 로그**: `writeOrTimeout` 관련 로그 (network_guard.dart 출력)

**통과 기준**: 노드 잔존 0개. 다음 발신 시 stale offer 자동 적용 안됨.

---

## 4. 회귀 테스트 (과거 이슈 재발 방지)

### R1. 좀비 peer 방지 (c33d770)

**과거 이슈**: cleanupCall 즉시 remove → Senior 가 status=ended 못 받고 zombie 상태로 남음 → 다음 발신 거부 (`remoteBusy`).

**테스트**:
1. 영상통화 발신 → Senior 수락 → 5초 통화
2. Family 종료
3. **즉시** (1초 내) 다시 발신 시도
4. 같은 절차를 5회 반복

**통과 기준**: 5/5 모두 정상 발신, Senior 측 `remoteBusy` 거부 0건. cleanupCall 의 10초 fire-and-forget delay 가 제대로 동작.

---

### R2. answered 가 ended 를 LWW 덮어쓰기 방지 (Senior transaction)

**과거 이슈**: Family 가 hangUp 으로 status=ended 쓴 직후 Senior 가 sendAnswer 로 status=answered 덮어씀 → Senior 자신의 listener 가 ended 못 받음.

**테스트**:
1. Family 통화 발신
2. Senior 가 수락 누르기 **직전에** Family 가 종료 버튼 (race 유발)
3. 10회 반복

**통과 기준**: Senior 가 `ended` 정상 수신 → cleanupCall 정상. RTDB `status` 가 `answered` 로 끝나는 케이스 0건. (Senior 의 `runTransaction(check ended → abort)` 가드 동작)

---

### R3. 1:N × 1:1 정책 — displace 절차 실측

**재정의 (2026-04-24)**: 기존 R3 은 버튼 활성화만 검증했으나, 현재는 Senior 가 call 수락 시 기존 monitor peer 들을 `endReason="otherCallStarted"` 로 displace 하는 전체 경로가 운영 중. 본 회귀는 **displace 가 올바르게 발동하고 Family A 가 명시적 UX(다이얼로그) 로 종결되는지** 실측 검증.

**관련 구현**:
- Senior: `MonitoringSession.handleUpgradeRequest()` → `displaceOtherMonitors()` ([Senior/app/src/main/java/com/seniorcare/senior/call/MonitoringSession.kt#L820](../../Senior/app/src/main/java/com/seniorcare/senior/call/MonitoringSession.kt#L820))
- Family 매핑: `webrtc_service.dart:634-641` `_mapEndReason("otherCallStarted") → TerminateReason.endedByOtherCall`
- Family UX: `monitoring_screen.dart:395-399` — "모니터링이 종료되었습니다 / 가족이 영상통화를 시작하여 모니터링이 종료되었습니다." 다이얼로그 → pop
- Family 버튼 가드: `family_detail_screen.dart:148-149` `_isInCall = active && type=='call'`

**준비**:
- Family A (`R3CR700SEKP`) 와 Family B (사용자 2번째 기기) 각각 로그인, 같은 가족 소속
- Senior (`KEP2024120921`) 1대
- 시작 전 양쪽 `adb logcat -c`

**실행**:
1. Family A: 모니터링 시작 → CONNECTED 확인
2. Family B: `family_detail_screen` → "영상통화" 버튼 → call 발신
3. Senior: 수동 수락 (Phase 2 승인)
4. Family A 상태 관찰

**기대 결과 — Family A (displace 당함)**:
- `listenForCallEnd` 에서 `endReason="otherCallStarted"` 수신
- FSM: `connected → terminating (hangup:endedByOtherCall) → terminated (cleanup_done)`
- 다이얼로그: "모니터링이 종료되었습니다 / 가족이 영상통화를 시작하여 모니터링이 종료되었습니다."
- 확인 버튼 → MonitoringScreen pop
- (순간적으로) `_callActiveByOther=true` → "통화로 전환" 버튼 숨김 관찰

**기대 결과 — Family B (call 발신자)**:
- `callType="call"` 정상 CONNECTED (양방향 영상/음성)

**기대 결과 — Senior**:
- `MonitoringSession: displace: 다른 monitor peer 1개 종료` 로그
- `rejectCall(..., OTHER_CALL_STARTED)` 호출
- `stopPeer(skipSignalingHangup=true, skipCallStatusUpdate=true)` 로 A peer 로컬 정리
- `leak check peers=1` (B call peer 만 남음)

**통과 기준**:
- Family A: `endedByOtherCall` reason 으로 FSM 종결 + 다이얼로그 정상 표시
- Family B: call 정상 진행
- Senior: displace 로그 + RTDB `/calls/{cidA}/endReason="otherCallStarted"` 기록
- 이후 Family B 종료 시 Senior peers 리크 0 (`peers=0`)

**edge case**: Family A 가 Wi-Fi off 상태에서 displace 이벤트가 발생하면 RTDB endReason write 가 큐잉 → 복구 시 flush. 이 경우 Family A 는 Wi-Fi 복구 후 다이얼로그를 뒤늦게 받음. 실측 기록 시 타이밍 명시.

---

### R4. 검은 화면 0개 (FSM 재설계 c2e8bd6)

**과거 이슈**: ICE restart 도중 화면 전환/오버레이 표시 race 로 검은 화면.

**테스트**:
- S2, S6, S15 시나리오 수행 시 검은 화면 발생 여부 시각 확인.

**통과 기준**: 어떤 phase 전이에서도 검은 화면 0개. `Positioned.fill` 누락 등 layout collapse 없음.

---

## 5. 1:N 환경 회귀 테스트 (displace 정책 도입 후)

> S1~S17 은 1:1 (Senior 1대 × Family 1대) 기준. 이 §5 는 **Family N대** 환경에서만 발생하는 동작을 별도로 검증.
>
> S1~S17 매 시나리오마다 **"영향받는 Family 만 그 경로를 따르고 다른 Family monitor 들은 영향받지 않는다"** 는 단순 독립성은 자명하므로, 본 §5 는 **단순 독립성을 넘어서 1:N 에서만 노출되는 새 동작** 만 골라 시나리오화한다.

**공통 준비**: Family A (`R3CR700SEKP`) + Family B (2번째 기기) 같은 가족 소속 로그인. Senior (`KEP2024120921`) 1대. 시작 전 양쪽 logcat 클리어.

**카테고리 (3계층)**:
- **§5.1 정책 신규 시나리오 (R5~R8)** — displace / capacity / busy 정책 자체의 검증 (1:1 에 대응 시나리오 없음)
- **§5.2 1:1 시나리오의 1:N 변형 (N3·N7·N11)** — 기존 S 시나리오 중 1:N 에서 새 동작이 추가로 노출되는 것
- **§5.3 1:N 고유 timing/overlap 케이스 (NX1~NX5)** — 두 Family 의 상태 전이가 시간 겹침으로 race 가 발생하는 케이스

---

### §5.1 정책 신규 시나리오

#### R5. Family A 단독 Wi-Fi off (multi-peer 독립성 베이스)

**가설**: Senior 의 monitor peer 들은 서로 독립. 한 Family 의 네트워크 장애가 다른 Family 세션에 영향을 주지 않아야 한다.

**준비**: Family A, Family B 모두 모니터링 CONNECTED.

**실행**:
1. Family A 만 Wi-Fi off 6초 → on (S2 시나리오)
2. Family B 는 계속 Wi-Fi 유지, monitor 그대로

**기대 결과 — Family A**: S2 와 동일 (grace 4s 후 ICE restart → `ice_restored`)

**기대 결과 — Family B**: 아무 변화 없음 (PC CONNECTED 유지, FSM 전이 없음)

**기대 결과 — Senior**: Family A peer 만 RESTARTING → CONNECTED 전이, Family B peer 는 CONNECTED 유지. peers 카운터 유지.

**통과 기준**: 로그상 A 의 restart 이벤트가 B 의 peer 상태에 영향 주지 않음 (B 측 `connectionState` 변경 로그 0건).

> R5 는 **§5.2 / §5.3 모든 시나리오의 전제 검증** (peer 독립성). R5 가 실패하면 그 위 시나리오들은 모두 무효.

#### R6. Senior Wi-Fi off (1:N 대칭 처리)

**가설**: Senior Wi-Fi 단절 시 모든 Family peer 가 동시 DISCONNECTED → 각자 ICE restart 시도. Senior 복구 시 모두 동시 복구 or 동시 iceFailed 종결.

**준비**: Family A, Family B 모두 모니터링 CONNECTED. Family A/B 는 Wi-Fi 유지.

**실행**:
1. Senior Wi-Fi off → 10초 대기 → on
2. 또는 Senior Wi-Fi off 유지 (60s+) → 양쪽 모두 iceFailed 종결 확인

**기대 결과 (Senior 복구)**:
- A/B 모두 grace 4s 후 restart 트리거
- A/B 각각 독립적으로 Senior 와 SDP 재교환
- 둘 다 `ice_restored` 로 복귀

**기대 결과 (Senior 영구 단절)**:
- A/B 모두 iceFailed 종결 (flap 60s or 한도 5 중 먼저)
- Senior 부팅 후 RTDB 잔존 노드 0개

**통과 기준**: A, B 결과가 **대칭** (동일 reason, 동일 FSM 경로). 한쪽만 복구되고 한쪽만 iceFailed 되는 비대칭 0건.

#### R7. Family A iceFailed 중 Family B 영향 없음

**가설**: 한 monitor peer 가 iceFailed 로 종결되어도 같은 Senior 의 다른 peer 는 정상 유지.

**준비**: Family A, Family B 모두 모니터링 CONNECTED.

**실행**:
1. Family A Wi-Fi **영구 off** (S4 시나리오) — 60초+ 대기
2. Family B 는 그대로 Wi-Fi 유지

**기대 결과 — Family A**: S4 와 동일 (iceFailed 종결 → MonitoringScreen pop)

**기대 결과 — Family B**: monitor 유지 (연결 상태 변화 없음)

**기대 결과 — Senior**: A peer 정리 (STOP_DELAY 15s 만료 → ENDED), B peer 유지. `peers=1 (Family B)` 확인.

**통과 기준**: A 가 iceFailed 로 사라진 뒤에도 B 가 영상 수신 계속. Senior leak check `peers=1`.

#### R8. Call 중 다른 Family 가 call 발신 (remoteBusy)

**가설**: Senior 가 call 중일 때 다른 Family 가 call 발신하면 `endReason="remoteBusy"` 로 즉시 거절.

**준비**: Family A 영상통화 진행 중 (Senior 수락됨, CONNECTED).

**실행**:
1. Family B 에서 "영상통화" 버튼 → call 발신
2. Family B 상태 관찰

**기대 결과 — Family B**:
- `callType="call"` 발신
- Senior 거절 → `endReason="remoteBusy"` 수신
- `_mapEndReason("remoteBusy") → TerminateReason.remoteBusy`
- 다이얼로그: "{Senior 이름}이(가) 통화 중입니다 / 다른 가족이 통화 중입니다. 잠시 후 다시 시도해주세요." → pop

**기대 결과 — Family A**: 통화 유지 (영향 없음)

**기대 결과 — Senior**: 기존 A call peer 유지, B 의 call 요청은 `rejectCall(..., REMOTE_BUSY)` 로 거절.

**통과 기준**: Family B 의 call 시도가 `remoteBusy` 다이얼로그로 깔끔하게 종결, Family A 세션 영향 없음.

---

### §5.2 1:1 시나리오의 1:N 변형

> 1:N 에서 새 동작이 추가로 노출되는 것만 골랐음. 다른 S 시나리오 (S1·S5·S6·S8·S9·S12·S13·S14·S15·S17) 는 단순 독립성으로 충분 (R5 통과 시 자동 보장).

#### N3. S3 (LTE 핸드오프) 1:N — A 만 LTE 전환

**가설**: A 가 Wi-Fi → LTE 핸드오프로 새 candidate (TURN relay) 로 복구. B 는 동일 Wi-Fi 유지. **Senior 가 한 peer 는 LTE relay, 다른 peer 는 Wi-Fi p2p 라는 서로 다른 transport 를 동시에 들고 있을 수 있는지** 검증.

**준비**: A 는 Wi-Fi + 모바일 데이터 둘 다 활성, B 는 Wi-Fi 만 활성. A/B 모두 모니터링 CONNECTED.

**실행**:
1. A 만 Wi-Fi off (모바일 데이터만 남김)
2. 5~10초 대기

**기대 결과**:
- A: S3 와 동일 (LTE candidate 로 ICE restart, 대부분 TURN relay)
- B: 영상 끊김 없음, ICE 상태 변화 없음
- Senior: A peer 의 transport 만 LTE relay 로 전환, B peer 는 LAN/Wi-Fi 그대로. `peers=2` 유지.

**통과 기준**: A 복구 (해상도 자동 다운 가능), B 영향 0. Senior 의 ICE candidate pool 이 peer 별로 격리되는지 확인.

#### N7. S7 (Senior 응답 지연) 1:N — Senior CPU 부하

**가설**: Senior CPU/GC pause 또는 인위적 sleep 으로 응답 지연 시 모든 Family peer 의 ICE restart answer 가 동시 timeout. Senior 의 multi-peer answer 처리가 직렬이면 두 번째 peer 는 더 늦어짐.

**준비**: A, B 모두 모니터링 CONNECTED.

**실행**:
1. A, B 동시에 Wi-Fi off → 6초 대기 → on (둘 다 restart 트리거)
2. Senior breakpoint 또는 인위적 부하 (예: Android Studio 디버거에서 12s 멈춤) 로 응답 지연
3. Senior 정상화

**기대 결과**:
- A, B 둘 다 attempt=2 로 재전송 (10s timeout)
- Senior 가 늦게 보낸 첫 answer 들 (A's, B's) 은 stale → 양측 모두 무시 (`signalingState == Stable` 가드)
- 두 번째 시도 정상 → A, B 모두 ice_restored

**통과 기준**: A, B 모두 복구. 한쪽만 복구되고 한쪽만 iceFailed 되는 비대칭 0건.

**검증 포인트**: Senior `MonitoringSession` 의 IO scope 가 peer 별로 독립인지. peer 간 mutex 가 있다면 직렬 처리되어 두 번째 peer 가 timeout 임박할 수 있음.

#### N11. S11 (upgrade 중 ICE failure) 1:N — A upgrade 실패 후 잔존

**가설**: A 가 monitor → call 업그레이드 시도 중 ICE failure 로 upgrade 실패 → A 가 monitor 상태로 잔존 (또는 종결) → 이때 B 가 영상통화를 발신하면 displace 정책이 정상 작동.

**준비**: A, B 모두 모니터링 CONNECTED.

**실행**:
1. A: "통화로 전환" 버튼 → upgrade 시작
2. upgrade renegotiation 진행 중 A Wi-Fi off 6~10s
3. ICE failure 로 A 의 upgrade 처리 결과 관찰 (monitor 복귀 vs iceFailed 종결)
4. A 가 monitor 잔존이면 → B "영상통화" → Senior 수락

**기대 결과**:
- A: upgrade fail 후 FSM 가 `upgrading → reconnecting → connected (callType=monitor)` 또는 `terminating(iceFailed)` 중 하나로 깨끗하게 결정
- A 가 monitor 잔존 시 B 의 call 수락 시점에 displace 발동 → A 가 `endedByOtherCall` 로 종결 (R3 와 동일 경로)

**통과 기준**:
- A 의 upgrade fail 경로 정상 (FSM stuck / `upgrading` 잔존 0)
- B 의 call 시 displace 정상 동작 (A peer 의 callType 이 잘못 `call` 로 박혀있어 displace 가 누락되지 않음)

**검증 포인트**: Senior `handleUpgradeRequest` 가 upgrade 실패 시 peer 의 `callType` 을 `monitor` 로 되돌리는지 확인. 만약 upgrade-pending 상태로 stuck 되면 displace 분류가 잘못되어 R3 시나리오가 깨질 수 있음.

---

### §5.3 1:N 고유 timing/overlap 케이스

> 1:1 에서는 절대 발생할 수 없고, 두 Family 의 상태 전이가 시간 겹침으로만 노출되는 race 케이스.

#### NX1. A grace 중 B 신규 합류 → A 복구

**가설**: A 가 disconnect → grace 4s 진입 → 이 사이 B 가 신규 monitor 시도 → A 복구 시 정상 ICE restart. Senior 가 grace 상태의 A peer 를 유지하면서 B peer 를 새로 추가할 수 있어야 함.

**준비**: A 만 모니터링 CONNECTED. B 는 `family_detail_screen` 대기.

**실행**:
1. A Wi-Fi off (grace 진입)
2. **2초 후** B "모니터링" 버튼 → 신규 monitor 시도
3. **5초 후** A Wi-Fi on (grace 4s 초과 → ICE restart 트리거됨)

**기대 결과**:
- A: grace 동안 reconnecting → ICE restart → 복구 (`ice_restored`)
- B: 신규 monitor 정상 CONNECTED
- Senior: A peer (RESTARTING) + B peer (CONNECTED) 동시 보유, `peers=2`

**통과 기준**: A 복구, B 정상 합류. Senior peer slot 손상 없음 (B 의 신규 추가가 A peer 를 잘못 정리하지 않음).

**edge case**: A 가 grace 중일 때 Senior 의 A peer 는 ENDED 가 아닌 RESTARTING 상태여야 함. STOP_DELAY 15s 만료 전에 복구해야 자동 종결되지 않음.

#### NX2. A iceFailed 직후 재 monitor → B 이미 진행 중

**가설**: A 가 iceFailed 로 종결 → A 가 즉시 모니터링 재시도 → B 가 이미 monitor 중 → A 가 정상 합류.

**준비**: A, B 모두 모니터링 CONNECTED.

**실행**:
1. A Wi-Fi 영구 off → 60s+ 대기 → A iceFailed 종결, MonitoringScreen pop
2. B 는 그대로 monitor 유지
3. A Wi-Fi on → "모니터링" 버튼 → 재 monitor

**기대 결과**:
- A: 신규 callId 발급, 새 SDP 교환, CONNECTED
- B: 영향 없음
- Senior: 잔존 A peer 정리 후 새 A peer 추가, `peers=2` (A new + B)

**통과 기준**: A 정상 합류. Senior 잔존 peer leak 0.

**검증 포인트**: Senior 의 `STOP_DELAY 15s` 정리가 끝난 후 재 monitor 인지, 정리 도중 인지에 따라 동작 다름. 정리 도중 재 monitor 시 callId 충돌 (동일 family/device 로 ENDING + NEW peer 동시 존재) 발생 가능성 확인.

#### NX3. A·B 동시 Wi-Fi off → 병렬 ICE restart

**가설**: A, B 가 동시에 Wi-Fi off → 동시에 grace 진입 → 동시에 ICE restart 트리거. Senior 의 multi-peer queue 가 두 offer 를 병렬 처리.

**준비**: A, B 모두 모니터링 CONNECTED.

**실행**:
1. A, B 동시 Wi-Fi off (스크립트로 병렬 `adb -s <A> shell cmd wifi set-wifi-enabled disabled & adb -s <B> shell cmd wifi set-wifi-enabled disabled`)
2. 6초 대기
3. 동시에 Wi-Fi on

**기대 결과**:
- A, B 모두 grace → restart offer 동시 전송
- Senior 가 A's offer, B's offer 를 각각 처리 → 각 peer answer 전송
- A, B 모두 `ice_restored`

**통과 기준**: 양측 모두 복구. Senior IO scope 가 peer 간 간섭 없음.

**검증 포인트**: Senior 로그에서 A, B 의 offer 처리 시간 차가 작은지 (±100ms) 확인. 직렬 처리되면 두 번째 peer 가 늦어짐 → N7 와 묶어 보면 Senior 처리 모델이 보임.

#### NX4. 4번째 monitor → capacityExceeded

**가설**: Senior 의 `MAX_PEERS=3` 상한 도달 시 4번째 peer 는 `capacityExceeded` 로 즉시 거절.

**준비**: A, B, C (3대) 모두 모니터링 CONNECTED. `peers=3`.

**실행**:
1. D (4번째 Family 기기) "모니터링" 버튼 → monitor 시도
2. D 상태 관찰

**기대 결과**:
- D: `endReason="capacityExceeded"` 수신 → 다이얼로그 → pop
- A, B, C: 영향 없음

**통과 기준**: D 거절, A/B/C 유지. Senior `peers=3` 상한 유지.

**전제**: Family 기기 4대 필요. **현재 사용자 보유 2대만 있으면 보류** — Senior 코드의 `MAX_PEERS=3` 상수를 임시로 2 로 낮춰서 3번째 거절 케이스로 검증 가능 (코드 변경 후 복원 필요).

#### NX5. 동시 upgrade race

**가설**: A monitor + B monitor 상태에서 A 와 B 가 거의 동시에 영상통화 발신 → Senior 의 `setSeniorAccepted` transaction 이 race-safe 하여 한쪽만 성공, 다른 쪽은 명시적 거절.

**준비**: A, B 모두 모니터링 CONNECTED.

**실행**:
1. A, B 거의 동시에 (사용자 두 손으로 동시 클릭, 또는 ADB tap 스크립트) "영상통화" 버튼
2. Senior 수락 (Phase 2 다이얼로그)

**기대 결과 (시나리오 1: A 가 먼저 도달)**:
- Senior 가 A 의 call 만 incoming 으로 표시 → 사용자가 수락 → A 양방향 통화 CONNECTED
- B 는 `endReason="remoteBusy"` 수신 → 다이얼로그 → pop
- 이후 displace 발동으로 다른 monitor (만약 있으면) 종결

**기대 결과 (시나리오 2: 두 incoming 동시 도달)**:
- Senior UI 정책에 따라: 최후 도달 call 만 표시, 또는 큐잉 표시
- 거절된 쪽은 `remoteBusy` 또는 `cancelled` 다이얼로그

**통과 기준**: 두 발신이 충돌 없이 한쪽만 성공, 다른 쪽 명시적 reason 으로 종결. RTDB `/calls/{cidA}/status` 와 `/calls/{cidB}/status` 가 일관 (둘 다 `answered` 가 아님).

**검증 포인트**: Senior `SignalingClient.listenForIncomingCalls` + `setSeniorAccepted` transaction 의 race 처리. `runTransaction` 의 abort 케이스 확인.

---

## 6. 기록 양식

각 시나리오 실행 결과를 아래 표로 기록:

| 시나리오 | 일시 | 디바이스 | 결과 | attempts | 복구 시간 | 비고 |
|---|---|---|---|---|---|---|
| S1 | 2026-04-17 14:00 | G991N | PASS | 0 | 0.8s | 자동 복구 |
| S2 | | | | | | |
| ... | | | | | | |

---

## 7. 알려진 한계 / 미검증

- **TURN 서버 의존**: 대칭 NAT 환경에서 STUN p2p 실패 시 relay 필요. 현재 ICE 서버 설정 (`_iceServers`) 의 TURN credential 만료 여부 확인 안됨.
- **iOS 미테스트**: 본 시트는 Android 기준. iOS (Sol iPhone) 에서 백그라운드 동작 별도 검증 필요.
- **flap window 60초**: 실제 모바일 환경에서 너무 짧을 가능성. 사용자 피드백 후 조정.
- **answer timeout 10초**: Senior 부하 상황에서 짧을 수 있음. 실측 후 조정.
- **Senior 자체 트리거 부재**: 현재 Family 만 트리거. Senior 측 단절 시 Family DISCONNECTED 까지 시간 소요. 양측 트리거 검토 여지.
- **MAX_PEERS=3 상한**: Senior 는 동시 monitor peer 최대 3개. 4번째 연결 시도는 `endReason="capacityExceeded"` 로 거절. 실제 부하 기기에서 상한 적정성 검증 필요.
- **1:N 회귀 (§5 전체)**: 2대 Family 기기 확보 시 실행 예정. 현재 미검증. NX4 (4대 동시) 는 3대 필요 — 보유 미달 시 `MAX_PEERS` 임시 하향으로 우회 검증 가능.
- **N7 / NX3 의 Senior 처리 모델 미상**: Senior `MonitoringSession` 의 IO scope 가 peer 별 독립인지 (병렬) vs 전역 mutex 인지 (직렬) 코드 추적 필요. 직렬이면 multi-peer 환경에서 timeout 임박 케이스 상존.
