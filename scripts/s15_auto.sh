#!/bin/bash
# S15 자동 — Family 앱 백그라운드 → foreground 복귀 (Doze 영향 검증)
#
# 시퀀스:
#   1. 모니터링 → CONNECTED 안정화
#   2. KEYCODE_HOME 으로 백그라운드 진입
#   3. (선택) Doze 강제 진입 (FORCE_DOZE=1)
#   4. BACKGROUND_S 만큼 대기 (기본 300s = 5분)
#   5. am start 로 Family 앱 foreground 복귀
#   6. observation 후 결과 검증
#
# 환경 변수:
#   BACKGROUND_S    백그라운드 유지 시간 (기본 300 = 5분, 명세 기준)
#   FORCE_DOZE      1 이면 dumpsys deviceidle force-idle deep (즉시 깊은 Doze)
#   OBSERVE_S       foreground 복귀 후 관찰 시간 (기본 30s)
#
# 사용법:
#   bash scripts/s15_auto.sh                              # 자연 5분 대기
#   FORCE_DOZE=1 BACKGROUND_S=120 bash scripts/s15_auto.sh # Doze 강제 + 2분만

set +e
trap 'adb -s R3CR700SEKP shell dumpsys deviceidle unforce >/dev/null 2>&1; echo "[S15] cleanup: doze unforce"' EXIT

FAMILY_DEVICE=R3CR700SEKP
SENIOR_DEVICE=KEP2024120921

MONITOR_BTN_X=795
MONITOR_BTN_Y=918

BACKGROUND_S=${BACKGROUND_S:-300}
FORCE_DOZE=${FORCE_DOZE:-0}
OBSERVE_S=${OBSERVE_S:-30}

LOG_DIR=e:/tmp/s15_auto
mkdir -p "$LOG_DIR"

PID_F=$(adb -s $FAMILY_DEVICE shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR_DEVICE shell pidof com.seniorcare.senior | tr -d '\r')
echo "PID_F=$PID_F PID_S=$PID_S"
if [ -z "$PID_F" ] || [ -z "$PID_S" ]; then
  echo "[S15] ERROR: app not running"
  exit 1
fi

echo "[S15] === START (background=${BACKGROUND_S}s, doze=${FORCE_DOZE}, observe=${OBSERVE_S}s) ==="

# Step 0: 다이얼로그 dismiss
DIALOG_DUMP=$(adb -s $FAMILY_DEVICE shell "uiautomator dump /sdcard/_s15_check.xml >/dev/null 2>&1; cat /sdcard/_s15_check.xml" 2>/dev/null)
if echo "$DIALOG_DUMP" | grep -q 'content-desc="확인"'; then
  OK_BOUNDS=$(echo "$DIALOG_DUMP" | grep -oE 'content-desc="확인"[^/]*bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1 | grep -oE 'bounds="\[[0-9,]+\]\[[0-9,]+\]"' | tr -dc '0-9,')
  X1=$(echo "$OK_BOUNDS" | cut -d, -f1); Y1=$(echo "$OK_BOUNDS" | cut -d, -f2)
  X2=$(echo "$OK_BOUNDS" | cut -d, -f3); Y2=$(echo "$OK_BOUNDS" | cut -d, -f4)
  CX=$(( (X1 + X2) / 2 )); CY=$(( (Y1 + Y2) / 2 ))
  echo "[S15] Dismiss 다이얼로그 ($CX,$CY)"
  adb -s $FAMILY_DEVICE shell input tap $CX $CY
  sleep 1
fi

# Step 1: 모니터링 시작
BASELINE=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | wc -l)
echo "[S15] Tap 모니터링 ($MONITOR_BTN_X,$MONITOR_BTN_Y) @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell input tap $MONITOR_BTN_X $MONITOR_BTN_Y

CONNECTED=0
for i in {1..20}; do
  sleep 0.5
  NEW=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE+1)))
  if echo "$NEW" | grep -q "answer_received"; then
    CONNECTED=1
    echo "[S15] FSM connected @ $(date +%T.%3N)"
    break
  fi
done
if [ "$CONNECTED" -eq 0 ]; then
  echo "[S15] ERROR: monitor connect 실패 — abort"
  exit 1
fi

sleep 5  # 안정화

# Step 2: 화면 끄기 + KEYCODE_HOME 으로 백그라운드 진입
echo "[S15] 화면 OFF + KEYCODE_HOME @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell input keyevent 26   # KEYCODE_POWER (화면 OFF)
sleep 1
adb -s $FAMILY_DEVICE shell input keyevent 3    # KEYCODE_HOME

