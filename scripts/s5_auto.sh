#!/bin/bash
# S5 자동 테스트 — flap window 60초 초과 (반복 disconnect)
#
# Wi-Fi 6s off / 6s on 사이클을 연속 반복하여 `_flapWindowStart` 기준
# 60초 상한 도달 → `iceFailed` 종결을 재현한다.
#
# 수동 실행의 한계:
#   사이클 수가 부족하거나 중간에 Wi-Fi on 오래 유지되면 Senior STOP_DELAY(15s)
#   만료로 Senior 가 자체 종결 → Family 는 혼자 5회 한도 경로로 귀결 (iceFailed 는
#   맞지만 원래 시나리오 의도인 flap window 검증이 아님). 자동화로만 재현 가능.
#
# 사전조건:
#   1. Family 앱이 MonitoringScreen 에서 CONNECTED 상태
#   2. Senior 앱 실행 중
#
# 사용법:
#   bash scripts/s5_auto.sh

set +e
trap 'adb -s R3CR700SEKP shell cmd wifi set-wifi-enabled enabled >/dev/null 2>&1' EXIT

FAMILY_DEVICE=R3CR700SEKP
SENIOR_DEVICE=KEP2024120921
MAX_CYCLES=10
OFF_SEC=6
ON_SEC=6

PID_F=$(adb -s $FAMILY_DEVICE shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR_DEVICE shell pidof com.seniorcare.senior | tr -d '\r')
echo "PID_F=$PID_F PID_S=$PID_S"

if [ -z "$PID_F" ] || [ -z "$PID_S" ]; then
  echo "[S5] ERROR: Family or Senior app not running"
  exit 1
fi

mkdir -p e:/tmp/ice_test
> e:/tmp/ice_test/family.log
> e:/tmp/ice_test/senior.log
echo "==== S5 auto: Family=$PID_F Senior=$PID_S ====" >> e:/tmp/ice_test/family.log
echo "========== S5 START $(date +%T) ==========" >> e:/tmp/ice_test/family.log

echo "===== S5 auto start at $(date +%H:%M:%S) ====="
for i in $(seq 1 $MAX_CYCLES); do
  T_OFF=$(date +%H:%M:%S)
  echo "[cycle $i] OFF at $T_OFF"
  adb -s $FAMILY_DEVICE shell cmd wifi set-wifi-enabled disabled >/dev/null 2>&1
  sleep $OFF_SEC

  T_ON=$(date +%H:%M:%S)
  echo "[cycle $i] ON  at $T_ON"
  adb -s $FAMILY_DEVICE shell cmd wifi set-wifi-enabled enabled >/dev/null 2>&1
  sleep $ON_SEC

  # 종결 감지
  if adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -50 | grep -q "CallPhase.terminated"; then
    echo "===== terminated detected at cycle $i — stop ====="
    break
  fi
done
echo "===== S5 auto end at $(date +%H:%M:%S) ====="
adb -s $FAMILY_DEVICE shell cmd wifi set-wifi-enabled enabled >/dev/null 2>&1

echo "========== S5 END $(date +%T) ==========" >> e:/tmp/ice_test/family.log
adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null >> e:/tmp/ice_test/family.log
adb -s $SENIOR_DEVICE logcat -d --pid=$PID_S 2>/dev/null >> e:/tmp/ice_test/senior.log
echo "[S5] Done — logs at e:/tmp/ice_test/"
