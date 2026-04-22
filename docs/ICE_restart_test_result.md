# ICE Restart 테스트 결과

실제 테스트 실행 로그 + 분석 기록. 시나리오 정의는 [ICE_restart_test.md](ICE_restart_test.md) 참조.

## 테스트 환경

- **Family 앱**: SM-G991N (`R3CR700SEKP`)
- **Senior 앱**: Lenovo M10VSA2 (`KEP2024120921`)
- **빌드**: debug APK
- **로그 경로**: `e:/tmp/ice_test/{family,senior}.log`

---

## 관련 수정 이력

| 수정 | 파일 | 이슈 |
|---|---|---|
| **B fix** (Senior) | `SignalingClient.kt`, `MonitoringSession.kt` | `listenForStatus` 가 노드 삭제(null) 를 "상대방 종료" 로 일괄 해석 → RESTARTING 중 Family onDisconnect 발화 시 ICE restart 기회 상실. 수정: RESTARTING 상태에서는 null 을 무시하고 STOP_DELAY 타이머에 위임. |
| **C fix** (Family) | `signaling_service.dart` | `sendIceRestartOffer` 의 `onTimeoutCleanup: remove()` 가 오프라인 상태에서 hang (실측 7.6s) → `NetworkException` throw 가 10s+ 로 밀림. 수정: `onTimeoutCleanup` 제거. 복구 경로는 Firebase SDK 큐 flush + Senior 선제 삭제(`sendIceRestartAnswer`) + `cleanupCall` 전체 삭제로 일원화. |

---

## S1 — Wi-Fi 일시 단절 (grace 4초 내 복구)

**상태**: ⏭ 실기기 재현 불가 → 코드 리뷰로 검증 완료

**사유**: Android Wi-Fi toggle 의 OS 재연결 오버헤드 (DHCP + WebSocket 재핸드셰이크) 만으로 최소 3~5초 소요 → `DISCONNECTED → CONNECTED` 지속 시간이 grace 4초 경계를 항상 초과.

