#!/bin/bash
# S6 Sweep — 모니터링 → 영상통화 upgrade 도중 Family Wi-Fi flap
#
# s6_auto.sh 호출. WIFI_OFF_DELAY_MS 별로 다른 race window 검증:
#   500ms    탭 직후 — requestUpgrade .once() 진입 직전 (Bug #5 영역)
#   1000ms   writeOrTimeout 3s 만료 영역 (Bug #1-B)
#   1700ms   renegotiation 진행 도중 (S6 핵심)
#   3500ms   IN_CALL 진입 후 ICE failure (S2 변형)
#
# 사전 조건:
#   - Family 앱이 FamilyDetailScreen (모니터링/영상통화 버튼 보임)
#   - Senior 자동수락 켜짐 (얼굴 감지) 또는 face 감지 가능 위치
#   - Family STREAM_VOICE_CALL 음량 mute
#
# 환경 변수:
#   DURATIONS    공백 구분 WIFI_OFF_DELAY_MS 목록 (기본 "500 1000 1700 3500")
#   OBSERVE_S    각 사이클 wifi off 후 관찰 시간 (기본 20)
#   BETWEEN_S    사이클 간 대기 (기본 15s — 종료 다이얼로그 dismiss + 재시작 안정화)
#
# 사용법:
#   bash scripts/s6_sweep.sh                                  # 기본 4 stages
#   DURATIONS="1700" bash scripts/s6_sweep.sh                 # 핵심만
#   OBSERVE_S=8 BETWEEN_S=20 bash scripts/s6_sweep.sh         # 짧게 + 재진입 여유

set +e

FAMILY_DEVICE=R3CR700SEKP
ORIG_VOL=$(adb -s $FAMILY_DEVICE shell media volume --stream 0 --get 2>/dev/null | grep -oE '[0-9]+' | tail -1)
echo "[SWEEP] Family STREAM_VOICE_CALL 원래 음량 = ${ORIG_VOL:-(unknown)}, mute 처리"
adb -s $FAMILY_DEVICE shell media volume --stream 0 --set 0 >/dev/null 2>&1

trap 'echo "[SWEEP] cleanup: Family Wi-Fi enable + 음량 복원"; adb -s R3CR700SEKP shell svc wifi enable >/dev/null 2>&1; adb -s R3CR700SEKP shell media volume --stream 0 --set ${ORIG_VOL:-5} >/dev/null 2>&1' EXIT

DURATIONS=${DURATIONS:-"500 1000 1700 3500"}
OBSERVE_S=${OBSERVE_S:-20}
BETWEEN_S=${BETWEEN_S:-15}

LOG_DIR=e:/tmp/s6_auto
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/sweep_summary.log"
> "$SUMMARY"

echo "==== S6 SWEEP START (모니터링 → 영상통화 upgrade + Wi-Fi flap) ====" | tee -a "$SUMMARY"
echo "DURATIONS: $DURATIONS (ms)" | tee -a "$SUMMARY"
echo "OBSERVE_S: $OBSERVE_S, BETWEEN_S: $BETWEEN_S" | tee -a "$SUMMARY"
echo "시작 시각: $(date +%T)" | tee -a "$SUMMARY"

LAST_D=""
for d in $DURATIONS; do LAST_D=$d; done

RESULTS=()

for d in $DURATIONS; do
  echo "" | tee -a "$SUMMARY"
  echo "─── upgrade 탭 후 +${d}ms wifi off ───" | tee -a "$SUMMARY"

  CYCLE_OUT=$(WIFI_OFF_DELAY_MS=$d OBSERVE_S=$OBSERVE_S bash e:/App/Family/scripts/s6_auto.sh 2>&1)
  echo "$CYCLE_OUT" | grep -E "FSM|hangup|upgradeFailed|ice_restored|renegotiate_done|hasFlapMarker self-clear|✅|⚠" | tee -a "$SUMMARY"

  CLASS=$(echo "$CYCLE_OUT" | grep -oE '\[S6\] (✅|⚠) .*' | tail -1)
  RESULTS+=("${d}ms: $CLASS")

  if [ "$d" != "$LAST_D" ]; then
    echo "[SWEEP] 사이클 간 ${BETWEEN_S}s 대기..." | tee -a "$SUMMARY"
    sleep $BETWEEN_S
  fi
done

echo "" | tee -a "$SUMMARY"
echo "==== S6 SWEEP 완료 ====" | tee -a "$SUMMARY"
echo "종료 시각: $(date +%T)" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"
echo "결과 요약:" | tee -a "$SUMMARY"
for r in "${RESULTS[@]}"; do
  echo "  $r" | tee -a "$SUMMARY"
done
echo "" | tee -a "$SUMMARY"
echo "Summary: $SUMMARY"
