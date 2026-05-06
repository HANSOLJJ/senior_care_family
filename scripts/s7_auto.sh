#!/bin/bash
# S7 자동 테스트 — 발신 (call 타입) connecting phase race
#
# 두 모드:
#   Mode A (default)         — Family wifi off race (WIFI_OFF_DELAY_MS 변형)
#   Mode B (SENIOR_OFFLINE)  — Senior Wi-Fi off → SDP answer 안 옴 → Phase 1 timeout 5s (unreachable)
#
# Mode A 사전조건:
#   1. Family 앱이 FamilyDetailScreen
#   2. Senior 앱 실행 중. 디버그 빌드 자동수락 OFF (얼굴감지 skip)
#   3. 좌표는 SM-G991N (1080x2400)
#
# Mode A WIFI_OFF_DELAY_MS 변형:
#   300    createCall RTDB write 자체가 timeout → networkOffline 가능성
#   1500   Senior 가 SDP answer 마친 후 → connected 진입 → S2 변형 (networkLost)
#   3000   동일 (S2 변형)
#   5000   동일 (S2 변형)
#
# Mode B (SENIOR_OFFLINE=true):
#   Senior Wi-Fi off → RTDB listen 못함 → SDP answer 안 옴 → Family Phase 1 timeout 5s → unreachable
#   (am force-stop 은 foreground service 때문에 안 먹힘 — wifi off 가 깔끔)
#
# 사용법:
#   bash scripts/s7_auto.sh                                 # Mode A 1500ms (기본)
#   WIFI_OFF_DELAY_MS=300 bash scripts/s7_auto.sh           # Mode A createCall race
#   SENIOR_OFFLINE=true bash scripts/s7_auto.sh             # Mode B unreachable

set +e

FAMILY_DEVICE=R3CR700SEKP
SENIOR_DEVICE=KEP2024120921

# 좌표
CALL_BTN_X=285
CALL_BTN_Y=918

WIFI_OFF_DELAY_MS=${WIFI_OFF_DELAY_MS:-1500}
OBSERVE_S=${OBSERVE_S:-30}
SENIOR_OFFLINE=${SENIOR_OFFLINE:-false}

LOG_DIR=e:/tmp/s7_auto
mkdir -p "$LOG_DIR"

if [ "$SENIOR_OFFLINE" = "true" ]; then
  # Mode B: Senior wifi off → RTDB listen 못함 → SDP answer 안 옴 → Phase 1 timeout
  # (am force-stop 은 foreground service 때문에 안 먹힘 → wifi off 가 깔끔)
  trap 'echo "[S7] cleanup: Senior Wi-Fi enable"; adb -s '"$SENIOR_DEVICE"' shell svc wifi enable >/dev/null 2>&1' EXIT
else
  # Mode A: Family wifi off
  trap 'echo "[S7] cleanup: Family Wi-Fi enable"; adb -s '"$FAMILY_DEVICE"' shell svc wifi enable >/dev/null 2>&1' EXIT
fi

PID_F=$(adb -s $FAMILY_DEVICE shell pidof com.seniorcare.family | tr -d '\r')
if [ -z "$PID_F" ]; then
  echo "[S7] ERROR: Family app not running"
  exit 1
fi

if [ "$SENIOR_OFFLINE" = "true" ]; then
  echo "[S7] === START (mode=SENIOR_OFFLINE, observe=${OBSERVE_S}s) ==="
else
  PID_S=$(adb -s $SENIOR_DEVICE shell pidof com.seniorcare.senior | tr -d '\r')
  if [ -z "$PID_S" ]; then
    echo "[S7] ERROR: Senior app not running (Mode A 는 Senior 실행 필요)"
    exit 1
  fi
  echo "[S7] === START (mode=WIFI_OFF, delay=${WIFI_OFF_DELAY_MS}ms, observe=${OBSERVE_S}s) ==="
fi
echo "[S7] PID_F=$PID_F PID_S=${PID_S:-(N/A)}"

# Step 0: 다이얼로그 자동 dismiss
DIALOG_DUMP=$(adb -s $FAMILY_DEVICE shell "uiautomator dump /sdcard/_s7_check.xml >/dev/null 2>&1; cat /sdcard/_s7_check.xml" 2>/dev/null)
if echo "$DIALOG_DUMP" | grep -q 'content-desc="확인"'; then
  OK_BOUNDS=$(echo "$DIALOG_DUMP" | grep -oE 'content-desc="확인"[^/]*bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1 | grep -oE 'bounds="\[[0-9,]+\]\[[0-9,]+\]"' | tr -dc '0-9,')
  X1=$(echo "$OK_BOUNDS" | cut -d, -f1)
  Y1=$(echo "$OK_BOUNDS" | cut -d, -f2)
  X2=$(echo "$OK_BOUNDS" | cut -d, -f3)
  Y2=$(echo "$OK_BOUNDS" | cut -d, -f4)
  CX=$(( (X1 + X2) / 2 ))
  CY=$(( (Y1 + Y2) / 2 ))
  echo "[S7] Dismiss 다이얼로그 ($CX,$CY)"
  adb -s $FAMILY_DEVICE shell input tap $CX $CY
  sleep 1
fi

# Step 1 (Mode B 만): Senior Wi-Fi off — RTDB listen 차단
if [ "$SENIOR_OFFLINE" = "true" ]; then
  echo "[S7] Senior Wi-Fi off @ $(date +%T.%3N)"
  adb -s $SENIOR_DEVICE shell svc wifi disable
  sleep 2  # wifi off 확실히 반영
fi

# Step 2: 영상통화 탭
BASELINE=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | wc -l)
TAP_TS=$(date +%T.%3N)
echo "[S7] Tap 영상통화 ($CALL_BTN_X,$CALL_BTN_Y) @ $TAP_TS"
adb -s $FAMILY_DEVICE shell input tap $CALL_BTN_X $CALL_BTN_Y

