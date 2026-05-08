#!/bin/bash
# S17 Sweep — Senior wifi off + Family 2대 (S4_5 multi-device 버전)
#
# s17_auto.sh 호출. timing 변주로 Senior wifi flap 시 두 Family 의 대칭 처리 검증.
#
# 사전 조건:
#   - Family A (R3CR700SEKP) + Family C (RFKYA00Y49L) FamilyDetailScreen
#
# 환경 변수:
#   DURATIONS    공백 구분 timing 목록 (기본 "1 2 3 4 5 6 15 70")
#   BETWEEN_S    사이클 간 대기 (기본 15s)
#
# 사용법:
#   bash scripts/s17_sweep.sh                              # 기본 8 stages
#   DURATIONS="1 4 6" bash scripts/s17_sweep.sh            # 핵심 timing

set +e

trap 'echo "[SWEEP] cleanup: Senior Wi-Fi enable"; adb -s KEP2024120921 shell svc wifi enable >/dev/null 2>&1' EXIT

DURATIONS=${DURATIONS:-"1 2 3 4 5 6 15 70"}
BETWEEN_S=${BETWEEN_S:-15}

LOG_DIR=e:/tmp/s17_auto
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/sweep_summary.log"
> "$SUMMARY"

echo "==== S17 SWEEP START (Senior wifi flap, multi-device) ====" | tee -a "$SUMMARY"
echo "DURATIONS: $DURATIONS" | tee -a "$SUMMARY"
echo "시작 시각: $(date +%T)" | tee -a "$SUMMARY"

LAST_D=""
for d in $DURATIONS; do LAST_D=$d; done

RESULTS=()

for d in $DURATIONS; do
  echo "" | tee -a "$SUMMARY"
  echo "─── Senior wifi off ${d}s + Family 2대 ───" | tee -a "$SUMMARY"

  if [ $d -ge 60 ]; then
    OBS=90
  elif [ $d -ge 15 ]; then
    OBS=40
  else
    OBS=25
  fi

  CYCLE_OUT=$(SENIOR_OFF_S=$d OBSERVE_S=$OBS bash e:/App/Family/scripts/s17_auto.sh 2>&1)
  echo "$CYCLE_OUT" | grep -E "ice_restored|networkLost|✅|⚠" | tee -a "$SUMMARY"

  CLASS=$(echo "$CYCLE_OUT" | grep -oE '\[S17\] (✅|⚠) .*' | tail -1)
  RESULTS+=("${d}s: $CLASS")

  if [ "$d" != "$LAST_D" ]; then
    echo "[SWEEP] 사이클 간 ${BETWEEN_S}s 대기..." | tee -a "$SUMMARY"
    sleep $BETWEEN_S
  fi
done

echo "" | tee -a "$SUMMARY"
echo "==== S17 SWEEP 완료 ====" | tee -a "$SUMMARY"
echo "종료 시각: $(date +%T)" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"
echo "결과 요약:" | tee -a "$SUMMARY"
for r in "${RESULTS[@]}"; do
  echo "  $r" | tee -a "$SUMMARY"
done
echo "" | tee -a "$SUMMARY"
echo "Summary: $SUMMARY"
