#!/bin/bash
# R2 자동 — restoreActiveStatus LWW race 검증
#
# 시나리오:
#   T+0      Senior Wi-Fi off → server-side onDisconnect 발화
#            → /calls/{cid}: status="ended" + endReason="seniorDisconnect"
#   T+W1     Family hangUp tap → endCall 이 status="ended" 만 덮어씀
#            (endReason 은 안 건드림 → "seniorDisconnect" 그대로)
#   T+W1+W2  Senior Wi-Fi on → reconnect → listenForStatus 가
#            {status=ended, endReason=seniorDisconnect} 받음 → 자기 결과로 인식
#            → cancelDisconnectCleanup + restoreActiveStatus
#            → setValue(status="answered", endReason=null) ← 좀비 노드!
#
# 검증 포인트:
#   - Senior 로그 "active status 복원 완료" → R2 race 발생 (좀비 시도)
#   - Family 로그 "calls 노드 삭제" → cleanupCall 10s 지연 후 자동 정리 확인
#   - 두 시점 사이 "통화 유지" 화면 vs Family "종료" UX 불일치
#
# 환경 변수:
#   ONDISCONNECT_WAIT_S   onDisconnect 발화 대기 (기본 1.5)
#   HANGUP_TO_WIFI_ON_S   Family hangUp → Senior Wi-Fi on (기본 0.5)
#   OBSERVE_S             관찰 시간 (기본 15)
#
# 사용법:
#   bash scripts/r2_auto.sh                              # 기본
#   ONDISCONNECT_WAIT_S=2 bash scripts/r2_auto.sh        # onDisconnect 더 확실히 대기

set +e
trap 'echo "[R2] cleanup: Senior Wi-Fi enable"; adb -s KEP2024120921 shell svc wifi enable >/dev/null 2>&1' EXIT

FAMILY_DEVICE=R3CR700SEKP
SENIOR_DEVICE=KEP2024120921

MONITOR_BTN_X=795
MONITOR_BTN_Y=918
HANGUP_BTN_X=768
HANGUP_BTN_Y=2202

ONDISCONNECT_WAIT_S=${ONDISCONNECT_WAIT_S:-1.5}
HANGUP_TO_WIFI_ON_S=${HANGUP_TO_WIFI_ON_S:-0.5}
OBSERVE_S=${OBSERVE_S:-15}

LOG_DIR=e:/tmp/r2_auto
mkdir -p "$LOG_DIR"

PID_F=$(adb -s $FAMILY_DEVICE shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR_DEVICE shell pidof com.seniorcare.senior | tr -d '\r')
echo "PID_F=$PID_F PID_S=$PID_S"
if [ -z "$PID_F" ] || [ -z "$PID_S" ]; then
  echo "[R2] ERROR: app not running"
  exit 1
fi

echo "[R2] === START ==="
echo "[R2] race window: onDisconnect_wait=${ONDISCONNECT_WAIT_S}s, hangup→wifi_on=${HANGUP_TO_WIFI_ON_S}s"

# Step 0: 다이얼로그 dismiss
DIALOG_DUMP=$(adb -s $FAMILY_DEVICE shell "uiautomator dump /sdcard/_r2_check.xml >/dev/null 2>&1; cat /sdcard/_r2_check.xml" 2>/dev/null)
if echo "$DIALOG_DUMP" | grep -q 'content-desc="확인"'; then
  OK_BOUNDS=$(echo "$DIALOG_DUMP" | grep -oE 'content-desc="확인"[^/]*bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1 | grep -oE 'bounds="\[[0-9,]+\]\[[0-9,]+\]"' | tr -dc '0-9,')
  X1=$(echo "$OK_BOUNDS" | cut -d, -f1); Y1=$(echo "$OK_BOUNDS" | cut -d, -f2)
  X2=$(echo "$OK_BOUNDS" | cut -d, -f3); Y2=$(echo "$OK_BOUNDS" | cut -d, -f4)
  CX=$(( (X1 + X2) / 2 )); CY=$(( (Y1 + Y2) / 2 ))
  echo "[R2] Dismiss 다이얼로그 ($CX,$CY)"
  adb -s $FAMILY_DEVICE shell input tap $CX $CY
  sleep 1
fi

# Step 1: 모니터링 시작
BASELINE_F=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | wc -l)
BASELINE_S=$(adb -s $SENIOR_DEVICE logcat -d --pid=$PID_S 2>/dev/null | wc -l)
echo "[R2] Tap 모니터링 ($MONITOR_BTN_X,$MONITOR_BTN_Y) @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell input tap $MONITOR_BTN_X $MONITOR_BTN_Y

CONNECTED=0
for i in {1..20}; do
  sleep 0.5
  NEW=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)))
  if echo "$NEW" | grep -q "answer_received"; then
    CONNECTED=1
    echo "[R2] FSM connected @ $(date +%T.%3N)"
    break
  fi
