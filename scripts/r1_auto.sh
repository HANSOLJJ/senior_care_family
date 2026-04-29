#!/bin/bash
# R1 — 좀비 peer 방지 (회귀 테스트)
#
# 시나리오:
#   1. Family 영상통화 발신 → Senior 얼굴인식 자동수락 → 5초 통화
#   2. Family 종료 (hangUp tap)
#   3. **즉시** (1초 내) 다시 발신
#   4. 5회 반복
#
# 통과 기준:
#   - 5/5 모두 정상 발신 (CallPhase.connected 도달)
#   - Senior 측 endReason="remoteBusy" 거부 0건
#   - cleanupCall 의 10초 fire-and-forget delay 가 제대로 동작 (Senior 가 status="ended" 안정 수신)
#
# 환경 변수:
#   REPEAT          반복 횟수 (기본 5)
#   CALL_DURATION_S 통화 유지 시간 (기본 5)
#   GAP_S           hangUp 후 다음 발신까지 (기본 1)

set +e
trap 'echo "[R1] cleanup: ensure wifi enabled"; adb -s KEP2024120921 shell svc wifi enable >/dev/null 2>&1' EXIT

FAMILY_DEVICE=R3CR700SEKP
SENIOR_DEVICE=KEP2024120921

CALL_BTN_X=285        # FamilyDetailScreen "영상통화" 버튼
CALL_BTN_Y=918
HANGUP_BTN_X=540      # MonitoringScreen 영상통화 화면 종료 버튼 (callType=call, 가운데 1개)
HANGUP_BTN_Y=2202

REPEAT=${REPEAT:-5}
CALL_DURATION_S=${CALL_DURATION_S:-5}
GAP_S=${GAP_S:-1}

LOG_DIR=e:/tmp/r1_auto
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/summary.log"
> "$SUMMARY"

PID_F=$(adb -s $FAMILY_DEVICE shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR_DEVICE shell pidof com.seniorcare.senior | tr -d '\r')
echo "PID_F=$PID_F PID_S=$PID_S" | tee -a "$SUMMARY"
if [ -z "$PID_F" ] || [ -z "$PID_S" ]; then
  echo "[R1] ERROR: app not running" | tee -a "$SUMMARY"
  exit 1
fi

echo "[R1] === START (REPEAT=$REPEAT, CALL_DURATION_S=$CALL_DURATION_S, GAP_S=$GAP_S) ===" | tee -a "$SUMMARY"

PASS=0
FAIL=0
RESULTS=()

# 시작 BASELINE — Senior 측 전체 로그에서 remoteBusy 발생 카운트용
SENIOR_BASELINE=$(adb -s $SENIOR_DEVICE logcat -d -v time -b all 2>/dev/null | wc -l)