**코드 리뷰 증명** ([webrtc_service.dart:407-437](../lib/services/call/webrtc_service.dart#L407-L437)):

```text
DISCONNECTED 진입: _disconnectTimer = Timer(4s, _triggerIceRestart)
CONNECTED 진입:    _disconnectTimer.cancel()   ← 4s 이내 CONNECTED 면 발화 차단
```

`Timer.cancel()` 의 Dart 표준 보장 + Dart single-threaded 실행 모델 → grace 내 복귀 시 restart 트리거 안 됨이 자명.

**결론**: S2 가 정상 동작 (타이머 발화 경로 검증됨) → S1 은 발화 차단 경로뿐이라 PASS 간주.

---

## S2 — Wi-Fi 단절 → grace 초과 → 복구 (1회 restart 성공)

**상태**: ✅ PASS (2026-04-22, RUN 4)

### S2 타임라인

```text
시각           Family                                              Senior
────────────────────────────────────────────────────────────────────────────────
15:01:52.806   FSM connecting → connected (answer_received)       15:01:53.194 CONNECTING → CONNECTED
                                      ════ 29초간 정상 ════
────────────────────────────────────────────────────────────────────────────────
15:02:22.357   PC DISCONNECTED  ← Wi-Fi off                        15:02:22.806  DISCONNECTED
                                                                   15:02:22.807  CONNECTED → RESTARTING
                                                                                 stopPeer 예약 (+15s)

                                                                   15:02:24.375  ★ 노드 삭제 감지 (status=null)
                                                                                 "RESTARTING 중이므로 STOP_DELAY 타이머에 위임"
                                                                                 ← B fix 동작

15:02:26.364   FSM connected → reconnecting (ice_restart_start)
15:02:26.381   writeOrTimeout ICE restart offer: op start
15:02:26.581   writeOrTimeout op done at 199ms  ← ★ C fix 증명 (이전 10628ms)
15:02:26.581   ICE restart offer 전송 (attempt=1)

                                                                   15:02:27.220  ICE restart offer 수신
                                                                   15:02:27.241  ICE restart answer 전송 완료 (21ms)
15:02:26.805   PC CONNECTED                                        15:02:27.333  PC CONNECTED
15:02:26.805   FSM reconnecting → connected (ice_restored)                       stopPeer 예약 취소
15:02:26.937   ICE restart answer 적용 완료                                       RESTARTING → CONNECTED
────────────────────────────────────────────────────────────────────────────────
15:02:34.511   사용자 hangup                                        15:02:35.570  상대방 종료 감지 (정상)
```

### S2 검증 결과

| 항목 | 기대 | 실제 | 통과 |
|---|---|---|---|
| grace 4s 대기 후 restart 트리거 | ✓ | 4.0s (22.357 → 26.364) | ✅ |
| FSM `connected → reconnecting` | ✓ | 정상 | ✅ |
| offer 전송 (attempt=1) | ✓ | 1회 | ✅ |
| Senior answer 수신 | ✓ | 21ms 만에 | ✅ |
| FSM `reconnecting → connected (ice_restored)` | ✓ | 정상 | ✅ |
| `_iceRestartAttempts == 1` | ✓ | 1 | ✅ |
| 재연결 오버레이 지속시간 | 최소화 | 441ms (사용자 거의 인지 못함) | ✅ |

### S2 가 원래 실패했던 이유 (이전 RUN)

**RUN 1 (원본 코드)**: `writeOrTimeout` 의 `onTimeoutCleanup` 7.6s hang + Senior `listenForStatus` 가 null 을 ended 로 해석 → Senior 가 STOP_DELAY(15s) 기다리지 않고 즉시 세션 파괴. 2차 restart 사이클 돌입 후 5회 재시도 실패.

**RUN 3 (B fix 만 적용)**: Senior 가 RESTARTING 중 null 무시 OK. 하지만 Family 측 `writeOrTimeout` 가 10628ms 걸려 `NetworkException` throw — 실제로는 큐잉된 set 이 복구 후 flush 되어 Senior 도달 → 운좋게 세이프 (STOP_DELAY 만료 1초 전). race 리스크 잔존.

**RUN 4 (B + C fix)**: op 199ms 만에 정상 ACK. race 완전 제거. 재연결 오버레이 441ms.

---

## S3 — Wi-Fi → LTE 핸드오프

**상태**: 🔲 미진행

---

## S4 — Wi-Fi 완전 단절 (5회 재시도 후 종결)

**상태**: ✅ PASS (2026-04-22, RUN 6)

### S4 타임라인

```text
시각           Family                                              Senior
──────────────────────────────────────────────────────────────────────────────────────
15:14:14.928   FSM connected (answer_received)                    (CONNECTED)
                                      ════ 32초 정상 ════
──────────────────────────────────────────────────────────────────────────────────────
15:14:46.962   PC DISCONNECTED (Wi-Fi off, 계속 유지)               (동시에 DISCONNECTED)
                                                                    stopPeer 예약 (+15s)
15:14:50.964   grace 4s 만료 → reconnecting [attempt 1]
15:14:50.987   writeOrTimeout op start
15:14:53.989   timeout 3001ms → NetworkException

                                                                   (STOP_DELAY 만료 → ENDED)
                                                                   Senior 세션 정리 완료
15:15:06.082   PC FAILED → _triggerIceRestart [attempt 2]
15:15:09.101   NetworkException
15:15:21.217   PC FAILED [attempt 3]
15:15:24.241   NetworkException
15:15:36.334   PC FAILED [attempt 4]
15:15:39.420   NetworkException
15:15:51.507   PC FAILED [attempt 5 진입 시도]
15:15:51.508   ★ WebRTC: flap window(60000 ms) 초과 → iceFailed 종결
15:15:51.508   FSM reconnecting → terminating (hangup:iceFailed)
15:15:51.691   FSM terminating → terminated (cleanup_done)
──────────────────────────────────────────────────────────────────────────────────────
최초 attempt (15:14:50.964) → 종결 (15:15:51.508) = 60.544초 (flap window 한도 초과)
```

### 검증 결과

| 항목 | 기대 | 실제 | 통과 |
|---|---|---|---|
| 5회 재시도 or flap window 60s 초과 종결 | ✓ | flap window 초과 (60.544s) | ✅ |
| `hangup:iceFailed` reason | ✓ | 정확 | ✅ |
| FSM `reconnecting → terminating → terminated` | ✓ | 정상 | ✅ |
| 재시도 간격 | 10s (설계) | **~15s** (PC FAILED 전환 의존) | ⚠ 설계 상이 |
| 화면 자동 pop | ✓ | 시각 확인됨 | ✅ |
| Senior STOP_DELAY 정상 만료 | ✓ | 정상 | ✅ |

### 재시도 간격 분석 (설계 vs 실제)

**설계 의도**: `_iceRestartAnswerTimer(10s)` 만료 시 자동 재시도 → 10초 간격.

**실제 동작**: `NetworkException` throw 시 answer timer 가 설정되지 않음 → PC `DISCONNECTED → FAILED` 전환 (WebRTC 내부 타이머 ~15s) 에만 의존. 결과적으로 **재시도 간격 ~15s**.

계산: `grace 4s + (attempt1 → attempt5 간 15s × 4) = 64s` — flap window 60s 를 근소하게 초과하여 5회차 진입 시점에 한도 초과로 종결됨. 기능은 정상 작동하지만 attempts 한도(5회) 가 실제로 도달할 틈이 거의 없음 (flap window 가 먼저 터짐).

### 이전 실패 이력 (RUN 5)

RUN 5 에서는 4회차 재시도 후 45초 시점에 `KEYCODE_BACK` (뒤로가기 제스처) 가 눌려 `MonitoringScreen.dispose()` → `WebRtcService.dispose()` → `hangUp()` (기본 reason `userHangup`) 경로로 조기 종료. 자동 종결 15초 전에 중단된 것. RUN 6 에서 사용자가 뒤로가기 안 누르고 대기 → 정상 자동 종결 확인.

### D fix — `NetworkException` 시 재시도 타이머 추가 (RUN 7 적용)

**배경**: `_maxFlapWindowMs` (60s) 체크는 `_triggerIceRestart` 진입 시에만 실행됨. NetworkException catch 경로에서 `_iceRestartAnswerTimer` 가 설정 안 되면 재진입이 WebRTC 내부 PC FAILED 전환 (조건부, 보장 없음) 에만 의존 → PC 가 영구 DISCONNECTED 로 머물면 flap window 체크조차 발화 못 하는 구멍.

**수정** ([webrtc_service.dart:509-528](../lib/services/call/webrtc_service.dart#L509-L528)):

```dart
} catch (e) {
  _iceRestartInProgress = false;
  if (e is NetworkException) {
    _iceRestartAnswerTimer?.cancel();
    _iceRestartAnswerTimer = Timer(
      const Duration(milliseconds: _iceRestartAnswerTimeoutMs),
      () {
        final state = _peerConnection?.connectionState;
        if (state == DISCONNECTED || state == FAILED) {
          _triggerIceRestart();
        }
      },
    );
  }
}
```

### S4 RUN 7 검증 (D fix 적용 후)

```text
15:27:15.044   reconnecting [attempt 1]    op done at 3008ms NetworkException
15:27:28.099   [attempt 2]  ← +10s 정확
15:27:41.166   [attempt 3]  ← +10s
15:27:54.260   [attempt 4]  ← +10s
15:28:07.342   [attempt 5]  ← +10s
15:28:20.353   ★ flap window(60000 ms) 초과 → iceFailed 종결
15:28:20.366   FSM terminating (hangup:iceFailed)
```

| 항목 | RUN 6 (D fix 전) | RUN 7 (D fix 후) |
|---|---|---|
| 재시도 간격 | ~15초 (PC FAILED 의존) | **10초 일정** ✅ |
| 실질 attempt 횟수 | 4회 (5회째 직전 종결) | **5회 완주** ✅ |
| 자동 종결 | flap window 60.5s | flap window 65s |
| `_triggerIceRestart` 재진입 보장 | WebRTC 내부 타이머 의존 | **우리 코드가 직접 보장** ✅ |

**효과**: PC 상태 변화에 의존하지 않고 코드 레벨에서 재시도 cadence 보장. 영구 stuck 케이스에서도 60~65초 안에 자동 종결.

---

## S5 — flap window 60초 초과 (반복 disconnect)

**상태**: ✅ PASS (2026-04-22, RUN 8)

### S5 타임라인

```text
15:30:49.370   FSM connected (모니터링 시작)
                                ════ 15초 정상 ════
15:31:04.223   DISCONNECTED             ← 1st off
15:31:08.225   reconnecting [attempt 1] (grace 4s 만료, _flapWindowStart 설정)
15:31:11.254   NetworkException (3s)
15:31:15.235   ★ PC CONNECTED            ← Wi-Fi 복구, FSM ice_restored
               _stableTimer 5s 시작
               → 15:31:20.235 stableTimer 발화, 리셋 (attempts=0, flapWindowStart=null)

15:31:22.821   DISCONNECTED              ← 2nd off (CONNECTED 7.6s 유지 후)
15:31:26.824   reconnecting [attempt 1 again] (_flapWindowStart 재설정)
15:31:29.858   NetworkException
                                ═══ D fix 10초 타이머 연속 재시도 ═══
15:31:39.883   [attempt 2]
15:31:52.910   [attempt 3]
15:32:05.930   [attempt 4]
15:32:18.951   [attempt 5] → op done at 417ms   ★ Wi-Fi 복구돼서 offer 전송 성공
                                                  (Senior 는 이미 STOP_DELAY 만료로 사라짐)
15:32:29.371   answer 미수신 10초 타임아웃 → _triggerIceRestart 재진입
15:32:29.371   ★ flap window(60000 ms) 초과 → iceFailed 종결
15:32:29.372   FSM reconnecting → terminating (hangup:iceFailed)
15:32:29.462   terminated (cleanup_done)
```

### S5 검증 결과

| 항목 | 기대 | 실제 | 통과 |
|---|---|---|---|
| `_stableTimer` 5초 유지 → 카운터 리셋 | ✓ | 첫 사이클 후 attempts 재시작 확인 | ✅ |
| 연속 flap 시 attempts 누적 | ✓ | 5회 모두 도달 | ✅ |
| flap window 60s 초과 → iceFailed | ✓ | 63초 시점 종결 | ✅ |
| 한번 복구 후 재단절 정상 처리 | ✓ | CONNECTED 7.6s 유지 → 리셋 → 새 사이클 시작 | ✅ |
| 최종 FSM terminated | ✓ | hangup:iceFailed | ✅ |

### S5 관찰

- **첫 사이클 CONNECTED 유지 7.6초** — 사용자가 의도는 6초였지만 OS 재연결 지연 포함 → 5초 stable 넘겨서 카운터 리셋됨. 이는 **예상 함정** (plan 에 명시): 사이클 중 CONNECTED 5초 이상 유지되면 카운터 리셋됨. 통제 어려움.
- 그럼에도 2차 사이클부터 attempts 누적되고 D fix 의 10초 재시도 타이머로 5회 완주 → flap window 초과.
- **Senior 는 첫 DISCONNECTED 시점에 STOP_DELAY 15s 타이머 시작** → 두 번째 off 중 만료되어 이후 세션 사라짐. Family 의 attempt 5 에서 set 성공했지만 answer 안 옴 → 10s timeout → flap window 확정.
- 실측 총 경과: 첫 DISCONNECTED (15:31:04) → 종결 (15:32:29) = **85초**. 두 번째 사이클 flap window 기준 63초.

---

## R1 — 좀비 peer 방지 (회귀)

**상태**: 🔲 미진행

---

## R2 — answered LWW 방지 (회귀)

**상태**: 🔲 미진행

---

## 알려진 이슈 / 관찰

### FSM `ice_restored` 판정 타이밍 (낙관적)

S2 RUN 4 에서 `ice_restored` 로의 FSM 전이가 `setLocalDescription` 직후 `PC CONNECTED` 이벤트만으로 일어남 (15:02:26.805). 실제 Senior answer 적용은 132ms 뒤 (15:02:26.937). 이번은 answer 가 빠르게 왔지만, **Senior answer 수신 전에 PC 가 기존 경로 자가복구로 CONNECTED 되면 `ice_restored` 가 너무 이르게 확정될 가능성**.

증상: 사용자에게 "복구됨" 표시되지만 실제 영상/오디오 패킷이 새 경로로 안 흐를 수 있음. 지금은 Senior 의 STOP_DELAY 타이머가 안전망이라 당장 큰 문제 없음.

개선 여지: `ice_restored` 를 "PC CONNECTED + Senior answer 적용 완료" 양쪽 충족 시로 변경. 우선순위 낮음 — 실 사용자 불만 발생 시 검토.

### 재시도 로직 미검증

`NetworkException` 이 throw 되면 `_iceRestartAnswerTimer` 가 설정되지 않아 자동 재시도 경로가 끊김. 현재 구조에서 재시도는 "다음 DISCONNECTED 이벤트" 에만 의존. **S4 (Wi-Fi 완전 단절) 테스트 시 5회 재시도가 실제로 일어나는지 확인 필요.**
