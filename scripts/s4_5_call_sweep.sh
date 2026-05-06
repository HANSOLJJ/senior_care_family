#!/bin/bash
# S4~S5 [영상통화] sweep — 양방향 영상통화 진행 중 Senior Wi-Fi flap
#
# s4_5_auto.sh 를 CALL_TYPE=call + STABILIZE_S=30 로 호출.
# 30초 안정화로 senior_accepted_auto + upgrade renegotiate 완료 후 Senior wifi off.
#
# 사전 조건:
#   - Senior CallActivity 자동수락 (얼굴인식) 활성
#   - Senior STREAM_VOICE_CALL mute
#
# 환경 변수:
#   DURATIONS    공백 구분 timing 목록 (기본 "1 2 3 4 5 6 15 70")
#   BETWEEN_S    사이클 간 대기 (기본 15s)
#   STABILIZE_S  안정화 시간 (기본 30)
#
# 사용법:
#   bash scripts/s4_5_call_sweep.sh
#   DURATIONS="3 6 15" bash scripts/s4_5_call_sweep.sh

set +e

# Family 영상통화 음성 mute
FAMILY_DEVICE=R3CR700SEKP
ORIG_VOL=$(adb -s $FAMILY_DEVICE shell media volume --stream 0 --get 2>/dev/null | grep -oE '[0-9]+' | tail -1)
echo "[SWEEP] Family STREAM_VOICE_CALL 원래 음량 = ${ORIG_VOL:-(unknown)}, mute 처리"
adb -s $FAMILY_DEVICE shell media volume --stream 0 --set 0 >/dev/null 2>&1

trap 'echo "[SWEEP] cleanup: Senior Wi-Fi enable + Family 음량 복원"; adb -s KEP2024120921 shell svc wifi enable >/dev/null 2>&1; adb -s R3CR700SEKP shell media volume --stream 0 --set ${ORIG_VOL:-5} >/dev/null 2>&1' EXIT

DURATIONS=${DURATIONS:-"1 2 3 4 5 6 15 70"}
BETWEEN_S=${BETWEEN_S:-15}
STABILIZE_S=${STABILIZE_S:-30}

LOG_DIR=e:/tmp/s4_5_call_auto
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/sweep_summary.log"
> "$SUMMARY"

echo "==== S4~S5 [영상통화] SWEEP START ====" | tee -a "$SUMMARY"
echo "DURATIONS: $DURATIONS" | tee -a "$SUMMARY"
echo "STABILIZE_S: $STABILIZE_S" | tee -a "$SUMMARY"
echo "시작 시각: $(date +%T)" | tee -a "$SUMMARY"

LAST_D=""
for d in $DURATIONS; do LAST_D=$d; done

RESULTS=()

for d in $DURATIONS; do
  echo "" | tee -a "$SUMMARY"
  echo "─── 영상통화 (양방향) + Senior Wi-Fi off ${d}s ───" | tee -a "$SUMMARY"

  if [ $d -ge 60 ]; then
    OBS=90
  elif [ $d -ge 15 ]; then
    OBS=40
  else
    OBS=25
  fi

  CYCLE_OUT=$(CALL_TYPE=call STABILIZE_S=$STABILIZE_S SENIOR_OFF_S=$d OBSERVE_S=$OBS bash e:/App/Family/scripts/s4_5_auto.sh 2>&1)
  echo "$CYCLE_OUT" | grep -E "Family 측 카운트:|PC DISCONNECTED:|PC CONNECTED:|ICE restart attempt:|ice_restart_start:|ice_restored:|종결 사유:|✅|⚠" | tee -a "$SUMMARY"

  CLASS=$(echo "$CYCLE_OUT" | grep -oE '\[S(4_5|16)\] [✅⚠] .*' | tail -1)
  RESULTS+=("${d}s: $CLASS")

  cp "e:/tmp/s4_5_auto/family_${d}s.log" "$LOG_DIR/family_${d}s.log" 2>/dev/null
  cp "e:/tmp/s4_5_auto/senior_${d}s.log" "$LOG_DIR/senior_${d}s.log" 2>/dev/null

  if [ "$d" != "$LAST_D" ]; then
    echo "[SWEEP] 사이클 간 ${BETWEEN_S}s 대기..." | tee -a "$SUMMARY"
    sleep $BETWEEN_S
  fi
done

echo "" | tee -a "$SUMMARY"
echo "==== S4~S5 [영상통화] SWEEP 완료 ====" | tee -a "$SUMMARY"
echo "종료 시각: $(date +%T)" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"
echo "결과 요약:" | tee -a "$SUMMARY"
for r in "${RESULTS[@]}"; do
  echo "  $r" | tee -a "$SUMMARY"
done
echo "" | tee -a "$SUMMARY"
echo "Summary: $SUMMARY"
