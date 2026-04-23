# 영상통화 / 모니터링 시나리오 다이어그램

Family ↔ Senior WebRTC 통화 · 모니터링 · ICE restart 전 시나리오.

> 시그널링 채널: Firebase RTDB `/calls/{callId}/`
> 구현 경로: [webrtc_service.dart](../lib/services/call/webrtc_service.dart), [signaling_service.dart](../lib/services/call/signaling_service.dart)

---

## 1. FSM 전체 상태 다이어그램

```mermaid
%%{init: {'theme':'default', 'flowchart': {'curve':'basis'}}}%%
stateDiagram-v2
    [*] --> idle
    idle --> connecting: startCall / startMonitoring
    connecting --> connected: answer 수신 (Phase1, 5s)
    connecting --> terminating: Phase1 timeout
    connected --> upgrading: upgradeToCall (monitor→call)
    upgrading --> connected: renegotiateAnswer 수신
    upgrading --> connected: 실패시 복귀
    connected --> reconnecting: DISCONNECTED(4s) / FAILED
    reconnecting --> connected: iceRestartAnswer + 5s 안정
    reconnecting --> terminating: iceFailed
    connected --> terminating: hangUp / remote ended
    upgrading --> terminating: hangUp
    terminating --> terminated: cleanup 완료
    terminated --> [*]
```

---

## 2. 양방향 통화 발신 — Phase 1 (벨 울림)

Senior 앱이 offer를 받고 answer를 돌려주는 단계. 5초 타임아웃.

```mermaid
%%{init: {'sequence': {'actorMargin':90, 'messageMargin':45, 'noteMargin':15, 'boxMargin':15, 'width':180}}}%%
sequenceDiagram
    autonumber
    actor U as Family User
    participant F as Family App
    participant R as RTDB
    participant S as Senior App

    U->>F: 통화 버튼
    F->>F: getUserMedia + PC 생성 (SendRecv)
    F->>F: createOffer + setLocalDescription
    F->>R: offer, status=ringing, callType=call, seniorAccepted=false
    F->>R: onDisconnect(cleanupCall) 등록
    R->>S: onChildAdded
    S->>S: answerCall + setRemoteDescription
    S->>R: answer, status=connected
    R->>F: onValue(answer)
    F->>F: setRemoteDescription
    F->>F: FSM connecting → connected
    Note over F,S: 이후 ICE candidate 양측 교환<br/>(callerCandidates / calleeCandidates)
```

Phase 1 timeout → `unreachable` (Senior 미실행/오프라인).

---

## 3. 양방향 통화 발신 — Phase 2 (실제 수락)

Senior 사용자의 얼굴감지 또는 수동 수락. 20초 타임아웃.

```mermaid
%%{init: {'sequence': {'actorMargin':90, 'messageMargin':45, 'noteMargin':15, 'width':180}}}%%
sequenceDiagram
    autonumber
    actor SU as Senior User
    participant S as Senior App
    participant R as RTDB
    participant F as Family App
    actor U as Family User

    Note over F,S: Phase 1 완료 (미디어 연결됨)
    SU->>S: 얼굴감지 or 수동 수락
    S->>R: seniorAccepted = true
    R->>F: onValue(seniorAccepted)
    F->>F: upgradeToCall (이미 SendRecv면 no-op)
    Note over F,S: 미디어 양방향 전송

    U->>F: 종료 버튼
    F->>F: hangUp (reason=normal)
    F->>R: status=ended, endReason=normal
    F->>F: 10s 후 노드 delete
    F->>F: FSM terminated → pop
```

Phase 2 timeout → `noAcceptance` (벨은 울렸으나 응답 없음).

---

## 4. CCTV 모니터링 (callType=monitor)

Family는 로컬 미디어 없이 Senior 영상만 수신 (RecvOnly).

```mermaid
%%{init: {'sequence': {'actorMargin':90, 'messageMargin':45, 'width':180}}}%%
sequenceDiagram
    autonumber
    actor U as Family User
    participant F as Family App
    participant R as RTDB
    participant S as Senior App

    U->>F: 모니터링 버튼
    F->>F: PC 생성 (로컬 미디어 없음, RecvOnly)
    F->>F: createOffer
    F->>R: offer, status=ringing, callType=monitor
    R->>S: onChildAdded
    S->>S: PC 생성 (SendOnly) + 카메라 캡처
    S->>R: answer, status=connected
    R->>F: onValue(answer)
    F->>F: FSM connecting → connected
    Note over F,S: Senior → Family 단방향 영상/음성
```