done
if [ "$CONNECTED" -eq 0 ]; then
  echo "[R2] ERROR: monitor connect 실패"
  exit 1
fi

# callId 추출 (Family 로그에서)
CALL_ID=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)) | grep -oE 'callId[=: ][a-zA-Z0-9_-]{10,}' | head -1 | grep -oE '[a-zA-Z0-9_-]{10,}$')
echo "[R2] callId=$CALL_ID"

sleep 3  # 안정화

# Step 2: Senior Wi-Fi off
T_OFF=$(date +%s.%3N)
echo "[R2] Senior Wi-Fi off @ $(date +%T.%3N)"
adb -s $SENIOR_DEVICE shell svc wifi disable

# Step 3: onDisconnect 발화 대기
echo "[R2] onDisconnect 발화 대기 ${ONDISCONNECT_WAIT_S}s..."
sleep $ONDISCONNECT_WAIT_S

# Step 4: Family hangUp tap (race 트리거)
T_HANGUP=$(date +%s.%3N)
echo "[R2] Family hangUp tap ($HANGUP_BTN_X,$HANGUP_BTN_Y) @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell input tap $HANGUP_BTN_X $HANGUP_BTN_Y

# Step 5: Senior Wi-Fi on (race 활성)
sleep $HANGUP_TO_WIFI_ON_S
T_ON=$(date +%s.%3N)
echo "[R2] Senior Wi-Fi on @ $(date +%T.%3N)"
adb -s $SENIOR_DEVICE shell svc wifi enable

# Step 6: observation
echo "[R2] Observation ${OBSERVE_S}s..."
sleep $OBSERVE_S

# 로그 저장
adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)) > "$LOG_DIR/family.log"
adb -s $SENIOR_DEVICE logcat -d -v time -b all > "$LOG_DIR/senior_all.log" 2>&1
grep " $PID_S " "$LOG_DIR/senior_all.log" > "$LOG_DIR/senior.log" 2>/dev/null
[ ! -s "$LOG_DIR/senior.log" ] && cp "$LOG_DIR/senior_all.log" "$LOG_DIR/senior.log"

echo ""
echo "[R2] === RESULT ==="

NEW_F=$(cat "$LOG_DIR/family.log")
NEW_S=$(cat "$LOG_DIR/senior.log")

# Senior 측 분기
RESTORE_LOGS=$(echo "$NEW_S" | grep -E "active status 복원|onDisconnect cleanup 취소|seniorDisconnect")
HANGUP_FAMILY=$(echo "$NEW_F" | grep -E "hangup:|endCall|통화 종료 신호|calls 노드 삭제|cleanupCall")

RESTORE_OK=$(echo "$NEW_S" | grep -c "active status 복원 완료")
CANCEL_OK=$(echo "$NEW_S" | grep -c "onDisconnect cleanup 취소")

echo "[R2] Senior 측 분기:"
echo "  cancelDisconnectCleanup 호출: $CANCEL_OK"
echo "  restoreActiveStatus 성공:     $RESTORE_OK"
echo ""
echo "[R2] Senior 관련 로그:"
echo "$RESTORE_LOGS" | head -10
echo ""
echo "[R2] Family hangUp/cleanup 로그:"
echo "$HANGUP_FAMILY" | head -10

# 결과 분류
echo ""
if [ $RESTORE_OK -gt 0 ]; then
  echo "[R2] ⚠ RACE 발생 — Senior restoreActiveStatus 호출됨"
  echo "    → /calls/$CALL_ID 가 status='answered', endReason=null 로 좀비 시도"
  if echo "$NEW_F" | grep -q "calls 노드 삭제\|cleanupCall.*완료\|remove 완료"; then
    echo "    → ✅ Family cleanupCall(10s 지연) 이 좀비 노드 정리"
    echo "    → 결과: 좀비 일시 발생 후 자동 정리. 그래도 fix 권장 (UX 일시 불일치 + cleanup 실패 대비)"
  else
    echo "    → ❌ Family cleanupCall 흔적 없음 — 좀비 노드 잔존 가능성. Firebase Console 확인 필요"
  fi
elif [ $CANCEL_OK -gt 0 ]; then
  echo "[R2] ⚠ 부분 race — cancelDisconnectCleanup 만 호출. restoreActiveStatus 미발화 (race window 빗나감)"
else
  echo "[R2] ✅ NO RACE — Senior 분기 안 탐"
  echo "    → Family hangUp 이 endReason 까지 덮어쓴 경우 또는"
  echo "    → onDisconnect 가 wifi off 1.5s 안에 발화 안 한 경우"
  echo "    → ONDISCONNECT_WAIT_S 늘려서 재시도"
fi

echo ""
echo "[R2] Logs:"
echo "  $LOG_DIR/family.log"
echo "  $LOG_DIR/senior.log"
echo "[R2] === DONE ==="
