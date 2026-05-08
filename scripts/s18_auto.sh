#!/bin/bash
# S18 — A grace 중 B 신규 합류 race (1 cycle)
#
# 시나리오:
#   1. Family A (R3CR700SEKP) 모니터링 active
#   2. Family B (RFKYA00Y49L) FamilyDetailScreen (idle)
#   3. A wifi off → A 측 PC disconnect → grace 4s 시작
#   4. JOIN_DELAY_S 대기 후 B 모니터링 발신 (grace 4s 안 또는 만료 후)
#   5. A grace 만료 + ICE restart 시도
#   6. observation — B connected 정상 + A 복구 또는 networkLost + Senior peer slot 정확
#
# 사전 조건:
#   - Family A R3CR700SEKP family detail (모니터링 가능)
#   - Family B RFKYA00Y49L family detail (idle, 모니터링 가능)
#   - 둘 다 같은 Senior (KEP) 페어링
#
# 환경 변수:
#   JOIN_DELAY_S    A wifi off 후 B 발신까지 대기 (기본 2.5)
#   A_OFF_S         A wifi off 유지 시간 (기본 6 — grace 만료 + ICE restart 1회 시도)
#   OBSERVE_S       wifi 복귀 후 관찰 시간 (기본 25)
#
# 사용법:
#   bash scripts/s18_auto.sh                                # JOIN_DELAY=2.5 (grace 만료 직전)
#   JOIN_DELAY_S=1 bash scripts/s18_auto.sh                 # grace 시작 직후 (early join)
#   JOIN_DELAY_S=4 bash scripts/s18_auto.sh                 # grace 만료 후 (B 가 ICE restart 시점에 합류)
#   JOIN_DELAY_S=5 A_OFF_S=15 bash scripts/s18_auto.sh      # 긴 단절 + B 합류

set +e

FAMILY_A=R3CR700SEKP
FAMILY_B=RFKYA00Y49L
SENIOR_DEVICE=KEP2024120921

MONITOR_BTN_X=795
MONITOR_BTN_Y=918
HANGUP_MONITOR_X=768
HANGUP_MONITOR_Y=2202

JOIN_DELAY_S=${JOIN_DELAY_S:-2.5}
A_OFF_S=${A_OFF_S:-6}
OBSERVE_S=${OBSERVE_S:-25}

LOG_DIR=e:/tmp/s18_auto
mkdir -p "$LOG_DIR"

trap 'echo "[S18] cleanup: A Wi-Fi enable + kill logcat"; adb -s '"$FAMILY_A"' shell svc wifi enable >/dev/null 2>&1; kill $LOGCAT_A_PID $LOGCAT_B_PID $LOGCAT_S_PID 2>/dev/null' EXIT

PID_A=$(adb -s $FAMILY_A shell pidof com.seniorcare.family | tr -d '\r')
PID_B=$(adb -s $FAMILY_B shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR_DEVICE shell pidof com.seniorcare.senior | tr -d '\r')
echo "[S18] PID_A=$PID_A PID_B=$PID_B PID_S=$PID_S"
if [ -z "$PID_A" ] || [ -z "$PID_B" ] || [ -z "$PID_S" ]; then
  echo "[S18] ERROR: app not running"
  exit 1
fi

echo "[S18] === START (join_delay=${JOIN_DELAY_S}s, a_off=${A_OFF_S}s, observe=${OBSERVE_S}s) ==="

