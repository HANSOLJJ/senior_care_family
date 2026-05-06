#!/bin/bash
# S16 Sweep — Senior Wi-Fi 단절 다양한 timing 으로 race window 매핑
#
# Default DURATIONS: 1 2 3 4 5 6 15 70 (총 8 stages)
#   1~3s: PC ICE keepalive 미발화 가능성 (PC 정상 유지)
#   4s:   PC DISCONNECTED 감지 시점 근처 (grace 4s 시작)
#   5s:   grace 진행 중 복구
#   6s:   grace 만료 직전/직후 (S2 대칭)
#   15s:  ICE restart 1~2회 시도 후 복구 (S2 변형)
#   70s:  flap window 60s 초과 → iceFailed (S4 대칭)
#
# 환경 변수:
#   DURATIONS    공백 구분 timing 목록 (기본 "1 2 3 4 5 6 15 70")
#   BETWEEN_S    사이클 간 대기 (기본 10s — 모니터링 정리 + 다이얼로그 dismiss)
#
# 사용법:
#   bash scripts/s4_5_sweep.sh                                # 기본 8 stages
#   DURATIONS="3 6 15" bash scripts/s4_5_sweep.sh             # 3개만

set +e
trap 'echo "[SWEEP] cleanup: Senior Wi-Fi enable"; adb -s KEP2024120921 shell svc wifi enable >/dev/null 2>&1' EXIT

DURATIONS=${DURATIONS:-"1 2 3 4 5 6 15 70"}
BETWEEN_S=${BETWEEN_S:-10}

LOG_DIR=e:/tmp/s4_5_auto
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/sweep_summary.log"
> "$SUMMARY"

echo "==== S16 SWEEP START ====" | tee -a "$SUMMARY"
echo "DURATIONS: $DURATIONS" | tee -a "$SUMMARY"
echo "시작 시각: $(date +%T)" | tee -a "$SUMMARY"

# 마지막 duration 식별 (사이클 간 대기 skip 용)
LAST_D=""
for d in $DURATIONS; do LAST_D=$d; done

RESULTS=()

for d in $DURATIONS; do
  echo "" | tee -a "$SUMMARY"
  echo "─── Senior Wi-Fi off ${d}s ───" | tee -a "$SUMMARY"

  # 70s+ 케이스는 OBSERVE 길게
  if [ $d -ge 60 ]; then
    OBS=90
  elif [ $d -ge 15 ]; then
    OBS=40
  else
    OBS=25
  fi

  CYCLE_OUT=$(SENIOR_OFF_S=$d OBSERVE_S=$OBS bash e:/App/Family/scripts/s4_5_auto.sh 2>&1)
  echo "$CYCLE_OUT" | grep -E "Family 측 카운트:|PC DISCONNECTED:|PC CONNECTED:|ICE restart attempt:|ice_restart_start:|ice_restored:|종결 사유:|✅|⚠" | tee -a "$SUMMARY"

  CLASS=$(echo "$CYCLE_OUT" | grep -oE '\[S16\] [✅⚠] .*' | tail -1)
  RESULTS+=("${d}s: $CLASS")

  if [ "$d" != "$LAST_D" ]; then
    echo "[SWEEP] 사이클 간 ${BETWEEN_S}s 대기..." | tee -a "$SUMMARY"
    sleep $BETWEEN_S
  fi
done

echo "" | tee -a "$SUMMARY"
echo "==== S16 SWEEP 완료 ====" | tee -a "$SUMMARY"
echo "종료 시각: $(date +%T)" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"
echo "결과 요약:" | tee -a "$SUMMARY"
for r in "${RESULTS[@]}"; do
  echo "  $r" | tee -a "$SUMMARY"
done
echo "" | tee -a "$SUMMARY"
echo "Summary: $SUMMARY"
