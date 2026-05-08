#!/bin/bash
# cellular_repro_a17.sh — A17 cellular handoff 검은 화면 재현 sweep
#
# cellular_ice_investigation.md §6 후보 6-A~E 통합 실행. 단일 디바이스 (A17 RFKYA00Y49L).
#
# Phase A (6-A): 반복 핸드오프 stress  — 모니터링 active 상태에서 wifi on/off N cycles
# Phase B (6-B): 영상통화 핸드오프      — call IN_CALL 진입 후 wifi off 5 cycles
# Phase C (6-C): cellular 재발신 반복   — wifi off 유지하고 영상통화 발신/종결 N cycles (이전 fail mode 진입 가장 비슷)
# Phase D (6-D): 긴 cellular 유지       — wifi off 70s → cellular only 신규 발신 검증
# Phase E (6-E): RTDB ended 지연 측정   — wifi vs cellular hangup → ended 도달 시간 비교
#
# 사전 조건:
#   - A17 RFKYA00Y49L: SIM 활성 + mobile data on + family detail screen
#   - Senior KEP2024120921: wifi on
#   - 좌표는 G991N 와 동일 가정 (1080x2400 세로)
#
# 사용법:
#   bash scripts/cellular_repro_a17.sh                       # 전체 (A→B→C→D→E)
#   PHASES=A bash scripts/cellular_repro_a17.sh              # A 만
#   PHASES=A,C bash scripts/cellular_repro_a17.sh            # A + C
#   CYCLES=10 bash scripts/cellular_repro_a17.sh             # cycle 수 변경
#   EARLY_STOP=1 bash scripts/cellular_repro_a17.sh          # fail 감지 시 중단

set +e

FAMILY=RFKYA00Y49L
SENIOR=KEP2024120921

MONITOR_BTN_X=795
MONITOR_BTN_Y=918
CALL_BTN_X=285
CALL_BTN_Y=918
HANGUP_MONITOR_X=768
HANGUP_MONITOR_Y=2202
HANGUP_CALL_X=540
HANGUP_CALL_Y=2202
SENIOR_ACCEPT_X=640
SENIOR_ACCEPT_Y=400

CYCLES=${CYCLES:-20}
PHASES=${PHASES:-A,B,C,D,E}
EARLY_STOP=${EARLY_STOP:-0}
BLACK_THRESHOLD=${BLACK_THRESHOLD:-15}  # 평균 luminance < 이 값 = 검은 화면 의심 (어두운 영상 false positive 방지)
EARLY_STOP_TRIGGERED=0

LOG_DIR=e:/tmp/cellular_repro
SCREENSHOT_DIR="$LOG_DIR/screenshots"
mkdir -p "$LOG_DIR" "$SCREENSHOT_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIGHTNESS_PY="$SCRIPT_DIR/check_brightness.py"

# ============================================================================
# Helper functions
# ============================================================================

