#!/bin/bash
# S8 자동 테스트 — ICE restart 도중 Senior 기기 파워 리셋
#
# 가설: Senior 가 죽으면 Family 는 5회 시도 후 iceFailed 로 정리.
#       부수적으로 `_iceRestartAnswerTimer(10s)` 발동 경로도 함께 검증됨.
#
# Senior 앱은 Device Owner 모드 + HAL freeze 자동 재부팅 로직 때문에
# `am force-stop` 이 무효 (좋은 방어 장치). 본 스크립트는 `adb reboot` 으로
# 기기 전체 재부팅하여 실전의 "전원 reset / OS crash / OTA 재시작" 케이스를
# 재현한다.
#
# 사전조건:
#   1. Family 앱이 MonitoringScreen 에서 CONNECTED 상태
#   2. Senior 앱 실행 중
#
# 실행 흐름:
#   Wi-Fi off → grace 4s → ice_restart_start 감지 →
#   Senior reboot → Wi-Fi on → 80s 대기 → iceFailed 종결 확인
#   (Senior 재부팅 완료는 비동기, 스크립트 종료 후 자연 복귀)
#
# 사용법:
#   bash scripts/s8_auto.sh

set +e

FAMILY_DEVICE=R3CR700SEKP
SENIOR_DEVICE=KEP2024120921
SENIOR_PKG=com.seniorcare.senior

# 종료 시 Wi-Fi 복구 보장
trap 'adb -s $FAMILY_DEVICE shell cmd wifi set-wifi-enabled enabled >/dev/null 2>&1' EXIT

PID_F=$(adb -s $FAMILY_DEVICE shell pidof com.seniorcare.family | tr -d '\r')
PID_S=$(adb -s $SENIOR_DEVICE shell pidof $SENIOR_PKG | tr -d '\r')
echo "PID_F=$PID_F PID_S=$PID_S"

if [ -z "$PID_F" ] || [ -z "$PID_S" ]; then
  echo "[S8] ERROR: Family or Senior app not running"
  exit 1
fi

mkdir -p e:/tmp/ice_test
> e:/tmp/ice_test/family.log
> e:/tmp/ice_test/senior.log
echo "==== S8 auto: Family=$PID_F Senior=$PID_S ====" >> e:/tmp/ice_test/family.log
echo "========== S8 START $(date +%T) ==========" >> e:/tmp/ice_test/family.log

BASELINE=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | wc -l)
echo "[S8] baseline=$BASELINE lines"

echo "[S8] Wi-Fi off @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell cmd wifi set-wifi-enabled disabled >/dev/null 2>&1

echo "[S8] Polling for ice_restart_start..."
DETECTED=0
for i in {1..30}; do
  sleep 0.5
  NEW=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE+1)))
  if echo "$NEW" | grep -q "ice_restart_start"; then
    echo "[S8] ice_restart_start @ $(date +%T.%3N)"
    DETECTED=1
    break
  fi
done

if [ "$DETECTED" -eq 0 ]; then
  echo "[S8] ERROR: ice_restart_start not detected in 15s — aborting"
  exit 1
fi

# offer 가 Firebase 에 쓸 여유 주기 (Wi-Fi 복구 후 flush 대비)
sleep 0.3

echo "[S8] Senior reboot @ $(date +%T.%3N)"
adb -s $SENIOR_DEVICE reboot

sleep 1
echo "[S8] Wi-Fi on @ $(date +%T.%3N)"
adb -s $FAMILY_DEVICE shell cmd wifi set-wifi-enabled enabled >/dev/null 2>&1

echo "[S8] Waiting up to 80s for iceFailed..."
for i in {1..160}; do
  sleep 0.5
  TAIL=$(adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null | tail -n +$((BASELINE+1)))
  if echo "$TAIL" | grep -q "CallPhase.terminated"; then
    echo "[S8] terminated @ $(date +%T.%3N) (after $((i/2))s)"
    break
  fi
done

echo "========== S8 END $(date +%T) ==========" >> e:/tmp/ice_test/family.log
adb -s $FAMILY_DEVICE logcat -d --pid=$PID_F 2>/dev/null >> e:/tmp/ice_test/family.log

echo "[S8] Senior 부팅은 자연 복귀 (수 분 소요). Family log: e:/tmp/ice_test/family.log"
echo "[S8] Done"
