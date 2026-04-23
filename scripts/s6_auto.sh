#!/bin/bash
# S6 자동 테스트 — restart 도중 hangUp 깨끗한 종결
#
# 사전조건:
#   1. Family 앱이 MonitoringScreen 에서 CONNECTED 상태
#   2. Senior 앱 실행 중
#   3. 종료 버튼 좌표 (HANGUP_X, HANGUP_Y) 가 현재 해상도에 맞음
#      — 기본값은 SM-G991N (1080x2400) 세로 모드 기준
#
# 실패 복구:
#   trap 으로 Wi-Fi 자동 복원 보장
#
# 사용법:
#   bash scripts/s6_auto.sh

set +e
trap 'adb -s R3CR700SEKP shell svc wifi enable >/dev/null 2>&1' EXIT

FAMILY_DEVICE=R3CR700SEKP
SENIOR_DEVICE=KEP2024120921
HANGUP_X=765
HANGUP_Y=2189

PID_F=$(adb -s $FAMILY_DEVICE shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR_DEVICE shell pidof com.seniorcare.senior | tr -d '\r')
echo "PID_F=$PID_F PID_S=$PID_S"

if [ -z "$PID_F" ] || [ -z "$PID_S" ]; then
  echo "[S6] ERROR: Family or Senior app not running"
  exit 1
fi

> e:/tmp/ice_test/family.log
> e:/tmp/ice_test/senior.log
echo "==== S6 auto: Family=$PID_F Senior=$PID_S ====" >> e:/tmp/ice_test/family.log
echo "========== S6 START $(date +%T) ==========" >> e:/tmp/ice_test/family.log

# Baseline 라인 수 저장 — Wi-Fi off 이전 로그 제외하고 새 이벤트만 매칭
BASELINE=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | wc -l)
echo "[S6] baseline=$BASELINE lines"

echo "[S6] Wi-Fi off @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell svc wifi disable

echo "[S6] Polling for ice_restart_start..."
DETECTED=0
for i in {1..20}; do
  sleep 0.5
  NEW=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE+1)))
  if echo "$NEW" | grep -q "ice_restart_start"; then
    echo "[S6] ice_restart_start @ $(date +%T.%3N)"
    DETECTED=1
    break
  fi
done

if [ "$DETECTED" -eq 0 ]; then
  echo "[S6] ERROR: ice_restart_start not detected in 10s — aborting"
  exit 1
fi

sleep 0.3
echo "[S6] Tap 종료 ($HANGUP_X, $HANGUP_Y) @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell input tap $HANGUP_X $HANGUP_Y

sleep 1.5
echo "[S6] Wi-Fi on @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell svc wifi enable

echo "[S6] Waiting 12s for cleanup..."
sleep 12

echo "========== S6 END $(date +%T) ==========" >> e:/tmp/ice_test/family.log
adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null >> e:/tmp/ice_test/family.log
adb -s $SENIOR_DEVICE logcat -d --pid=$PID_S 2>/dev/null >> e:/tmp/ice_test/senior.log
echo "[S6] Done — logs at e:/tmp/ice_test/"
