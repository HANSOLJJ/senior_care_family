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

- **Family 앱**: SM-G991N (Galaxy S21, `R3CR700SEKP`) — Wi-Fi/LTE 전환 가능
- **Senior 앱**: SM-T500 (Galaxy Tab A7, `R9TT903QE5V`) — 고정 Wi-Fi
- **Firebase 프로젝트**: `dcom-smart-frame`
- **빌드**: `flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk`
- **로그**: `adb -s R3CR700SEKP logcat -v time *:S flutter:V` (Family)
- **로그**: `adb -s R9TT903QE5V logcat -v time SignalingClient:V WebRTC:V *:S` (Senior)
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

### S10. 양방향 통화 (call) vs 모니터링 (monitor) 동일 동작

**가설**: ICE restart 로직은 callType 무관하게 동작.

**실행**:
- A) 모니터링 시작 → S2 시나리오
- B) 영상통화 시작 → S2 시나리오

**기대 결과**: 두 케이스 모두 동일 로그 패턴, 동일 복구 시간.

**통과 기준**: 양쪽 다 restart 후 영상/음성 복구.

**유의**: monitor 는 음성 없음, call 은 양방향 음성. restart 후 음성 끊김/에코 없는지 들어보기.

---

### S11. 모니터링→통화 업그레이드 도중 ICE failure

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

**가설**: 아직 CONNECTED 도달 전이라면 restart 트리거 대신 발신 자체 실패로 처리.

**준비**: Family 모니터링 시작 직후 (Senior 수락 전 또는 SDP 교환 중).

**실행**: Family Wi-Fi off (5~10초) → on.

**기대 결과**:
- DISCONNECTED 가 발생하지 않을 가능성 높음 (PC 가 NEW/CONNECTING 상태)
- 또는 FAILED 직행 → `_triggerIceRestart` 진입하지만 `_callId==null` 가드는 통과
- restart 시도하나 Senior 측에 first offer 가 아직 도달 못한 상태일 수 있음 → 결과 불분명

**통과 기준**: 발신 실패 시 깨끗한 종결 (`hangUp` 호출, 화면 pop). FSM stuck 없음.

**유의**: 이 시나리오는 동작 정의가 모호함. 실 결과를 기록하고 정책 결정 필요.

---

### S13. 다중 disconnect 동안 중복 트리거 방지

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

**가설**: Firebase RTDB persistence 캐시로 인해 구 answer 가 재발화되더라도 무시.

**준비**: S2 1회 완료.

**실행**: 인위적 재현 어려움 — Family 앱 강제 종료 후 재시작 → 동일 callId 통화에 재참여 시도 (실제로는 callId 가 새로 발급되므로 발생 어려움). 대신 코드 리뷰로 검증.

**검증 코드**:
- Senior `sendIceRestartAnswer` 가 `callRef.child("iceRestartOffer").removeValue()` 선제 호출 (E:\App\Senior\app\src\main\java\com\seniorcare\senior\webrtc\SignalingClient.kt:330)
- Family `_iceRestartAnswerSub` 의 `signalingState == Stable` 체크로 중복 setRemote 거절 (E:\App\Family\lib\services\call\webrtc_service.dart:_registerSignalingListeners)

**통과 기준**: 코드 가드 존재. 실 환경에서 stale answer 로그가 보이면 `WebRTC: ICE restart answer 무시 (stable, 이미 적용됨)` 발생 후 정상.

---

### S15. Family 앱 백그라운드 → foreground 복귀

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

**가설**: Family 가 아닌 Senior 가 끊긴 경우, Family PC 도 DISCONNECTED 진입 → restart 트리거. Senior 도 동시에 자체 트리거?

**준비**: S1 과 동일.

**실행**: Senior Wi-Fi off 6초 → on.

**기대 결과**:
- Family 측 restart 트리거 (offer 전송) → Senior Wi-Fi 복귀 후 offer 수신 → answer 전송
- 또는 Senior 측에서도 별도 메커니즘으로 트리거 시도 (현재 Senior 는 listener 만, 자발적 트리거 없음)

**검증 코드**: Senior `SignalingClient` 에 `pc.restartIce()` 자체 트리거 코드 없음 → Family 가 항상 트리거 주체.

**통과 기준**: Senior 단절도 Family 가 복구.

---

### S17. RTDB 쓰기 타임아웃 (오프라인 가드)

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

### R3. monitor 진행 중에도 다른 가족이 영상통화 가능 (1:N × 1:1)

**과거 이슈**: `_isInCall` 이 `active==true` 만 체크 → monitor 중에도 call 버튼 비활성.

**테스트**:
1. Family A → Senior 모니터링 시작
2. Family B 폰에서 같은 가족 진입
3. Family B 의 "영상통화" 버튼 활성 상태 확인

**통과 기준**: Family B 가 영상통화 발신 가능. (현재 fix: `active && type=='call'` 만 체크)

**유의**: ICE restart 와 직접 관련 없지만 통화 정책의 핵심이라 회귀 테스트 포함.

---

### R4. 검은 화면 0개 (FSM 재설계 c2e8bd6)

**과거 이슈**: ICE restart 도중 화면 전환/오버레이 표시 race 로 검은 화면.

**테스트**:
- S2, S6, S15 시나리오 수행 시 검은 화면 발생 여부 시각 확인.

**통과 기준**: 어떤 phase 전이에서도 검은 화면 0개. `Positioned.fill` 누락 등 layout collapse 없음.

---

## 5. 기록 양식

각 시나리오 실행 결과를 아래 표로 기록:

| 시나리오 | 일시 | 디바이스 | 결과 | attempts | 복구 시간 | 비고 |
|---|---|---|---|---|---|---|
| S1 | 2026-04-17 14:00 | G991N | PASS | 0 | 0.8s | 자동 복구 |
| S2 | | | | | | |
| ... | | | | | | |

---

## 6. 알려진 한계 / 미검증

- **TURN 서버 의존**: 대칭 NAT 환경에서 STUN p2p 실패 시 relay 필요. 현재 ICE 서버 설정 (`_iceServers`) 의 TURN credential 만료 여부 확인 안됨.
- **iOS 미테스트**: 본 시트는 Android 기준. iOS (Sol iPhone) 에서 백그라운드 동작 별도 검증 필요.
- **flap window 60초**: 실제 모바일 환경에서 너무 짧을 가능성. 사용자 피드백 후 조정.
- **answer timeout 10초**: Senior 부하 상황에서 짧을 수 있음. 실측 후 조정.
- **Senior 자체 트리거 부재**: 현재 Family 만 트리거. Senior 측 단절 시 Family DISCONNECTED 까지 시간 소요. 양측 트리거 검토 여지.
