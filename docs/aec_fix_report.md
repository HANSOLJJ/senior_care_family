# AEC(에코 제거) 수정 보고서

## 기기 정보
- **모델**: RK3566 (rk3566_t)
- **Android**: 11 (SDK 30)
- **시리얼**: ADT36E26010101
- **WebRTC SDK**: io.github.webrtc-sdk:android:137.7151.04 (M137)
- **플러그인**: flutter_webrtc 1.3.0

### 비교 기기: SM-T500 (Galaxy Tab A7)
- **Android**: 12 (SDK 31)
- **HW AEC**: `AcousticEchoCanceler.isAvailable()` = **true** (Qualcomm `libqcomvoiceprocessing.so`)
- **HW NS**: **true**
- SM-T500은 HW AEC가 잘 동작하여 에코 문제 없음. 아래 내용은 모두 RK3566 대상.

---

## 1. 근본 원인

### 원래 코드 (MethodCallHandlerImpl.java line 240)
```java
boolean useHardwareAudioProcessing = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q;
audioDeviceModuleBuilder.setUseHardwareAcousticEchoCanceler(useHardwareAudioProcessing)
                  .setUseLowLatency(useLowLatency)
                  .setUseHardwareNoiseSuppressor(useHardwareAudioProcessing);
```

**문제**: Android 11(SDK 30) >= Q(SDK 29) -> `true` -> APM이 SW AEC(AEC3)를 비활성화함 (HW가 처리한다고 믿음).

하지만 RK3566 기기:
- `AcousticEchoCanceler.isAvailable()` = **false** (HW AEC 없음)
- `/vendor/etc/audio_effects.xml`에 AEC/NS 효과 모두 주석 처리 상태
- **결과: HW AEC도 없고, SW AEC도 꺼짐 -> 에코 제거 = 0**

### Google Meet이 되는 이유
Google Meet은 자체 커스텀 오디오 모듈(`WebRtcAudioRecordExternal`)을 사용하여 `setUseHardwareAcousticEchoCanceler` 설정과 무관하게 자체 AEC 파이프라인이 항상 동작함.

---

## 2. Phase 1: SW AEC3 활성화

### 수정 1: 앱 코드 -- audio constraint 변경
**파일**: `lib/services/webrtc_service.dart`

```dart
// Before -- 커스텀 Map이 flutter_webrtc에서 무시됨
'audio': {
  'echoCancellation': true,
  'noiseSuppression': true,
  'autoGainControl': true,
}

// After -- addDefaultAudioConstraints() 호출되어 올바른 포맷으로 전달됨
'audio': true
```

### 수정 2: 플러그인 패치 -- HW AEC 실제 확인
**파일**: `plugins/flutter_webrtc/android/.../MethodCallHandlerImpl.java` (line 240~248)

```java
// After -- 실제 기기 HW AEC/NS 지원 여부 확인
boolean hwAecAvailable = JavaAudioDeviceModule.isBuiltInAcousticEchoCancelerSupported();
boolean hwNsAvailable = JavaAudioDeviceModule.isBuiltInNoiseSuppressorSupported();
boolean useLowLatency = hwAecAvailable && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O;
audioDeviceModuleBuilder.setUseHardwareAcousticEchoCanceler(hwAecAvailable)
                  .setUseLowLatency(useLowLatency)
                  .setUseHardwareNoiseSuppressor(hwNsAvailable);
```

**효과**:
- `hwAecAvailable = false` -> APM이 SW AEC(AEC3) 자동 활성화
- `useLowLatency = false` -> AudioTrack fast mode 비활성화
- **결과**: 에코 감소 체감, 하지만 여전히 부족

---

## 3. Phase 2: AEC3 튜닝 + RNNoise (진행중)

Phase 1(SW AEC3 활성화)만으로는 에코가 충분히 제거되지 않아 추가 대책 적용 중.

### 수정 3: AEC3 Field Trials
**파일**: `plugins/flutter_webrtc/android/.../MethodCallHandlerImpl.java` (line ~200)

```java
.setFieldTrials(
    "WebRTC-Aec3UseLowEarlyReflectionsDefaultGain/Enabled/" +
    "WebRTC-Aec3UseLowLateReflectionsDefaultGain/Enabled/" +
    "WebRTC-Aec3HighPassFilterEchoReference/Enabled/" +
    "WebRTC-Aec3EnforceConservativeHfSuppression/Enabled/")
```