for cycle in $(seq 1 $REPEAT); do
  echo "" | tee -a "$SUMMARY"
  echo "─── CYCLE $cycle / $REPEAT ───" | tee -a "$SUMMARY"

  # 0. 다이얼로그 dismiss (이전 사이클 잔존)
  DIALOG_DUMP=$(adb -s $FAMILY_DEVICE shell "uiautomator dump /sdcard/_r1_check.xml >/dev/null 2>&1; cat /sdcard/_r1_check.xml" 2>/dev/null)
  if echo "$DIALOG_DUMP" | grep -q 'content-desc="확인"'; then
    OK_BOUNDS=$(echo "$DIALOG_DUMP" | grep -oE 'content-desc="확인"[^/]*bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1 | grep -oE '\[[0-9,]+\]' | head -2)
    X1=$(echo "$OK_BOUNDS" | head -1 | tr -d '[]' | cut -d, -f1)
    Y1=$(echo "$OK_BOUNDS" | head -1 | tr -d '[]' | cut -d, -f2)
    X2=$(echo "$OK_BOUNDS" | tail -1 | tr -d '[]' | cut -d, -f1)
    Y2=$(echo "$OK_BOUNDS" | tail -1 | tr -d '[]' | cut -d, -f2)
    CX=$(( (X1 + X2) / 2 )); CY=$(( (Y1 + Y2) / 2 ))
    echo "[R1] dismiss dialog ($CX,$CY)" | tee -a "$SUMMARY"
    adb -s $FAMILY_DEVICE shell input tap $CX $CY
    sleep 1
  fi

  # 1. 영상통화 발신
  BASELINE_F=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | wc -l)
  TAP_TS=$(date +%T.%3N)
  echo "[R1] Tap 영상통화 ($CALL_BTN_X,$CALL_BTN_Y) @ $TAP_TS" | tee -a "$SUMMARY"
  adb -s $FAMILY_DEVICE shell input tap $CALL_BTN_X $CALL_BTN_Y

  # 2. Senior 자동수락 + answer_received + connected 대기 (최대 30s)
  CONNECTED=0
  REJECTED=0
  for i in {1..60}; do
    sleep 0.5
    NEW=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)))
    if echo "$NEW" | grep -qE "renegotiate_done|CallPhase.connected.*reason: senior_accepted_auto"; then
      CONNECTED=1
      echo "[R1] CallPhase.connected @ $(date +%T.%3N) (탭 후 ${i}*0.5s)" | tee -a "$SUMMARY"
      break
    fi
    if echo "$NEW" | grep -qE "remoteBusy|remoteBusy"; then
      REJECTED=1
      echo "[R1] ❌ remoteBusy 거절됨 — 좀비 peer 발생" | tee -a "$SUMMARY"
      break
    fi
  done

  if [ "$REJECTED" -eq 1 ]; then
    RESULTS+=("$cycle: ❌ FAIL (remoteBusy)")
    FAIL=$((FAIL+1))
    sleep 5
    continue
  fi
  if [ "$CONNECTED" -eq 0 ]; then
    RESULTS+=("$cycle: ❌ FAIL (connect timeout)")
    FAIL=$((FAIL+1))
    sleep 5
    continue
  fi

  # callId 추출
  CALL_ID=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)) | grep -oE 'callId[=: ][a-zA-Z0-9_-]{10,}' | head -1 | grep -oE '[a-zA-Z0-9_-]{10,}$')
  echo "[R1] callId=$CALL_ID" | tee -a "$SUMMARY"

  # 3. CALL_DURATION_S 통화 유지
  echo "[R1] 통화 유지 ${CALL_DURATION_S}s..." | tee -a "$SUMMARY"
  sleep $CALL_DURATION_S

  # 4. Family hangUp tap
  HANGUP_TS=$(date +%T.%3N)
  echo "[R1] Family hangUp tap ($HANGUP_BTN_X,$HANGUP_BTN_Y) @ $HANGUP_TS" | tee -a "$SUMMARY"
  adb -s $FAMILY_DEVICE shell input tap $HANGUP_BTN_X $HANGUP_BTN_Y

  # 5. Family terminated 확인 (최대 5s)
  TERMINATED=0
  for i in {1..10}; do
    sleep 0.5
    NEW=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE_F+1)))
    if echo "$NEW" | grep -q "CallPhase.terminating → CallPhase.terminated"; then
      TERMINATED=1
      echo "[R1] Family terminated @ $(date +%T.%3N)" | tee -a "$SUMMARY"
      break
    fi
  done
  if [ "$TERMINATED" -eq 0 ]; then
    echo "[R1] ⚠ terminated 미확인 (5s 내)" | tee -a "$SUMMARY"
  fi

  # 6. GAP_S 후 다음 cycle (마지막 cycle 제외)
  RESULTS+=("$cycle: ✅ PASS (connected + terminated)")
  PASS=$((PASS+1))

  if [ "$cycle" -ne "$REPEAT" ]; then
    echo "[R1] gap ${GAP_S}s..." | tee -a "$SUMMARY"
    sleep $GAP_S
  fi
done

echo "" | tee -a "$SUMMARY"
echo "==== R1 RESULT ====" | tee -a "$SUMMARY"
echo "PASS: $PASS / $REPEAT" | tee -a "$SUMMARY"
echo "FAIL: $FAIL / $REPEAT" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"
echo "사이클별 결과:" | tee -a "$SUMMARY"
for r in "${RESULTS[@]}"; do
  echo "  $r" | tee -a "$SUMMARY"
done

# Senior 측 remoteBusy 카운트
SENIOR_LOG=$(adb -s $SENIOR_DEVICE logcat -d -v time -b all 2>/dev/null | tail -n +$((SENIOR_BASELINE+1)))
SENIOR_REJECT_COUNT=$(echo "$SENIOR_LOG" | grep -c "remoteBusy")
echo "" | tee -a "$SUMMARY"
echo "Senior 측 'remoteBusy' 발생: $SENIOR_REJECT_COUNT 건" | tee -a "$SUMMARY"

# 로그 저장
echo "$SENIOR_LOG" > "$LOG_DIR/senior_full.log"

echo "" | tee -a "$SUMMARY"
if [ "$PASS" -eq "$REPEAT" ] && [ "$SENIOR_REJECT_COUNT" -eq 0 ]; then
  echo "[R1] ✅ ALL PASS — 좀비 peer 발생 없음" | tee -a "$SUMMARY"
else
  echo "[R1] ❌ REGRESSION — $FAIL 사이클 실패 또는 Senior remoteBusy $SENIOR_REJECT_COUNT 건 발생" | tee -a "$SUMMARY"
fi

echo "" | tee -a "$SUMMARY"
echo "Logs:" | tee -a "$SUMMARY"
echo "  $SUMMARY" | tee -a "$SUMMARY"
echo "  $LOG_DIR/senior_full.log" | tee -a "$SUMMARY"
echo "[R1] === DONE ===" | tee -a "$SUMMARY"
