#!/bin/bash
# ============================================
# Smart Frame 태블릿 프로비저닝 스크립트
# 사용법: ./provision_tablet.sh [시리얼번호]
# 시리얼번호 생략 시 연결된 단일 기기에 적용
# ============================================

SERIAL=""
if [ -n "$1" ]; then
    SERIAL="-s $1"
fi

ADB="adb $SERIAL"

echo "=== Smart Frame 태블릿 프로비저닝 시작 ==="

# 1. 잠금 화면 비활성화
echo "[1/8] 잠금 화면 비활성화..."
$ADB shell settings put secure lockscreen.disabled 1

# 2. 화면 꺼짐 시간 최대로 (약 24일 = 사실상 안 꺼짐)
echo "[2/8] 화면 타임아웃 비활성화..."
$ADB shell settings put system screen_off_timeout 2147483647

# 3. 화면 회전 잠금 (자동회전 끄기 + 가로 고정)
echo "[3/8] 화면 회전 잠금..."
$ADB shell settings put system accelerometer_rotation 0
$ADB shell settings put system user_rotation 0  # 0=세로, 1=가로

# 4. 배터리 최적화에서 앱 제외 (Samsung 등에서 wake lock 무시 방지)
echo "[4/8] 배터리 최적화 제외..."
$ADB shell dumpsys deviceidle whitelist +com.example.senior_win

# 5. APK 설치
echo "[5/8] APK 설치..."
$ADB install -r build/app/outputs/flutter-apk/app-debug.apk

# 6. 기본 홈 런처로 설정
echo "[6/8] 기본 홈 런처 설정..."
$ADB shell cmd package set-home-activity com.example.senior_win/.MainActivity

# 7. 화면 밝기 최대 (액자용)
echo "[7/8] 화면 밝기 설정..."
$ADB shell settings put system screen_brightness_mode 0
$ADB shell settings put system screen_brightness 255

# 8. 알림/소리 무음 (액자에 알림 불필요)
echo "[8/8] 알림 무음 설정..."
$ADB shell settings put system notification_sound 0
$ADB shell settings put system sound_effects_enabled 0

echo ""
echo "=== 프로비저닝 완료! ==="
echo "태블릿을 재부팅하면 Smart Frame이 자동으로 실행됩니다."
echo "재부팅 명령: $ADB reboot"
echo ""
echo "=== 현재 설정 확인 ==="
echo "잠금화면: $($ADB shell settings get secure lockscreen.disabled)"
echo "화면타임아웃: $($ADB shell settings get system screen_off_timeout)"
echo "자동회전: $($ADB shell settings get system accelerometer_rotation)"
echo "회전방향: $($ADB shell settings get system user_rotation) (0=세로, 1=가로)"
echo "밝기모드: $($ADB shell settings get system screen_brightness_mode) (0=수동)"
echo "밝기값: $($ADB shell settings get system screen_brightness)"
