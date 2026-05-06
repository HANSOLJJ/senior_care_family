#!/bin/bash
# R2 자동 (영상통화 버전) — restoreActiveStatus LWW race + UX 영향 검증
#
# 모니터링 vs 영상통화 차이:
#   모니터링: Senior UI 없음 → R2 race UX 영향 0 (CPU/배터리만 낭비)
#   영상통화: Senior 풀스크린 통화 화면 → race 동안 "통화 중" 잔존 + Family 영상 frozen
#
# 시퀀스:
#   1. Family 영상통화 발신 → Senior 얼굴인식 자동수락 (사용자 책임)
#   2. answer_received → CallPhase.connected → 안정화 3s
#   3. Senior Wi-Fi off
#   4. ONDISCONNECT_WAIT_S 대기 (onDisconnect 발화)
#   5. Family hangUp tap → endCall (status="ended", endReason 무건드림)
#   6. HANGUP_TO_WIFI_ON_S 대기 → Senior Wi-Fi on
#   7. observation — Senior FSM ENDED 시점 측정
#
# 검증 포인트:
#   - Senior 로그 "active status 복원 완료" → R2 race 발생
#   - Senior FSM ENDED 도달 시각 — Family hangUp 으로부터 얼마나 오래 잔존?
#   - 그 시간 동안 Senior UI 는 "통화 중" 화면 표시 (카메라 + 마이크 활성)
#
# 환경 변수:
#   ONDISCONNECT_WAIT_S   기본 1.5
#   HANGUP_TO_WIFI_ON_S   기본 0.5
#   OBSERVE_S             기본 30 (영상통화 PC keepalive 더 김)

set +e
trap 'echo "[R2-CALL] cleanup: Senior Wi-Fi enable"; adb -s KEP2024120921 shell svc wifi enable >/dev/null 2>&1' EXIT

FAMILY_DEVICE=R3CR700SEKP
SENIOR_DEVICE=KEP2024120921

# 좌표 (SM-G991N 1080x2400)
CALL_BTN_X=285        # FamilyDetailScreen "영상통화" 버튼
CALL_BTN_Y=918
# 영상통화 화면은 종료 버튼 1개만 가운데 배치 (모니터링은 통화전환+종료 2개)
# Row Center, button width 140, screen width 1080 → X 중앙 = 540. Y 는 모니터링과 동일 2202.
HANGUP_BTN_X=540
HANGUP_BTN_Y=2202

ONDISCONNECT_WAIT_S=${ONDISCONNECT_WAIT_S:-1.5}
HANGUP_TO_WIFI_ON_S=${HANGUP_TO_WIFI_ON_S:-0.5}
OBSERVE_S=${OBSERVE_S:-30}

LOG_DIR=e:/tmp/r2_call_auto
mkdir -p "$LOG_DIR"

PID_F=$(adb -s $FAMILY_DEVICE shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR_DEVICE shell pidof com.seniorcare.senior | tr -d '\r')
echo "PID_F=$PID_F PID_S=$PID_S"
if [ -z "$PID_F" ] || [ -z "$PID_S" ]; then
  echo "[R2-CALL] ERROR: app not running"
  exit 1
fi

echo "[R2-CALL] === START ==="
echo "[R2-CALL] race window: onDisconnect_wait=${ONDISCONNECT_WAIT_S}s, hangup→wifi_on=${HANGUP_TO_WIFI_ON_S}s, observe=${OBSERVE_S}s"

# Step 0: 다이얼로그 dismiss
DIALOG_DUMP=$(adb -s $FAMILY_DEVICE shell "uiautomator dump /sdcard/_r2c_check.xml >/dev/null 2>&1; cat /sdcard/_r2c_check.xml" 2>/dev/null)
if echo "$DIALOG_DUMP" | grep -q 'content-desc="확인"'; then
  OK_BOUNDS=$(echo "$DIALOG_DUMP" | grep -oE 'content-desc="확인"[^/]*bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1 | grep -oE 'bounds="\[[0-9,]+\]\[[0-9,]+\]"' | tr -dc '0-9,')
  X1=$(echo "$OK_BOUNDS" | cut -d, -f1); Y1=$(echo "$OK_BOUNDS" | cut -d, -f2)
  X2=$(echo "$OK_BOUNDS" | cut -d, -f3); Y2=$(echo "$OK_BOUNDS" | cut -d, -f4)
  CX=$(( (X1 + X2) / 2 )); CY=$(( (Y1 + Y2) / 2 ))
  echo "[R2-CALL] Dismiss 다이얼로그 ($CX,$CY)"
  adb -s $FAMILY_DEVICE shell input tap $CX $CY
  sleep 1
fi

# Step 1: 영상통화 발신
BASELINE_F=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | wc -l)
BASELINE_S=$(adb -s $SENIOR_DEVICE logcat -d --pid=$PID_S 2>/dev/null | wc -l)
echo "[R2-CALL] Tap 영상통화 ($CALL_BTN_X,$CALL_BTN_Y) @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell input tap $CALL_BTN_X $CALL_BTN_Y

# Step 2: Senior 자동수락 + answer_received 대기 (최대 30s)
CONNECTED=0
for i in {1..60}; do
  sleep 0.5
  NEW=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)))
  if echo "$NEW" | grep -q "renegotiate_done\|CallPhase.connected" ; then
    CONNECTED=1
    echo "[R2-CALL] CallPhase.connected @ $(date +%T.%3N) (탭 후 ${i}*0.5s)"
    break
  fi
