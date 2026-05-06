#!/bin/bash
# S13 race 단일 사이클 — 영상통화 1→2 전이 시 Family wifi flap (senior_accepted_auto race)
#
# Plan B 검증 시나리오. s1_3_auto.sh 와 다른 점:
#   - 자동탭 (Senior 수락) 직후 **즉시** wifi off — senior_accepted_auto signal 이 RTDB
#     write 도중 wifi off → wifi 복귀 후 도달 → upgrade 시도 시 노드 상태 판단 race trigger.
#   - STABILIZE_S 안정화 단계 없음. senior_accepted_auto 대기 loop 없음.
#
# 환경 변수:
#   FAMILY_OFF_S   wifi off 유지 시간 (기본 4 — race 가장 자주 발생했던 케이스)
#   OBSERVE_S      wifi 복귀 후 관찰 시간 (기본 30)
#
# 사용법:
#   bash scripts/s13_auto.sh                            # 기본 (4초 off)
#   FAMILY_OFF_S=2 bash scripts/s13_auto.sh             # 다른 timing

set +e
trap 'echo "[S13] cleanup: Family Wi-Fi enable + kill logcat"; adb -s R3CR700SEKP shell svc wifi enable >/dev/null 2>&1; kill $LOGCAT_F_PID $LOGCAT_S_PID 2>/dev/null' EXIT

FAMILY_DEVICE=R3CR700SEKP
SENIOR_DEVICE=KEP2024120921

CALL_BTN_X=285
CALL_BTN_Y=918
SENIOR_ACCEPT_X=640
SENIOR_ACCEPT_Y=400

FAMILY_OFF_S=${FAMILY_OFF_S:-4}
OBSERVE_S=${OBSERVE_S:-30}

LOG_DIR=e:/tmp/s13_auto
mkdir -p "$LOG_DIR"

PID_F=$(adb -s $FAMILY_DEVICE shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR_DEVICE shell pidof com.seniorcare.senior | tr -d '\r')
echo "PID_F=$PID_F PID_S=$PID_S"
if [ -z "$PID_F" ] || [ -z "$PID_S" ]; then
  echo "[S13] ERROR: app not running"
  exit 1
fi

echo "[S13] === START (family_off=${FAMILY_OFF_S}s, observe=${OBSERVE_S}s) ==="

