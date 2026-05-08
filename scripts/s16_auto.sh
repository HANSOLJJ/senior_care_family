#!/bin/bash
# S16 — Family 양쪽 동시 wifi off (S1~3 의 multi-device 버전, 1 cycle)
#
# 두 Family 모니터링 active 상태에서 동시 wifi off → 양쪽 PC disconnect →
# grace 4s → ICE restart 시도. Senior 측 두 peer 병렬 처리 검증.
#
# 사전 조건:
#   - Family A (R3CR700SEKP) + Family C (RFKYA00Y49L) FamilyDetailScreen
#   - 둘 다 Android (좌표 SM-G991N / SM-A175 동일 가정 — 1080x2400 세로)
#
# 환경 변수:
#   FAMILY_OFF_S    wifi off 시간 (기본 3)
#   OBSERVE_S       wifi 복귀 후 관찰 시간 (기본 25, 긴 단절은 호출자가 늘림)
#
# 사용법:
#   bash scripts/s16_auto.sh                       # 기본 3s
#   FAMILY_OFF_S=15 bash scripts/s16_auto.sh       # 긴 단절 (networkLost)

set +e

FAMILY_A=R3CR700SEKP
FAMILY_C=RFKYA00Y49L
SENIOR_DEVICE=KEP2024120921

MONITOR_BTN_X=795
MONITOR_BTN_Y=918

FAMILY_OFF_S=${FAMILY_OFF_S:-3}
OBSERVE_S=${OBSERVE_S:-25}

LOG_DIR=e:/tmp/s16_auto
mkdir -p "$LOG_DIR"

trap 'echo "[S16] cleanup: 양쪽 Wi-Fi enable + kill logcat"; adb -s '"$FAMILY_A"' shell svc wifi enable >/dev/null 2>&1; adb -s '"$FAMILY_C"' shell svc wifi enable >/dev/null 2>&1; kill $LOGCAT_A_PID $LOGCAT_C_PID $LOGCAT_S_PID 2>/dev/null' EXIT

PID_A=$(adb -s $FAMILY_A shell pidof com.seniorcare.family | tr -d '\r')
PID_C=$(adb -s $FAMILY_C shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR_DEVICE shell pidof com.seniorcare.senior | tr -d '\r')
echo "[S16] PID_A=$PID_A PID_C=$PID_C PID_S=$PID_S"
if [ -z "$PID_A" ] || [ -z "$PID_C" ] || [ -z "$PID_S" ]; then
  echo "[S16] ERROR: app not running"
  exit 1
fi

echo "[S16] === START (family_off=${FAMILY_OFF_S}s, observe=${OBSERVE_S}s) ==="

