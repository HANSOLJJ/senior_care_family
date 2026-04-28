#!/bin/bash
# S16 자동 — Senior Wi-Fi 단절 (반대 방향)
#
# 시퀀스:
#   1. (자동) Family 모니터링 시작 → CONNECTED
#   2. 안정화 5s
#   3. Senior Wi-Fi off
#   4. SENIOR_OFF_S 만큼 대기 (기본 6 — grace 4s + 여유)
#   5. Senior Wi-Fi on
#   6. observation
#   7. 결과 분류 — Family 측 ICE restart 동작
#
# 주의:
#   - KEP M10VSA2 의 WiFi 자발적 drop 이슈 (Senior CLAUDE.md) 가능 → 노이즈 가능성
#   - Senior 자동수락 (얼굴인식) 영향 없음 (monitor type 만 검증)
#
# 환경 변수:
#   SENIOR_OFF_S   Senior Wi-Fi off 유지 시간 (기본 6s)
#   OBSERVE_S      복구 후 관찰 시간 (기본 30s)
#
# 사용법:
#   bash scripts/s16_auto.sh                          # 기본 (6초 off, S2 대칭)
#   SENIOR_OFF_S=15 bash scripts/s16_auto.sh          # 좀 더 긴 단절
#   SENIOR_OFF_S=70 bash scripts/s16_auto.sh          # flap window 60s 초과 (S4 대칭)

set +e
trap 'echo "[S16] cleanup: Senior Wi-Fi enable"; adb -s KEP2024120921 shell svc wifi enable >/dev/null 2>&1' EXIT

FAMILY_DEVICE=R3CR700SEKP
SENIOR_DEVICE=KEP2024120921

MONITOR_BTN_X=795
MONITOR_BTN_Y=918

SENIOR_OFF_S=${SENIOR_OFF_S:-6}
OBSERVE_S=${OBSERVE_S:-30}

LOG_DIR=e:/tmp/s16_auto
mkdir -p "$LOG_DIR"

PID_F=$(adb -s $FAMILY_DEVICE shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR_DEVICE shell pidof com.seniorcare.senior | tr -d '\r')
echo "PID_F=$PID_F PID_S=$PID_S"
if [ -z "$PID_F" ] || [ -z "$PID_S" ]; then
  echo "[S16] ERROR: app not running"
  exit 1
fi

echo "[S16] === START (senior_off=${SENIOR_OFF_S}s, observe=${OBSERVE_S}s) ==="

# Step 0: 다이얼로그 dismiss
DIALOG_DUMP=$(adb -s $FAMILY_DEVICE shell "uiautomator dump /sdcard/_s16_check.xml >/dev/null 2>&1; cat /sdcard/_s16_check.xml" 2>/dev/null)
if echo "$DIALOG_DUMP" | grep -q 'content-desc="확인"'; then
  OK_BOUNDS=$(echo "$DIALOG_DUMP" | grep -oE 'content-desc="확인"[^/]*bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1 | grep -oE 'bounds="\[[0-9,]+\]\[[0-9,]+\]"' | tr -dc '0-9,')
  X1=$(echo "$OK_BOUNDS" | cut -d, -f1); Y1=$(echo "$OK_BOUNDS" | cut -d, -f2)
  X2=$(echo "$OK_BOUNDS" | cut -d, -f3); Y2=$(echo "$OK_BOUNDS" | cut -d, -f4)
  CX=$(( (X1 + X2) / 2 )); CY=$(( (Y1 + Y2) / 2 ))
  echo "[S16] Dismiss 다이얼로그 ($CX,$CY)"
  adb -s $FAMILY_DEVICE shell input tap $CX $CY
  sleep 1
fi

# Step 1: 모니터링 시작
BASELINE_F=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | wc -l)
BASELINE_S=$(adb -s $SENIOR_DEVICE logcat -d --pid=$PID_S 2>/dev/null | wc -l)
echo "[S16] Tap 모니터링 ($MONITOR_BTN_X,$MONITOR_BTN_Y) @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell input tap $MONITOR_BTN_X $MONITOR_BTN_Y

CONNECTED=0
for i in {1..20}; do
  sleep 0.5
  NEW=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)))
  if echo "$NEW" | grep -q "answer_received"; then
    CONNECTED=1
    echo "[S16] FSM connected @ $(date +%T.%3N)"
    break
  fi