# Step 0: 양쪽 다이얼로그 dismiss
for DEV in $FAMILY_A $FAMILY_B; do
  DIALOG_DUMP=$(adb -s $DEV shell "uiautomator dump /sdcard/_s18_check.xml >/dev/null 2>&1; cat /sdcard/_s18_check.xml" 2>/dev/null)
  if echo "$DIALOG_DUMP" | grep -q 'content-desc="확인"'; then
    OK_BOUNDS=$(echo "$DIALOG_DUMP" | grep -oE 'content-desc="확인"[^/]*bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1 | grep -oE 'bounds="\[[0-9,]+\]\[[0-9,]+\]"' | tr -dc '0-9,')
    X1=$(echo "$OK_BOUNDS" | cut -d, -f1); Y1=$(echo "$OK_BOUNDS" | cut -d, -f2)
    X2=$(echo "$OK_BOUNDS" | cut -d, -f3); Y2=$(echo "$OK_BOUNDS" | cut -d, -f4)
    CX=$(( (X1 + X2) / 2 )); CY=$(( (Y1 + Y2) / 2 ))
    echo "[S18] $DEV 다이얼로그 dismiss ($CX,$CY)"
    adb -s $DEV shell input tap $CX $CY
    sleep 1
  fi
done

# Step 1: logcat background 캡처
SUFFIX=${JOIN_DELAY_S}s
LOG_A="$LOG_DIR/family_a_${SUFFIX}.log"
LOG_B="$LOG_DIR/family_b_${SUFFIX}.log"
LOG_S="$LOG_DIR/senior_${SUFFIX}.log"
> "$LOG_A"; > "$LOG_B"; > "$LOG_S"

adb -s $FAMILY_A logcat -v time -T 0 --pid=$PID_A > "$LOG_A" 2>/dev/null &
LOGCAT_A_PID=$!
adb -s $FAMILY_B logcat -v time -T 0 --pid=$PID_B > "$LOG_B" 2>/dev/null &
LOGCAT_B_PID=$!
adb -s $SENIOR_DEVICE logcat -v time -T 0 --pid=$PID_S > "$LOG_S" 2>/dev/null &
LOGCAT_S_PID=$!
sleep 0.3

# Step 2: A 모니터링 발신 (B 는 idle 유지)
echo "[S18] A 모니터링 발신 @ $(date +%T.%3N)"
adb -s $FAMILY_A shell input tap $MONITOR_BTN_X $MONITOR_BTN_Y

# A connected 대기
CONNECTED_A=0
for i in {1..20}; do
  sleep 0.5
  if grep -q "answer_received" "$LOG_A" 2>/dev/null; then CONNECTED_A=1; break; fi
done
echo "[S18] A CONNECTED=$CONNECTED_A @ $(date +%T.%3N)"
if [ "$CONNECTED_A" -eq 0 ]; then
  echo "[S18] ERROR: A connect 실패"
  exit 1
fi

# Step 3: 안정화 3초
sleep 3

# Step 4: A wifi off
T_OFF=$(date +%T.%3N)
echo "[S18] A Wi-Fi off @ $T_OFF"
adb -s $FAMILY_A shell svc wifi disable

# Step 5: JOIN_DELAY_S 대기 후 B 모니터링 발신
echo "[S18] JOIN_DELAY ${JOIN_DELAY_S}s 대기..."
sleep $JOIN_DELAY_S

T_JOIN=$(date +%T.%3N)
echo "[S18] B 모니터링 발신 @ $T_JOIN (A wifi off 로부터 ${JOIN_DELAY_S}s 후)"
adb -s $FAMILY_B shell input tap $MONITOR_BTN_X $MONITOR_BTN_Y

# B connected 대기
CONNECTED_B=0
for i in {1..30}; do
  sleep 0.5
  if grep -q "answer_received" "$LOG_B" 2>/dev/null; then CONNECTED_B=1; break; fi
done
echo "[S18] B CONNECTED=$CONNECTED_B @ $(date +%T.%3N)"

# Step 6: A wifi off 잔여 시간
REMAINING=$(awk "BEGIN{print $A_OFF_S - $JOIN_DELAY_S}")
if awk "BEGIN{exit !($REMAINING > 0)}"; then
  echo "[S18] A wifi off 잔여 ${REMAINING}s 유지..."
  sleep $REMAINING
fi

# Step 7: A wifi on
T_ON=$(date +%T.%3N)
echo "[S18] A Wi-Fi on @ $T_ON"
adb -s $FAMILY_A shell svc wifi enable

# Step 8: observation
echo "[S18] Observation ${OBSERVE_S}s..."
sleep $OBSERVE_S

sleep 1
kill $LOGCAT_A_PID $LOGCAT_B_PID $LOGCAT_S_PID 2>/dev/null
sleep 0.5

NEW_A="$(cat $LOG_A)"
NEW_B="$(cat $LOG_B)"

# 결과 카운트
ICE_RESTORED_A=$(echo "$NEW_A" | grep -c "ice_restored")
ICE_RESTORED_B=$(echo "$NEW_B" | grep -c "ice_restored")
NETWORK_LOST_A=$(echo "$NEW_A" | grep -c "hangup:networkLost")
NETWORK_LOST_B=$(echo "$NEW_B" | grep -c "hangup:networkLost")
B_CAPACITY=$(echo "$NEW_B" | grep -c "capacityExceeded\|remoteBusy")

echo "[S18] === RESULT ==="
echo "  Family A: ice_restored=$ICE_RESTORED_A networkLost=$NETWORK_LOST_A"
echo "  Family B: connected=$CONNECTED_B ice_restored=$ICE_RESTORED_B networkLost=$NETWORK_LOST_B capacityErr=$B_CAPACITY"

# 결과 분류
if [ "$CONNECTED_B" -eq 1 ] && [ "$ICE_RESTORED_A" -gt 0 ] && [ "$NETWORK_LOST_A" -eq 0 ]; then
  echo "[S18] ✅ B connected 정상 + A 복구 — race 영향 없음"
elif [ "$CONNECTED_B" -eq 1 ] && [ "$NETWORK_LOST_A" -gt 0 ]; then
  echo "[S18] ✅ B connected 정상 + A networkLost (긴 단절 정상) — peer slot 정확"
elif [ "$CONNECTED_B" -eq 0 ] && [ "$B_CAPACITY" -gt 0 ]; then
  echo "[S18] ⚠ B capacity/busy 거절 — Senior 가 A grace 중 새 peer 거부 (정책 분류 필요)"
elif [ "$CONNECTED_B" -eq 0 ]; then
  echo "[S18] ⚠ B connect 실패 (capacity 아님) — Senior 측 peer slot 손상 의심"
else
  echo "[S18] ⚠ 분류 불명확 — raw log 확인"
fi

echo "[S18] Logs:"
echo "  $LOG_A"
echo "  $LOG_B"
echo "  $LOG_S"

# Cleanup: 양쪽 모니터링 종료
adb -s $FAMILY_A shell input tap $HANGUP_MONITOR_X $HANGUP_MONITOR_Y >/dev/null 2>&1
adb -s $FAMILY_B shell input tap $HANGUP_MONITOR_X $HANGUP_MONITOR_Y >/dev/null 2>&1
sleep 2

echo "[S18] === DONE ==="
