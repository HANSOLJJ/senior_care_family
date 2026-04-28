#!/bin/bash
# S11 자동 테스트 — monitor → call upgrade 도중 ICE failure
#
# 사전조건:
#   1. Family 앱이 FamilyDetailScreen 에 위치 (가족 상세 화면 — 모니터링/영상통화 버튼 보임)
#   2. Senior 앱 자동수락 켜짐 (얼굴 감지) 또는 사용자 수동 수락 가능
#   3. 좌표는 SM-G991N (1080x2400) 세로 모드 기준
#
# WIFI_OFF_DELAY_MS 조정으로 다양한 race window 커버:
#   500    Bug #5 race    (탭 직후 Wi-Fi off — requestUpgrade .once() hang)
#   1000   Bug #1-B 영역  (requestUpgrade writeOrTimeout 3s 만료)
#   1700   S11 핵심       (renegotiation 도중 ICE failure)
#   3500   S2 변형        (IN_CALL 진입 후 ICE failure)
#
# 사용법:
#   bash scripts/s11_auto.sh                          # 기본 1700ms (S11 핵심)
#   WIFI_OFF_DELAY_MS=500 bash scripts/s11_auto.sh    # Bug #5
#   WIFI_OFF_DELAY_MS=1000 bash scripts/s11_auto.sh   # Bug #1-B
#   WIFI_OFF_DELAY_MS=3500 bash scripts/s11_auto.sh   # S2 변형

set +e
trap 'echo "[S11] cleanup: Wi-Fi enable"; adb -s R3CR700SEKP shell svc wifi enable >/dev/null 2>&1' EXIT

FAMILY_DEVICE=R3CR700SEKP
SENIOR_DEVICE=KEP2024120921

# 좌표 (SM-G991N 1080x2400, uiautomator dump 기준)
MONITOR_BTN_X=795       # FamilyDetailScreen "모니터링" 버튼 중심
MONITOR_BTN_Y=918
UPGRADE_BTN_X=312       # MonitoringScreen "통화 전환" 버튼 중심
UPGRADE_BTN_Y=2202
HANGUP_BTN_X=768        # MonitoringScreen "종료" 버튼 중심
HANGUP_BTN_Y=2202

WIFI_OFF_DELAY_MS=${WIFI_OFF_DELAY_MS:-1700}
OBSERVE_S=${OBSERVE_S:-20}

LOG_DIR=e:/tmp/s11_auto
mkdir -p "$LOG_DIR"

PID_F=$(adb -s $FAMILY_DEVICE shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR_DEVICE shell pidof com.seniorcare.senior | tr -d '\r')
echo "PID_F=$PID_F PID_S=$PID_S"
if [ -z "$PID_F" ] || [ -z "$PID_S" ]; then
  echo "[S11] ERROR: Family or Senior app not running"
  exit 1
fi

echo "[S11] === START (delay=${WIFI_OFF_DELAY_MS}ms, observe=${OBSERVE_S}s) ==="

# Step 0: 다이얼로그 자동 dismiss (이전 사이클 iceFailed 다이얼로그 등)
# uiautomator dump 로 "확인" 버튼 존재 시 좌표 추출 후 탭. 없으면 skip.
DIALOG_DUMP=$(adb -s $FAMILY_DEVICE shell "uiautomator dump /sdcard/_s11_check.xml >/dev/null 2>&1; cat /sdcard/_s11_check.xml" 2>/dev/null)
if echo "$DIALOG_DUMP" | grep -q 'content-desc="확인"'; then
  OK_BOUNDS=$(echo "$DIALOG_DUMP" | grep -oE 'content-desc="확인"[^/]*bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1 | grep -oE 'bounds="\[[0-9,]+\]\[[0-9,]+\]"' | tr -dc '0-9,')
  X1=$(echo "$OK_BOUNDS" | cut -d, -f1)
  Y1=$(echo "$OK_BOUNDS" | cut -d, -f2)
  X2=$(echo "$OK_BOUNDS" | cut -d, -f3)
  Y2=$(echo "$OK_BOUNDS" | cut -d, -f4)
  CX=$(( (X1 + X2) / 2 ))
  CY=$(( (Y1 + Y2) / 2 ))
  echo "[S11] Dismiss 다이얼로그 ($CX,$CY)"
  adb -s $FAMILY_DEVICE shell input tap $CX $CY
  sleep 1
fi

# Step 1: 모니터링 시작
BASELINE=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | wc -l)
echo "[S11] Tap 모니터링 ($MONITOR_BTN_X,$MONITOR_BTN_Y) @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell input tap $MONITOR_BTN_X $MONITOR_BTN_Y