# Step 0: 양쪽 다이얼로그 dismiss (이전 사이클의 종결 다이얼로그)
for DEV in $FAMILY_A $FAMILY_C; do
  DIALOG_DUMP=$(adb -s $DEV shell "uiautomator dump /sdcard/_s16_check.xml >/dev/null 2>&1; cat /sdcard/_s16_check.xml" 2>/dev/null)
  if echo "$DIALOG_DUMP" | grep -q 'content-desc="확인"'; then
    OK_BOUNDS=$(echo "$DIALOG_DUMP" | grep -oE 'content-desc="확인"[^/]*bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1 | grep -oE 'bounds="\[[0-9,]+\]\[[0-9,]+\]"' | tr -dc '0-9,')
    X1=$(echo "$OK_BOUNDS" | cut -d, -f1); Y1=$(echo "$OK_BOUNDS" | cut -d, -f2)
    X2=$(echo "$OK_BOUNDS" | cut -d, -f3); Y2=$(echo "$OK_BOUNDS" | cut -d, -f4)
    CX=$(( (X1 + X2) / 2 )); CY=$(( (Y1 + Y2) / 2 ))
    echo "[S16] $DEV 다이얼로그 dismiss ($CX,$CY)"
    adb -s $DEV shell input tap $CX $CY
    sleep 1
  fi
done

# Step 1: logcat background 캡처
SUFFIX=${FAMILY_OFF_S}s
LOG_A="$LOG_DIR/family_a_${SUFFIX}.log"
LOG_C="$LOG_DIR/family_c_${SUFFIX}.log"
LOG_S="$LOG_DIR/senior_${SUFFIX}.log"
> "$LOG_A"; > "$LOG_C"; > "$LOG_S"

adb -s $FAMILY_A logcat -v time -T 0 --pid=$PID_A > "$LOG_A" 2>/dev/null &
LOGCAT_A_PID=$!
adb -s $FAMILY_C logcat -v time -T 0 --pid=$PID_C > "$LOG_C" 2>/dev/null &
LOGCAT_C_PID=$!
adb -s $SENIOR_DEVICE logcat -v time -T 0 --pid=$PID_S > "$LOG_S" 2>/dev/null &
LOGCAT_S_PID=$!
sleep 0.3

# Step 2: 양쪽 모니터링 동시 발신 (specific PID wait — wait 무인자는 logcat 까지 기다리니 금지)
echo "[S16] 양쪽 모니터링 발신 @ $(date +%T.%3N)"
adb -s $FAMILY_A shell input tap $MONITOR_BTN_X $MONITOR_BTN_Y &
TAP_A_PID=$!
adb -s $FAMILY_C shell input tap $MONITOR_BTN_X $MONITOR_BTN_Y &
TAP_C_PID=$!
wait $TAP_A_PID $TAP_C_PID

# Step 3: 양쪽 connected 대기
CONNECTED_A=0; CONNECTED_C=0
for i in {1..20}; do
  sleep 0.5
  if [ "$CONNECTED_A" -eq 0 ] && grep -q "answer_received" "$LOG_A" 2>/dev/null; then CONNECTED_A=1; fi
  if [ "$CONNECTED_C" -eq 0 ] && grep -q "answer_received" "$LOG_C" 2>/dev/null; then CONNECTED_C=1; fi
  if [ "$CONNECTED_A" -eq 1 ] && [ "$CONNECTED_C" -eq 1 ]; then break; fi
done
echo "[S16] CONNECTED A=$CONNECTED_A C=$CONNECTED_C @ $(date +%T.%3N)"
if [ "$CONNECTED_A" -eq 0 ] || [ "$CONNECTED_C" -eq 0 ]; then
  echo "[S16] ERROR: 한쪽 또는 양쪽 connect 실패"
  exit 1
fi

# Step 4: 안정화 3초
sleep 3

# Step 5: 양쪽 동시 wifi off (cellular 가능하면 자연스러운 LTE handoff 테스트)
T_OFF=$(date +%T.%3N)
echo "[S16] 양쪽 Wi-Fi off @ $T_OFF"
adb -s $FAMILY_A shell svc wifi disable &
WIFI_OFF_A_PID=$!
adb -s $FAMILY_C shell svc wifi disable &
WIFI_OFF_C_PID=$!
wait $WIFI_OFF_A_PID $WIFI_OFF_C_PID

# Step 6: wifi off 유지
echo "[S16] Wi-Fi off ${FAMILY_OFF_S}s 유지..."
sleep $FAMILY_OFF_S

# Step 7: 양쪽 동시 wifi on (cellular → wifi 복귀)
T_ON=$(date +%T.%3N)
echo "[S16] 양쪽 Wi-Fi on @ $T_ON"
adb -s $FAMILY_A shell svc wifi enable &
WIFI_ON_A_PID=$!
adb -s $FAMILY_C shell svc wifi enable &
WIFI_ON_C_PID=$!
wait $WIFI_ON_A_PID $WIFI_ON_C_PID

# Step 8: observation
echo "[S16] Observation ${OBSERVE_S}s..."
sleep $OBSERVE_S

sleep 1
kill $LOGCAT_A_PID $LOGCAT_C_PID $LOGCAT_S_PID 2>/dev/null
sleep 0.5

NEW_A="$(cat $LOG_A)"
NEW_C="$(cat $LOG_C)"

# 결과 카운트
ICE_RESTORED_A=$(echo "$NEW_A" | grep -c "ice_restored")
ICE_RESTORED_C=$(echo "$NEW_C" | grep -c "ice_restored")
NETWORK_LOST_A=$(echo "$NEW_A" | grep -c "hangup:networkLost")
NETWORK_LOST_C=$(echo "$NEW_C" | grep -c "hangup:networkLost")
ICE_SKIP_A=$(echo "$NEW_A" | grep -c "PC=CONNECTED.*networkLost skip")
ICE_SKIP_C=$(echo "$NEW_C" | grep -c "PC=CONNECTED.*networkLost skip")

echo "[S16] === RESULT ==="
echo "  Family A: ice_restored=$ICE_RESTORED_A networkLost=$NETWORK_LOST_A skip=$ICE_SKIP_A"
echo "  Family C: ice_restored=$ICE_RESTORED_C networkLost=$NETWORK_LOST_C skip=$ICE_SKIP_C"

# 대칭성 분류
# 비대칭 케이스는 race 가 아닌 디바이스 cellular 가용성 차이일 수 있음 (S16 result md 참고).
# 한쪽이 cellular IN_SERVICE 면 wifi off 시 fallback 으로 PC 유지 → ice_restored,
# 다른 쪽이 cellular DENIED/OUT_OF_SERVICE 면 RTDB unreachable → ICE restart fail → networkLost.
# 비대칭 발생 시 양쪽 디바이스의 telephony 상태 (mServiceState, mDataConnectionState) 확인 필요.
if [ "$NETWORK_LOST_A" -eq 0 ] && [ "$NETWORK_LOST_C" -eq 0 ] && [ "$ICE_RESTORED_A" -gt 0 ] && [ "$ICE_RESTORED_C" -gt 0 ]; then
  echo "[S16] ✅ 대칭 복구 — 양쪽 ice_restored"
elif [ "$NETWORK_LOST_A" -gt 0 ] && [ "$NETWORK_LOST_C" -gt 0 ]; then
  echo "[S16] ✅ 대칭 networkLost 종결 (긴 단절 정상)"
elif [ "$NETWORK_LOST_A" -eq 0 ] && [ "$NETWORK_LOST_C" -gt 0 ]; then
  echo "[S16] ⚠ 비대칭: A 복구 / C networkLost — cellular 가용성 차이 또는 race 검토"
  echo "[S16]   힌트: 양쪽 mobile data 상태 확인 (adb shell dumpsys telephony.registry | grep mServiceState)"
elif [ "$NETWORK_LOST_A" -gt 0 ] && [ "$NETWORK_LOST_C" -eq 0 ]; then
  echo "[S16] ⚠ 비대칭: A networkLost / C 복구 — cellular 가용성 차이 또는 race 검토"
  echo "[S16]   힌트: 양쪽 mobile data 상태 확인 (adb shell dumpsys telephony.registry | grep mServiceState)"
else
  echo "[S16] ⚠ 분류 불명확 — raw log 확인"
fi

echo "[S16] Logs:"
echo "  $LOG_A"
echo "  $LOG_C"
echo "  $LOG_S"

# Cleanup: 양쪽 모니터링 종료 (다음 stage 가 FamilyDetail 에서 시작하도록)
adb -s $FAMILY_A shell input tap 768 2202 >/dev/null 2>&1
adb -s $FAMILY_C shell input tap 768 2202 >/dev/null 2>&1
sleep 2

echo "[S16] === DONE ==="
