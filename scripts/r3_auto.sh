#!/bin/bash
# R3 — 1:N × 1:1 displace 정책 실측 (반자동)
#
# 시나리오:
#   - Family A (Android, R3CR700SEKP) 모니터링 CONNECTED
#   - Family B (iPhone) 영상통화 발신 → Senior 자동수락 (얼굴인식)
#   - Senior 가 Family A peer 를 displace → endReason="otherCallStarted"
#   - Family A: FSM connected → terminating(hangup:endedByOtherCall) → terminated
#
# 검증:
#   - Family A: 다이얼로그 "모니터링이 종료되었습니다" → pop
#   - Senior: displace 로그 + RTDB /calls/{cidA}/endReason="otherCallStarted"
#
# 사용자 매뉴얼 액션:
#   1. 시작 전 iPhone Family B 가 같은 Senior 가족의 FamilyDetailScreen 에 위치
#   2. 스크립트가 prompt 띄울 때 iPhone 에서 "영상통화" 버튼 탭 → [Enter]

set +e
trap 'echo "[R3] cleanup: ensure wifi enabled"; adb -s R3CR700SEKP shell svc wifi enable >/dev/null 2>&1' EXIT

FAMILY_A_DEVICE=R3CR700SEKP
SENIOR_DEVICE=KEP2024120921

MONITOR_BTN_X=795
MONITOR_BTN_Y=918

OBSERVE_S=${OBSERVE_S:-30}

LOG_DIR=e:/tmp/r3_auto
mkdir -p "$LOG_DIR"

PID_F=$(adb -s $FAMILY_A_DEVICE shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR_DEVICE shell pidof com.seniorcare.senior | tr -d '\r')
echo "Family A PID=$PID_F, Senior PID=$PID_S"
if [ -z "$PID_F" ] || [ -z "$PID_S" ]; then
  echo "[R3] ERROR: app not running"
  exit 1
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo "[R3] 사전 준비 (수동):"
echo "  1. iPhone Family B 가 같은 Senior 가족의 FamilyDetailScreen 에 위치"
echo "     ※ FamilyDetailScreen = '영상통화' / '모니터링' 버튼이 보이는 화면"
echo ""
echo "준비 완료 후 [Enter] 입력하여 자동화 시작:"
echo "════════════════════════════════════════════════════════"
read -r

# Step 1: Family A 모니터링 시작
BASELINE_F=$(adb -s $FAMILY_A_DEVICE logcat -d --pid=$PID_F 2>/dev/null | wc -l)
echo "[R3] Family A Tap 모니터링 ($MONITOR_BTN_X,$MONITOR_BTN_Y) @ $(date +%T.%3N)"
adb -s $FAMILY_A_DEVICE shell input tap $MONITOR_BTN_X $MONITOR_BTN_Y

# Step 2: Family A connected 대기
A_CONNECTED=0
for i in {1..20}; do
  sleep 0.5
  NEW=$(adb -s $FAMILY_A_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)))
  if echo "$NEW" | grep -q "answer_received"; then
    A_CONNECTED=1
    echo "[R3] Family A FSM connected @ $(date +%T.%3N)"
    break
  fi
done
if [ "$A_CONNECTED" -eq 0 ]; then
  echo "[R3] ERROR: Family A monitor connect 실패"
  exit 1
fi

CALL_ID_A=$(adb -s $FAMILY_A_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)) | grep -oE 'callId[=: ][a-zA-Z0-9_-]{10,}' | head -1 | grep -oE '[a-zA-Z0-9_-]{10,}$')
echo "[R3] Family A callId=$CALL_ID_A"

sleep 5  # 안정화

# Step 3: User triggers iPhone Family B 영상통화
SENIOR_RACE_BASELINE=$(adb -s $SENIOR_DEVICE logcat -d -v time -b all 2>/dev/null | wc -l)
echo ""
echo "════════════════════════════════════════════════════════"
echo "[R3] >>> 지금 iPhone Family B 에서 '영상통화' 버튼 탭 <<<"
echo "    Senior 자동수락 (얼굴인식) 후 displace 발생 예상"
echo "    탭 직후 [Enter] 입력:"
echo "════════════════════════════════════════════════════════"
read -r
T_TAP=$(date +%T.%3N)
echo "[R3] Family B 영상통화 탭 (사용자 신고) @ $T_TAP"

# Step 4: observation — Family A displace 대기
echo "[R3] Observation ${OBSERVE_S}s — Family A displace 감지 대기..."
sleep $OBSERVE_S

# 로그 저장
adb -s $FAMILY_A_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)) > "$LOG_DIR/family_a.log"
adb -s $SENIOR_DEVICE logcat -d -v time -b all 2>/dev/null | tail -n +$((SENIOR_RACE_BASELINE+1)) > "$LOG_DIR/senior_race.log"

NEW_A=$(cat "$LOG_DIR/family_a.log")
SENIOR_RACE=$(cat "$LOG_DIR/senior_race.log")

echo ""
echo "[R3] === RESULT ==="

# Family A 검증
A_HANGUP=$(echo "$NEW_A" | grep -oE 'hangup:[a-zA-Z]+' | tail -1 | sed 's/hangup://')
A_OTHER_CALL=$(echo "$NEW_A" | grep -c "endedByOtherCall\|hangup:endedByOtherCall")
A_DIALOG=$(echo "$NEW_A" | grep -c "모니터링이 종료\|otherCallStarted")
A_TERMINATED=$(echo "$NEW_A" | grep -c "CallPhase.terminating → CallPhase.terminated")

echo "[R3] Family A:"
echo "  종결 사유:                     ${A_HANGUP:-(없음)}"
echo "  endedByOtherCall 매핑:         $A_OTHER_CALL 건"
echo "  CallPhase.terminated 도달:     $A_TERMINATED 건"

# Senior 측 displace 검증
SENIOR_DISPLACE=$(echo "$SENIOR_RACE" | grep -c "displace")
SENIOR_OTHERCALL_WRITE=$(echo "$SENIOR_RACE" | grep -c "otherCallStarted")
SENIOR_REJECTCALL=$(echo "$SENIOR_RACE" | grep -c "rejectCall.*OTHER_CALL_STARTED")

echo ""
echo "[R3] Senior:"
echo "  displace 로그:                 $SENIOR_DISPLACE 건"
echo "  endReason='otherCallStarted':  $SENIOR_OTHERCALL_WRITE 건"
echo "  rejectCall(OTHER_CALL_STARTED): $SENIOR_REJECTCALL 건"

# 통과 기준 분류
echo ""
if [ "$A_HANGUP" = "endedByOtherCall" ] && [ "$A_TERMINATED" -gt 0 ] && [ "$SENIOR_DISPLACE" -gt 0 ]; then
  echo "[R3] ✅ PASS — Family A displace 정상 + Senior displace 로그 + endReason 기록"
elif [ "$A_HANGUP" = "endedByOtherCall" ]; then
  echo "[R3] ⚠ Family A displace 정상이지만 Senior 로그 일부 누락 — 수동 검토 필요"
elif [ -n "$A_HANGUP" ]; then
  echo "[R3] ❌ FAIL — Family A 종결 사유가 '$A_HANGUP' (예상: endedByOtherCall)"
else
  echo "[R3] ❌ FAIL — Family A 종결 안 됨 (Family B 가 영상통화 안 했거나 Senior 자동수락 실패)"
fi

echo ""
echo "[R3] Logs:"
echo "  $LOG_DIR/family_a.log"
echo "  $LOG_DIR/senior_race.log"
echo "[R3] === DONE ==="