# CONNECTED 대기
CONNECTED=0
for i in {1..20}; do
  sleep 0.5
  NEW=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE+1)))
  if echo "$NEW" | grep -q "answer_received"; then
    CONNECTED=1
    echo "[S11] FSM connected @ $(date +%T.%3N) (after ${i}*0.5s)"
    break
  fi
done
if [ "$CONNECTED" -eq 0 ]; then
  echo "[S11] ERROR: monitor connect 실패 — abort"
  exit 1
fi

sleep 2  # 양방향 monitor 안정화

# Step 2: "통화 전환" 탭
BASELINE=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | wc -l)
TAP_TS=$(date +%T.%3N)
echo "[S11] Tap 통화 전환 ($UPGRADE_BTN_X,$UPGRADE_BTN_Y) @ $TAP_TS"
adb -s $FAMILY_DEVICE shell input tap $UPGRADE_BTN_X $UPGRADE_BTN_Y

# Step 3: WIFI_OFF_DELAY_MS 후 Wi-Fi off
SLEEP_S=$(awk "BEGIN { printf \"%.3f\", $WIFI_OFF_DELAY_MS/1000 }")
sleep $SLEEP_S
echo "[S11] Wi-Fi off @ $(date +%T.%3N) (탭 후 +${WIFI_OFF_DELAY_MS}ms)"
adb -s $FAMILY_DEVICE shell svc wifi disable

# Step 4: observation
echo "[S11] Observation ${OBSERVE_S}s..."
sleep $OBSERVE_S

# Step 5: Wi-Fi on (trap 도 안전망)
echo "[S11] Wi-Fi on @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell svc wifi enable

sleep 5  # cleanup race 마감

# 로그 저장
SUFFIX=${WIFI_OFF_DELAY_MS}ms
adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE+1)) > "$LOG_DIR/family_${SUFFIX}.log"
adb -s $SENIOR_DEVICE logcat -d -v time -b all > "$LOG_DIR/senior_${SUFFIX}.log" 2>&1

NEW="$(cat $LOG_DIR/family_${SUFFIX}.log)"

# 결과 분류
echo "[S11] === RESULT ==="
echo "$NEW" | grep -E "FSM|hangup|upgradeFailed|ice_restored|ice_restart_start|iceFailed|네트워크 실패|renegotiate_done|seniorAccepted" | tail -25

echo ""
if echo "$NEW" | grep -q "hangup:upgradeFailed"; then
  echo "[S11] ✅ Bug #1-B 경로 — hangup:upgradeFailed (NetworkException catch → hangUp)"
elif echo "$NEW" | grep -q "renegotiate_done"; then
  if echo "$NEW" | grep -q "ice_restart_start"; then
    if echo "$NEW" | grep -q "ice_restored"; then
      echo "[S11] ✅ S11 정상 — upgrade 후 ICE restart 복구 (renegotiate_done + ice_restored)"
    elif echo "$NEW" | grep -q "hangup:iceFailed"; then
      echo "[S11] ✅ S4 변형 — upgrade 후 iceFailed 종결"
    else
      echo "[S11] ⚠ upgrade 후 reconnecting 진행 중 — 더 긴 observe 필요"
    fi
  else
    echo "[S11] ✅ 정상 IN_CALL 진입 (Wi-Fi off 영향 안 받음)"
  fi
elif echo "$NEW" | grep -q "ice_restart_start"; then
  if echo "$NEW" | grep -q "hangup:iceFailed"; then
    echo "[S11] ✅ upgrade 도중 ICE 한도 초과 → iceFailed"
  else
    echo "[S11] ⚠ ice_restart 진행 중 종결 안 됨"
  fi
elif echo "$NEW" | grep -q "upgrade skip"; then
  echo "[S11] ⚠ Bug #5 trace — upgrade silent skip (.once() persistence cache miss)"
else
  echo "[S11] ⚠ 분류 불명확 — $LOG_DIR/family_${SUFFIX}.log 직접 확인"
fi

echo ""
echo "[S11] Logs:"
echo "  $LOG_DIR/family_${SUFFIX}.log"
echo "  $LOG_DIR/senior_${SUFFIX}.log"
echo "[S11] === DONE ==="