dismiss_dialog() {
  local dev=$1
  local DUMP=$(adb -s $dev shell "uiautomator dump /sdcard/_dlg.xml >/dev/null 2>&1; cat /sdcard/_dlg.xml" 2>/dev/null)
  if echo "$DUMP" | grep -q 'content-desc="확인"'; then
    local OK_BOUNDS=$(echo "$DUMP" | grep -oE 'content-desc="확인"[^/]*bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1 | grep -oE 'bounds="\[[0-9,]+\]\[[0-9,]+\]"' | tr -dc '0-9,')
    local X1=$(echo "$OK_BOUNDS" | cut -d, -f1); local Y1=$(echo "$OK_BOUNDS" | cut -d, -f2)
    local X2=$(echo "$OK_BOUNDS" | cut -d, -f3); local Y2=$(echo "$OK_BOUNDS" | cut -d, -f4)
    local CX=$(( (X1 + X2) / 2 )); local CY=$(( (Y1 + Y2) / 2 ))
    adb -s $dev shell input tap $CX $CY
    sleep 1
  fi
}

make_call() {
  local logf=$1
  local timeout_s=${2:-15}
  local mark=$(wc -l < "$logf" 2>/dev/null || echo 0)

  adb -s $FAMILY shell input tap $CALL_BTN_X $CALL_BTN_Y
  for i in $(seq 1 $((timeout_s * 2))); do
    sleep 0.5
    if tail -n +$mark "$logf" 2>/dev/null | grep -q "answer_received"; then
      sleep 1.5
      adb -s $SENIOR shell input tap $SENIOR_ACCEPT_X $SENIOR_ACCEPT_Y
      for j in {1..20}; do
        sleep 0.5
        if tail -n +$mark "$logf" 2>/dev/null | grep -q "senior_accepted_auto\|renegotiate_done"; then
          return 0
        fi
      done
      return 0
    fi
  done
  return 1
}

make_monitor() {
  local logf=$1
  local timeout_s=${2:-15}
  local mark=$(wc -l < "$logf" 2>/dev/null || echo 0)

  adb -s $FAMILY shell input tap $MONITOR_BTN_X $MONITOR_BTN_Y
  for i in $(seq 1 $((timeout_s * 2))); do
    sleep 0.5
    if tail -n +$mark "$logf" 2>/dev/null | grep -q "answer_received"; then
      return 0
    fi
  done
  return 1
}

end_active() {
  local mode=$1
  if [ "$mode" = "call" ]; then
    adb -s $FAMILY shell input tap $HANGUP_CALL_X $HANGUP_CALL_Y
  else
    adb -s $FAMILY shell input tap $HANGUP_MONITOR_X $HANGUP_MONITOR_Y
  fi
  sleep 2
}

# fail mode 지표 추출 (BufferPool count, ICE candidate count, gathering complete)
inspect_fail() {
  local logf=$1
  local since_mark=$2
  local recent=$(tail -n +$since_mark "$logf" 2>/dev/null)
  local buf=$(echo "$recent" | grep -c "BufferPool")
  local cand=$(echo "$recent" | grep -cE "candidate.*srflx|candidate.*host|candidate.*relay")
  local gather=$(echo "$recent" | grep -c "ICE gathering complete\|GatheringComplete")
  echo "BufferPool=$buf candidates=$cand gather_complete=$gather"
}

# 스크린샷 캡처 + 밝기 검사
# 사용: capture_and_check <label>
# 반환: 0 = OK, 1 = 검은 화면 의심, 2 = 캡처 실패
capture_and_check() {
  local label=$1
  local ts=$(date +%H%M%S)
  local png="$SCREENSHOT_DIR/${ts}_${label}.png"

  adb -s $FAMILY exec-out screencap -p > "$png" 2>/dev/null

  if [ ! -s "$png" ]; then
    echo "[SCRN] $label: 캡처 실패"
    return 2
  fi

  local result
  result=$(python "$BRIGHTNESS_PY" "$png" "$BLACK_THRESHOLD" 2>&1)
  local rc=$?
  echo "[SCRN] $label: $result → $png"

  return $rc
}

# ============================================================================
# 시작 — logcat capture, dialog dismiss
# ============================================================================

PID_F=$(adb -s $FAMILY shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR shell pidof com.seniorcare.senior | tr -d '\r')
echo "[REPRO] PID_F=$PID_F PID_S=$PID_S"
if [ -z "$PID_F" ] || [ -z "$PID_S" ]; then
  echo "[REPRO] ERROR: app not running"
  exit 1
fi

LOG_F="$LOG_DIR/family_a17.log"
LOG_S="$LOG_DIR/senior.log"
> "$LOG_F"; > "$LOG_S"

adb -s $FAMILY logcat -v time -T 0 --pid=$PID_F > "$LOG_F" 2>/dev/null &
LOGCAT_F_PID=$!
adb -s $SENIOR logcat -v time -T 0 --pid=$PID_S > "$LOG_S" 2>/dev/null &
LOGCAT_S_PID=$!
sleep 0.3

trap 'echo "[REPRO] cleanup"; adb -s '"$FAMILY"' shell svc wifi enable >/dev/null 2>&1; kill $LOGCAT_F_PID $LOGCAT_S_PID 2>/dev/null' EXIT

dismiss_dialog $FAMILY
sleep 2

echo "[REPRO] === SWEEP START (PHASES=$PHASES, CYCLES=$CYCLES) === $(date +%T.%3N)"

# ============================================================================
# Phase A — 반복 핸드오프 stress (모니터링)
# ============================================================================
if echo ",$PHASES," | grep -q ",A,"; then
  echo ""
  echo "[REPRO] ====== Phase A: 반복 핸드오프 stress (모니터링, $CYCLES cycles, off=5s on=5s) ======"
  MARK_A=$(wc -l < "$LOG_F")

  if make_monitor "$LOG_F" 15; then
    echo "[A] 모니터링 connected @ $(date +%T.%3N)"
    sleep 3

    A_OFF_S=${A_OFF_S:-5}
    A_ON_S=${A_ON_S:-12}
    for i in $(seq 1 $CYCLES); do
      echo "[A] cycle $i/$CYCLES: wifi off @ $(date +%T.%3N)"
      adb -s $FAMILY shell svc wifi disable
      sleep $A_OFF_S
      echo "[A] cycle $i/$CYCLES: wifi on @ $(date +%T.%3N)"
      adb -s $FAMILY shell svc wifi enable
      sleep $A_ON_S  # 안정화 (짧을수록 가혹한 stress)

      INDICATORS=$(inspect_fail "$LOG_F" $MARK_A)
      echo "[A]   $INDICATORS"

      capture_and_check "A_c${i}"
      SCRN_RC=$?
      if [ "$SCRN_RC" = "1" ] && [ "$EARLY_STOP" = "1" ]; then
        echo "[A] 검은 화면 의심 + EARLY_STOP=1 → 중단"
        EARLY_STOP_TRIGGERED=1
        break
      fi

      RECENT=$(tail -200 "$LOG_F")
      if echo "$RECENT" | grep -q "hangup:networkLost"; then
        echo "[A] networkLost 발생 — Phase A 조기 종결"
        break
      fi
    done

    sleep 5
    end_active "monitor"

    PHASE_A=$(tail -n +$MARK_A "$LOG_F")
    A_RESTORED=$(echo "$PHASE_A" | grep -c "ice_restored")
    A_LOST=$(echo "$PHASE_A" | grep -c "hangup:networkLost")
    echo "[A] RESULT: ice_restored=$A_RESTORED networkLost=$A_LOST"
  else
    echo "[A] ERROR: 모니터링 connect 실패"
  fi

  if [ "$EARLY_STOP_TRIGGERED" = "1" ]; then
    echo "[REPRO] === EARLY STOP after Phase A === 사용자 화면 확인 / wifi 직접 복귀"
    echo "Logs: $LOG_F / $LOG_S / Screenshots: $SCREENSHOT_DIR"
    exit 0
  fi
  sleep 3
fi

# ============================================================================
# Phase B — 영상통화 핸드오프 (5 cycles)
# ============================================================================
if echo ",$PHASES," | grep -q ",B,"; then
  echo ""
  echo "[REPRO] ====== Phase B: 영상통화 핸드오프 (5 cycles, IN_CALL → wifi off 7s) ======"

  for b_i in 1 2 3 4 5; do
    echo ""
    echo "[B] cycle $b_i/5 — 발신 @ $(date +%T.%3N)"
    MARK_B=$(wc -l < "$LOG_F")

    dismiss_dialog $FAMILY
    sleep 2

    if make_call "$LOG_F" 15; then
      echo "[B] cycle $b_i — IN_CALL @ $(date +%T.%3N)"
      sleep 10
      capture_and_check "B_c${b_i}_pre"

      echo "[B] cycle $b_i — wifi off @ $(date +%T.%3N)"
      adb -s $FAMILY shell svc wifi disable
      sleep 7
      echo "[B] cycle $b_i — wifi on @ $(date +%T.%3N)"
      adb -s $FAMILY shell svc wifi enable
      sleep 18  # 안정화 — reconnecting overlay 사라지고 frame 흐를 시간

      capture_and_check "B_c${b_i}_post"
      SCRN_RC=$?

      INDICATORS=$(inspect_fail "$LOG_F" $MARK_B)
      PHASE_B=$(tail -n +$MARK_B "$LOG_F")
      B_RESTORED=$(echo "$PHASE_B" | grep -c "ice_restored")
      B_LOST=$(echo "$PHASE_B" | grep -c "hangup:networkLost")
      echo "[B] cycle $b_i RESULT: ice_restored=$B_RESTORED networkLost=$B_LOST $INDICATORS"

      if [ "$SCRN_RC" = "1" ] && [ "$EARLY_STOP" = "1" ]; then
        echo "[B] 검은 화면 의심 + EARLY_STOP=1 → 중단 (사용자 화면 확인)"
        EARLY_STOP_TRIGGERED=1
        break
      fi

      end_active "call"
      sleep 3
    else
      echo "[B] cycle $b_i — call connect 실패"
      end_active "call"
      sleep 3
    fi
  done

  if [ "$EARLY_STOP_TRIGGERED" = "1" ]; then
    echo "[REPRO] === EARLY STOP after Phase B === 사용자 화면 확인"
    echo "Logs: $LOG_F / $LOG_S / Screenshots: $SCREENSHOT_DIR"
    exit 0
  fi
fi

# ============================================================================
# Phase C — cellular only 재발신 반복 (이전 fail mode 와 가장 비슷)
# ============================================================================
if echo ",$PHASES," | grep -q ",C,"; then
  echo ""
  echo "[REPRO] ====== Phase C: cellular only 재발신 반복 ($CYCLES cycles) ======"

  echo "[C] wifi off (cellular only 진입) @ $(date +%T.%3N)"
  adb -s $FAMILY shell svc wifi disable
  sleep 5

  C_SUCCESS=0; C_BUFFER_ZERO=0; C_FAIL=0
  for c_i in $(seq 1 $CYCLES); do
    echo ""
    echo "[C] cycle $c_i/$CYCLES — 발신 @ $(date +%T.%3N)"
    MARK_C=$(wc -l < "$LOG_F")

    dismiss_dialog $FAMILY
    sleep 1

    if make_call "$LOG_F" 15; then
      sleep 8  # IN_CALL 안정화 (frame 흐르기 시작 시간)

      capture_and_check "C_c${c_i}"
      SCRN_RC=$?

      INDICATORS=$(inspect_fail "$LOG_F" $MARK_C)
      BUF_COUNT=$(echo "$INDICATORS" | grep -oE "BufferPool=[0-9]+" | cut -d= -f2)
      echo "[C] cycle $c_i — IN_CALL — $INDICATORS"

      C_BLACK_FLAG=0
      if [ "$SCRN_RC" = "1" ]; then
        echo "[C] cycle $c_i — ⚠ 검은 화면 감지 (밝기 검사)"
        C_BUFFER_ZERO=$((C_BUFFER_ZERO + 1))
        C_BLACK_FLAG=1
      elif [ -n "$BUF_COUNT" ] && [ "$BUF_COUNT" -eq 0 ] 2>/dev/null; then
        echo "[C] cycle $c_i — ⚠ FAIL MODE 의심 (BufferPool=0)"
        C_BUFFER_ZERO=$((C_BUFFER_ZERO + 1))
        C_BLACK_FLAG=1
      else
        C_SUCCESS=$((C_SUCCESS + 1))
      fi

      if [ "$C_BLACK_FLAG" = "1" ] && [ "$EARLY_STOP" = "1" ]; then
        echo "[C] EARLY_STOP=1 → Phase C 중단 (통화 유지된 상태로 — 사용자 화면 확인)"
        EARLY_STOP_TRIGGERED=1
        break
      fi

      end_active "call"
      sleep 3
    else
      echo "[C] cycle $c_i — connect 실패"
      C_FAIL=$((C_FAIL + 1))
      end_active "call"
      sleep 3
    fi
  done

  echo ""
  echo "[C] RESULT: success=$C_SUCCESS black_or_buffer_zero=$C_BUFFER_ZERO connect_fail=$C_FAIL"

  if [ "$EARLY_STOP_TRIGGERED" = "1" ]; then
    echo ""
    echo "[REPRO] === EARLY STOP === $(date +%T.%3N)"
    echo "통화 살아있는 상태로 중단됨. 사용자가 화면 확인하세요."
    echo "wifi 는 자동 복귀 안 함 (cellular 상태 유지). 끝나면 직접 wifi enable 해주세요."
    echo "Logs: $LOG_F / $LOG_S"
    echo "Screenshots: $SCREENSHOT_DIR"
    exit 0
  fi

  echo "[C] wifi on @ $(date +%T.%3N)"
  adb -s $FAMILY shell svc wifi enable
  sleep 10
fi

# ============================================================================
# Phase D — 긴 cellular 유지
# ============================================================================
if echo ",$PHASES," | grep -q ",D,"; then
  echo ""
  echo "[REPRO] ====== Phase D: 긴 cellular 유지 (70s wifi off → cellular only 신규 발신) ======"

  MARK_D=$(wc -l < "$LOG_F")
  dismiss_dialog $FAMILY
  sleep 2

  if make_monitor "$LOG_F" 15; then
    echo "[D] 모니터링 connected — wifi off 70s @ $(date +%T.%3N)"
    sleep 3
    adb -s $FAMILY shell svc wifi disable
    sleep 70

    PHASE_D=$(tail -n +$MARK_D "$LOG_F")
    D_LOST=$(echo "$PHASE_D" | grep -c "hangup:networkLost")
    echo "[D] 70s 단절 후 networkLost=$D_LOST"

    end_active "monitor"
    sleep 3
    dismiss_dialog $FAMILY
    sleep 2

    # cellular only 상태에서 신규 발신
    echo "[D] cellular only 신규 monitor 발신 @ $(date +%T.%3N)"
    MARK_D2=$(wc -l < "$LOG_F")
    if make_monitor "$LOG_F" 15; then
      echo "[D] cellular only — 모니터링 connected ✓"
      sleep 5
      capture_and_check "D_cellular"
      INDICATORS=$(inspect_fail "$LOG_F" $MARK_D2)
      echo "[D]   $INDICATORS"
      end_active "monitor"
    else
      echo "[D] cellular only — 모니터링 connect 실패 ⚠"
      end_active "monitor"
    fi

    sleep 3
    echo "[D] wifi on @ $(date +%T.%3N)"
    adb -s $FAMILY shell svc wifi enable
    sleep 10
  else
    echo "[D] ERROR: 모니터링 connect 실패"
  fi
fi

# ============================================================================
# Phase E — RTDB ended 지연 측정
# ============================================================================
if echo ",$PHASES," | grep -q ",E,"; then
  echo ""
  echo "[REPRO] ====== Phase E: RTDB ended 지연 측정 (wifi vs cellular, 각 3 cycles) ======"

  # wifi baseline
  echo "[E] wifi mode baseline"
  adb -s $FAMILY shell svc wifi enable >/dev/null 2>&1
  sleep 10
  for e_i in 1 2 3; do
    dismiss_dialog $FAMILY
    sleep 2
    if make_call "$LOG_F" 15; then
      sleep 5
      T_HANGUP=$(date +%T.%3N)
      echo "[E] wifi $e_i — hangup tap @ $T_HANGUP"
      end_active "call"
      sleep 5
    else
      echo "[E] wifi $e_i — connect 실패"
      end_active "call"
      sleep 3
    fi
  done

  # cellular
  echo "[E] cellular mode"
  adb -s $FAMILY shell svc wifi disable
  sleep 5
  for e_i in 1 2 3; do
    dismiss_dialog $FAMILY
    sleep 2
    if make_call "$LOG_F" 15; then
      sleep 5
      T_HANGUP=$(date +%T.%3N)
      echo "[E] cellular $e_i — hangup tap @ $T_HANGUP"
      end_active "call"
      sleep 5
    else
      echo "[E] cellular $e_i — connect 실패"
      end_active "call"
      sleep 3
    fi
  done

  echo "[E] wifi 복귀"
  adb -s $FAMILY shell svc wifi enable
  sleep 10

  echo "[E] 분석 — 다음 grep 으로 timestamp 추출:"
  echo "  Family hangup → write 완료:"
  echo "    grep -E 'hangUp\\(reason|status=ended write|시그널링.*ended' $LOG_F"
  echo "  Senior ended 수신:"
  echo "    grep -E '상대방 종료 감지|listenForStatus.*ended|status=ended' $LOG_S"
fi

# ============================================================================
# 최종 cleanup
# ============================================================================
adb -s $FAMILY shell svc wifi enable >/dev/null 2>&1
sleep 2

echo ""
echo "[REPRO] === SWEEP DONE === $(date +%T.%3N)"
echo "Logs:"
echo "  $LOG_F"
echo "  $LOG_S"
echo ""
echo "fail mode 감지 grep:"
echo "  grep -E 'BufferPool|networkLost|ice_restored|GatheringComplete|candidate.*srflx' $LOG_F"
echo ""
echo "검은 화면 의심 시:"
echo "  - BufferPool count 가 0 또는 낮은 cycle 찾기"
echo "  - ICE candidate 개수 cycle 별 변화 추적"
echo "  - 사용자 화면 캡처 (검은 화면 vs 정상 화면 구분)"
