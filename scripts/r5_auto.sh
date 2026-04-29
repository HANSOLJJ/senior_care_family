#!/bin/bash
# R5 — Family A 단독 Wi-Fi off (multi-peer 독립성 베이스, 반자동)
#
# 시나리오:
#   - Family A (Android, R3CR700SEKP) + Family B (iPhone, 같은 가족) 모두 모니터링 CONNECTED
#   - Family A 만 Wi-Fi off 6초 → on (S2 시나리오)
#   - Family B 는 Wi-Fi 유지, monitor 그대로
#
# 검증:
#   - Family A: S2 와 동일 (grace 4s 후 ICE restart → ice_restored)
#   - Family B: peer 상태 변경 0건 (Senior log 에서 Family B 의 cid 가 DISCONNECTED/RESTARTING/ENDED 안 나타남)
#   - Senior: Family A peer 만 RESTARTING → CONNECTED 전이, Family B peer CONNECTED 유지
#
# 사용자 매뉴얼 액션:
#   1. 시작 전 iPhone Family B 에서 같은 Senior 가족 진입 → "모니터링" 버튼 탭 → CONNECTED 확인
#   2. iPhone 화면 켜둔 채로 [Enter] 입력하여 자동화 시작

set +e
trap 'echo "[R5] cleanup: ensure wifi enabled"; adb -s R3CR700SEKP shell svc wifi enable >/dev/null 2>&1' EXIT

FAMILY_A_DEVICE=R3CR700SEKP
SENIOR_DEVICE=KEP2024120921

MONITOR_BTN_X=795
MONITOR_BTN_Y=918

WIFI_OFF_S=${WIFI_OFF_S:-6}
OBSERVE_S=${OBSERVE_S:-30}

LOG_DIR=e:/tmp/r5_auto
mkdir -p "$LOG_DIR"

PID_F=$(adb -s $FAMILY_A_DEVICE shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR_DEVICE shell pidof com.seniorcare.senior | tr -d '\r')
echo "Family A PID=$PID_F, Senior PID=$PID_S"
if [ -z "$PID_F" ] || [ -z "$PID_S" ]; then
  echo "[R5] ERROR: app not running"
  exit 1
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo "[R5] 사전 준비 (수동):"
echo "  1. iPhone Family B → 같은 Senior 가족 진입"
echo "  2. iPhone Family B → '모니터링' 버튼 탭"
echo "  3. iPhone 에 'CONNECTED' 영상 표시 확인"
echo ""
echo "준비 완료 후 [Enter] 입력하여 자동화 시작:"
echo "════════════════════════════════════════════════════════"
read -r

# Senior 측 peer count 확인 (Family B 의 cid 가 등록되어 있어야)
SENIOR_BASELINE=$(adb -s $SENIOR_DEVICE logcat -d -v time -b all 2>/dev/null | wc -l)
SENIOR_PEERS_PRE=$(adb -s $SENIOR_DEVICE logcat -d -v time -b all 2>/dev/null | grep -oE '연결 상태: CONNECTED' | wc -l)
echo "[R5] Senior 측 사전 CONNECTED 이벤트 누적: $SENIOR_PEERS_PRE 건 (Family B 가 1건 추가했어야)"

# Step 1: Family A 모니터링 시작
BASELINE_F=$(adb -s $FAMILY_A_DEVICE logcat -d --pid=$PID_F 2>/dev/null | wc -l)
echo "[R5] Family A Tap 모니터링 ($MONITOR_BTN_X,$MONITOR_BTN_Y) @ $(date +%T.%3N)"
adb -s $FAMILY_A_DEVICE shell input tap $MONITOR_BTN_X $MONITOR_BTN_Y

# Step 2: Family A connected 대기
A_CONNECTED=0
for i in {1..20}; do
  sleep 0.5
  NEW=$(adb -s $FAMILY_A_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)))
  if echo "$NEW" | grep -q "answer_received"; then
    A_CONNECTED=1
    echo "[R5] Family A FSM connected @ $(date +%T.%3N)"
    break
  fi
done
if [ "$A_CONNECTED" -eq 0 ]; then
  echo "[R5] ERROR: Family A monitor connect 실패"
  exit 1
fi

# Family A callId 추출
CALL_ID_A=$(adb -s $FAMILY_A_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)) | grep -oE 'callId[=: ][a-zA-Z0-9_-]{10,}' | head -1 | grep -oE '[a-zA-Z0-9_-]{10,}$')
echo "[R5] Family A callId=$CALL_ID_A"

sleep 5  # 안정화

# Senior 측 active peer 들 cid 추출 (Family A 의 cid 와 그 외 — Family B 의 cid 추정)
ACTIVE_PEERS=$(adb -s $SENIOR_DEVICE logcat -d -v time -b all 2>/dev/null | grep -oE '\[-[a-zA-Z0-9_-]{10,}\] 연결 상태: CONNECTED' | grep -oE '\[-[a-zA-Z0-9_-]+\]' | sort -u)
echo "[R5] Senior 활성 peer cid 목록:"
echo "$ACTIVE_PEERS"