done
if [ "$CONNECTED" -eq 0 ]; then
  echo "[S16] ERROR: monitor connect 실패"
  exit 1
fi

sleep 5  # 안정화

# Step 2: Senior Wi-Fi off
T_OFF=$(date +%T.%3N)
echo "[S16] Senior Wi-Fi off @ $T_OFF"
adb -s $SENIOR_DEVICE shell svc wifi disable

# Step 3: 단절 유지
echo "[S16] Senior Wi-Fi off ${SENIOR_OFF_S}s 유지..."
sleep $SENIOR_OFF_S

# Step 4: Senior Wi-Fi on
T_ON=$(date +%T.%3N)
echo "[S16] Senior Wi-Fi on @ $T_ON"
adb -s $SENIOR_DEVICE shell svc wifi enable

# Step 5: observation
echo "[S16] Observation ${OBSERVE_S}s..."
sleep $OBSERVE_S

sleep 5

# 로그 저장
SUFFIX=${SENIOR_OFF_S}s
adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)) > "$LOG_DIR/family_${SUFFIX}.log"
adb -s $SENIOR_DEVICE logcat -d -v time -b all > "$LOG_DIR/senior_${SUFFIX}.log" 2>&1

NEW_F="$(cat $LOG_DIR/family_${SUFFIX}.log)"

echo "[S16] === RESULT ==="

# 카운트
DISCONNECT_COUNT=$(echo "$NEW_F" | grep -c "RTCPeerConnectionStateDisconnected")
CONNECTED_COUNT=$(echo "$NEW_F" | grep -c "RTCPeerConnectionStateConnected")
ICE_START_COUNT=$(echo "$NEW_F" | grep -c "ice_restart_start")
ICE_RESTORED_COUNT=$(echo "$NEW_F" | grep -c "ice_restored")
ATTEMPT_COUNT=$(echo "$NEW_F" | grep -c "ICE restart attempt=")
HANGUP_REASON=$(echo "$NEW_F" | grep -oE 'hangup:[a-zA-Z]+' | tail -1 | sed 's/hangup://')

echo "[S16] Family 측 카운트:"
echo "  PC DISCONNECTED: $DISCONNECT_COUNT"
echo "  PC CONNECTED:    $CONNECTED_COUNT"
echo "  ICE restart attempt: $ATTEMPT_COUNT"
echo "  ice_restart_start:   $ICE_START_COUNT"
echo "  ice_restored:        $ICE_RESTORED_COUNT"
echo "  종결 사유:           ${HANGUP_REASON:-(정상 유지 또는 진행 중)}"

echo ""
echo "[S16] Family 주요 이벤트:"
echo "$NEW_F" | grep -E "\[FSM\]|연결 상태 = RTCPeerConnectionState|hangup:|ICE restart attempt|네트워크 실패|ice_restored|cleanup_done" | head -25

echo ""

# 결과 분류
case "$HANGUP_REASON" in
  "")
    if [ $ICE_RESTORED_COUNT -gt 0 ]; then
      echo "[S16] ✅ 정상 복구 — ICE restart 후 ice_restored (Senior Wi-Fi 복귀 정상 처리)"
    elif [ $DISCONNECT_COUNT -eq 0 ]; then
      echo "[S16] ⚠ Family 측 PC DISCONNECTED 0건 — Senior Wi-Fi 단절이 Family PC 에 영향 안 줌 (이상)"
    else
      echo "[S16] ⚠ DISCONNECTED 발생했지만 ice_restored / hangup 기록 없음 — 진행 중 또는 미완"
    fi ;;
  iceFailed)
    echo "[S16] ✅ iceFailed — flap window/한도 초과 자동 종결 (Senior 영구 단절 시 정상)" ;;
  remoteEnded)
    echo "[S16] ⚠ remoteEnded — Senior 측에서 종결 신호 (Senior 자체 정리 가능성)" ;;
  *)
    echo "[S16] ⚠ 종결 사유: $HANGUP_REASON" ;;
esac

echo ""
echo "[S16] Logs:"
echo "  $LOG_DIR/family_${SUFFIX}.log"
echo "  $LOG_DIR/senior_${SUFFIX}.log"

# Cleanup: 모니터링 살아있으면 종료 (정상 복구 케이스). iceFailed 종결된 경우 빈 영역 탭이라 무해.
adb -s $FAMILY_DEVICE shell input tap 768 2202 >/dev/null 2>&1
sleep 2

echo "[S16] === DONE ==="