# Step 0: 다이얼로그 dismiss
DIALOG_DUMP=$(adb -s $FAMILY_DEVICE shell "uiautomator dump /sdcard/_s13_check.xml >/dev/null 2>&1; cat /sdcard/_s13_check.xml" 2>/dev/null)
if echo "$DIALOG_DUMP" | grep -q 'content-desc="확인"'; then
  OK_BOUNDS=$(echo "$DIALOG_DUMP" | grep -oE 'content-desc="확인"[^/]*bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1 | grep -oE 'bounds="\[[0-9,]+\]\[[0-9,]+\]"' | tr -dc '0-9,')
  X1=$(echo "$OK_BOUNDS" | cut -d, -f1); Y1=$(echo "$OK_BOUNDS" | cut -d, -f2)
  X2=$(echo "$OK_BOUNDS" | cut -d, -f3); Y2=$(echo "$OK_BOUNDS" | cut -d, -f4)
  CX=$(( (X1 + X2) / 2 )); CY=$(( (Y1 + Y2) / 2 ))
  echo "[S13] Dismiss 다이얼로그 ($CX,$CY)"
  adb -s $FAMILY_DEVICE shell input tap $CX $CY
  sleep 1
fi

sleep 2

# Step 1: 발신 시작
SUFFIX=${FAMILY_OFF_S}s
LOG_F="$LOG_DIR/family_${SUFFIX}.log"
LOG_S="$LOG_DIR/senior_${SUFFIX}.log"
> "$LOG_F"
> "$LOG_S"

# logcat background 캡처
adb -s $FAMILY_DEVICE logcat -v time -T 0 --pid=$PID_F > "$LOG_F" 2>/dev/null &
LOGCAT_F_PID=$!
adb -s $SENIOR_DEVICE logcat -v time -T 0 --pid=$PID_S > "$LOG_S" 2>/dev/null &
LOGCAT_S_PID=$!
sleep 0.3

echo "[S13] Tap 영상통화 ($CALL_BTN_X,$CALL_BTN_Y) @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell input tap $CALL_BTN_X $CALL_BTN_Y

# Step 2: answer_received 대기 (1단계 connected)
CONNECTED=0
for i in {1..20}; do
  sleep 0.5
  if grep -q "answer_received" "$LOG_F" 2>/dev/null; then
    CONNECTED=1
    echo "[S13] FSM connected (1단계) @ $(date +%T.%3N)"
    break
  fi
done
if [ "$CONNECTED" -eq 0 ]; then
  echo "[S13] ERROR: connect 실패"
  kill $LOGCAT_F_PID $LOGCAT_S_PID 2>/dev/null
  exit 1
fi

# Step 3: Senior INCOMING 화면 대기 (1.5s)
sleep 1.5

# Step 4: ★ race trigger — 자동탭 + 즉시 wifi off
# senior_accepted_auto signal 이 RTDB write 도중 wifi off → upgrade 진행 시 노드 상태 race
echo "[S13] Tap Senior 자동수락 ($SENIOR_ACCEPT_X,$SENIOR_ACCEPT_Y) @ $(date +%T.%3N)"
adb -s $SENIOR_DEVICE shell input tap $SENIOR_ACCEPT_X $SENIOR_ACCEPT_Y
T_OFF=$(date +%T.%3N)
echo "[S13] Family Wi-Fi off @ $T_OFF (자동탭 직후 — race trigger)"
adb -s $FAMILY_DEVICE shell svc wifi disable

# Step 5: wifi off 유지
echo "[S13] Family Wi-Fi off ${FAMILY_OFF_S}s 유지..."
sleep $FAMILY_OFF_S

# Step 6: wifi on
T_ON=$(date +%T.%3N)
echo "[S13] Family Wi-Fi on @ $T_ON"
adb -s $FAMILY_DEVICE shell svc wifi enable

# Step 7: observation
echo "[S13] Observation ${OBSERVE_S}s..."
sleep $OBSERVE_S

sleep 1
kill $LOGCAT_F_PID $LOGCAT_S_PID 2>/dev/null
sleep 0.5

NEW_F="$(cat $LOG_F)"
NEW_S="$(cat $LOG_S)"

echo "[S13] === RESULT ==="

# 카운트
NOACCEPTANCE=$(echo "$NEW_F" | grep -c "hangup:noAcceptance")
ICE_RESTORED=$(echo "$NEW_F" | grep -c "ice_restored")
UPGRADE_DONE=$(echo "$NEW_F" | grep -c "renegotiate_done")
NETWORK_LOST=$(echo "$NEW_F" | grep -c "hangup:networkLost")
USER_HANGUP=$(echo "$NEW_F" | grep -c "hangup:userHangup")
HANGUP_REASON=$(echo "$NEW_F" | grep -oE 'hangup:[a-zA-Z]+' | tail -1 | sed 's/hangup://')

echo "[S13] Family 측:"
echo "  ice_restored:           $ICE_RESTORED"
echo "  renegotiate_done:       $UPGRADE_DONE"
echo "  hangup:noAcceptance:    $NOACCEPTANCE  ← race fail 지표"
echo "  hangup:networkLost:     $NETWORK_LOST"
echo "  hangup:userHangup:      $USER_HANGUP"
echo "  종결 사유:              ${HANGUP_REASON:-(정상 유지)}"

echo ""
echo "[S13] Family 주요 이벤트:"
echo "$NEW_F" | grep -E "\[FSM\] CallPhase|hasFlapMarker|senior_accepted_auto|모니터링 → 통화 전환|renegotiate_done|noAcceptance|networkLost|ICE restart" | head -25

echo ""

# 결과 분류 (race fail 지표 = noAcceptance. 다른 종결 사유는 race 무관 정상 흐름)
if [ "$NOACCEPTANCE" -gt 0 ]; then
  echo "[S13] ⚠ noAcceptance — Plan B race 풀림 실패! 전이 race 미해결"
elif [ "$UPGRADE_DONE" -gt 0 ] && [ -z "$HANGUP_REASON" ]; then
  echo "[S13] ✅ upgrade 정상 완료 (renegotiate_done) + 종결 없음 → race 풀림 검증 OK"
elif [ "$HANGUP_REASON" = "upgradeFailed" ]; then
  echo "[S13] ✅ upgradeFailed — wifi off 가 upgrade renegotiate 중간에 떨어져 RTDB write 실패 (race 무관 정상)"
elif [ "$HANGUP_REASON" = "networkLost" ]; then
  echo "[S13] ✅ networkLost — wifi off 길어 ICE restart 실패 정상 종결 (race 무관)"
elif [ "$HANGUP_REASON" = "userHangup" ]; then
  echo "[S13] ✅ userHangup — cleanup tap 정상 종결 (race 풀림 후)"
else
  echo "[S13] ⚠ 종결 사유: ${HANGUP_REASON:-(없음)} — 검토 필요"
fi

echo ""
echo "[S13] Logs:"
echo "  $LOG_F"
echo "  $LOG_S"

# Cleanup: 영상통화 종료 버튼 (540, 2202)
adb -s $FAMILY_DEVICE shell input tap 540 2202 >/dev/null 2>&1
sleep 2

echo "[S13] === DONE ==="