# Family B 의 cid (Family A 가 아닌 것)
CALL_ID_B=$(echo "$ACTIVE_PEERS" | grep -v "$CALL_ID_A" | head -1 | tr -d '[]')
echo "[R5] Family B callId 추정: $CALL_ID_B"
if [ -z "$CALL_ID_B" ]; then
  echo "[R5] WARNING: Family B 의 cid 식별 실패 — iPhone 에 모니터링 시작 안 됐거나 로그가 너무 옛날 것"
fi

# Step 3: Family A wifi off
T_OFF=$(date +%T.%3N)
echo ""
echo "[R5] === Family A Wi-Fi off @ $T_OFF (${WIFI_OFF_S}s 유지) ==="
adb -s $FAMILY_A_DEVICE shell svc wifi disable

# 후속 모니터링용 baseline
SENIOR_RACE_BASELINE=$(adb -s $SENIOR_DEVICE logcat -d -v time -b all 2>/dev/null | wc -l)

sleep $WIFI_OFF_S

# Step 4: Family A wifi on
T_ON=$(date +%T.%3N)
echo "[R5] === Family A Wi-Fi on @ $T_ON ==="
adb -s $FAMILY_A_DEVICE shell svc wifi enable

# Step 5: observation
echo "[R5] Observation ${OBSERVE_S}s..."
sleep $OBSERVE_S

# 로그 저장
adb -s $FAMILY_A_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)) > "$LOG_DIR/family_a.log"
adb -s $SENIOR_DEVICE logcat -d -v time -b all 2>/dev/null | tail -n +$((SENIOR_RACE_BASELINE+1)) > "$LOG_DIR/senior_race.log"

NEW_A=$(cat "$LOG_DIR/family_a.log")
SENIOR_RACE=$(cat "$LOG_DIR/senior_race.log")

echo ""
echo "[R5] === RESULT ==="

# Family A 검증
A_DISCONNECT=$(echo "$NEW_A" | grep -c "RTCPeerConnectionStateDisconnected")
A_RESTORED=$(echo "$NEW_A" | grep -c "ice_restored")
A_HANGUP=$(echo "$NEW_A" | grep -oE 'hangup:[a-zA-Z]+' | tail -1 | sed 's/hangup://')

echo "[R5] Family A:"
echo "  PC DISCONNECTED:  $A_DISCONNECT"
echo "  ice_restored:     $A_RESTORED"
echo "  종결 사유:        ${A_HANGUP:-(정상 유지)}"

# Family B 검증 — race window 동안 Family B cid 에 대한 상태 변경 이벤트
if [ -n "$CALL_ID_B" ]; then
  B_EVENTS=$(echo "$SENIOR_RACE" | grep -E "\[$CALL_ID_B\]" | grep -E "DISCONNECTED|RESTARTING|ENDED|연결 상태: CLOSED")
  B_EVENT_COUNT=$(echo "$B_EVENTS" | grep -c .)
  echo ""
  echo "[R5] Family B (cid=$CALL_ID_B) race window 동안 상태 변경 이벤트:"
  if [ "$B_EVENT_COUNT" -eq 0 ]; then
    echo "  ✅ 0 건 — Family B 영향 없음 (peer 독립성 PASS)"
  else
    echo "  ❌ $B_EVENT_COUNT 건 — Family B 영향 받음 (peer 독립성 FAIL):"
    echo "$B_EVENTS" | head -10
  fi
else
  echo "  ⚠ Family B cid 식별 실패 — Senior 로그에서 Family A 외 다른 peer 가 안 보임"
fi

# 결과 분류
echo ""
case "$A_HANGUP" in
  "")
    if [ $A_RESTORED -gt 0 ]; then
      echo "[R5] Family A: ✅ 정상 복구 (S2 동일)"
      if [ "$B_EVENT_COUNT" -eq 0 ] && [ -n "$CALL_ID_B" ]; then
        echo "[R5] ✅ ALL PASS — Family A 복구 + Family B 독립성 유지"
      fi
    else
      echo "[R5] Family A: ⚠ DISCONNECTED 발생했지만 ice_restored 미확인"
    fi
    ;;
  iceFailed)
    echo "[R5] Family A: ⚠ iceFailed — flap 한도 초과 (예상 외)" ;;
  *)
    echo "[R5] Family A: ⚠ 종결 사유 $A_HANGUP" ;;
esac

echo ""
echo "[R5] Logs:"
echo "  $LOG_DIR/family_a.log"
echo "  $LOG_DIR/senior_race.log"
echo "[R5] === DONE ==="
