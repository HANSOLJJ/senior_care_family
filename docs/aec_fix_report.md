# AEC(에코 제거) 수정 보고서

## 기기 정보
- **모델**: RK3566 (rk3566_t)
- **Android**: 11 (SDK 30)
- **시리얼**: ADT36E26010101
- **WebRTC SDK**: io.github.webrtc-sdk:android:137.7151.04 (M137)
- **플러그인**: flutter_webrtc 1.3.0

---

## 1. 근본 원인

### 원래 코드 (MethodCallHandlerImpl.java line 240)
```java
boolean useHardwareAudioProcessing = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q;
audioDeviceModuleBuilder.setUseHardwareAcousticEchoCanceler(useHardwareAudioProcessing)
                  .setUseLowLatency(useLowLatency)
                  .setUseHardwareNoiseSuppressor(useHardwareAudioProcessing);
```

**문제**: Android 11(SDK 30) ≥ Q(SDK 29) → `true` → APM이 SW AEC(AEC3)를 비활성화함 (HW가 처리한다고 믿음).

하지만 RK3566 기기:
- `AcousticEchoCanceler.isAvailable()` = **false** (HW AEC 없음)
- `/vendor/etc/audio_effects.xml`에 AEC/NS 효과 모두 주석 처리 상태
- **결과: HW AEC도 없고, SW AEC도 꺼짐 → 에코 제거 = 0**

### Google Meet이 되는 이유
Google Meet은 자체 커스텀 오디오 모듈(`WebRtcAudioRecordExternal`)을 사용하여 `setUseHardwareAcousticEchoCanceler` 설정과 무관하게 자체 AEC 파이프라인이 항상 동작함.

---

## 2. 적용된 수정 (현재 상태)

### 수정 1: 앱 코드 — audio constraint 변경
**파일**: `lib/services/webrtc_service.dart`

```dart
// Before — 커스텀 Map이 flutter_webrtc에서 무시됨
'audio': {
  'echoCancellation': true,
  'noiseSuppression': true,
  'autoGainControl': true,
}

// After — addDefaultAudioConstraints() 호출되어 올바른 포맷으로 전달됨
'audio': true
```

### 수정 2: 플러그인 패치 — HW AEC 실제 확인
**파일**: `flutter_webrtc-1.3.0/.../MethodCallHandlerImpl.java` (line 240~248)

```java
// Before — Android 버전만 보고 판단
boolean useHardwareAudioProcessing = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q;
boolean useLowLatency = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O;
audioDeviceModuleBuilder.setUseHardwareAcousticEchoCanceler(useHardwareAudioProcessing)
                  .setUseLowLatency(useLowLatency)
                  .setUseHardwareNoiseSuppressor(useHardwareAudioProcessing);

// After — 실제 기기 HW AEC/NS 지원 여부 확인
boolean hwAecAvailable = JavaAudioDeviceModule.isBuiltInAcousticEchoCancelerSupported();
boolean hwNsAvailable = JavaAudioDeviceModule.isBuiltInNoiseSuppressorSupported();
boolean useLowLatency = hwAecAvailable && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O;
Log.i(TAG, "HW AEC available: " + hwAecAvailable + ", HW NS available: " + hwNsAvailable + ", low latency: " + useLowLatency);
audioDeviceModuleBuilder.setUseHardwareAcousticEchoCanceler(hwAecAvailable)
                  .setUseLowLatency(useLowLatency)
                  .setUseHardwareNoiseSuppressor(hwNsAvailable);
```

**효과**:
- `hwAecAvailable = false` → APM이 SW AEC(AEC3) 자동 활성화
- `useLowLatency = false` → AudioTrack fast mode 비활성화

---

## 3. 시도했으나 효과 없었던 것들

### OS-level AEC 활성화 (audio_effects.xml 수정)
`/vendor/etc/audio_effects.xml`에 `libaudiopreprocessing.so` 등록 + AEC/NS 이펙트 + preprocess 섹션 추가.

**실패 원인**: RK3566 HAL이 Record Thread에서 fast capture를 강제 활성화 → AudioFlinger가 SW 이펙트 부착 거부.
```
checkEffectCompatibility_l(): non HW effect Acoustic Echo Canceler on record thread AudioIn_1E in fast mode
AudioEffect: set(): AudioFlinger could not create effect, status: -22
```
- `audio_policy_configuration.xml`에 `AUDIO_INPUT_FLAG_FAST` 없음
- `AudioStreamIn flags: AUDIO_INPUT_FLAG_NONE`
- 그럼에도 HAL 내부에서 fast capture 활성화 → 제어 불가

### Audio Source를 MIC로 변경
`VOICE_COMMUNICATION` → `MIC`로 변경하여 fast mode 회피 시도.

**실패 원인**: Audio source와 무관하게 HAL이 fast capture 활성화. MIC로 바꿔도 동일한 fast mode 에러 발생.

### Field Trials (AEC3 파라미터 튜닝)
`WebRTC-Aec3ShortHeadroomKillSwitch/Enabled/` 설정하여 AEC3의 delay headroom을 줄여 더 공격적으로 에코 억제 시도.

**결과**: 개선 없음. 오히려 악화된 느낌. 원복함.

### 원격 오디오 트랙 볼륨 0.5로 제한
`Helper.setVolume(0.5, event.track)`으로 스피커 출력 볼륨을 낮춰 음향 커플링 감소 시도.

**결과**: 개선 없음. Field Trials와 함께 원복함.

---

## 4. 현재 상태

| 항목 | 상태 |
|------|------|
| HW AEC | **false** (기기 미지원) |
| SW AEC (APM AEC3) | **활성** (수정 2로 활성화됨) |
| OS-level AEC | **사용 불가** (HAL fast capture 블로킹) |
| 에코 상태 | 수정 전 대비 감소되었으나, Google Meet 수준에는 미달 |
| 통화 시작 직후 | 에코 특히 심함 (AEC3 적응 필터 수렴 시간 필요, 0.5~2초) |

---

## 5. 남은 개선 옵션

### A. 통화 초반 마이크 mute (간단)
AEC3 적응 필터가 수렴하는 0.5~2초 동안 마이크를 mute하거나 볼륨을 극도로 낮춰 초반 에코 방지.

### B. SpeexDSP 잔여 에코 억제기 (고난이도)
`ExternalAudioProcessingFactory`의 `capturePostProcessing` 훅에 SpeexDSP 기반 잔여 에코 억제기를 추가. AEC3가 처리 못한 잔여 에코를 추가 제거.

### C. HAL fast capture 비활성화 (시스템 수정)
Rockchip HAL 설정이나 소스 수정으로 fast capture 비활성화 → OS-level AEC 사용 가능해짐. 하지만 HAL 소스 접근 필요.

---

## 6. 수정된 파일 목록

| 파일 | 변경 내용 | 상태 |
|------|-----------|------|
| `lib/services/webrtc_service.dart` | `'audio': true`로 변경 | **적용 중** |
| `flutter_webrtc-1.3.0/.../MethodCallHandlerImpl.java` | HW AEC 실제 확인 + low latency 조건부 | **적용 중** |
| `/vendor/etc/audio_effects.xml` (기기) | AEC/NS preprocess 추가 | 적용되었으나 효과 없음 (fast capture) |
| `docs/audio_effects_rk3566_modified.xml` | 수정된 XML 백업 | 참고용 |
| `docs/audio_effects_rk3566_backup.xml` | 원본 XML 백업 | 참고용 |
