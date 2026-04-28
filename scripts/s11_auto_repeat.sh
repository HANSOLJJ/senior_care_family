#!/bin/bash
# S11 반복 자동 테스트 — 같은 timing 으로 N회 반복하여 안정성/회귀 검증
#
# 환경 변수:
#   REPEAT             반복 횟수 (기본 5)
#   WIFI_OFF_DELAY_MS  s11_auto.sh 에 그대로 전달 (기본 800 = Bug #1-B)
#   OBSERVE_S          s11_auto.sh 에 그대로 전달 (기본 30)
#   BETWEEN_S          사이클 간 대기 (기본 8s — 다이얼로그 표시 + 안정화 시간)
#
# 사용법:
#   bash scripts/s11_auto_repeat.sh                                    # 5회 Bug #1-B
#   REPEAT=3 WIFI_OFF_DELAY_MS=1700 OBSERVE_S=80 bash scripts/s11_auto_repeat.sh   # 3회 S11 변형
#
# 결과:
#   $LOG_DIR/repeat_summary.log 에 cycle 별 결과 분류 누적

set +e
trap 'adb -s R3CR700SEKP shell svc wifi enable >/dev/null 2>&1' EXIT

REPEAT=${REPEAT:-5}
WIFI_OFF_DELAY_MS=${WIFI_OFF_DELAY_MS:-800}
OBSERVE_S=${OBSERVE_S:-30}
BETWEEN_S=${BETWEEN_S:-8}

LOG_DIR=e:/tmp/s11_auto
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/repeat_summary_${WIFI_OFF_DELAY_MS}ms.log"
> "$SUMMARY"

echo "==== S11 REPEAT START (n=$REPEAT, delay=${WIFI_OFF_DELAY_MS}ms, observe=${OBSERVE_S}s) ====" | tee -a "$SUMMARY"
echo "시작 시각: $(date +%T)" | tee -a "$SUMMARY"

PASS=0
FAIL=0
CLASSIFY=()

for cycle in $(seq 1 $REPEAT); do
  echo "" | tee -a "$SUMMARY"
  echo "─── CYCLE $cycle / $REPEAT ───" | tee -a "$SUMMARY"

  CYCLE_OUT=$(WIFI_OFF_DELAY_MS=$WIFI_OFF_DELAY_MS OBSERVE_S=$OBSERVE_S bash e:/App/Family/scripts/s11_auto.sh 2>&1)
  echo "$CYCLE_OUT" | tail -10 | tee -a "$SUMMARY"

  # 결과 분류 추출
  CLASS=$(echo "$CYCLE_OUT" | grep -oE '\[S11\] [✅⚠] .*' | tail -1)
  CLASSIFY+=("Cycle $cycle: $CLASS")

  if echo "$CYCLE_OUT" | grep -q "✅"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi

  # 사이클 간 대기 (다이얼로그 자동 dismiss 는 다음 s11_auto.sh 시작 시 처리됨)
  if [ $cycle -lt $REPEAT ]; then
    echo "[REPEAT] 사이클 간 ${BETWEEN_S}s 대기..." | tee -a "$SUMMARY"
    sleep $BETWEEN_S
  fi
done

echo "" | tee -a "$SUMMARY"
echo "==== S11 REPEAT 완료 ====" | tee -a "$SUMMARY"
echo "종료 시각: $(date +%T)" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"
echo "결과: PASS=$PASS / FAIL=$FAIL (총 $REPEAT)" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"
echo "사이클별 분류:" | tee -a "$SUMMARY"
for c in "${CLASSIFY[@]}"; do
  echo "  $c" | tee -a "$SUMMARY"
done
echo "" | tee -a "$SUMMARY"
echo "Summary: $SUMMARY"