---

## 5. 모니터링 → 통화 전환 (upgradeToCall)

RecvOnly 상태에서 사용자가 "통화 전환" 버튼 누르면 renegotiation 수행.

```mermaid
%%{init: {'sequence': {'actorMargin':90, 'messageMargin':45, 'width':180}}}%%
sequenceDiagram
    autonumber
    actor U as Family User
    participant F as Family App
    participant R as RTDB
    participant S as Senior App

    Note over F,S: 모니터링 중 (connected, RecvOnly)
    U->>F: 통화로 전환 버튼
    F->>F: FSM connected → upgrading
    F->>F: getUserMedia + replaceTrack
    F->>F: Transceiver RecvOnly → SendRecv
    F->>F: createOffer (renegotiation)
    F->>R: renegotiateOffer, upgradeRequest=call
    R->>S: onValue
    S->>S: setRemoteDescription + createAnswer
    S->>R: renegotiateAnswer
    R->>F: onValue
    F->>F: setRemoteDescription
    F->>F: FSM upgrading → connected
    Note over F,S: 이제 양방향 통화
```

실패 시 monitor 상태로 복귀.

---

## 6. ICE Restart — 정상 복구

네트워크 전환(Wi-Fi↔LTE), NAT rebinding, 일시 단절 시 자동 복구.

```mermaid
%%{init: {'sequence': {'actorMargin':90, 'messageMargin':50, 'width':200}}}%%
sequenceDiagram
    autonumber
    participant PC as RTCPeerConnection
    participant F as Family (WebRtcService)
    participant R as RTDB
    participant S as Senior

    Note over PC,F: 정상 상태 (connected)
    PC->>F: connectionState = DISCONNECTED
    F->>F: grace 타이머 시작 (4s)
    Note over F: 4s 내 CONNECTED 복귀 시<br/>restart 불필요 — 타이머 취소
    F->>F: grace 만료 → _triggerIceRestart
    F->>F: 한도 체크 (flap<60s, attempts<5)
    F->>F: FSM connected → reconnecting
    F->>PC: restartIce + createOffer
    F->>R: iceRestartOffer (write 3s timeout)
    R->>S: onValue
    S->>S: setRemoteDescription + createAnswer
    S->>R: iceRestartAnswer
    R->>F: onValue
    F->>PC: setRemoteDescription
    Note over F,S: 새 ICE candidate 재교환
    PC->>F: connectionState = CONNECTED
    F->>F: FSM reconnecting → connected
    F->>F: 5s 안정 후 attempts=0 리셋
```

**FAILED 상태는 grace 없이 즉시 restart 트리거**.

---

## 7. ICE Restart — 한도 초과 / 실패

answer 미수신 자동 재시도, 최종 실패 시 iceFailed 종료.

```mermaid
%%{init: {'sequence': {'actorMargin':90, 'messageMargin':50, 'width':200}}}%%
sequenceDiagram
    autonumber
    participant PC as RTCPeerConnection
    participant F as Family
    participant R as RTDB

    Note over PC,F: reconnecting 상태, restart 시도 중
    F->>R: iceRestartOffer 전송
    Note over F: answer 대기 (10s)

    alt 10s 내 answer 미수신
        F->>F: _iceRestartInProgress = false
        Note over F: 여전히 DISCONNECTED/FAILED면<br/>_triggerIceRestart 재귀 호출
    else 한도 초과 (attempts≥5 or flap>60s)
        F->>F: hangUp (reason=iceFailed)
        F->>R: status=ended, endReason=iceFailed
        F->>F: FSM terminating → terminated
    end
```

