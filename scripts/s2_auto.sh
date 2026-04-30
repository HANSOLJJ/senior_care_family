#!/bin/bash
# S2 자동 — Family Wi-Fi 단절 (plan A 검증용 — familyDisconnect 마커 + Senior grace)
#
# 시퀀스:
#   1. Family 모니터링 시작 → CONNECTED
#   2. 안정화 5s
#   3. Family Wi-Fi off
#   4. FAMILY_OFF_S 만큼 대기
#   5. Family Wi-Fi on
#   6. observation
#   7. 결과 분류 — Family/Senior 양측 동작
#      (familyDisconnect 마커 / 자기 마커 무시 / ICE restart 1회 / Senior grace / networkLost)
#
# Plan A 핵심 검증:
#   - Family setCallCleanupOnDisconnect 가 .remove() 가 아닌 .updateChildren() 마커 set
#   - Senior listenForStatus 의 familyDisconnect 분기 → grace 진입
#   - Family _callEndSub 의 자기 마커 무시 (PC CONNECTED) 또는 networkLost 종결 (PC 미복구)
#   - Family ICE restart 1회 시도 (재시도 없음)
#   - Senior STOP_DELAY 7s 안에 ICE restart offer 받으면 통화 유지
#
# 환경 변수:
#   FAMILY_OFF_S   Family Wi-Fi off 유지 시간 (기본 3s)
#   OBSERVE_S      복구 후 관찰 시간 (기본 30s)
#
# 사용법:
#   bash scripts/s2_auto.sh                          # 기본 3s off
#   FAMILY_OFF_S=1 bash scripts/s2_auto.sh           # 짧은 flap (PC keepalive 자가 복구)
#   FAMILY_OFF_S=6 bash scripts/s2_auto.sh           # ICE restart 1회 시도 (Senior grace 안)
#   FAMILY_OFF_S=15 bash scripts/s2_auto.sh          # Senior STOP_DELAY 만료 케이스
#   FAMILY_OFF_S=70 bash scripts/s2_auto.sh          # 영구 끊김 (networkLost 종결)

set +e
trap 'echo "[S2] cleanup: Family Wi-Fi enable"; adb -s R3CR700SEKP shell svc wifi enable >/dev/null 2>&1' EXIT

FAMILY_DEVICE=R3CR700SEKP
SENIOR_DEVICE=KEP2024120921

MONITOR_BTN_X=795
MONITOR_BTN_Y=918

FAMILY_OFF_S=${FAMILY_OFF_S:-3}
OBSERVE_S=${OBSERVE_S:-30}

LOG_DIR=e:/tmp/s2_auto
mkdir -p "$LOG_DIR"

PID_F=$(adb -s $FAMILY_DEVICE shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR_DEVICE shell pidof com.seniorcare.senior | tr -d '\r')
echo "PID_F=$PID_F PID_S=$PID_S"
if [ -z "$PID_F" ] || [ -z "$PID_S" ]; then
  echo "[S2] ERROR: app not running"
  exit 1
fi

echo "[S2] === START (family_off=${FAMILY_OFF_S}s, observe=${OBSERVE_S}s) ==="