| Field Trial | 효과 |
|-------------|------|
| `UseLowEarlyReflectionsDefaultGain` | Early reflections gain 0.1로 축소 |
| `UseLowLateReflectionsDefaultGain` | Late reflections gain 0.1로 축소 |
| `HighPassFilterEchoReference` | 렌더(스피커) 경로에 HPF 적용 |
| `EnforceConservativeHfSuppression` | 고주파 에코 공격적 억제 |

**결과**: Phase 1 대비 약간 개선

### 수정 4: RNNoise v0.2 포스트프로세서
AEC3 후단에 RNNoise(GRU 기반 신경망 노이즈 억제기)를 추가하여 잔여 에코를 "노이즈"로 처리하여 제거.

**구성:**
- **RNNoise C 소스**: `plugins/flutter_webrtc/android/src/main/jni/rnnoise/` (v0.2, 10개 .c 파일)
- **NDK 빌드**: `plugins/flutter_webrtc/android/src/main/jni/CMakeLists.txt` (NEON 최적화)
- **JNI 브릿지**: `plugins/flutter_webrtc/android/src/main/jni/rnnoise_jni.c`
- **Java 래퍼**: `plugins/flutter_webrtc/android/.../audio/RNNoiseProcessor.java`
- **등록**: `MethodCallHandlerImpl.java` line ~347에서 `capturePostProcessing.addProcessor()` 호출

**핵심 발견:**
- WebRTC `ExternalAudioProcessingFactory`의 버퍼는 **float** 데이터 (int16 아님!)
- `numBands=3, numFrames=480, bufCap=1920` -> 480 float values
- 초기에 int16으로 읽어서 지지직 소리 발생 -> float 처리로 수정하여 해결

**동작 원리:**
1. WebRTC AEC3가 에코 1차 제거
2. RNNoise가 `capturePostProcessing`에서 잔여 에코/노이즈 추가 억제
3. RNNoise는 reference 신호 불필요 -- mic 신호만으로 동작

**결과**: 활성 상태, 테스트 중

### 수정 5: getStats() AEC 메트릭 로깅
**파일**: `lib/services/webrtc_service.dart`

통화 중 5초 간격으로 WebRTC stats 로깅:
```dart
_aecStatsTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
  final stats = await pc.getStats();
  for (final report in stats) {
    if (report.values.containsKey('echoReturnLoss')) {
      print('AEC stats: ERL=${v['echoReturnLoss']}dB ERLE=${v['echoReturnLossEnhancement']}dB');
    }
    if (report.type == 'media-source' && report.values.containsKey('audioLevel')) {
      print('AEC stats: audioLevel=${v['audioLevel']} totalAudioEnergy=${v['totalAudioEnergy']}');
    }
  }
});
```

**결과**:
- `audioLevel` / `totalAudioEnergy` 정상 출력
- `echoReturnLoss` / `echoReturnLossEnhancement`는 M137에서 노출되지 않음 -> ERLE 수치화 불가

### flutter_webrtc 로컬 플러그인 이동
**파일**: `pubspec.yaml`
```yaml
flutter_webrtc:
  path: plugins/flutter_webrtc
```

---

## 4. 시도했으나 효과 없었던 것들

| 시도 | 실패 원인 |
|------|-----------|
| OS-level AEC (`audio_effects.xml` 수정) | HAL fast capture 강제 활성화 -> AudioFlinger SW 이펙트 거부 |
| Audio Source MIC로 변경 | HAL이 source 무관하게 fast capture 활성화 |
| `ShortHeadroomKillSwitch` Field Trial | 개선 없음, 오히려 악화 |
| 원격 트랙 볼륨 0.5 제한 | 개선 없음 |
| SpeexDSP 검토 | AEC3와 호환 안 됨 (자체 echo state 필요) |

---

## 5. 현재 상태

| 항목 | 상태 |
|------|------|
| HW AEC | **false** (기기 미지원) |
| SW AEC (APM AEC3) | **활성** (Phase 1에서 활성화) |
| AEC3 Field Trials | **4개 적용중** (Reflections + HPF + HF Suppression) |
| RNNoise v0.2 | **활성** (capturePostProcessing, float 버퍼, 48kHz) |
| getStats() 로깅 | **활성** (audioLevel만 사용 가능, ERL/ERLE 미노출) |
| OS-level AEC | **사용 불가** (HAL fast capture 블로킹) |
| 에코 상태 | Phase 1 대비 개선, 여전히 Google Meet 수준 미달 |

---

## 6. AEC3 Field Trials 전체 목록 (83개)

