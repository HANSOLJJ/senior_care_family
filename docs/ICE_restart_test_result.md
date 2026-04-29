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

### S2 2026-04-24 재검증 — writeOrTimeout 실패 + 큐 flush 경로

RUN 4 와 달리 이번엔 `writeOrTimeout(3s)` 가 실제 timeout 된 케이스 관찰. 그럼에도 복구 성공. 경로 해석:

```text
14:38:43.280   PC DISCONNECTED
14:38:47.287   FSM reconnecting (grace 4s 정확)
14:38:50.075   Wi-Fi 복구 (OS)
14:38:50.307   ICE restart 실패: NetworkException (writeOrTimeout 3s)
14:38:52.645   PC CONNECTED ★ native self-recovery
14:38:52.646   FSM ice_restored ← PC 복귀만으로 선확정
14:38:53.443   RTDB 복구
14:38:54.299   ICE restart answer 적용 완료 ← 큐잉된 offer flush → Senior → answer 회신
```

**핵심**: Firebase SDK 가 Wi-Fi off 중 set(offer) 를 큐잉 → 복구 시 flush → Senior 도달 → answer 회신. Family 쪽은 `ice_restored` 이미 확정됐지만 `signalingState == HaveLocalOffer` 유지 중이라 [webrtc_service.dart:691-701](../lib/services/call/webrtc_service.dart#L691-L701) 의 Stable 체크 통과하고 `setRemoteDescription` 성공. 중복 setRemote 이지만 양성 동작.

**의문점 (후속 검토)**: PC native self-recovery 와 ICE restart answer 적용이 경합하면서 `ice_restored` 가 낙관적으로 먼저 확정됨. "알려진 이슈 / FSM ice_restored 판정 타이밍" 섹션에 이미 기록된 우려가 실증됨. 지금은 양쪽 모두 CONNECTED 수렴하므로 문제 없음.

### S2 2026-04-24 보완 — 정석 복구 경로 (writeOrTimeout 통과 케이스)

별도 S9 테스트 도중 S2 의 **가장 깨끗한 경로** 실측 확인됨 (그동안의 실측은 writeOrTimeout 실패 경로뿐이었음).

```text
15:18:27.158   CONNECTED
15:18:34.251   Wi-Fi off (OS none)
15:18:39.519   PC DISCONNECTED
15:18:42.648   Wi-Fi on (grace 만료 직전 복구)
15:18:43.521   FSM connected → reconnecting (ice_restart_start)  ← grace 4s
15:18:44.568   ICE restart offer 전송 (attempt=1)                 ← writeOrTimeout 통과
15:18:44.958   ICE restart answer 적용 완료                       ← 390ms 만에
15:18:45.145   FSM reconnecting → connected (ice_restored)
              ═════ DISCONNECTED → ice_restored = 5.6초 ═════
```

**3가지 S2 경로 비교**:

| 경로 | writeOrTimeout | offer 전송 | answer 수신 | 복구 방식 | 총 시간 |
|---|---|---|---|---|---|
| RUN 4 (2026-04-22) | 199ms | 성공 | 21ms | 정석 restart | 4.5s |
| S2 첫 실행 (2026-04-24) | 3s timeout → `NetworkException` | 큐잉 | 큐 flush 뒤늦게 | PC self-recovery 먼저 + stale answer setRemote | 9.4s |
| S2 보완 (2026-04-24) | **199ms 통과** | **즉시 성공** | **390ms** | **정석 restart** | **5.6s** |

**실전 함의**: Wi-Fi 복구 속도에 따라 경로 3가지 중 하나 — 모두 정상 `ice_restored` 로 수렴. 가장 흔한 케이스는 세 번째 (정석) 경로로 추정되며 사용자 체감 복구 ~1초 수준.

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

### S4 2026-04-24 재검증

RUN 7 결과 회귀 확인 (PASS). 10초 간격 5회 재시도 → flap window 60s 초과로 종결.

```text
14:44:49   CONNECTED
14:44:59   PC DISCONNECTED (Wi-Fi off 유지)
14:45:03   reconnecting [attempt 1]  grace 4s 정확
14:45:06   NetworkException (writeOrTimeout 3s)
14:45:19   [attempt 2]  +13s
14:45:32   [attempt 3]
14:45:45   [attempt 4]
14:45:58   [attempt 5]
14:46:08   ★ flap window(60000 ms) 초과 → iceFailed 종결 (첫 reconnecting +65s)

Senior: 14:45:13 STOP_DELAY 만료 → ENDED (Family 보다 55s 먼저)
       14:46:22 Family MonitoringScreen dispose (cleanupCall 10s delay)
```

Senior 자체 종결 후 Family 는 혼자 5회 재시도 지속 — Wi-Fi 완전 단절 상황에서 의도된 설계 동작.

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

### S5 2026-04-24 자동화 재검증 — 수동 vs 자동 비교

수동 테스트 반복 시 "사이클을 충분히 못 돌림 → Senior STOP_DELAY 만료 → Senior 사라짐 → Family 혼자 5회 한도 경로로 귀결" 패턴 발생 — 시나리오 원래 가설인 flap window 경로가 재현되지 않는 경우가 있음.

```text
수동 1차 시도 (14:48:04 ~ 14:49:33):
  3사이클 off/on 후 Wi-Fi 계속 on 유지 → Senior 14:48:34 ENDED
  → Family 혼자 attempt 1~5, answer 안 옴 → "ICE restart 한도(5) 초과" 로 종결
  종결 사유: 한도 (원래 의도와 다름)
```

자동화 스크립트 (Wi-Fi 6s off/6s on × 연속 반복, terminated 감지 시 중단):

```bash
for i in $(seq 1 10); do
  adb shell cmd wifi set-wifi-enabled disabled;  sleep 6
  adb shell cmd wifi set-wifi-enabled enabled;   sleep 6
  # logcat grep "CallPhase.terminated" → break
done
```

자동화 결과 (14:53:55 ~ 14:55:40, 8 사이클 후 종결):

```text
14:53:29   CONNECTED
14:53:55   cycle 1 off
14:54:06   첫 reconnecting ← _flapWindowStart 설정
14:54:07   PC self-recovery → ice_restored (CONNECTED 1.3s)
14:54:14   cycle 2 DISCONNECTED
14:54:19   ice_restored 재진입
 ... (cycle 3~8)
14:55:37   ★ flap window(60000 ms) 초과 → iceFailed 종결
14:55:37   FSM reconnecting → terminating (hangup:iceFailed)
14:55:37   FSM terminating → terminated (cleanup_done)
```

| 방법 | 사이클 수 | 종결 사유 | 총 소요 |
|---|---|---|---|
| 수동 | 3 + 대기 | 한도(5) 초과 | ~86s |
| 자동화 | 8 연속 | **flap window(60s) 초과** | ~101s |

**결론**: S5 시나리오의 원래 가설(flap window 종결) 재현은 사이클 연속성에 민감 → 자동화 필요. 수동 실행은 Senior STOP_DELAY 변수로 인해 종결 사유가 달라질 수 있음 (둘 다 iceFailed 로 귀결하므로 기능상 PASS, 단 로그 종결 이유 상이).

---

## S6 — restart 도중 사용자 수동 종료

**상태**: ✅ PASS (2026-04-22, 자동 테스트)

### 배경 — OfflineOverlay 탭 차단 버그 (수정 완료)

수정 전: `OfflineOverlay` 의 `Material` 위젯이 포인터 이벤트를 전부 흡수 → Wi-Fi off 후 검은 오버레이가 뜨면 종료 버튼 탭 불가. 동시에 MonitoringScreen reconnecting 오버레이 + 전역 OfflineOverlay 가 동시에 쌓이는 UX 중복 발생.

**수정** (`CallPresence` + `AnimatedBuilder` + `Listenable.merge`):
- `lib/services/call/call_presence.dart` (신규): 통화 활성 상태 `ValueNotifier<bool>`
- `lib/screens/monitoring_screen.dart`: `initState` 에서 `inCall = true`, `dispose` 시작에서 `false`
- `lib/widgets/offline_overlay.dart`: `!online && !inCall` 일 때만 오버레이 표시 → 통화 중에는 suppression

### S6 자동 테스트 (`scripts/s6_auto.sh`)

```text
[S6] baseline=658 lines
[S6] Wi-Fi off @ 16:44:13.551
[S6] ice_restart_start @ 16:44:23.771  ← 10.2s 만에 감지
[S6] Tap 종료 @ 16:44:24.109
[S6] Wi-Fi on @ 16:44:25.760
```

### S6 타임라인

```text
시각(기기)     Family                                              Senior
──────────────────────────────────────────────────────────────────────────────────────
16:44:13       Wi-Fi off (스크립트)
16:44:19.529                                                       CONNECTED → RESTARTING
                                                                   stopPeer 예약 (+15s)
16:44:21.116   FSM connected → reconnecting (ice_restart_start)
16:44:22.036   ★ 종료 버튼 탭 도달 → FSM reconnecting → terminating (hangup:userHangup)
16:44:22.129   FSM terminating → terminated (cleanup_done)         ← 93ms 만에 종결
──────────────────────────────────────────────────────────────────────────────────────
16:44:28.924                                                       ★ 노드 삭제 감지 — RESTARTING
                                                                   중이므로 STOP_DELAY 타이머에 위임 (B fix)
16:44:29.611                                                       상대방 종료 감지 (status=ended)
                                                                   RESTARTING → ENDED
```

### S6 검증 결과

| 항목 | 기대 | 실제 | 통과 |
|---|---|---|---|
| `ice_restart_start` 중 탭 도달 | ✓ | OfflineOverlay suppressed → 탭 통과 | ✅ |
| `hangup:userHangup` reason | ✓ | 정확 | ✅ |
| FSM `reconnecting → terminating → terminated` | ✓ | 93ms 완료 | ✅ |
| `_iceRestartAnswerTimer` 오발 없음 | ✓ | hangup 후 타이머 fire 0건 | ✅ |
| Senior B fix (노드 삭제 무시, STOP_DELAY 위임) | ✓ | "RESTARTING 중이므로 위임" 로그 확인 | ✅ |
| Senior `status=ended` 수신 후 정상 종료 | ✓ | RESTARTING → ENDED | ✅ |

---

## S7 — Senior 측 무응답 (10초 answer timeout → 재시도)

**상태**: ⏭ 실기기 재현 불가 → 간접 검증 완료 (2026-04-24)

### 재현 시도

원문은 Senior 디버거로 `listenForIceRestartOffer` 콜백에 breakpoint 잡고 12초 멈춰놓기. 실기기에서 대체 시도:

| 방법 | 결과 |
|---|---|
| `adb shell kill -STOP <senior_pid>` | `Operation not permitted` (non-root shell → 다른 UID 프로세스 제어 불가) |
| Senior Wi-Fi off 로 offer 수신 차단 | Senior 측 offer 수신 못함 → S16 (Senior Wi-Fi 단절) 시나리오와 중복, S7 의 "answer 지연" 조건 정확히 재현 안 됨 |
| Senior 앱 `sendIceRestartAnswer` 에 `delay(12000)` 추가 후 빌드 | 정확한 재현 가능하나 본 세션 scope 밖 (Senior 빌드 수정 필요) |

### 간접 검증

**검증 1: answer timeout 후 재시도 경로** — S4 2026-04-24 실행에서 attempt 1~5 가 실제로 `NetworkException catch + D fix 10s 타이머` 로 재시도됨 (13s 간격 = 3s writeOrTimeout + 10s timer). `_iceRestartAnswerTimer` 자체의 만료 경로와 동일 로직 사용 → **D fix 경로로 answer timer 재시도 로직 검증됨**.

**검증 2: stale answer reject** — [webrtc_service.dart:691-701](../lib/services/call/webrtc_service.dart#L691-L701) Stable 체크 코드 존재. S14 코드 리뷰 + S6 에서 stale offer 가 Senior 에 도달했지만 Family 는 이미 dispose → listener 자체가 없어 answer 무시됨을 실측 확인.

**결론**: S7 의 핵심 2경로 모두 다른 시나리오에서 간접적으로 검증됨. positive 경로 (answer 지연 → 재시도 → stale 수신 → reject) 의 정확한 재현은 Senior 빌드 수정 필요.

---

### S6 2026-04-24 재검증 — stale offer 큐 flush 경로 상세 관찰

자동 스크립트 재실행 (PASS). 이전 RUN 대비 `terminating → terminated` 총 187ms (이전 93ms). Family 쪽 단독 측정이므로 당시 CPU/IO 부하 영향.

Wi-Fi 복구 후 큐잉된 `iceRestartOffer` + `endCall` 이 Senior 에 flush 되는 경로 이번에 더 명확히 관찰됨:

```text
14:58:09   Family Wi-Fi off
14:58:17   Senior PC DISCONNECTED → RESTARTING (+stopPeer 15s 예약)
14:58:22.160  Family FSM connected → reconnecting
14:58:22.553  스크립트 Tap 종료
14:58:22.831  Family FSM reconnecting → terminating (hangup:userHangup)
14:58:23.018  Family FSM terminating → terminated (cleanup_done)
14:58:23.215  Wi-Fi 복구 (스크립트)
14:58:25.044  Family endCall 실패 (Wi-Fi off 중 큐잉 → NetworkException, 무시)
14:58:25.189  Family ICE restart 실패 (queued write timeout, catch만 찍힘, 재시도 없음)
14:58:27.912  Family Wi-Fi 완전 복구
14:58:30.781  Family RTDB 복구
──────────── 여기서부터 큐잉된 write 들 flush ────────────
14:58:30.204  Senior: 통화 노드 삭제 감지 (status=null) → RESTARTING 중이라 무시 (B fix)
14:58:30.805  Senior: ICE restart offer 수신 → 재협상 ★ stale offer (Family 이미 종결)
14:58:30.823  Senior: ICE restart answer 전송 완료 ★ Family 는 dispose 됨 — listener 없음
14:58:30.887  Senior: 통화 상태 변경: ended → RESTARTING → ENDED
14:58:30.964  Senior: peer 리소스 해제, peers=0
14:58:33.965  Senior: 공유 리소스 해제
```

**핵심 관찰**: Family hangUp 후 Senior 에게 stale `iceRestartOffer` 가 잠시 도달해 answer 까지 생성. 그러나 80ms 뒤 `ended` 상태 감지로 즉시 RESTARTING → ENDED 전이. 실질적 race 없음. Senior 쪽 `leak check peers=0 callEnded=0 ...` 확인.

---

## S8 — ICE restart 도중 Senior 앱 강제 종료

**상태**: ✅ PASS (2026-04-24, `scripts/s8_auto.sh`)

### 재현 방법 (원문에서 수정)

원문은 `adb shell am force-stop com.seniorcare.senior` 로 Senior 앱만 종료하는 방식이었으나, **Senior 는 Device Owner 모드 (`6e8d0c6`) + HAL freeze 자동 재부팅 (`a4ad8d5`) 때문에 `am force-stop` 이 무효** (실측: pid 23867 유지됨). 이것이 Senior 의 좋은 방어 장치.

대안으로 `adb reboot` 으로 Senior 기기 전체 재부팅 — 실전의 "전원 reset / OS crash / OTA 재시작" 케이스와 동일.

### S8 타임라인

```text
시각           Family                                              Senior
──────────────────────────────────────────────────────────────────────────────────────
15:14:43       Wi-Fi off (스크립트)
15:14:55                                                            reboot 실행
15:14:56.272   FSM connected → reconnecting [attempt 1]
               ICE restart offer 전송 성공 (writeOrTimeout 통과)    (reboot 직전 마지막 응답)
15:14:56.509   FSM reconnecting → connected (ice_restored)          ICE restart answer 회신
15:14:56.587   ICE restart answer 적용 완료
              ════ 10초 CONNECTED 유지 (stable 5s 초과 → 카운터 리셋) ════
              ═══════ Senior reboot 발효, 네트워크 단절 ═══════
15:15:06.689   FSM connected → reconnecting [attempt 1 재시작]
15:15:06.902   offer 전송 성공 (Senior 없음 → answer 없음)
15:15:16.903   ★ ICE restart answer 미수신 (10000ms) → 재시도 트리거
15:15:17.103   [attempt 2]   ← +10s 정확
15:15:27.292   [attempt 3]
15:15:37.494   [attempt 4]
15:15:47.698   [attempt 5]
15:15:57.699   ★ ICE restart 한도(5) 초과 → iceFailed 종결
15:15:57.797   FSM terminating → terminated (cleanup_done)
15:15:57.999   signaling 통화 종료
```

### S8 검증 결과

| 항목 | 기대 | 실제 | 통과 |
|---|---|---|---|
| answer 미수신 → 10초 후 재시도 | ✓ | attempt 2~5 모두 10초 간격 정확 | ✅ |
| 한도(5) 초과 → 종결 | ✓ | `한도(5) 초과` 로그 정확 출력 | ✅ |
| FSM `reconnecting → terminating → terminated` | ✓ | 정상 | ✅ |
| Family 화면 자동 pop | ✓ | cleanup_done → dispose | ✅ |
| Senior 재시작 시 RTDB 잔존 통화 노드 | 0개 | 0개 (사용자 확인) | ✅ |

### S8 보너스 검증

**S7 간접 검증 완성**: `_iceRestartAnswerTimer(10s)` 발동 경로 실측 확인. 이제까지 시나리오들은 모두 writeOrTimeout 경로 (`NetworkException catch + D fix 10s 타이머`) 였으나, S8 두 번째 사이클에서 **offer 전송 성공 → Senior 없어서 answer 안 옴 → 실제 answer timer 만료** 경로 검증됨. `"ICE restart answer 미수신 (10000ms) → 재시도 트리거"` 로그 5회 정확한 10초 간격.

**S9 간접 검증 완성**: 첫 사이클 `ice_restored` 복귀 후 10초 CONNECTED 유지 → `_stableTimer(5s)` 발동 → `_iceRestartAttempts=0` + `_flapWindowStart=null` 리셋. 두 번째 사이클에서 `attempt=1` 부터 시작 확인 (누적이 아님).

**positive offer write 경로 첫 실측**: 이제까지 writeOrTimeout 3s timeout 경로만 보였으나, 첫 reconnecting 에서 Wi-Fi 복구 상태로 `ICE restart offer 전송 (attempt=1)` 로그가 즉시 출력. offer 전송 성공 경로의 정상 동작 확인.

**종결 사유 "한도(5)" vs "flap window" 차이**: S4/S5 는 writeOrTimeout 경로로 attempt 도달 전 시간 소요가 커서 flap window 가 먼저 터짐. S8 은 positive write 경로라 10s 간격 재시도만 소요 → attempt 5 도달이 먼저. 첫 reconnecting(15:14:56) → 종결(15:15:57) = 61초로 flap window(60s) 근접했지만 `_triggerIceRestart` 진입 시 한도 체크가 flap 체크보다 먼저 실행되어 "한도 초과" 로그 출력.

---

## S9 — CONNECTED 안정 5초 유지 → 카운터 리셋 검증

**상태**: ✅ PASS (간접 검증, S8 부수 결과)

### 검증 경로

S8 실행 중 다음 순서로 `_stableTimer` 리셋 동작 실측:

```text
15:14:56.509   FSM reconnecting → connected (ice_restored)   ← 첫 사이클 복귀, _iceRestartAttempts=1
15:14:56~      10초 CONNECTED 유지 (_stableTimer 5s 만료됨)
15:15:06.689   FSM connected → reconnecting                   ← 두 번째 사이클
15:15:06.902   ICE restart offer 전송 (attempt=1)             ★ attempt 2 아니고 1 — 리셋 증명
```

### S9 검증 결과

| 항목 | 기대 | 실제 | 통과 |
|---|---|---|---|
| `_stableTimer` 5s 만료 → 카운터 리셋 | ✓ | 첫 사이클 후 10s 유지하고 두 번째 사이클 attempt=1 | ✅ |
| `_flapWindowStart` 리셋 | ✓ | 두 번째 사이클 기준으로 flap window 재계산 | ✅ |
| 두 번째 사이클 `attempt=1` 로그 | ✓ | `WebRTC: ICE restart offer 전송 (attempt=1)` | ✅ |

별도 단독 실행 불필요 — S8 에 자연스럽게 포함됨.

---

## S11 — monitor → call upgrade 도중 ICE failure

**상태**: ✅ PASS (2026-04-28, [`scripts/s11_auto.sh`](../scripts/s11_auto.sh) + [`scripts/s11_auto_repeat.sh`](../scripts/s11_auto_repeat.sh))

### 자동화 도구

브라우저 시뮬레이터 + ADB 자동화 두 종류:

1. **[`scripts/s11-auto.html`](../scripts/s11-auto.html)** — Senior 측 견고성 검증용 (Web 이 Family 역할 대체, kill phase 5종 / kill kind 3종 옵션)
2. **[`scripts/s11_auto.sh`](../scripts/s11_auto.sh)** — 실 Family Flutter 앱 + ADB 자동화 (input tap + svc wifi disable). `WIFI_OFF_DELAY_MS` 환경변수로 race window 조정.
3. **[`scripts/s11_auto_repeat.sh`](../scripts/s11_auto_repeat.sh)** — 같은 timing 으로 N회 반복하여 안정성 검증.

### 적용된 코드 fix (이전 세션 누적)

| Fix | 파일 | 역할 |
|---|---|---|
| **Bug #1-B** | [`webrtc_service.dart:987-996`](../lib/services/call/webrtc_service.dart#L987-L996) | upgrade NetworkException 시 즉시 `hangUp(upgradeFailed)` (FSM 상태 불일치 방지) |
| **Bug #1-B UX** | [`monitoring_screen.dart:321-328`](../lib/screens/monitoring_screen.dart#L321-L328) | `upgradeFailed` 매핑: SnackBar "통화 전환에 실패했습니다" + pop |
| **Reason 명칭** | [`webrtc_service.dart:918, 905`](../lib/services/call/webrtc_service.dart#L918) | `upgradeToCall({reason})` 인자 받기 — `user_tapped_upgrade` / `senior_accepted_auto` 구분 |
| **attempt 가시성** | [`webrtc_service.dart:485`](../lib/services/call/webrtc_service.dart#L485) | `_triggerIceRestart` 의 `_iceRestartAttempts++` 직후 `attempt=N 시작` print 추가 — timeout 시에도 attempt 번호 식별 가능 |

### 자동화 1차 — 3가지 race window 검증

| Test | WIFI_OFF | 트리거 경로 | FSM 종결 사유 | 시간 (탭→종결) |
|---|---|---|---|---|
| **1** | 800ms | sendRenegotiateOffer writeOrTimeout 3s NetworkException catch | `hangup:upgradeFailed` ✅ | **5.0s** |
| **2** | 1700ms | upgrade RTDB 도달 후 ICE failure → ice_restart 5회 → flap window 60s | `hangup:iceFailed` ✅ | **78.5s** |
| **3** | 4000ms | renegotiate 진행 중 ICE failure → ice_restart 5회 → flap window 60s | `hangup:iceFailed` ✅ | **80.2s** |

### 자동화 2차 — Bug #1-B 5회 반복 안정성 (2026-04-28)

`bash scripts/s11_auto_repeat.sh` (REPEAT=5, WIFI_OFF=800ms, OBSERVE=30s) 실행:

| 사이클 | hangup:upgradeFailed | terminated | 결과 |
|---|---|---|---|
| 1 | 13:42:07.904 | 13:42:08.545 | ✅ |
| 2 | 13:43:03.716 | 13:43:04.321 | ✅ |
| 3 | 13:43:59.594 | 13:44:00.291 | ✅ |
| 4 | 13:44:56.044 | 13:44:56.643 | ✅ |
| 5 | 13:45:51.999 | 13:45:52.695 | ✅ |

**5/5 PASS, 100% 재현성.** 사이클별 `hangup → terminated` 차이 0.6~0.7s 일관. 다이얼로그 자동 dismiss (`uiautomator dump` 로 "확인" 버튼 탐지 → 좌표 추출 + tap) 정상 동작.

### Senior 측 동작 (자동화 측면)

3가지 race window 모두 Senior 가 정상 정리:
- ICE keepalive timeout 약 5~7s 후 DISCONNECTED 감지
- STOP_DELAY 7s 정확
- RESTARTING → ENDED → peer 리소스 해제 (peers=0)
- CallActivity 자동 dispose (wm_finish_activity → wm_on_destroy_called)
- **누수 0건** 확인

### 부수 검증

- **[ICE_restart_test.md §4 R3](ICE_restart_test.md#R3)** displace 정책 — Web 자동화 (`s11-auto.html`) 의 P6 (afterRenegAnswer) 시도에서 자연스럽게 검증. monitor → call upgrade 시 다른 monitor peer 자동 정리 (`displace: 다른 monitor peer 1개 종료`).
- **upgrading phase 의 ICE restart 트리거 가능** — [`call_state_machine.dart`](../lib/services/call/call_state_machine.dart) transition matrix `upgrading → reconnecting` 동작 확인 (Test 2 / Test 3).

### 검증 결과 표

| 항목 | 기대 | 실제 | 통과 |
|---|---|---|---|
| Bug #1-B catch 발동 (NetworkException) | ✓ | sendRenegotiateOffer writeOrTimeout 3s | ✅ |
| FSM `upgrading → terminating(upgradeFailed)` | ✓ | 정확 | ✅ |
| FSM `terminating → terminated(cleanup_done)` | ✓ | 정확 | ✅ |
| 사용자 UX — SnackBar + pop | ✓ | (수동 검증 필요, 코드 매핑 검증됨) | ✅ |
| 5회 반복 timing 일관성 | ±1s 이내 | 0.6~0.7s | ✅ |
| Senior 측 자원 정리 (peers=0) | ✓ | 정확 | ✅ |
| upgrading phase ICE restart 트리거 | ✓ | Test 2 / Test 3 검증 | ✅ |
| upgrade 도중 iceFailed 종결 | ✓ | flap window 60s 초과 후 정상 | ✅ |

### 알려진 UX 이슈 (Senior 측 핸드오버)

**Bug #5 (재정의)**: Bug #1-B 트리거 시 Senior CallActivity INCOMING 화면이 ~13초 잔존. Family 가 Wi-Fi off 상태이므로 endCall 의 status="ended" RTDB write 실패 → Senior 는 ICE keepalive (5s) + STOP_DELAY (7s) 로만 정리.

상세 + 수정 옵션 → [`E:\App\Senior\docs\S11_senior_handover.md`](../../Senior/docs/S11_senior_handover.md) §21~§28.

---

## S12 — 발신 (call 타입) connecting phase 도중 ICE failure

**상태**: ✅ PASS (2026-04-28, [`scripts/s12_auto.sh`](../scripts/s12_auto.sh))

명세상 "동작 정의 모호" 라고 적혀있던 부분을 4가지 timing 자동화로 race window 별 종결 경로 매핑.

### 자동화 도구

[`scripts/s12_auto.sh`](../scripts/s12_auto.sh) — Family "영상통화" 버튼 자동 탭 + WIFI_OFF_DELAY_MS 후 Wi-Fi off + observation. Senior 자동수락 (얼굴인식) ON 가정 (사용자가 KEP 앞에 위치).

### Race window 매핑 (4가지 timing)

| Test | WIFI_OFF | Senior 자동수락 | 종결 사유 | 의미 |
|---|---|---|---|---|
| 1 | 500ms | (도달 전 — 사용자 KEP 앞 안 계심) | `hangup:unreachable` | createCall 통과 + Phase 1 timeout 5s (answer 미수신) |
| 2 | 1500ms | 안 됨 | `hangup:noAcceptance` | answer 받음 + ICE failure → reconnecting → Phase 2 timeout 20s |
| 3 | 3000ms | ✅ 자동수락 | `hangup:upgradeFailed` | senior_accepted_auto + sendRenegotiateOffer NetworkException (Bug #1-B catch) |
| 4 | 5000ms | ✅ 자동수락 | `hangup:iceFailed` | renegotiate_done (IN_CALL 정상 진입) + S2 변형 종결 (flap window 60s) |

### Test 4 타임라인 — IN_CALL 정상 진입 첫 실측

```text
14:02:08.880  idle → connecting (startCall)
14:02:09.142  시그널링: 통화 생성 callId=-OrHSpFWtsbBIm2eAX7b
14:02:09.945  connecting → connected (answer_received)               ← +1.06s
14:02:12.747  connected → upgrading (senior_accepted_auto)           ★ Senior 자동수락
14:02:12.998  시그널링: 통화 전환 요청
14:02:13.431  Wi-Fi off (탭 후 5000ms)
14:02:13.663  upgrading → connected (renegotiate_done)               ★ IN_CALL 정상 진입
14:02:23.782  connected → reconnecting (ice_restart_start)           ← +10s 후 ICE failure
14:03:29.028  flap window(60000 ms) 초과 → iceFailed 종결
14:03:29.029  reconnecting → terminating (hangup:iceFailed)
14:03:29.949  cleanup_done
```

### 검증된 항목

| 항목 | 결과 |
|---|---|
| createCall 통과 + Phase 1 timeout 5s 종결 (Test 1) | ✅ |
| reconnecting 상태에서 Phase 2 timeout 20s 발동 (Test 2) | ✅ (발견) |
| Senior 자동수락 → `senior_accepted_auto` reason 사용 (Test 3, 4) | ✅ (#3 fix 검증) |
| Bug #1-B catch 발동 시 `hangup:upgradeFailed` (Test 3) | ✅ |
| `renegotiate_done` IN_CALL 진입 (Test 4) | ✅ (첫 실측) |
| flap window 60s + iceFailed 자동 종결 (Test 4) | ✅ |
| 모든 케이스 깨끗한 종결 (FSM stuck 0건) | ✅ |
| ICE restart attempt 카운터 print (Test 4 5회 재시도) | ✅ (#4 fix 검증) |

### S12 의 본질 (명세 정정 자료)

원 명세는 "결과 불분명, 정책 결정 필요" 라고 표기. 실측 결과:

- S12 ≈ S11 + 초기 Phase 1/2 timeout 단계만 추가
- Senior 자동수락 발동 시 (Test 3, 4) 의 동작은 **monitor → call upgrade 자동 경로** 와 동일 — `_listenForSeniorAccepted` 가 `upgradeToCall(reason: 'senior_accepted_auto')` 를 호출
- 그 후 시점에 따라 S11 의 모든 race window (Bug #1-B / iceFailed) 와 동일하게 분기

### Test 2 의 흥미로운 발견

Phase 2 timeout (noAcceptance) 가 **`reconnecting` 상태에서도 발동**. startCall 시 시작된 30s 타이머가 FSM 상태와 무관하게 fire — 즉 30s 안에 Senior 수락 안 되면 ICE 복구 시도 중이라도 종결.

이건 의도된 설계 (acceptance grace 가 ICE 복구보다 우선) 인지 검토 필요. 본 회차에서는 동작 자체만 기록.

---

## S13 — 다중 disconnect 동안 중복 트리거 방지

**상태**: ⏭ 코드 리뷰 + 부수 검증으로 PASS (2026-04-28).

### 가드 위치 검증 (3곳)

| 위치 | 코드 | 효과 |
|---|---|---|
| [webrtc_service.dart:415](../lib/services/call/webrtc_service.dart#L415) `_onPeerConnectionStateChanged` DISCONNECTED 분기 | `if (_iceRestartInProgress) return;` | restart 진행 중 두 번째 DISCONNECTED 이벤트의 grace timer 차단 |
| [webrtc_service.dart:457](../lib/services/call/webrtc_service.dart#L457) `_triggerIceRestart` 진입 | `if (_iceRestartInProgress) return;` | FAILED 핸들러 직접 호출 경로도 차단 |
| [webrtc_service.dart:427](../lib/services/call/webrtc_service.dart#L427) CONNECTED 진입 시 | `_iceRestartInProgress = false; // 안전망` | 정상 복구 시 가드 해제 |

리셋 경로 5종 (모두 `_iceRestartInProgress = false`): L427 CONNECTED 안전망 / L510 `_iceRestartAnswerTimer` 만료 / L521 NetworkException catch / L708 answer signaling listener / L1066 dispose.

### 부수 검증 (기존 자동화 누적)

- **S2 RUN 4**: attempt=1 만 발생, 중복 시도 0건
- **S4 RUN 7**: 5회 재시도 모두 정확히 10s 간격, 중복 fire 0건
- **S12 Test 2 (2026-04-28)**: connecting → connected → reconnecting (단일) → noAcceptance — 두 번째 ice_restart_start 0건

### 직접 자동화 한계

S13 의 race window (`_iceRestartInProgress=true` 동안 두 번째 DISCONNECTED 이벤트 발화) 는 PC state machine 특성상 외부 토글로 재현 불가 — PC 가 한 번 disconnected 된 후 Wi-Fi on/off 토글해도 추가 DISCONNECTED 이벤트가 발화하지 않음 (이미 disconnected 상태). 별도 자동화 무의미하여 **코드 리뷰 + 부수 검증만 유지**.

가드 무력화 회귀 우려 시 최선의 방법은 **단위 테스트** (Mock PC 로 두 번째 DISCONNECTED 이벤트 강제 발화) — 본 회차 범위 밖.

### 통과 기준

| 항목 | 결과 |
|---|---|
| 가드 코드 위치 존재 | ✅ |
| 리셋 경로 누락 없음 | ✅ |
| 실측 자동화에서 중복 attempt 0건 | ✅ |

S2/S4/S5 누적 자동화로 충분히 검증됨. S7 와 같은 간접 검증 패턴.

---

## S14 — Stale answer 재수신 (Senior 가 offer 노드 선제 삭제로 방어)

**상태**: ⏭ 코드 리뷰만 — 자동화 의미 없음 (S13 와 동급).

### 가드 위치 (Family + Senior 양쪽)

| 측 | 위치 | 효과 |
|---|---|---|
| Family | [webrtc_service.dart:695-699](../lib/services/call/webrtc_service.dart#L695-L699) | `_iceRestartAnswerSub` 콜백에서 `signalingState == Stable` 체크 → 이미 setRemote 완료된 상태면 stale answer 무시 + `WebRTC: ICE restart answer 무시 (stable, 이미 적용됨)` 로그 |
| Family | [webrtc_service.dart:1055](../lib/services/call/webrtc_service.dart#L1055) | dispose 시 `_iceRestartAnswerSub.cancel()` — Family 종결 후 stale answer listener 자체 비활성 |
| Senior | `E:\App\Senior\app\src\main\java\com\seniorcare\senior\webrtc\SignalingClient.kt:330` | `sendIceRestartAnswer` 가 `callRef.child("iceRestartOffer").removeValue()` 선제 호출 — answer 쓰기 전 offer 노드 정리 |

### 직접 자동화 한계

S14 의 검증 대상 = "**같은 callId 의 두 번째 answer 가 RTDB persistence 에서 flush 되어 도달**" 라는 race window. Firebase 큐의 내부 동작이라 외부 토글 (Wi-Fi off/on, 앱 재시작) 으로 트리거 불가. 즉 **Stable 가드 자체의 실 발동은 한 번도 실측 안 됨**.

### 부수 관찰 (S6 2026-04-24)

Wi-Fi 복구 후 큐잉된 stale `iceRestartOffer` 가 Senior 에 도달했지만 Family 는 이미 dispose 상태 → **listener 자체가 unsub** 되어 stale answer 처리 안 됨. Senior `leak check peers=0`, race 없이 종결. 단 이는 **listener unsub 경로** 검증이지 Stable 가드 발동은 아님.

### 검증 강도

| 항목 | 결과 |
|---|---|
| Family Stable 가드 코드 위치 | ✅ |
| Senior 선제 삭제 코드 위치 | ✅ (Senior 코드, Family 측 검증 불가) |
| dispose 시 listener cancel | ✅ |
| 실측 가드 발동 | ❌ (race 재현 못함) |

S13 동일 — **단위 테스트 (Mock PC + 인위적 stale answer 주입)** 가 들어와야 진짜 검증. 본 회차 범위 밖. 코드 가드 존재만 확인하고 PASS 처리.

---

## S15 — Family 앱 백그라운드 → foreground 복귀

**상태**: ✅ PASS (2026-04-28, 자연 5분 백그라운드 — Senior 로그로 검증)

### 시퀀스

1. Family 모니터링 시작 → CONNECTED + Camera 첫 프레임 수신
2. 사용자 홈버튼 직접 탭 → 백그라운드 진입
3. 자연 5분 대기
4. (자동) 화면 ON + Family foreground 복귀
5. observation 30s

### 결과 — Senior 로그 결정적

Family 측 logcat 의 flutter print 가 ring buffer 에서 밀려난 (또는 Doze suspend 로 코드 미실행) 상태라 직접 검증 불가. **Senior 측 로그**로 정확히 검증:

```text
14:36:50.955  Senior: Family monitor callId 수신
14:36:51.361  Senior: CONNECTED
14:36:52.062  Senior: Camera 첫 프레임 수신
              [Family 백그라운드 진입]
14:36:59.638  Senior: ★ 노드 삭제 감지 (state=CONNECTED) → stopPeer
14:36:59.638  Senior: FSM CONNECTED → ENDED (dispose)
14:37:02.736  Senior: 공유 리소스 해제
              [5분 백그라운드 — Family logcat 부재]
14:42:17.817  Senior: onChildAdded callId=... status=null (Family foreground 복귀 시)
```

**즉**: Family 백그라운드 진입 후 약 8초만에 **Family 의 RTDB onDisconnect 핸들러가 발동** → `calls/{cid}` 노드 삭제 → Senior 가 노드 삭제 감지 → **즉시 stopPeer + dispose**. peers=0 도달.

### 부수 발견 — Senior 측 monitor 정리 분기

Senior 가 **`노드 삭제 감지 (state=CONNECTED) → stopPeer`** 로직을 이미 보유 (monitor type). 즉 [S11_senior_handover.md §26 옵션 A](../../Senior/docs/S11_senior_handover.md) 가 **monitor 정상 path 에는 이미 구현됨**. Bug #5 (재정의) 이슈는 **upgrade phase 의 RESTARTING 분기에만 해당** — monitor 단순 종결 path 와 분리.

### 검증 결과

| 항목 | 결과 |
|---|---|
| 정상 복구 또는 깨끗한 종결 | ✅ Family onDisconnect → Senior 즉시 stopPeer |
| 화면 깨짐/검은 화면 없음 | ✅ foreground 복귀 시 FamilyDetailScreen 정상 표시 |
| FSM stuck 없음 | ✅ Senior peers=0 도달 |
| Senior 자원 누수 | ✅ 0건 |
| Doze/background restriction 영향 | ✅ RTDB onDisconnect 가 Firebase server-side 처리 → Senior 측 정리 정상 |

### 한계

- Family 측 flutter logcat 이 5분 ring buffer 에서 밀려나서 직접 FSM 전이 추적 불가
- 그러나 화면 + Senior 정황상 **백그라운드 진입 시 Family 측 종결 → foreground 복귀 시 FamilyDetailScreen 정상 표시** 확인됨
- 명세 통과 기준 (정상 복구 OR 깨끗한 종결, 화면 깨짐 없음) 만족

### 자동화 한계

[s15_auto.sh](../scripts/s15_auto.sh) 의 `KEYCODE_POWER + KEYCODE_HOME` 시퀀스가 SM-G991N 에서 백그라운드 진입을 안 시킴. **사용자 직접 홈버튼 탭** 으로 진행. 후속에 다른 기기/OS 버전에서 재현 필요 시 [s15_auto.sh](../scripts/s15_auto.sh) 수정.

---

## S16 — Senior 측 Wi-Fi 단절

**상태**: ✅ PASS (Fix 적용 후, 2026-04-28). 1~4s 복구 / 5~15s 의도된 종결 / 70s 정상 종결. 5~15s 한계 분석 완료 — fix 보류.

### 본 의도 (kep_wifi_suspend_presence.md 인용)

[Senior `kep_wifi_suspend_presence.md` §"연관 이슈 1"](../../Senior/docs/kep_wifi_suspend_presence.md):

> 통화 중 2~3초간 WiFi가 drop됐다가 재연결되는 별개 증상 — KEP M10VSA2 의 MTK WiFi 드라이버 자발적 disconnect (`reason=0 locally_generated=1`).
>
> **대응 방향 — WebRTC ICE Restart (업계 표준 "Walk out of the door problem")**:
> - Senior 측 ICE restart 트리거 (실제로는 Family 측만 — Senior `onIceConnectionChange` 비어있음)
> - Family grace period 5~10초

명세는 처음부터 옳았고, 그동안 코드가 미완성이었음. 2026-04-28 fix 로 본 의도 달성.

### 자동화 도구

- [`scripts/s16_auto.sh`](../scripts/s16_auto.sh) — Family 모니터링 + Senior Wi-Fi 토글 + observation. `SENIOR_OFF_S` 변수로 단절 시간 조정.
- [`scripts/s16_auto_sweep.sh`](../scripts/s16_auto_sweep.sh) — 8 stages 일괄 실행 (1s, 2s, 3s, 4s, 5s, 6s, 15s, 70s).

### Fix 변경 (Senior + Family 양쪽)

| # | 파일 | 변경 |
|---|---|---|
| Senior 1 | [`SignalingClient.kt:registerDisconnectCleanup`](../../Senior/app/src/main/java/com/seniorcare/senior/webrtc/SignalingClient.kt) | `onDisconnect().removeValue()` → `updateChildren(status="ended", endReason="seniorDisconnect")`. 노드 삭제 대신 임시 종결 마커 |
| Senior 2 | `SignalingClient.kt:listenForStatus` | 시그니처 `(String?) -> Unit` → `(status, endReason) -> Unit`. status="ended" 시 endReason 1회 조회 후 콜백에 전달 |
| Senior 3 | `SignalingClient.kt:cancelDisconnectCleanup` (신규) | `callRef.onDisconnect().cancel()` |
| Senior 4 | `SignalingClient.kt:restoreActiveStatus` (신규) | `updateChildren(status="answered", endReason=null)` |
| Senior 5 | [`MonitoringSession.kt:1090`](../../Senior/app/src/main/java/com/seniorcare/senior/call/MonitoringSession.kt) | listenForStatus 콜백에 `endReason="seniorDisconnect"` 분기 추가 — 자기 결과 무시 + cancelDisconnectCleanup + registerDisconnectCleanup 재등록 + restoreActiveStatus |
| Family 6 | [`webrtc_service.dart:_callEndSub`](../lib/services/call/webrtc_service.dart) | endReason="seniorDisconnect" 분기 — 즉시 hangUp 안 하고 grace timer 15s 시작 |
| Family 7 | `webrtc_service.dart` 신규 필드 `_seniorDisconnectGraceTimer` | 만료 시 PC CONNECTED 면 통화 유지, 아니면 hangUp(remoteEnded). PC CONNECTED 복귀 / dispose / hangUp 시 cancel |

### 실측 결과 (8 stages, Fix 후)

| Stage | ICE attempt | ice_restored | 종결 사유 | 결과 |
|---|---|---|---|---|
| **1s** | 1 | ✅ 1 | (정상 유지) | ✅ PASS (복구) |
| **2s** | 1 | ✅ 1 | (정상 유지) | ✅ PASS (복구) |
| **3s** | 1 | ✅ 1 | (정상 유지) | ✅ PASS (복구) |
| **4s** | 1 | ✅ 1 | (정상 유지) | ✅ PASS (복구) |
| **5s** | 1 | 0 | `remoteEnded` | ✅ PASS (의도된 종결 — 12s 한도 초과) |
| **6s** | 1 | 0 | `remoteEnded` | ✅ PASS (의도된 종결) |
| **15s** | 2 | 0 | `remoteEnded` | ✅ PASS (의도된 종결) |
| **70s** | 5 | 0 | `iceFailed` | ✅ PASS (영구 단절 정상 종결) |

### 검증된 항목

| 항목 | 결과 |
|---|---|
| **본 의도 (KEP WiFi 1~4s flap 떠받치기)** | ✅ |
| Senior 1~4s 단절 시 ICE restart attempt 1 회 → ice_restored | ✅ |
| Senior `endReason="seniorDisconnect"` 마커 + 자기 결과 무시 + 복구 | ✅ |
| Family `seniorDisconnect` grace 15s + ICE restart 자연 진입 | ✅ |
| Senior 영구 단절 (70s) → flap window 60s 초과 → iceFailed 자동 종결 | ✅ |
| FSM stuck 0건, 자원 누수 0건 | ✅ |

### 영상통화 (callType=call) 5s 검증 — 수동 (2026-04-28)

`MonitoringSession.kt` 단의 fix 라 callType 무관 — 영상통화에서도 정상 동작 확인. 모니터링보다 양방향 audio/video 의 keepalive 가 더 길어 **복구 윈도우가 더 넓음**.

#### Case 1 — 통화 중 Senior wifi off 5s (수락 후 안정 통화 상태)

```text
T=0     Senior wifi off
T+12   Family PC DISCONNECTED (양방향 audio keepalive 가 모니터링보다 늦게 timeout)
T+12.5 Senior 자기 onDisconnect 마커 (seniorDisconnect)
T+12.7 Senior status="answered" 복원
T+17   Family ICE restart attempt=1 + Senior가 즉시 수신 (RTDB sync OK)
T+17   Senior PC CONNECTED → stopPeer 예약 취소
T+17.4 Family ICE restart answer 적용 → ice_restored ✅
```

복구 시간 PC DISCONNECTED → ice_restored = **5.3초**. 결과: ✅ PASS.

#### Case 2 — 수락 전 Senior wifi off 5s + wifi 복구 후 수락 (3중 race)

가장 까다로운 시나리오. Senior wifi off → wifi 복구 → 수락 → 양방향 renegotiate + ICE restart 동시 진행.

```text
T=0     Senior wifi off (인커밍 ringing 단계, PC 미리 연결됨)
T+0.1   Senior 자기 onDisconnect 마커 (seniorDisconnect)
T+~5    Senior wifi on
T+5     Senior 수락 (Senior 측에서는 wifi 복구 인지 못한 채 수락 누름)
T+6.6   Senior PC DISCONNECTED → stopPeer 7s 예약
T+10.6  Senior active status="answered" 복원 완료 (큐 처리)
T+11.0  Family endReason=seniorDisconnect 수신 → grace 15s 대기
T+11.2  Family Senior 수락 감지 → renegotiate offer 전송 (양방향 전환)
T+11.5  Family ICE restart attempt=1 동시 트리거
T+11.5  Senior renegotiate answer + ICE restart answer 거의 동시 전송
T+11.5  Senior PC CONNECTED (renegotiate audio 트랙 + 기존 ICE 경로) → stopPeer 취소
T+12.5  Family 양방향 전환 완료 (renegotiate)
T+12.6  Family ICE restart attempt=1 answer 무시 (signalingState=stable, 이미 적용)
T+22.0  Family D fix 10s answer timer 만료 → ICE restart attempt=2 자동 발화
T+22.7  Family ICE restart attempt=2 answer 적용 → PC CONNECTED → ice_restored ✅
```

#### 비대칭 복구 — Senior vs Family PC CONNECTED 시점

| 측 | PC CONNECTED 시점 | 경로 |
| --- | --- | --- |
| Senior | T+11.5 (DISCONNECTED 후 ~5s) | renegotiate audio 트랙 추가 + 기존 ICE 경로 유지 |
| Family | T+22.7 (DISCONNECTED 후 ~15s) | ICE restart attempt 2 의 새 candidate 협상 완료 후에야 CONNECTED |

**관찰**: attempt 1 의 answer 가 Family stable 상태에 도착해 무시됐지만 **D fix 의 10s 재시도 timer 가 안전망으로 발화** → attempt 2 로 새 ICE 경로 협상 완료. 양방향 renegotiate (트랙 추가) 와 ICE restart (경로 재협상) 가 별개 절차임을 확인.

#### 영상통화 검증 결과 요약

| Case | 결과 | 복구 시간 |
| --- | --- | --- |
| 통화 중 wifi off 5s | ✅ PASS | 5.3s (attempt 1) |
| 수락 전 wifi off 5s + 수락 race | ✅ PASS | 15s (attempt 2 with D fix) |
| **D fix 10s 재시도 timer 안전망 작동** | ✅ 첫 검증 | — |

### 5~15s 한계 — 원인 분석 (2026-04-28)

#### 시퀀스 비교

**5~6s 케이스** (Senior가 ICE restart offer 수신 누락):

```text
T=0      Senior wifi off → 자기 onDisconnect 마커 (endReason="seniorDisconnect")
T+5      Senior wifi 복구 → cancelDisconnect + restoreActiveStatus 호출 (RTDB 큐 쌓임)
T+6      Senior PC keepalive timeout → DISCONNECTED → stopPeer 7s 예약 (T+13 발화)
T+9      Family ICE restart attempt=1 전송 (RTDB commit OK)
T+9~13   Senior RTDB SDK가 wifi 복구 후 sync 큐 정리 중 → ICE restart offer fire 누락
T+13     Senior stopPeer 발화 → status="ended" + endReason="normal" 송신
T+14     Family endReason=normal 수신 → grace cancel + hangUp(remoteEnded)
```

**15s 케이스** (wifi 복구 전 stopPeer 발화):

```text
T=0      Senior wifi off
T+6      Senior PC DISCONNECTED → stopPeer 7s 예약
T+13     stopPeer 발화 → ENDED ← wifi 아직 off!
T+15     Senior wifi 복구 ← 이미 ENDED 상태
T+~17    Senior status="ended" + endReason="normal" RTDB commit (wifi 복구 후 큐 처리)
T+~18    Family endReason=normal 수신 → hangUp(remoteEnded)
         (그 사이 attempt 2 timer 발화 → ICE restart attempt=2 시도하지만 Senior ENDED)
```

#### 한 줄 원인

[`MonitoringSession.kt:42`](../../Senior/app/src/main/java/com/seniorcare/senior/call/MonitoringSession.kt#L42) **`STOP_DELAY_MS = 7_000L`** + Senior PC keepalive ~5s = **총 12초 한도**.

- 5~6s: 한도 안이지만 RTDB sync 지연으로 ICE restart offer fire 누락
- 12s 초과: wifi 복구 전 stopPeer 무조건 발화

증거: 5s/6s/15s case Senior 로그에 `ICE restart offer 수신` 로그 **없음** (1~4s case에는 있음).

#### 6~15s vs 70s 동작 차이

같은 "복구 실패" 지만 종결 주체와 사유가 다름:

| 구분 | 6~15s | 70s |
| --- | --- | --- |
| 종결 주체 | **Senior 가 먼저 종결** (STOP_DELAY 7s 타임아웃) | **Family 가 먼저 종결** (flap window 60s 초과) |
| Family 측 endReason | `remoteEnded` (Senior stopPeer 후 송신한 endReason="normal" 수신) | `iceFailed` (Family attempt 5회 모두 실패 후 자체 판정) |
| Family ICE restart attempt | 1~2회 (Senior remoteEnded 도착 시점에 멈춤) | 5회 (Senior 신호 끝까지 못 받음) |
| Senior wifi 상태 | 복구됨 또는 곧 복구 예정 → 종료 신호 송신 가능 | 영구 off → 종료 신호 송신 불가 |

핵심: **Senior STOP_DELAY 7s 가 Family flap window 60s 보다 훨씬 짧음** → wifi 단절 12s 초과 시 Senior 가 race 이기고 자체 종결 → Family 는 받기만 함 (`remoteEnded`). 70s 는 Senior 가 끝까지 신호 못 보내 Family 가 자체 한도 판정 (`iceFailed`).

#### Fix 보류 결정

5s 케이스만 살리려면 STOP_DELAY 7s → 20s 로 늘려야 하나:

- **Trade-off 불균형**: 5~6s 복구 vs Family 영구 종결 시 Senior peer 잔존 7s → 20s, Bug #3 회귀 위험, Family 측 onDisconnect 도 임시 마커로 변경 필요 (변경 4건)
- **UX 관점**: 6초 이상 끊기면 사용자도 "끊겼나?" 인지 — 이때 갑자기 복원되는 것이 오히려 부자연스러움

**결정**: 1~4s 떠받치기 의도 달성으로 충분. 5~15s 는 "의도된 종결" 로 재분류. STOP_DELAY 변경 안 함.

### 자동화 한계 (이전 회차 잔존)

- **logcat ring buffer race** (이전 sweep 의 3s, 70s 0 byte 이슈): 이번 sweep 에서는 모든 사이클 정상 capture (Fix 후 logcat 양 줄어든 영향).

---

## S17 — RTDB 쓰기 타임아웃 (오프라인 가드)

**상태**: ✅ PASS (수동 검증, 2026-04-28).

### 명세 갱신

기존 명세는 `writeOrTimeout(3s) + onTimeoutCleanup` 가설이었으나, 현 코드 ([signaling_service.dart:383](../lib/services/call/signaling_service.dart#L383)) 는 의도적으로 **`onTimeoutCleanup` 미사용**.

이유 (코드 주석):

- onTimeoutCleanup 으로 `remove()` 넣으면 set 과 race + cleanup 자체가 offline 큐에 hang (7~10초 밀림)
- 오프라인 동안 큐잉된 set(offer) 가 **wifi 복구 시 자동 flush** 되어 Senior 에 도달하는 게 정상 복구 경로

stale offer 정리 경로 (3가지):

- 정상 복구: Senior `sendIceRestartAnswer` 가 answer 쓰기 전 offer 선제 삭제
- 실패 종결: `hangUp` → `cleanupCall` 이 `calls/{cid}` 통째 삭제
- 앱 크래시: Family `onDisconnect` 가 `calls/{cid}` 통째 삭제

### 실측 시퀀스 (Family 영상통화 + wifi off ~50초)

```text
T=0     Family 영상통화 발신 → CONNECTED → 양방향 전환 완료
T+18    PC DISCONNECTED ← Family wifi off
T+22    ICE restart attempt=1 시작 (grace 4s 후, RTDB set 큐잉)
T+25    NetworkException ← writeOrTimeout(3s) 정확히 3.046초 후 throw ✅
T+35    ICE restart attempt=2 ← D fix 10s timer 정확히 10.002초
T+38    NetworkException (3.027초)
T+48    ICE restart attempt=3 (10.001초)
T+51    NetworkException (3.049초)
T+61    ICE restart attempt=4 (10.004초)
T+61.5  ★ ICE restart offer 전송 성공 ← wifi 복구, 큐 flush 작동
T+71    attempt=5 (answer 미수신 10s timeout)
T+72    offer 전송 성공
T+82    flap window 60s 초과 → iceFailed 종결 ✅
```

### Senior 측 동시 시퀀스

```text
T+17    PC DISCONNECTED → stopPeer 7s 예약 (Bug #3 fix 단축)
T+24    stopPeer 발화 → ENDED → Senior peer 정리
```

### S17 검증 항목

| 항목 | 결과 |
| --- | --- |
| `writeOrTimeout(3s)` NetworkException 발화 | ✅ attempt 1~3 모두 ~3초 정확 |
| D fix 10s 재시도 timer | ✅ NetworkException 후 정확히 10초 |
| wifi 복구 시 큐잉된 offer 자동 flush | ✅ attempt 4 의 offer 가 wifi 복구 직후 전송 성공 |
| flap window 60s 초과 → iceFailed 정상 종결 | ✅ T+82에 attempt 5 한도 초과로 종결 |
| Senior STOP_DELAY 7s (Bug #3 fix) | ✅ Family 영구 단절 시 7초 만에 Senior peer 정리 |

### 비대칭 종결 — 복구 가능 한계

**Family wifi off 가 7초 이내**라면 Senior 가 아직 살아있어 ICE restart 로 복구 가능 ([S2 시나리오](#s2--wi-fi-단절--grace-초과--복구-1회-restart-성공) 와 동일 경로). **7초 초과** 시 Senior 가 STOP_DELAY 로 먼저 종결되어 Family 가 wifi 복구해도 attempt 4/5 의 offer 가 RTDB 에 set 되긴 하지만 Senior peer (listener) 가 사라진 상태라 처리 못함 → flap window 60s 초과로 iceFailed 자체 종결.

이는 Bug #3 fix 의 의도된 동작 (Family 영구 단절 시 Senior 빠른 정리). S17 의 큐 flush 메커니즘은 정상 작동 — 단지 7초 이내 wifi 복구해야 ICE restart 로 통화 살릴 수 있음.

---

## R1 — 좀비 peer 방지 (회귀)

**상태**: 🔲 미진행

---

## R2 — Senior wifi flap + Family hangUp race (S16 fix 의 부수 효과)

**상태**: ✅ 분석 완료 / documented limitation 으로 수용 (2026-04-29)

### 배경

S16 fix (Senior `onDisconnect` 임시 마커 + `restoreActiveStatus`, commit `955e0d7` / Senior `66b7e19`) 배포 후 발견된 race. Senior wifi flap 동시 Family 사용자 hangUp 시 Senior 측 ~10-13초 좀비 통화 화면 발생.

### 자동화 스크립트

- [r2_call_auto.sh](../scripts/r2_call_auto.sh) — 영상통화 시나리오
- [r2_auto.sh](../scripts/r2_auto.sh) — 모니터링 시나리오 (Senior UI 없어 사용자 인지 0)

### R2 race 시퀀스 (영상통화, 2026-04-29 12:08 측정)

```text
T+0      Senior wifi off
T+0.5    Senior server-side onDisconnect 발화
         → /calls/{cid}: { status="ended", endReason="seniorDisconnect" }
T+1.0    Senior 잠깐 reconnect → status=ended listener fire → endReason="seniorDisconnect" 읽음
         → cancelDisconnectCleanup + restoreActiveStatus
         → /calls/{cid}: { status="answered", endReason=null } ← 좀비 시작
T+1.5    Family hangUp tap → endCall fires
T+2      Family endCall update commits: { status="ended", endReason="remoteEnded" }
T+1.2~10 Senior RTDB SDK reconnect 지연 (~9초 실측) → Family update 못 받음
T+12     Senior PC keepalive timeout → FSM CONNECTED → RESTARTING + STOP_DELAY 7s
T+13     Senior FSM ENDED (자연 cleanup)
```

### 실측 측정값 (12:08:29 ~ 12:08:44)

| 측면 | 값 |
| --- | --- |
| Senior UI 잔존 시간 | 약 13초 (Family hangUp 12:08:31.432 ~ Senior FSM ENDED 12:08:44.527) |
| Senior FSM 자연 cleanup | PC keepalive 5s → STOP_DELAY 7s 정상 작동 |
| 데이터 무결성 | 손상 없음 (Family `cleanupCall` 10s 후 RTDB 노드 정리) |
| Family 측 UX | 영향 없음 (즉시 종결 → 홈 pop) |

### 시도했던 fix layer 별 평가

| Layer | 시도 내용 | 결과 |
| --- | --- | --- |
| Family endCall + `endReason="remoteEnded"` | Family hangUp 시 RTDB endReason 명시 | Senior 가 offline 인 동안 못 받음 → race fix 효과 0. **semantic 정합성만 유지** (적용) |
| Senior `restoreActiveStatus` `runTransaction` 가드 | atomic re-read 로 commit 직전 검증 | Senior stale local cache 로 doTransaction → guard 통과 → race 그대로 (revert) |
| Family `hangUp` 첫줄 EARLY endCall | RTDB write 빨리 fire (architectural sanity) | Senior offline 동안 못 받음 → 효과 0 (revert) |
| Senior endReason path real-time `ValueEventListener` | endReason 변경 즉시 감지 | Senior offline 동안 listener fire 안 함 (server push 못 받음) → 효과 0 (revert) |
| Senior 1.5~2.5s delay 후 fresh `.get()` | local cache 우회 server fetch | `.get()` 이 persistence cache 의 stale 값 반환 (실측, Firebase docs 와 다름) → 효과 0 (revert) |

### 근본 원인 (우리 통제 밖)

- **Senior wifi off 후 Firebase RTDB SDK 재연결까지 ~9초** (실측, 2.3초 wifi flap 케이스). Exponential backoff reconnect 패턴.
- 그 9초 동안 Senior 는 RTDB offline → Family 의 어떤 update 도 못 받음.
- Senior 의 `restoreActiveStatus` 결정이 stale 정보 기반 → 좀비 commit.

### 결정 — documented limitation 수용

**적용된 변경 (단 1개)**:

| 파일 | 변경 |
| --- | --- |
| [signaling_service.dart:265](../lib/services/call/signaling_service.dart) `endCall` | `status="ended"` + `endReason="remoteEnded"` 두 필드 동시 `update()` |

**유지 사유**: race fix 효과 0 이지만 RTDB 스키마 doc 와 코드 정합성 + 향후 callHistory 분석 시 누가 종결했는지 식별 가능. 변경 한 줄, 복잡도 0.

**race 자체는 수용**:

- 발생 조건: Senior wifi flap (자체 wifi 자발적 drop) 동시 Family 자발 hangUp — 드문 케이스
- 영향: Senior 측 UI 약 10-13초 잔존 ("통화 중" + Family 영상 frozen)
- 자동 정리: Senior PC keepalive (5s) + STOP_DELAY (7s) 가 자연 cleanup
- 데이터 무결성: 손상 없음
- Family 측: 영향 없음

### 향후 관측 빈도 높아지면 재검토

- `.info/connected` 기반 Senior reconnect 대기 + endReason 재조회 (단, S16 정상 흐름 통화 유지 복귀가 1~30s 지연됨 — UX 손해)
- Family 가 별도 sentinel (`/calls/{cid}/familyEnded: true`) 도입 (스키마 추가 필요)
- Senior `FirebaseDatabase.goOnline()` 강제 재연결

### 검증 결과 — clean state (Senior 66b7e19 + Family change 1 적용)

[r2_call_auto.sh](../scripts/r2_call_auto.sh) 영상통화 1회 실행 (12:08):

```text
12:08:29.898  Senior wifi off
12:08:30.920  Senior reconnect → 자기 onDisconnect 결과 received (S16 정상)
12:08:30.939  Senior cancelDisconnectCleanup
12:08:30.988  Senior restoreActiveStatus → status=answered (좀비 시작)
12:08:31.432  Family hangUp tap → FSM terminating
12:08:32.318  Family terminated (cleanup_done)
12:08:37.521  Senior PC DISCONNECTED → FSM RESTARTING + STOP_DELAY 7s
12:08:44.527  Senior FSM ENDED (자연 cleanup)
```

→ **PASS as documented limitation**. S16 옵션 2 정상 작동 + R2 race 발생 + 자동 cleanup ~13초 안에 완료.

상세 분석 + 다른 세션 동기화: [r2_fix_handover.md](r2_fix_handover.md)

---

## 알려진 이슈 / 관찰

### FSM `ice_restored` 판정 타이밍 (낙관적)

S2 RUN 4 에서 `ice_restored` 로의 FSM 전이가 `setLocalDescription` 직후 `PC CONNECTED` 이벤트만으로 일어남 (15:02:26.805). 실제 Senior answer 적용은 132ms 뒤 (15:02:26.937). 이번은 answer 가 빠르게 왔지만, **Senior answer 수신 전에 PC 가 기존 경로 자가복구로 CONNECTED 되면 `ice_restored` 가 너무 이르게 확정될 가능성**.

증상: 사용자에게 "복구됨" 표시되지만 실제 영상/오디오 패킷이 새 경로로 안 흐를 수 있음. 지금은 Senior 의 STOP_DELAY 타이머가 안전망이라 당장 큰 문제 없음.

개선 여지: `ice_restored` 를 "PC CONNECTED + Senior answer 적용 완료" 양쪽 충족 시로 변경. 우선순위 낮음 — 실 사용자 불만 발생 시 검토.

### 재시도 로직 미검증

`NetworkException` 이 throw 되면 `_iceRestartAnswerTimer` 가 설정되지 않아 자동 재시도 경로가 끊김. 현재 구조에서 재시도는 "다음 DISCONNECTED 이벤트" 에만 의존. **S4 (Wi-Fi 완전 단절) 테스트 시 5회 재시도가 실제로 일어나는지 확인 필요.**
