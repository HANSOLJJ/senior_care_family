#!/bin/bash
# S12 자동 테스트 — 발신 (call 타입) connecting phase 도중 ICE failure / network drop
#
# 사전조건:
#   1. Family 앱이 FamilyDetailScreen 에 위치
#   2. Senior 앱 실행 중. 자동수락 OFF 가정 (수동 수락 안 함 — Phase 1/2 timeout 검증)
#   3. 좌표는 SM-G991N (1080x2400) 기준
#
# WIFI_OFF_DELAY_MS 변형 (race window):
#   300    createCall RTDB write 자체가 timeout → networkOffline 가능성
#   1500   createCall 통과, Senior CallActivity INCOMING 표시 후 → answer 못 옴 → unreachable
#   3000   같은 위치, Senior 수동 수락 가능했으면 answer 받았을 시점
#   5000   Phase 1 timeout 5s 직후 — 이미 종결됐을 수 있음
#
# 사용법:
#   bash scripts/s12_auto.sh                          # 기본 1500ms
#   WIFI_OFF_DELAY_MS=300 bash scripts/s12_auto.sh    # createCall race
#   WIFI_OFF_DELAY_MS=3000 bash scripts/s12_auto.sh   # SDP 교환 진행 중

set +e
trap 'echo "[S12] cleanup: Wi-Fi enable"; adb -s R3CR700SEKP shell svc wifi enable >/dev/null 2>&1' EXIT

FAMILY_DEVICE=R3CR700SEKP
SENIOR_DEVICE=KEP2024120921

# 좌표 (SM-G991N 1080x2400)
CALL_BTN_X=285        # FamilyDetailScreen "영상통화" 버튼 중심 (S11 의 모니터링 (795,918) 과 좌우 대칭)
CALL_BTN_Y=918

WIFI_OFF_DELAY_MS=${WIFI_OFF_DELAY_MS:-1500}
OBSERVE_S=${OBSERVE_S:-30}   # Phase 1 timeout 5s + Phase 2 timeout 20s 커버

LOG_DIR=e:/tmp/s12_auto
mkdir -p "$LOG_DIR"

PID_F=$(adb -s $FAMILY_DEVICE shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR_DEVICE shell pidof com.seniorcare.senior | tr -d '\r')
echo "PID_F=$PID_F PID_S=$PID_S"
if [ -z "$PID_F" ] || [ -z "$PID_S" ]; then
  echo "[S12] ERROR: Family or Senior app not running"
  exit 1
fi

echo "[S12] === START (delay=${WIFI_OFF_DELAY_MS}ms, observe=${OBSERVE_S}s) ==="

# Step 0: 다이얼로그 자동 dismiss (이전 사이클의 unreachable/noAcceptance/iceFailed 다이얼로그)
DIALOG_DUMP=$(adb -s $FAMILY_DEVICE shell "uiautomator dump /sdcard/_s12_check.xml >/dev/null 2>&1; cat /sdcard/_s12_check.xml" 2>/dev/null)
if echo "$DIALOG_DUMP" | grep -q 'content-desc="확인"'; then
  OK_BOUNDS=$(echo "$DIALOG_DUMP" | grep -oE 'content-desc="확인"[^/]*bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1 | grep -oE 'bounds="\[[0-9,]+\]\[[0-9,]+\]"' | tr -dc '0-9,')
  X1=$(echo "$OK_BOUNDS" | cut -d, -f1)
  Y1=$(echo "$OK_BOUNDS" | cut -d, -f2)
  X2=$(echo "$OK_BOUNDS" | cut -d, -f3)
  Y2=$(echo "$OK_BOUNDS" | cut -d, -f4)
  CX=$(( (X1 + X2) / 2 ))
  CY=$(( (Y1 + Y2) / 2 ))
  echo "[S12] Dismiss 다이얼로그 ($CX,$CY)"
  adb -s $FAMILY_DEVICE shell input tap $CX $CY
  sleep 1
fi

# Step 1: "영상통화" 탭 — connecting phase 진입
BASELINE=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | wc -l)
TAP_TS=$(date +%T.%3N)
echo "[S12] Tap 영상통화 ($CALL_BTN_X,$CALL_BTN_Y) @ $TAP_TS"
adb -s $FAMILY_DEVICE shell input tap $CALL_BTN_X $CALL_BTN_Y