WebRTC HEAD branch 소스코드 + `field_trials.py` 레지스트리 기준.
`setFieldTrials()`에 `"키/Enabled/"` 또는 `"키/값/"` 형태로 전달.

**네이밍 규칙:**
- `KillSwitch` 접미사: Enabled 시 해당 기능 **비활성화** (이중 부정)
- `Override` 접미사: 숫자 값으로 기본값 직접 오버라이드 (예: `"키/0.01/"`)
- `Enforce` 접두사: 특정 동작 강제
- `Use` 접두사: 대체 설정 활성화

### 현재 적용중 (4개)
| # | Field Trial Key | 설명 |
|---|----------------|------|
| 1 | `WebRTC-Aec3UseLowEarlyReflectionsDefaultGain` | Early reflections gain을 0.1로 축소 |
| 2 | `WebRTC-Aec3UseLowLateReflectionsDefaultGain` | Late reflections gain을 0.1로 축소 |
| 3 | `WebRTC-Aec3HighPassFilterEchoReference` | 렌더 경로(스피커 출력)에 HPF 적용 |
| 4 | `WebRTC-Aec3EnforceConservativeHfSuppression` | 고주파(HF) 에코 공격적 억제 |

### 시도 후 원복 (1개)
| # | Field Trial Key | 결과 |
|---|----------------|------|
| 5 | `WebRTC-Aec3ShortHeadroomKillSwitch` | 개선 없음/악화, 원복 |

### 미시도 -- 초기 상태 Duration (9개)
통화 시작 직후 AEC3의 초기 수렴 시간 제어. 값이 짧을수록 빠르게 억제 시작.
| # | Field Trial Key | 설명 |
|---|----------------|------|
| 6 | `WebRTC-Aec3UseZeroInitialStateDuration` | 초기 상태 0초 (즉시 억제) |
| 7 | `WebRTC-Aec3UseDot1SecondsInitialStateDuration` | 초기 상태 0.1초 |
| 8 | `WebRTC-Aec3UseDot2SecondsInitialStateDuration` | 초기 상태 0.2초 |
| 9 | `WebRTC-Aec3UseDot3SecondsInitialStateDuration` | 초기 상태 0.3초 |
| 10 | `WebRTC-Aec3UseDot6SecondsInitialStateDuration` | 초기 상태 0.6초 |
| 11 | `WebRTC-Aec3UseDot9SecondsInitialStateDuration` | 초기 상태 0.9초 |
| 12 | `WebRTC-Aec3Use1Dot2SecondsInitialStateDuration` | 초기 상태 1.2초 |
| 13 | `WebRTC-Aec3Use1Dot6SecondsInitialStateDuration` | 초기 상태 1.6초 |
| 14 | `WebRTC-Aec3Use2Dot0SecondsInitialStateDuration` | 초기 상태 2.0초 |

### 미시도 -- Reverb Default Length (7개)
AEC3 잔향 모델의 기본 잔향 꼬리 길이 제어.
| # | Field Trial Key | 설명 |
|---|----------------|------|
| 15 | `WebRTC-Aec3UseDot2ReverbDefaultLen` | 기본 잔향 길이 0.2 |
| 16 | `WebRTC-Aec3UseDot3ReverbDefaultLen` | 기본 잔향 길이 0.3 |
| 17 | `WebRTC-Aec3UseDot4ReverbDefaultLen` | 기본 잔향 길이 0.4 |
| 18 | `WebRTC-Aec3UseDot5ReverbDefaultLen` | 기본 잔향 길이 0.5 |
| 19 | `WebRTC-Aec3UseDot6ReverbDefaultLen` | 기본 잔향 길이 0.6 |
| 20 | `WebRTC-Aec3UseDot7ReverbDefaultLen` | 기본 잔향 길이 0.7 |
| 21 | `WebRTC-Aec3UseDot8ReverbDefaultLen` | 기본 잔향 길이 0.8 |

