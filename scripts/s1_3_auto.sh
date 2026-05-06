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
#   bash scripts/s1_3_auto.sh                          # 기본 3s off
#   FAMILY_OFF_S=1 bash scripts/s1_3_auto.sh           # 짧은 flap (PC keepalive 자가 복구)
#   FAMILY_OFF_S=6 bash scripts/s1_3_auto.sh           # ICE restart 1회 시도 (Senior grace 안)
#   FAMILY_OFF_S=15 bash scripts/s1_3_auto.sh          # Senior STOP_DELAY 만료 케이스
#   FAMILY_OFF_S=70 bash scripts/s1_3_auto.sh          # 영구 끊김 (networkLost 종결)

set +e
trap 'echo "[S2] cleanup: Family Wi-Fi enable + kill logcat"; adb -s R3CR700SEKP shell svc wifi enable >/dev/null 2>&1; kill $LOGCAT_F_PID $LOGCAT_S_PID 2>/dev/null' EXIT

FAMILY_DEVICE=R3CR700SEKP
SENIOR_DEVICE=KEP2024120921

# CALL_TYPE: "monitor" (기본) 또는 "call"
CALL_TYPE=${CALL_TYPE:-monitor}
MONITOR_BTN_X=795
MONITOR_BTN_Y=918
CALL_BTN_X=285        # FamilyDetailScreen "영상통화" 버튼
CALL_BTN_Y=918

FAMILY_OFF_S=${FAMILY_OFF_S:-3}
OBSERVE_S=${OBSERVE_S:-30}
# 안정화 시간 — wifi off 전 대기. CALL_TYPE=call 일 때 senior_accepted_auto + upgrade 완료까지
# 충분히 길어야 양방향 진행 후 wifi flap 시나리오 (S1~S3 [영상통화]) 검증 가능. 짧으면
# 1→2 전이 race 시나리오 (S13) 가 검증됨.
STABILIZE_S=${STABILIZE_S:-5}

LOG_DIR=e:/tmp/s1_3_auto
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

# Step 1: 발신 시작 (CALL_TYPE 분기)
SUFFIX=${FAMILY_OFF_S}s
LOG_F="$LOG_DIR/family_${SUFFIX}.log"
LOG_S="$LOG_DIR/senior_${SUFFIX}.log"
> "$LOG_F"
> "$LOG_S"

# logcat background 캡처 (-T 0 = 지금부터 streaming, ring buffer rotation 영향 없음)
adb -s $FAMILY_DEVICE logcat -v time -T 0 --pid=$PID_F > "$LOG_F" 2>/dev/null &
LOGCAT_F_PID=$!
adb -s $SENIOR_DEVICE logcat -v time -T 0 --pid=$PID_S > "$LOG_S" 2>/dev/null &
LOGCAT_S_PID=$!
sleep 0.3  # logcat connect 대기

if [ "$CALL_TYPE" = "call" ]; then
  echo "[S2] Tap 영상통화 ($CALL_BTN_X,$CALL_BTN_Y) @ $(date +%T.%3N)"
  adb -s $FAMILY_DEVICE shell input tap $CALL_BTN_X $CALL_BTN_Y
else
  echo "[S2] Tap 모니터링 ($MONITOR_BTN_X,$MONITOR_BTN_Y) @ $(date +%T.%3N)"
  adb -s $FAMILY_DEVICE shell input tap $MONITOR_BTN_X $MONITOR_BTN_Y
fi

CONNECTED=0
for i in {1..20}; do
  sleep 0.5
  if grep -q "answer_received" "$LOG_F" 2>/dev/null; then
    CONNECTED=1
    echo "[S2] FSM connected @ $(date +%T.%3N)"
    break
  fi
done
if [ "$CONNECTED" -eq 0 ]; then
  echo "[S2] ERROR: ${CALL_TYPE} connect 실패"
  kill $LOGCAT_F_PID $LOGCAT_S_PID 2>/dev/null
  exit 1
fi

# CALL_TYPE=call: Senior INCOMING 화면 자동 수락 — onTouchEvent ACTION_DOWN 이 수락 trigger.
# 화면 1280x800 중앙 (640, 400) 탭. 얼굴인식 대신 ADB 탭으로 즉시 수락.
if [ "$CALL_TYPE" = "call" ]; then
  sleep 1.5  # Senior CallActivity INCOMING 화면 띄울 시간
  echo "[S2] Tap Senior 자동수락 (640,400) @ $(date +%T.%3N)"
  adb -s $SENIOR_DEVICE shell input tap 640 400
  # senior_accepted_auto signal 도달 대기 (upgrade 진행 보장)
  for i in {1..20}; do
    sleep 0.5
    if grep -q "senior_accepted_auto\|renegotiate_done" "$LOG_F" 2>/dev/null; then
      echo "[S2] 영상통화 upgrade 완료 @ $(date +%T.%3N)"
      break
    fi
  done
fi

sleep $STABILIZE_S  # 안정화

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

# logcat background 종료 (buffer flush 대기)
sleep 1
kill $LOGCAT_F_PID $LOGCAT_S_PID 2>/dev/null
sleep 0.5

NEW_F="$(cat $LOG_F)"
NEW_S="$(cat $LOG_S)"

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
echo "  $LOG_F"
echo "  $LOG_S"

# Cleanup: CALL_TYPE 별 종료 버튼 좌표 분기
# - monitor: 빈 영역 탭 (모니터링 자동 종료) — (768, 2202)
# - call: 영상통화 종료 버튼 — (540, 2202) bounds=[330,2124][750,2280]
if [ "$CALL_TYPE" = "call" ]; then
  adb -s $FAMILY_DEVICE shell input tap 540 2202 >/dev/null 2>&1
else
  adb -s $FAMILY_DEVICE shell input tap 768 2202 >/dev/null 2>&1
fi
sleep 2

echo "[S2] === DONE ==="