# Step 0: 다이얼로그 dismiss
DIALOG_DUMP=$(adb -s $FAMILY_DEVICE shell "uiautomator dump /sdcard/_s2_check.xml >/dev/null 2>&1; cat /sdcard/_s2_check.xml" 2>/dev/null)
if echo "$DIALOG_DUMP" | grep -q 'content-desc="확인"'; then
  OK_BOUNDS=$(echo "$DIALOG_DUMP" | grep -oE 'content-desc="확인"[^/]*bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1 | grep -oE 'bounds="\[[0-9,]+\]\[[0-9,]+\]"' | tr -dc '0-9,')
  X1=$(echo "$OK_BOUNDS" | cut -d, -f1); Y1=$(echo "$OK_BOUNDS" | cut -d, -f2)
  X2=$(echo "$OK_BOUNDS" | cut -d, -f3); Y2=$(echo "$OK_BOUNDS" | cut -d, -f4)
  CX=$(( (X1 + X2) / 2 )); CY=$(( (Y1 + Y2) / 2 ))
  echo "[S2] Dismiss 다이얼로그 ($CX,$CY)"
  adb -s $FAMILY_DEVICE shell input tap $CX $CY
  sleep 1
fi

# SnackBar "다시 걸기" 자동 dismiss 대기 (1.5s 자동 dismiss + 마진)
sleep 2

# Step 1: 모니터링 시작
BASELINE_F=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | wc -l)
BASELINE_S=$(adb -s $SENIOR_DEVICE logcat -d --pid=$PID_S 2>/dev/null | wc -l)
echo "[S2] Tap 모니터링 ($MONITOR_BTN_X,$MONITOR_BTN_Y) @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell input tap $MONITOR_BTN_X $MONITOR_BTN_Y

CONNECTED=0
for i in {1..20}; do
  sleep 0.5
  NEW=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)))
  if echo "$NEW" | grep -q "answer_received"; then
    CONNECTED=1
    echo "[S2] FSM connected @ $(date +%T.%3N)"
    break
  fi
done
if [ "$CONNECTED" -eq 0 ]; then
  echo "[S2] ERROR: monitor connect 실패"
  exit 1
fi

sleep 5  # 안정화

# Step 2: Family Wi-Fi off
T_OFF=$(date +%T.%3N)
echo "[S2] Family Wi-Fi off @ $T_OFF"
adb -s $FAMILY_DEVICE shell svc wifi disable

# Step 3: 단절 유지
echo "[S2] Family Wi-Fi off ${FAMILY_OFF_S}s 유지..."
sleep $FAMILY_OFF_S

# Step 4: Family Wi-Fi on
T_ON=$(date +%T.%3N)
echo "[S2] Family Wi-Fi on @ $T_ON"
adb -s $FAMILY_DEVICE shell svc wifi enable

# Step 5: observation
echo "[S2] Observation ${OBSERVE_S}s..."
sleep $OBSERVE_S

sleep 5

# 로그 저장
SUFFIX=${FAMILY_OFF_S}s
adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)) > "$LOG_DIR/family_${SUFFIX}.log"
adb -s $SENIOR_DEVICE logcat -d --pid=$PID_S 2>/dev/null | tail -n +$((BASELINE_S+1)) > "$LOG_DIR/senior_${SUFFIX}.log"

NEW_F="$(cat $LOG_DIR/family_${SUFFIX}.log)"
NEW_S="$(cat $LOG_DIR/senior_${SUFFIX}.log)"

echo "[S2] === RESULT ==="

# Family 측 카운트
DISCONNECT_COUNT=$(echo "$NEW_F" | grep -c "RTCPeerConnectionStateDisconnected")
CONNECTED_COUNT=$(echo "$NEW_F" | grep -c "RTCPeerConnectionStateConnected")
ATTEMPT_COUNT=$(echo "$NEW_F" | grep -c "ICE restart 1회 시도 시작")
ICE_RESTORED_COUNT=$(echo "$NEW_F" | grep -c "ice_restored")
SELF_MARKER_IGNORED=$(echo "$NEW_F" | grep -c "자기 familyDisconnect 마커 무시")
SELF_MARKER_HANGUP=$(echo "$NEW_F" | grep -c "자기 familyDisconnect 마커 + PC 미복구")
HANGUP_REASON=$(echo "$NEW_F" | grep -oE 'hangup:[a-zA-Z]+' | tail -1 | sed 's/hangup://')

# Senior 측 카운트
SENIOR_GRACE=$(echo "$NEW_S" | grep -c "Family wifi flap 추정 → grace 진입")
SENIOR_RESTART_RECV=$(echo "$NEW_S" | grep -c "ICE restart offer 수신 → 재협상")
SENIOR_RESTART_DUP=$(echo "$NEW_S" | grep -c "이미 1회 소진")
SENIOR_STOPPEER_SCHED=$(echo "$NEW_S" | grep -c "stopPeer 예약 (")
SENIOR_STOPPEER_CANCEL=$(echo "$NEW_S" | grep -c "stopPeer 예약 취소")