### 미시도 -- Suppressor 마스크 Override (12개)
억제기의 투명도/억제 강도를 직접 제어. 값 범위 0~10. 낮을수록 더 강하게 억제.
| # | Field Trial Key | 설명 |
|---|----------------|------|
| 22 | `WebRTC-Aec3SuppressorNormalLfMaskTransparentOverride` | Normal 모드 LF 투명 임계 |
| 23 | `WebRTC-Aec3SuppressorNormalLfMaskSuppressOverride` | Normal 모드 LF 억제 임계 |
| 24 | `WebRTC-Aec3SuppressorNormalHfMaskTransparentOverride` | Normal 모드 HF 투명 임계 |
| 25 | `WebRTC-Aec3SuppressorNormalHfMaskSuppressOverride` | Normal 모드 HF 억제 임계 |
| 26 | `WebRTC-Aec3SuppressorNormalMaxDecFactorLfOverride` | Normal 모드 LF 최대 감소 팩터 |
| 27 | `WebRTC-Aec3SuppressorNormalMaxIncFactorOverride` | Normal 모드 최대 증가 팩터 |
| 28 | `WebRTC-Aec3SuppressorNearendLfMaskTransparentOverride` | Nearend 모드 LF 투명 임계 |
| 29 | `WebRTC-Aec3SuppressorNearendLfMaskSuppressOverride` | Nearend 모드 LF 억제 임계 |
| 30 | `WebRTC-Aec3SuppressorNearendHfMaskTransparentOverride` | Nearend 모드 HF 투명 임계 |
| 31 | `WebRTC-Aec3SuppressorNearendHfMaskSuppressOverride` | Nearend 모드 HF 억제 임계 |
| 32 | `WebRTC-Aec3SuppressorNearendMaxDecFactorLfOverride` | Nearend 모드 LF 최대 감소 팩터 |
| 33 | `WebRTC-Aec3SuppressorNearendMaxIncFactorOverride` | Nearend 모드 최대 증가 팩터 |

### 미시도 -- Dominant Nearend 감지 (7개)
Double-talk(양방향 동시 발화) 감지 튜닝.
| # | Field Trial Key | 설명 |
|---|----------------|------|
| 34 | `WebRTC-Aec3SensitiveDominantNearendActivation` | 근단 음성 감지 더 민감하게 |
| 35 | `WebRTC-Aec3VerySensitiveDominantNearendActivation` | 근단 음성 감지 매우 민감하게 |
| 36 | `WebRTC-Aec3SuppressorDominantNearendEnrThresholdOverride` | 근단 ENR 임계값 (0~100) |
| 37 | `WebRTC-Aec3SuppressorDominantNearendEnrExitThresholdOverride` | 근단 ENR 해제 임계값 (0~100) |
| 38 | `WebRTC-Aec3SuppressorDominantNearendSnrThresholdOverride` | 근단 SNR 임계값 (0~100) |
| 39 | `WebRTC-Aec3SuppressorDominantNearendHoldDurationOverride` | 근단 활성 유지 시간 (0~1000 blocks) |
| 40 | `WebRTC-Aec3SuppressorDominantNearendTriggerThresholdOverride` | 근단 트리거 임계값 (0~1000) |

### 미시도 -- Suppressor 튜닝 프리셋 (9개)
억제기 동작 속도/강도 사전 정의 세트.
| # | Field Trial Key | 설명 |
|---|----------------|------|
| 41 | `WebRTC-Aec3SuppressorTuningOverride` | 억제기 전체 튜닝 오버라이드 (복합 파라미터) |
| 42 | `WebRTC-Aec3EnforceMoreTransparentNormalSuppressorTuning` | Normal 모드 더 투명 (억제 줄임) |
| 43 | `WebRTC-Aec3EnforceMoreTransparentNormalSuppressorHfTuning` | Normal HF 더 투명 |
| 44 | `WebRTC-Aec3EnforceMoreTransparentNearendSuppressorTuning` | Nearend 모드 더 투명 |
| 45 | `WebRTC-Aec3EnforceMoreTransparentNearendSuppressorHfTuning` | Nearend HF 더 투명 |
| 46 | `WebRTC-Aec3EnforceRapidlyAdjustingNormalSuppressorTunings` | Normal 모드 빠른 조정 |
| 47 | `WebRTC-Aec3EnforceRapidlyAdjustingNearendSuppressorTunings` | Nearend 모드 빠른 조정 |
| 48 | `WebRTC-Aec3EnforceSlowlyAdjustingNormalSuppressorTunings` | Normal 모드 느린 조정 |
| 49 | `WebRTC-Aec3EnforceSlowlyAdjustingNearendSuppressorTunings` | Nearend 모드 느린 조정 |

