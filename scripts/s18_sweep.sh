#!/bin/bash
# S18 Sweep — A grace 중 B 신규 합류 race (timing 변주)
#
# s18_auto.sh 호출. JOIN_DELAY_S 변주로 grace 4s 의 다양한 시점에서 B 합류 검증.
#
# timing 매트릭스:
#   - 1s: grace 시작 직후 (A reconnect 처리 시작 + B 합류)
#   - 2s, 2.5s, 3s, 3.5s: grace 만료 직전 (A ICE restart 임박 + B 합류)
#   - 5s: grace 만료 후 (A ICE restart 진행 중 + B 합류)
#   - 7s: A networkLost 종결 후 (B 만 단독 합류)
#
# 사전 조건:
#   - Family A R3CR700SEKP + Family B RFKYA00Y49L family detail
#
# 환경 변수:
#   DELAYS       공백 구분 timing 목록 (기본 "1 2 2.5 3 3.5 5 7")
#   A_OFF_S      A wifi off 유지 시간 (기본 8 — grace + ICE restart 1회 시도 + 종결)
#   BETWEEN_S    사이클 간 대기 (기본 15)
#
# 사용법:
#   bash scripts/s18_sweep.sh                              # 기본 7 stages
#   DELAYS="2 3 5" bash scripts/s18_sweep.sh               # 핵심 timing 만

set +e

trap 'echo "[SWEEP] cleanup: A Wi-Fi enable"; adb -s R3CR700SEKP shell svc wifi enable >/dev/null 2>&1' EXIT

DELAYS=${DELAYS:-"1 2 2.5 3 3.5 5 7"}
A_OFF_S=${A_OFF_S:-8}
BETWEEN_S=${BETWEEN_S:-15}

LOG_DIR=e:/tmp/s18_auto
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/sweep_summary.log"
> "$SUMMARY"

echo "==== S18 SWEEP START (A grace 중 B 합류, timing 변주) ====" | tee -a "$SUMMARY"
echo "DELAYS: $DELAYS" | tee -a "$SUMMARY"
echo "A_OFF_S: $A_OFF_S" | tee -a "$SUMMARY"
echo "시작 시각: $(date +%T)" | tee -a "$SUMMARY"

LAST_D=""
for d in $DELAYS; do LAST_D=$d; done

RESULTS=()

for d in $DELAYS; do
  echo "" | tee -a "$SUMMARY"
  echo "─── JOIN_DELAY ${d}s + A_OFF ${A_OFF_S}s ───" | tee -a "$SUMMARY"

  CYCLE_OUT=$(JOIN_DELAY_S=$d A_OFF_S=$A_OFF_S OBSERVE_S=25 bash e:/App/Family/scripts/s18_auto.sh 2>&1)
  echo "$CYCLE_OUT" | grep -E "Family A:|Family B:|✅|⚠" | tee -a "$SUMMARY"

  CLASS=$(echo "$CYCLE_OUT" | grep -oE '\[S18\] (✅|⚠) .*' | tail -1)
  RESULTS+=("delay=${d}s: $CLASS")

  if [ "$d" != "$LAST_D" ]; then
    echo "[SWEEP] 사이클 간 ${BETWEEN_S}s 대기..." | tee -a "$SUMMARY"
    sleep $BETWEEN_S
  fi
done

echo "" | tee -a "$SUMMARY"
echo "==== S18 SWEEP 완료 ====" | tee -a "$SUMMARY"
echo "종료 시각: $(date +%T)" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"
echo "결과 요약:" | tee -a "$SUMMARY"
for r in "${RESULTS[@]}"; do
  echo "  $r" | tee -a "$SUMMARY"
done
echo "" | tee -a "$SUMMARY"
echo "Summary: $SUMMARY"