# Step 3: Doze 강제 (선택)
if [ "$FORCE_DOZE" = "1" ]; then
  echo "[S15] Doze 강제 진입 @ $(date +%T.%3N)"
  adb -s $FAMILY_DEVICE shell dumpsys deviceidle force-idle deep
  adb -s $FAMILY_DEVICE shell dumpsys deviceidle | grep -E "mState|mDeepEnabled" | head -3
fi

# Step 4: 백그라운드 대기
echo "[S15] 백그라운드 ${BACKGROUND_S}s 대기..."
START_BG=$(date +%s)
while true; do
  ELAPSED=$(($(date +%s) - START_BG))
  if [ $ELAPSED -ge $BACKGROUND_S ]; then break; fi
  REMAIN=$((BACKGROUND_S - ELAPSED))
  if [ $((ELAPSED % 30)) -eq 0 ] || [ $REMAIN -le 10 ]; then
    echo "[S15] 백그라운드 ${ELAPSED}s 경과 (남은 ${REMAIN}s) @ $(date +%T)"
  fi
  sleep 10
done

# Step 5: Doze 해제 (전이 정상화) + 화면 ON + 앱 foreground
if [ "$FORCE_DOZE" = "1" ]; then
  echo "[S15] Doze 해제 @ $(date +%T.%3N)"
  adb -s $FAMILY_DEVICE shell dumpsys deviceidle unforce
fi

echo "[S15] 화면 ON + 잠금 해제 시도 + Family foreground @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell input keyevent 26     # 화면 ON
sleep 1
adb -s $FAMILY_DEVICE shell input keyevent 82     # KEYCODE_MENU (잠금 화면 dismiss 시도)
sleep 1
adb -s $FAMILY_DEVICE shell am start -n com.seniorcare.family/.MainActivity

# Step 6: observation
echo "[S15] Foreground 복귀 후 ${OBSERVE_S}s 관찰..."
sleep $OBSERVE_S

# 로그 저장
adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE+1)) > "$LOG_DIR/family.log"
adb -s $SENIOR_DEVICE logcat -d -v time -b all > "$LOG_DIR/senior.log" 2>&1

NEW="$(cat $LOG_DIR/family.log)"

echo "[S15] === RESULT ==="

# FSM 전이 추적
echo "[S15] FSM 전이 이력:"
echo "$NEW" | grep -E "\[FSM\]|연결 상태 = RTCPeerConnectionState|hangup:|cleanup_done|네트워크 실패|복구|이미|background|onPause|onResume" | head -25

echo ""

# PC state 변화 추적
DISCONNECT_COUNT=$(echo "$NEW" | grep -c "RTCPeerConnectionStateDisconnected")
CONNECTED_COUNT=$(echo "$NEW" | grep -c "RTCPeerConnectionStateConnected")
FAILED_COUNT=$(echo "$NEW" | grep -c "RTCPeerConnectionStateFailed")
ICE_RESTART_COUNT=$(echo "$NEW" | grep -c "ice_restart_start")
HANGUP_REASON=$(echo "$NEW" | grep -oE 'hangup:[a-zA-Z]+' | tail -1 | sed 's/hangup://')

echo "[S15] 카운트:"
echo "  PC DISCONNECTED: $DISCONNECT_COUNT"
echo "  PC CONNECTED:    $CONNECTED_COUNT"
echo "  PC FAILED:       $FAILED_COUNT"
echo "  ice_restart_start: $ICE_RESTART_COUNT"
echo "  종결 사유:       ${HANGUP_REASON:-(진행 중)}"

# 결과 분류
echo ""
case "$HANGUP_REASON" in
  "")
    if [ $CONNECTED_COUNT -gt 0 ] && [ $DISCONNECT_COUNT -eq 0 ]; then
      echo "[S15] ✅ 정상 유지 — 백그라운드 동안 PC CONNECTED 유지 (Doze 영향 없음)"
    elif echo "$NEW" | grep -q "ice_restored"; then
      echo "[S15] ✅ 정상 복구 — ICE restart 후 ice_restored"
    else
      echo "[S15] ⚠ 진행 중 — observation 부족 또는 복구 진행 중"
    fi ;;
  iceFailed)
    echo "[S15] ✅ iceFailed 종결 — ICE restart 한도/flap window 초과 (정상 종결)" ;;
  userHangup)
    echo "[S15] ⚠ userHangup — 자동화 외 종결 (예상치 못함)" ;;
  *)
    echo "[S15] ⚠ 종결 사유: $HANGUP_REASON" ;;
esac

echo ""
echo "[S15] Logs: $LOG_DIR/family.log"
echo "[S15] === DONE ==="