# Step 2: WIFI_OFF_DELAY_MS 후 Wi-Fi off
SLEEP_S=$(awk "BEGIN { printf \"%.3f\", $WIFI_OFF_DELAY_MS/1000 }")
sleep $SLEEP_S
echo "[S12] Wi-Fi off @ $(date +%T.%3N) (탭 후 +${WIFI_OFF_DELAY_MS}ms)"
adb -s $FAMILY_DEVICE shell svc wifi disable

# Step 3: observation
echo "[S12] Observation ${OBSERVE_S}s..."
sleep $OBSERVE_S

# Step 4: Wi-Fi on
echo "[S12] Wi-Fi on @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell svc wifi enable

sleep 5

# 로그 저장
SUFFIX=${WIFI_OFF_DELAY_MS}ms
adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE+1)) > "$LOG_DIR/family_${SUFFIX}.log"
adb -s $SENIOR_DEVICE logcat -d -v time -b all > "$LOG_DIR/senior_${SUFFIX}.log" 2>&1

NEW="$(cat $LOG_DIR/family_${SUFFIX}.log)"

# 결과 분류
echo "[S12] === RESULT ==="
echo "$NEW" | grep -E "FSM|hangup|unreachable|noAcceptance|networkOffline|iceFailed|orphanCleaned|발신 시작|시그널링: 통화|네트워크 실패|Phase 1|Phase 2|answer_received|answer 미수신" | tail -25

echo ""
# 종결 사유 우선순위로 분류 — hangup: 패턴 명시적으로 매칭
HANGUP_REASON=$(echo "$NEW" | grep -oE 'hangup:[a-zA-Z]+' | tail -1 | sed 's/hangup://')
case "$HANGUP_REASON" in
  networkOffline)
    echo "[S12] ✅ networkOffline — createCall RTDB write timeout (가장 이른 race)" ;;
  orphanCleaned)
    echo "[S12] ✅ orphanCleaned — createCall + hangUp race" ;;
  unreachable)
    echo "[S12] ✅ unreachable — Phase 1 timeout 5s (answer 미수신)" ;;
  noAcceptance)
    echo "[S12] ✅ noAcceptance — Phase 2 timeout 20s (Senior 미수락)" ;;
  iceFailed)
    if echo "$NEW" | grep -q "renegotiate_done"; then
      echo "[S12] ✅ iceFailed — Senior 자동수락 + renegotiate_done (IN_CALL) → S2 변형 종결"
    else
      echo "[S12] ✅ iceFailed — connecting 통과 후 ICE failure 종결"
    fi ;;
  upgradeFailed)
    echo "[S12] ✅ upgradeFailed — Senior 자동수락 + Bug #1-B catch (sendRenegotiateOffer NetworkException)" ;;
  userHangup)
    echo "[S12] ⚠ userHangup — Family 가 사용자 종료 (예상치 못한 경로)" ;;
  *)
    if echo "$NEW" | grep -q "answer_received"; then
      echo "[S12] ⚠ answer_received 후 종결 진행 중 (observation 부족 가능) — 로그 직접 확인"
    else
      echo "[S12] ⚠ 분류 불명확 ($HANGUP_REASON) — $LOG_DIR/family_${SUFFIX}.log 직접 확인"
    fi ;;
esac

echo ""
echo "[S12] Logs:"
echo "  $LOG_DIR/family_${SUFFIX}.log"
echo "  $LOG_DIR/senior_${SUFFIX}.log"
echo "[S12] === DONE ==="