done
if [ "$CONNECTED" -eq 0 ]; then
  echo "[R2-CALL] ERROR: 통화 connected 실패 (Senior 자동수락 안 됨?)"
  exit 1
fi

# callId 추출
CALL_ID=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)) | grep -oE 'callId[=: ][a-zA-Z0-9_-]{10,}' | head -1 | grep -oE '[a-zA-Z0-9_-]{10,}$')
echo "[R2-CALL] callId=$CALL_ID"

sleep 3  # 안정화

# Step 3: race 시작 시각 마커
T_RACE_START=$(date +%T.%3N)
echo ""
echo "[R2-CALL] ─── race 시작 @ $T_RACE_START ───"

# Step 4: Senior wifi off
echo "[R2-CALL] Senior Wi-Fi off @ $(date +%T.%3N)"
adb -s $SENIOR_DEVICE shell svc wifi disable

# Step 5: onDisconnect 발화 대기
sleep $ONDISCONNECT_WAIT_S

# Step 6: Family hangUp tap
T_HANGUP=$(date +%T.%3N)
echo "[R2-CALL] Family hangUp tap ($HANGUP_BTN_X,$HANGUP_BTN_Y) @ $T_HANGUP"
adb -s $FAMILY_DEVICE shell input tap $HANGUP_BTN_X $HANGUP_BTN_Y

# Step 7: Senior wifi on (race 활성)
sleep $HANGUP_TO_WIFI_ON_S
echo "[R2-CALL] Senior Wi-Fi on @ $(date +%T.%3N)"
adb -s $SENIOR_DEVICE shell svc wifi enable

# Step 8: observation
echo "[R2-CALL] Observation ${OBSERVE_S}s..."
sleep $OBSERVE_S

# 로그 저장
adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)) > "$LOG_DIR/family.log"
adb -s $SENIOR_DEVICE logcat -d -v time -b all > "$LOG_DIR/senior_all.log" 2>&1
grep "($PID_S)" "$LOG_DIR/senior_all.log" > "$LOG_DIR/senior.log" 2>/dev/null
[ ! -s "$LOG_DIR/senior.log" ] && grep " $PID_S " "$LOG_DIR/senior_all.log" > "$LOG_DIR/senior.log" 2>/dev/null
[ ! -s "$LOG_DIR/senior.log" ] && cp "$LOG_DIR/senior_all.log" "$LOG_DIR/senior.log"

echo ""
echo "[R2-CALL] === RESULT ==="

NEW_F=$(cat "$LOG_DIR/family.log")
NEW_S=$(cat "$LOG_DIR/senior.log")

# Senior 측 분기
RESTORE_OK=$(echo "$NEW_S" | grep -c "active status 복원 완료")
CANCEL_OK=$(echo "$NEW_S" | grep -c "onDisconnect cleanup 취소")

# Family hangUp 시각
T_FAMILY_HANGUP=$(echo "$NEW_F" | grep -E "hangup:userHangup|hangup:remoteEnded" | head -1 | grep -oE '[0-9]+:[0-9]+:[0-9]+\.[0-9]+' | head -1)
# Senior FSM ENDED 시각
T_SENIOR_ENDED=$(echo "$NEW_S" | grep -E "→ ENDED|FSM.*ENDED|peer 리소스 해제" | head -1 | grep -oE '[0-9]+:[0-9]+:[0-9]+\.[0-9]+' | head -1)

echo "[R2-CALL] Senior 측 분기:"
echo "  cancelDisconnectCleanup 호출: $CANCEL_OK"
echo "  restoreActiveStatus 성공:     $RESTORE_OK"
echo ""
echo "[R2-CALL] 시점 비교 (Senior UI 잔존 시간):"
echo "  Family hangUp: $T_FAMILY_HANGUP"
echo "  Senior ENDED:  $T_SENIOR_ENDED"
echo ""

echo "[R2-CALL] Senior 주요 이벤트:"
echo "$NEW_S" | grep -E "통화 상태 변경|seniorDisconnect|active status|onDisconnect cleanup|연결 상태|FSM peer|stopPeer|sendIceRestart|→ ENDED|peer 리소스 해제" | head -25

echo ""
echo "[R2-CALL] Family hangUp 흐름:"
echo "$NEW_F" | grep -E "FSM.*Call|hangup:|통화 종료 신호|cleanup_done|네트워크 실패" | head -10

# 결과 분류
echo ""
if [ $RESTORE_OK -gt 0 ]; then
  echo "[R2-CALL] ⚠ RACE 발생 — Senior restoreActiveStatus 호출"
  echo "    → Senior 측 통화 화면 잔존 (Family 종결 후): $T_FAMILY_HANGUP ~ $T_SENIOR_ENDED"
  echo "    → 그 시간 동안 Senior 사용자에게 'Family 영상 멎어있는 통화 중' 화면 표시"
elif [ $CANCEL_OK -gt 0 ]; then
  echo "[R2-CALL] ⚠ 부분 race"
else
  echo "[R2-CALL] ✅ NO RACE — race window 빗나감"
fi

echo ""
echo "[R2-CALL] Logs:"
echo "  $LOG_DIR/family.log"
echo "  $LOG_DIR/senior.log"
echo "[R2-CALL] === DONE ==="