구현: [webrtc_service.dart:448-513](../lib/services/call/webrtc_service.dart#L448-L513)

---

## 8. 비정상 종료 — 앱 크래시 / 네트워크 끊김

Firebase onDisconnect 핸들러가 서버 측에서 자동 cleanup.

```mermaid
%%{init: {'sequence': {'actorMargin':90, 'messageMargin':50, 'width':200}}}%%
sequenceDiagram
    autonumber
    participant F as Family App
    participant R as RTDB (Firebase)
    participant S as Senior App

    F->>R: createCall + onDisconnect(cleanupCall) 등록
    Note over F: 앱 크래시 / 강제 종료 / 네트워크 단절
    R->>R: 연결 끊김 감지 → /calls/{callId} 자동 삭제
    R->>S: onValue(null) / onChildRemoved
    S->>S: 로컬 cleanup + UI pop
```

---

## 9. 비정상 종료 — Senior 측 종료 감지

Family가 Senior의 종료 이벤트를 감지하고 적절한 이유로 매핑.

```mermaid
%%{init: {'sequence': {'actorMargin':90, 'messageMargin':50, 'width':200}}}%%
sequenceDiagram
    autonumber
    participant S as Senior App
    participant R as RTDB
    participant F as Family App

    Note over S: 앱 종료 / 다른 통화 / 네트워크 끊김
    S->>R: status=ended (± endReason)
    R->>F: listenForCallEnd 이벤트
    alt endReason 없음
        F->>F: reason = remoteEnded
    else endReason = remoteBusy
        F->>F: reason = remoteBusy
    else endReason = otherCallStarted
        F->>F: reason = endedByOtherCall
    end
    F->>F: hangUp + UI pop
```

---

## 10. 종료 사유(endReason) 매트릭스

| endReason | 트리거 | FSM 경유 | UI 메시지 |
| --------- | ------ | -------- | --------- |
| `normal` | 사용자 hangUp | terminating | 통화 종료 |
| `unreachable` | Phase 1 timeout (5s) | connecting→terminating | 응답 없음 |
| `noAcceptance` | Phase 2 timeout (20s) | connected→terminating | 수신자가 받지 않음 |
| `iceFailed` | flap>60s or attempts≥5 | reconnecting→terminating | 연결 실패 |
| `remoteEnded` | 원격 status=ended | connected→terminating | 상대방이 종료 |
| `remoteBusy` | Senior 다른 통화 중 | connecting→terminating | 통화 중 |
| `capacityExceeded` | Senior MAX_PEERS 초과 | connecting→terminating | 모니터링 한도 초과 |
| `otherCallStarted` | 모니터링 중 Senior가 call 시작 | connected→terminating | 다른 통화로 전환됨 |

---

## 11. RTDB `/calls/{callId}/` 필드 요약

```text
/calls/{callId}/
├── offer                   SDP offer (Family 작성)
├── answer                  SDP answer (Senior 작성)
├── status                  ringing | connected | ended
├── callType                call | monitor
├── endReason               위 매트릭스 참조
├── targetDeviceId          Senior 기기 ANDROID_ID
├── targetFamilyId          가족 그룹 ID
├── callerUid               Family 사용자 UID
├── callerName              표시 이름
├── createdAt               ServerValue.timestamp
├── seniorAccepted          Phase 2 수락 플래그 (call only)
├── upgradeRequest          call (monitor→call 전환)
├── renegotiateOffer        SDP (upgrade)
├── renegotiateAnswer       SDP (upgrade 응답)
├── iceRestartOffer         SDP (ICE restart)
├── iceRestartAnswer        SDP (ICE restart 응답)
├── callerCandidates/{push} candidate, sdpMid, sdpMLineIndex
└── calleeCandidates/{push} candidate, sdpMid, sdpMLineIndex
```

종료 정리: `status=ended` 기록 후 10초 지연 → 노드 delete.

---

## 12. 타임아웃 상수

| 상수 | 값 | 위치 |
| ---- | -- | ---- |
| Phase 1 (answer 대기) | 5s | `startCall` / `startMonitoring` |
| Phase 2 (seniorAccepted 대기) | 20s | `_listenForSeniorAccepted` |
| DISCONNECTED grace | 4s | `_startDisconnectedGrace` |
| ICE restart answer 대기 | 10s | `_iceRestartAnswerTimeoutMs` |
| ICE restart 한도 | 5회 / 60s window | `_maxIceRestartAttempts` / `_maxFlapWindowMs` |
| 종료 후 노드 정리 | 10s | `hangUp` (fire-and-forget) |
| RTDB write timeout | 3s | `writeOrTimeout` (NetworkGuard) |