# Step 3 (Mode A 만): WIFI_OFF_DELAY_MS 후 Wi-Fi off
if [ "$SENIOR_OFFLINE" != "true" ]; then
  SLEEP_S=$(awk "BEGIN { printf \"%.3f\", $WIFI_OFF_DELAY_MS/1000 }")
  sleep $SLEEP_S
  echo "[S7] Wi-Fi off @ $(date +%T.%3N) (탭 후 +${WIFI_OFF_DELAY_MS}ms)"
  adb -s $FAMILY_DEVICE shell svc wifi disable
fi

# Step 4: observation
echo "[S7] Observation ${OBSERVE_S}s..."
sleep $OBSERVE_S

# Step 5: cleanup
if [ "$SENIOR_OFFLINE" = "true" ]; then
  echo "[S7] Senior Wi-Fi on @ $(date +%T.%3N)"
  adb -s $SENIOR_DEVICE shell svc wifi enable
else
  echo "[S7] Wi-Fi on @ $(date +%T.%3N)"
  adb -s $FAMILY_DEVICE shell svc wifi enable
fi

sleep 5

# 로그 저장
if [ "$SENIOR_OFFLINE" = "true" ]; then
  SUFFIX=offline
else
  SUFFIX=${WIFI_OFF_DELAY_MS}ms
fi
adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE+1)) > "$LOG_DIR/family_${SUFFIX}.log"
adb -s $SENIOR_DEVICE logcat -d -v time -b all > "$LOG_DIR/senior_${SUFFIX}.log" 2>&1

NEW="$(cat $LOG_DIR/family_${SUFFIX}.log)"

# 결과 분류
echo "[S7] === RESULT ==="
echo "$NEW" | grep -E "FSM|hangup|unreachable|noAcceptance|networkOffline|iceFailed|orphanCleaned|발신 시작|시그널링: 통화|네트워크 실패|Phase 1|Phase 2|answer_received|answer 미수신|networkLost" | tail -25

echo ""
HANGUP_REASON=$(echo "$NEW" | grep -oE 'hangup:[a-zA-Z]+' | tail -1 | sed 's/hangup://')
case "$HANGUP_REASON" in
  networkOffline)
    echo "[S7] ✅ networkOffline — createCall RTDB write timeout (가장 이른 race)" ;;
  orphanCleaned)
    echo "[S7] ✅ orphanCleaned — createCall + hangUp race" ;;
  unreachable)
    echo "[S7] ✅ unreachable — Phase 1 timeout 5s (answer 미수신)" ;;
  noAcceptance)
    echo "[S7] ✅ noAcceptance — Phase 2 timeout 20s (Senior 미수락)" ;;
  iceFailed)
    if echo "$NEW" | grep -q "renegotiate_done"; then
      echo "[S7] ✅ iceFailed — Senior 자동수락 + renegotiate_done (IN_CALL) → S2 변형 종결"
    else
      echo "[S7] ✅ iceFailed — connecting 통과 후 ICE failure 종결"
    fi ;;
  upgradeFailed)
    echo "[S7] ✅ upgradeFailed — Senior 자동수락 + Bug #1-B catch" ;;
  networkLost)
    echo "[S7] ✅ networkLost — connected 진입 후 wifi off → S2 변형" ;;
  userHangup)
    echo "[S7] ⚠ userHangup — Family 가 사용자 종료 (예상치 못한 경로)" ;;
  *)
    if echo "$NEW" | grep -q "answer_received"; then
      echo "[S7] ⚠ answer_received 후 종결 진행 중 (observation 부족 가능) — 로그 직접 확인"
    else
      echo "[S7] ⚠ 분류 불명확 ($HANGUP_REASON) — $LOG_DIR/family_${SUFFIX}.log 직접 확인"
    fi ;;
esac

echo ""
echo "[S7] Logs:"
echo "  $LOG_DIR/family_${SUFFIX}.log"
echo "  $LOG_DIR/senior_${SUFFIX}.log"
echo "[S7] === DONE ==="