echo "[S2] Family 측 카운트:"
echo "  PC DISCONNECTED: $DISCONNECT_COUNT"
echo "  PC CONNECTED:    $CONNECTED_COUNT"
echo "  ICE restart 1회 시도 시작: $ATTEMPT_COUNT"
echo "  ice_restored:              $ICE_RESTORED_COUNT"
echo "  자기 마커 무시 (PC CONNECTED): $SELF_MARKER_IGNORED"
echo "  자기 마커 hangUp(networkLost): $SELF_MARKER_HANGUP"
echo "  종결 사유: ${HANGUP_REASON:-(정상 유지 또는 진행 중)}"

echo ""
echo "[S2] Senior 측 카운트:"
echo "  familyDisconnect grace 진입: $SENIOR_GRACE"
echo "  ICE restart 수신 (1-shot):   $SENIOR_RESTART_RECV"
echo "  ICE restart sticky 차단:     $SENIOR_RESTART_DUP"
echo "  STOP_DELAY 예약 (7s):        $SENIOR_STOPPEER_SCHED"
echo "  STOP_DELAY 예약 취소 (복구): $SENIOR_STOPPEER_CANCEL"

echo ""
echo "[S2] Family 주요 이벤트:"
echo "$NEW_F" | grep -E "\[FSM\]|연결 상태 = RTCPeerConnectionState|hangup:|ICE restart 1회 시도|familyDisconnect|ice_restored|networkLost|cleanup_done" | head -30

echo ""
echo "[S2] Senior 주요 이벤트:"
echo "$NEW_S" | grep -E "Family wifi flap|ICE restart offer 수신|이미 1회 소진|stopPeer|RESTARTING|ENDED|familyDisconnect|status=null" | head -25

echo ""

# 결과 분류
case "$HANGUP_REASON" in
  "")
    if [ $ICE_RESTORED_COUNT -gt 0 ]; then
      echo "[S2] ✅ 정상 복구 — ICE restart 1회 후 ice_restored (Family Wi-Fi 복귀 정상 처리)"
    elif [ $DISCONNECT_COUNT -eq 0 ] && [ $SELF_MARKER_IGNORED -gt 0 ]; then
      echo "[S2] ✅ 통화 유지 — PC CONNECTED 유지 + 자기 familyDisconnect 마커 무시 (짧은 flap, plan A 효과)"
    elif [ $DISCONNECT_COUNT -eq 0 ]; then
      echo "[S2] ⚠ PC DISCONNECTED 0건 — wifi off 가 PC 에 영향 안 줌 (의외)"
    else
      echo "[S2] ⚠ DISCONNECTED 발생했지만 ice_restored / hangup 기록 없음 — 진행 중 또는 미완"
    fi ;;
  networkLost)
    echo "[S2] ✅ networkLost — ICE restart 1회 시도 실패 또는 자기 마커 + PC 미복구 정상 종결" ;;
  remoteEnded)
    echo "[S2] ⚠ remoteEnded — Senior 측 종결 신호 (Senior STOP_DELAY 만료 후 stopPeer)" ;;
  *)
    echo "[S2] ⚠ 종결 사유: $HANGUP_REASON" ;;
esac

echo ""
echo "[S2] Logs:"
echo "  $LOG_DIR/family_${SUFFIX}.log"
echo "  $LOG_DIR/senior_${SUFFIX}.log"

# Cleanup: 모니터링 살아있으면 종료. SnackBar "다시 걸기" 가 떠 있을 수도 있으나 1.5s 자동 dismiss.
adb -s $FAMILY_DEVICE shell input tap 768 2202 >/dev/null 2>&1
sleep 2

echo "[S2] === DONE ==="