### 미시도 -- 투명 모드 / Anti-Howling (5개)
에코가 없을 때 신호를 최대한 통과시키는 모드, 하울링 방지.
| # | Field Trial Key | 설명 |
|---|----------------|------|
| 50 | `WebRTC-Aec3TransparentModeKillSwitch` | 투명 모드 비활성화 |
| 51 | `WebRTC-Aec3TransparentModeHmm` | 투명 모드 HMM 기반 전환 |
| 52 | `WebRTC-Aec3TransparentAntiHowlingGain` | 투명 모드 anti-howling gain |
| 53 | `WebRTC-Aec3AntiHowlingMinimizationKillSwitch` | Anti-howling 최소화 비활성화 |
| 54 | `WebRTC-Aec3SuppressorAntiHowlingGainOverride` | Anti-howling gain 값 오버라이드 (0~10) |

### 미시도 -- AEC 상태/필터 리셋 (4개)
| # | Field Trial Key | 설명 |
|---|----------------|------|
| 55 | `WebRTC-Aec3AecStateFullResetKillSwitch` | AEC 상태 전체 리셋 비활성화 |
| 56 | `WebRTC-Aec3AecStateSubtractorAnalyzerResetKillSwitch` | Subtractor analyzer 리셋 비활성화 |
| 57 | `WebRTC-Aec3CoarseFilterResetHangoverKillSwitch` | Coarse 필터 리셋 hangover 비활성화 |
| 58 | `WebRTC-Aec3DeactivateInitialStateResetKillSwitch` | 초기 상태 리셋 비활성화 |

### 미시도 -- 딜레이 추정 (6개)
| # | Field Trial Key | 설명 |
|---|----------------|------|
| 59 | `WebRTC-Aec3DelayEstimateSmoothingOverride` | 딜레이 추정 스무딩 값 (0~1) |
| 60 | `WebRTC-Aec3DelayEstimateSmoothingDelayFoundOverride` | 딜레이 발견 후 스무딩 값 (0~1) |
| 61 | `WebRTC-Aec3EnforceCaptureDelayEstimationDownmixing` | 캡처 딜레이 추정 다운믹싱 강제 |
| 62 | `WebRTC-Aec3EnforceCaptureDelayEstimationLeftRightPrioritization` | L/R 우선순위 |
| 63 | `WebRTC-Aec3EnforceRenderDelayEstimationDownmixing` | 렌더 딜레이 추정 다운믹싱 강제 |
| 64 | `WebRTC-Aec3RenderDelayEstimationLeftRightPrioritizationKillSwitch` | L/R 우선순위 비활성화 |

### 미시도 -- ERLE/에코 추정 (5개)
| # | Field Trial Key | 설명 |
|---|----------------|------|
| 65 | `WebRTC-Aec3UseErleOnsetCompensationInDominantNearend` | Nearend에서 ERLE onset 보상 |
| 66 | `WebRTC-Aec3MinErleDuringOnsetsKillSwitch` | Onset 시 최소 ERLE 비활성화 |
| 67 | `WebRTC-Aec3OnsetDetectionKillSwitch` | Onset 감지 비활성화 |
| 68 | `WebRTC-Aec3UseUnboundedEchoSpectrum` | 무제한 에코 스펙트럼 사용 (suppression_gain.cc) |
| 69 | `WebRTC-Aec3EchoSaturationDetectionKillSwitch` | 에코 포화 감지 비활성화 |

### 미시도 -- Reverb/잔향 (3개)
| # | Field Trial Key | 설명 |
|---|----------------|------|
| 70 | `WebRTC-Aec3UseNearendReverbLen` | Nearend 전용 잔향 길이 사용 |
| 71 | `WebRTC-Aec3NonlinearModeReverbKillSwitch` | 비선형 잔향 모드 비활성화 |
| 72 | `WebRTC-Aec3ConservativeTailFreqResponse` | 보수적 꼬리 주파수 응답 |

### 미시도 -- Stationarity/렌더 활성 (4개)
| # | Field Trial Key | 설명 |
|---|----------------|------|
| 73 | `WebRTC-Aec3EnforceStationarityProperties` | 정상성(stationarity) 속성 강제 |
| 74 | `WebRTC-Aec3EnforceStationarityPropertiesAtInit` | 초기화 시 정상성 속성 강제 |
| 75 | `WebRTC-Aec3EnforceLowActiveRenderLimit` | 낮은 렌더 활성 임계 |
| 76 | `WebRTC-Aec3EnforceVeryLowActiveRenderLimit` | 매우 낮은 렌더 활성 임계 |

