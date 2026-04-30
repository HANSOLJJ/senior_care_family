#!/bin/bash
# S2 Sweep — Family Wi-Fi 단절 다양한 timing 으로 plan A 검증
#
# Default DURATIONS: 1 2 3 4 5 6 15 70 (총 8 stages, S16 sweep 대칭)
#   1~3s:  PC connectionState DISCONNECTED 안 갈 수 있음. 자기 familyDisconnect 마커 받지만
#          PC CONNECTED 라 무시 → 통화 유지 (plan A 의 핵심 효과)
#   4s:    PC DISCONNECTED 시점 근처 (grace 4s 시작)
#   5s:    grace 진행 중 복구 (Senior STOP_DELAY 7s 안)
#   6s:    grace 만료 직전 — ICE restart 1회 시도 → Senior 가 받음 → 복구
#   15s:   Senior STOP_DELAY 7s 만료 후 stopPeer → Family networkLost 종결
#   70s:   영구 끊김 — Family ICE restart 시도해도 도달 못 함 → networkLost
#
# 환경 변수:
#   DURATIONS    공백 구분 timing 목록 (기본 "1 2 3 4 5 6 15 70")
#   BETWEEN_S    사이클 간 대기 (기본 10s — SnackBar dismiss + Senior 정리)
#
# 사용법:
#   bash scripts/s2_auto_sweep.sh                                 # 기본 8 stages
#   DURATIONS="1 3 6 15" bash scripts/s2_auto_sweep.sh            # 4개만

set +e
trap 'echo "[SWEEP] cleanup: Family Wi-Fi enable"; adb -s R3CR700SEKP shell svc wifi enable >/dev/null 2>&1' EXIT

DURATIONS=${DURATIONS:-"1 2 3 4 5 6 15 70"}
BETWEEN_S=${BETWEEN_S:-10}

LOG_DIR=e:/tmp/s2_auto
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/sweep_summary.log"
> "$SUMMARY"

echo "==== S2 SWEEP START (Family Wi-Fi flap, plan A) ====" | tee -a "$SUMMARY"
echo "DURATIONS: $DURATIONS" | tee -a "$SUMMARY"
echo "시작 시각: $(date +%T)" | tee -a "$SUMMARY"

# 마지막 duration 식별 (사이클 간 대기 skip 용)
LAST_D=""
for d in $DURATIONS; do LAST_D=$d; done

RESULTS=()

for d in $DURATIONS; do
  echo "" | tee -a "$SUMMARY"
  echo "─── Family Wi-Fi off ${d}s ───" | tee -a "$SUMMARY"

  # 70s+ 케이스는 OBSERVE 길게
  if [ $d -ge 60 ]; then
    OBS=90
  elif [ $d -ge 15 ]; then
    OBS=40
  else
    OBS=25
  fi

  CYCLE_OUT=$(FAMILY_OFF_S=$d OBSERVE_S=$OBS bash e:/App/Family/scripts/s2_auto.sh 2>&1)
  echo "$CYCLE_OUT" | grep -E "Family 측 카운트:|Senior 측 카운트:|PC DISCONNECTED:|PC CONNECTED:|ICE restart 1회 시도|ice_restored:|자기 마커|familyDisconnect grace|ICE restart 수신|sticky 차단|STOP_DELAY|종결 사유:|✅|⚠" | tee -a "$SUMMARY"

  CLASS=$(echo "$CYCLE_OUT" | grep -oE '\[S2\] [✅⚠] .*' | tail -1)
  RESULTS+=("${d}s: $CLASS")

  if [ "$d" != "$LAST_D" ]; then
    echo "[SWEEP] 사이클 간 ${BETWEEN_S}s 대기..." | tee -a "$SUMMARY"
    sleep $BETWEEN_S
  fi
done

echo "" | tee -a "$SUMMARY"
echo "==== S2 SWEEP 완료 ====" | tee -a "$SUMMARY"
echo "종료 시각: $(date +%T)" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"
echo "결과 요약:" | tee -a "$SUMMARY"
for r in "${RESULTS[@]}"; do
  echo "  $r" | tee -a "$SUMMARY"
done
echo "" | tee -a "$SUMMARY"
echo "Summary: $SUMMARY"