### 미시도 -- 기타 (7개)
| # | Field Trial Key | 설명 |
|---|----------------|------|
| 77 | `WebRTC-Aec3UseShortConfigChangeDuration` | 설정 변경 시 짧은 전환 시간 |
| 78 | `WebRTC-Aec3BufferingMaxAllowedExcessRenderBlocksOverride` | 최대 렌더 블록 초과 허용량 |
| 79 | `WebRTC-Aec3RenderBufferCallCounterUpdateKillSwitch` | 렌더 버퍼 카운터 업데이트 비활성화 |
| 80 | `WebRTC-Aec3ClampInstQualityToOneKillSwitch` | 순간 품질 1 클램프 비활성화 |
| 81 | `WebRTC-Aec3ClampInstQualityToZeroKillSwitch` | 순간 품질 0 클램프 비활성화 |
| 82 | `WebRTC-Aec3StereoContentDetectionKillSwitch` | 스테레오 콘텐츠 감지 비활성화 |
| 83 | `WebRTC-Aec3SetupSpecificDefaultConfigDefaultsKillSwitch` | 셋업별 기본값 비활성화 |

### 소스 파일 위치
| 소스 파일 | 관련 Field Trials |
|-----------|-------------------|
| `echo_canceller3.cc` | 대부분 (60+개) |
| `aec_state.cc` | #55-58 (상태/리셋) |
| `residual_echo_estimator.cc` | #1, 2, 65 (반사음, ERLE) |
| `transparent_mode.cc` | #50-51 (투명 모드) |
| `suppression_gain.cc` | #68 (무제한 에코 스펙트럼) |
| `subtractor.cc` | #57 (coarse 필터) |
| `subband_erle_estimator.cc` | #66 (최소 ERLE) |
| `render_delay_buffer.cc` | #79 (렌더 버퍼 카운터) |

---

## 7. 남은 개선 옵션 (우선순위순)

### A. 추가 Field Trials 조합 테스트
한 번에 1~2개씩 추가하고 체감 비교.

**우선 시도:**
1. `UseDot3SecondsInitialStateDuration` -- 통화 초기 에코 빠른 수렴
2. `SensitiveDominantNearendActivation` -- double-talk 시 근단 음성 보존
3. `SuppressorNormalLfMaskSuppressOverride/0.01/` -- 억제 강도 직접 제어 (최후 수단)
4. `UseZeroInitialStateDuration` -- 초기 상태 즉시 억제

### B. Double-talk 자동화 테스트
혼자서 double-talk 시나리오 테스트:
- SM-T500에서 자동 음성 재생 (far-end)
- RK3566 마이크 근처에 별도 기기로 음성 재생 (near-end)
- audioLevel 로깅으로 에코 누출 정도 확인

### C. RNNoise band-split 최적화
현재 480 float를 통째로 처리하지만, 실제로는 3 bands x 160 samples.
Band 0(저주파, 음성 대역)만 처리하면 더 정확한 억제 가능.

### D. VAD 기반 마이크 게이팅
로컬 음성 미감지 시 마이크 신호를 -30~40dB 감쇠.
무음 구간의 에코 완전 제거. Double-talk에서는 도움 안 됨.

### E. HAL fast capture 비활성화 (시스템 수정)
Rockchip HAL 소스 수정으로 fast capture 비활성화 -> OS-level AEC 사용 가능.
HAL 소스 접근 필요.

---

## 8. 수정된 파일 목록

| 파일 | 변경 내용 | 상태 |
|------|-----------|------|
| `lib/services/webrtc_service.dart` | `'audio': true` + getStats() ERLE 로깅 | **적용중** |
| `plugins/flutter_webrtc/android/.../MethodCallHandlerImpl.java` | HW AEC 확인 + Field Trials 4개 + RNNoise 등록 | **적용중** |
| `plugins/flutter_webrtc/android/.../audio/RNNoiseProcessor.java` | RNNoise Java wrapper (float 버퍼) | **적용중** |
| `plugins/flutter_webrtc/android/.../audio/AudioProcessingAdapter.java` | ExternalAudioProcessingFactory 어댑터 | **적용중** |
| `plugins/flutter_webrtc/android/src/main/jni/rnnoise_jni.c` | JNI bridge (float 처리) | **적용중** |
| `plugins/flutter_webrtc/android/src/main/jni/CMakeLists.txt` | NDK 빌드 (NEON 최적화) | **적용중** |
| `plugins/flutter_webrtc/android/src/main/jni/rnnoise/` | RNNoise v0.2 C 소스 (10개 파일) | **적용중** |
| `plugins/flutter_webrtc/android/build.gradle` | NDK/CMake 빌드 설정 추가 | **적용중** |
| `pubspec.yaml` | flutter_webrtc -> 로컬 path dependency | **적용중** |
