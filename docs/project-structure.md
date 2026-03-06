# Smart Frame - 프로젝트 구조

디지털 액자 + 영상통화 앱 (Flutter). Android 태블릿 4대에서 동작.

---

## 기술 스택

| 분류 | 기술 | 용도 |
|------|------|------|
| **프레임워크** | Flutter (Dart SDK ^3.10.8) | 크로스플랫폼 UI |
| **영상통화** | WebRTC (flutter_webrtc 1.3.0, M137) | P2P 영상/음성 |
| **시그널링** | Firebase Realtime Database | offer/answer/ICE 교환, 기기 등록 |
| **푸시 알림** | Firebase Cloud Messaging (FCM) | 통화 수신 알림 |
| **얼굴 감지** | Google ML Kit (google_mlkit_face_detection) | 자동 응답 트리거 |
| **카메라** | camera 패키지 | 얼굴 감지용 프리뷰 |
| **TTS** | flutter_tts | 음성 안내 |
| **오디오** | just_audio | 벨소리 재생 |
| **에코 제거** | WebRTC AEC3 + RNNoise v0.2 (NDK/JNI) | 에코/노이즈 억제 |

---

## Firebase 구성

- **프로젝트**: `dcom-smart-frame`
- **RTDB URL**: `https://dcom-smart-frame-default-rtdb.firebaseio.com`
- **패키지명**: `com.example.senior_win`
- **설정 파일**: `android/app/google-services.json`

### RTDB 구조
```
/devices/{deviceId}/
  ├── online: true/false
  ├── fcmToken: "..."
  └── lastSeen: timestamp

/calls/{callId}/
  ├── offer: {sdp, type}
  ├── answer: {sdp, type}
  ├── targetDeviceId: "..."
  ├── status: "waiting" | "answered" | "ended"
  ├── callerCandidates/
  │   └── {candidateId}: {candidate, sdpMid, sdpMLineIndex}
  └── calleeCandidates/
      └── {candidateId}: {candidate, sdpMid, sdpMLineIndex}
```

### Firebase 사용 패키지
- `firebase_core: ^4.4.0` -- Firebase 초기화
- `firebase_messaging: ^16.1.1` -- FCM 푸시 알림
- `firebase_database: ^12.1.3` -- Realtime Database (시그널링 + 기기 등록)

---

## 디렉토리 구조

```
Senior/
├── lib/                                    # Dart 소스 코드
│   ├── main.dart                           # 앱 진입점, AppConfig, 기기 등록
│   ├── screens/
│   │   ├── slideshow_screen.dart           # 슬라이드쇼 + 기기ID 표시 + 터치->기기선택
│   │   ├── incoming_call_screen.dart       # 수신 화면 (벨소리 + 얼굴감지 -> 자동응답)
│   │   ├── video_call_screen.dart          # 영상통화 화면 (수신측)
│   │   ├── outgoing_call_screen.dart       # 발신 대기 + 영상통화 화면
│   │   └── device_list_screen.dart         # 기기 선택 화면 (발신용)
│   ├── services/
│   │   ├── signaling_service.dart          # RTDB 시그널링 (offer/answer/ICE/끊김감지)
│   │   ├── webrtc_service.dart             # WebRTC 연결 관리 (makeCall/answerCall/hangUp)
│   │   ├── fcm_service.dart                # FCM 토큰 관리 + RTDB 저장
│   │   └── face_detection_service.dart     # 얼굴감지 + 워밍업 (cancelWarmup 지원)
│   └── widgets/
│       └── photo_frame_view.dart           # 사진 표시 위젯
│
├── assets/
│   ├── images/                             # 슬라이드쇼 사진 (10장)
│   └── sounds/
│       └── ringtone.mp3                    # 수신 벨소리
│
├── plugins/
│   └── flutter_webrtc/                     # 로컬 패치된 flutter_webrtc 플러그인 (아래 상세 설명)
│       └── android/src/main/
│           ├── java/com/cloudwebrtc/webrtc/
│           │   ├── MethodCallHandlerImpl.java      # [수정] HW AEC 감지 + Field Trials + RNNoise 등록
│           │   └── audio/
│           │       ├── AudioProcessingAdapter.java  # [원본] ExternalAudioProcessingFactory 어댑터
│           │       ├── AudioProcessingController.java # [원본] capturePostProcessing/renderPreProcessing 슬롯
│           │       └── RNNoiseProcessor.java        # [신규] RNNoise Java wrapper (float 버퍼)
│           └── jni/                                 # [신규] 전체 폴더
│               ├── CMakeLists.txt                   # [신규] NDK 빌드 설정 (NEON 최적화)
│               ├── rnnoise_jni.c                    # [신규] JNI 브릿지 (float 처리)
│               └── rnnoise/                         # [외부] RNNoise v0.2 C 소스 (10개 .c + 헤더)
│
├── android/
│   └── app/
│       ├── google-services.json            # Firebase 설정
│       ├── build.gradle                    # Android 빌드 설정
│       └── src/main/AndroidManifest.xml    # 권한 설정
│
├── docs/
│   ├── project-structure.md                # 이 문서
│   └── aec_fix_report.md                   # AEC 에코 제거 수정 보고서
│
├── pubspec.yaml                            # Flutter 의존성 관리
└── CLAUDE.md                               # AI 어시스턴트용 프로젝트 컨텍스트
```

---

## plugins/ -- flutter_webrtc 로컬 패치 + RNNoise

### 왜 로컬 플러그인인가?

`flutter_webrtc` 1.3.0 (pub.dev 원본)은 RK3566처럼 **HW AEC가 없는 기기**에서 에코 제거가 안 되는 버그가 있음.
원인: Android SDK 버전만 보고 HW AEC 사용 여부를 결정 → HW AEC가 없어도 SW AEC(AEC3)를 비활성화.

pub cache의 플러그인을 직접 수정하면 `flutter pub get` 시 원복되므로, 프로젝트 내부(`plugins/`)로 복사하여 로컬 path dependency로 사용.

```yaml
# pubspec.yaml
flutter_webrtc:
  path: plugins/flutter_webrtc
```

### 파일 변경 내역

| 파일 | 상태 | 변경 내용 |
|------|------|-----------|
| `MethodCallHandlerImpl.java` | **수정** | HW AEC 실제 확인 + Field Trials 4개 + RNNoise 등록 |
| `build.gradle` | **수정** | NDK/CMake 빌드 설정 추가 |
| `RNNoiseProcessor.java` | **신규 작성** | RNNoise Java wrapper (ExternalAudioFrameProcessing 구현) |
| `rnnoise_jni.c` | **신규 작성** | JNI 브릿지 (float 버퍼 처리) |
| `CMakeLists.txt` | **신규 작성** | NDK 빌드 설정 (NEON 최적화) |
| `rnnoise/` (10개 .c + 헤더) | **외부 소스 복사** | RNNoise v0.2 tarball에서 복사 |
| `AudioProcessingAdapter.java` | 원본 유지 | ExternalAudioProcessingFactory 어댑터 (변경 없음) |
| `AudioProcessingController.java` | 원본 유지 | capturePostProcessing/renderPreProcessing 슬롯 (변경 없음) |

### 패치 내용 (MethodCallHandlerImpl.java)

1. **HW AEC 실제 확인** (line ~240): `Build.VERSION.SDK_INT >= Q` 대신 `JavaAudioDeviceModule.isBuiltInAcousticEchoCancelerSupported()` 호출
   - HW AEC 없으면 → WebRTC APM이 SW AEC(AEC3) 자동 활성화
2. **AEC3 Field Trials** (line ~200): `PeerConnectionFactory.initialize()` 시 `setFieldTrials()`로 AEC3 튜닝 파라미터 전달
3. **RNNoise 등록** (line ~346): `capturePostProcessing.addProcessor(rnNoiseProcessor)` 호출

### RNNoise 후킹 지점 상세

RNNoise가 WebRTC 오디오 파이프라인에 끼어드는 정확한 경로:

```
MethodCallHandlerImpl.java :: initialize() (line 346~357)
│
├── 1. AudioProcessingController 생성 (line 346)
│      └── 내부에서 ExternalAudioProcessingFactory 생성
│      └── capturePostProcessing (마이크 후처리 슬롯)
│      └── renderPreProcessing (스피커 전처리 슬롯)  ← 현재 미사용
│
├── 2. RNNoiseProcessor 생성 + 등록 (line 349-350)
│      audioProcessingController.capturePostProcessing.addProcessor(rnNoiseProcessor)
│
├── 3. PeerConnectionFactory에 연결 (line 353)
│      factoryBuilder.setAudioProcessingFactory(
│          audioProcessingController.externalAudioProcessingFactory)
│
└── 4. PeerConnectionFactory 생성 (line 355-357)
       이 시점부터 모든 WebRTC 오디오가 이 파이프라인을 통과
```

#### WebRTC 내부에서 호출되는 순서

```
[WebRTC C++ 내부]
  AudioTransportImpl::RecordedDataIsAvailable()    ← OS에서 마이크 데이터 도착
       │
       v
  AudioProcessingImpl::ProcessCaptureStreamLocked()
       │
       ├── AEC3::ProcessCapture()                  ← 에코 제거 (AEC3)
       ├── NoiseSuppression::Analyze/Process()     ← 내장 노이즈 억제 (NS)
       ├── GainControl::ProcessCaptureAudio()      ← 자동 게인 (AGC)
       │
       v
  ExternalAudioProcessingFactory::Process()        ← ★ 여기서 Java로 콜백
       │
       v
[Java - AudioProcessingAdapter.java :: process()]
       │  synchronized(audioProcessors) 블록 안에서 등록된 프로세서 순차 호출
       │
       v
[Java - RNNoiseProcessor.java :: process(numBands=3, numFrames=480, buffer)]
       │  buffer: DirectByteBuffer, 1920 bytes = 480 floats
       │  48kHz가 아니면 return (16kHz 콜백은 skip)
       │  numFrames != 480이면 return
       │
       v
[JNI - rnnoise_jni.c :: nativeProcessFloat()]
       │  float *data = GetDirectBufferAddress(buffer)  ← 복사 없이 직접 접근
       │  rnnoise_process_frame(st, out_float, data)    ← RNNoise GRU 추론
       │  memcpy(data, out_float, 480 * sizeof(float))  ← 결과를 원본 버퍼에 덮어쓰기
       │
       v
  WebRTC가 처리된 버퍼를 인코더로 전달 → 네트워크 전송
```

**핵심**: `ExternalAudioProcessingFactory`가 제공하는 `ByteBuffer`는 WebRTC C++ 내부 메모리를 직접 가리키는 **DirectByteBuffer**. Java/JNI에서 이 버퍼를 in-place로 수정하면 WebRTC가 그 결과를 바로 사용. 별도의 복사가 불필요.

#### 두 개의 콜백 슬롯

| 슬롯 | 위치 | 용도 | 현재 상태 |
|------|------|------|----------|
| `capturePostProcessing` | AEC3/NS/AGC **이후**, 인코더 **이전** | 마이크 신호 후처리 | **RNNoise 등록됨** |
| `renderPreProcessing` | 디코더 **이후**, 스피커 **이전** | 수신 오디오 전처리 | 미사용 |

`capturePostProcessing`에 등록했기 때문에 AEC3가 먼저 에코를 1차 제거한 뒤, RNNoise가 잔여 에코/노이즈를 2차로 억제하는 구조.

### RNNoise 기술 스택

```
[Java] RNNoiseProcessor.java
  │  ExternalAudioFrameProcessing 인터페이스 구현
  │  process(numBands, numFrames, ByteBuffer) 호출
  │
  │  JNI 호출 (System.loadLibrary("rnnoise_jni"))
  v
[C/JNI] rnnoise_jni.c
  │  ByteBuffer에서 float* 직접 접근 (GetDirectBufferAddress)
  │  rnnoise_process_frame() 호출 후 결과를 버퍼에 memcpy
  │
  v
[C] rnnoise/ (v0.2, 10개 소스파일)
  │  denoise.c    -- 메인 프레임 처리 (FFT -> GRU 추론 -> IFFT)
  │  rnn.c        -- GRU/Dense 레이어 구현
  │  nnet.c       -- 신경망 추론 엔진
  │  pitch.c      -- 피치 검출 (코릴레이션 기반)
  │  kiss_fft.c   -- FFT 구현
  │  celt_lpc.c   -- LPC 분석
  │  nnet_default.c, rnnoise_data.c, rnnoise_tables.c -- 학습된 가중치
  │  parse_lpcnet_weights.c -- 가중치 파서
  │
  └── NDK 빌드: CMakeLists.txt (arm64-v8a NEON 최적화)
```

### 핵심 발견 사항

- `ExternalAudioProcessingFactory`의 버퍼는 **float** 데이터 (int16 아님!)
- `numBands=3, numFrames=480, bufCap=1920` → 480개 float (3 bands x 160 samples)
- 초기에 int16으로 읽어서 지지직 소리 발생 → float 처리로 수정하여 해결
- RNNoise는 48kHz 전용 (16kHz 초기화 콜백은 자동 skip, 48kHz 콜백에서만 동작)
- `DirectByteBuffer`라서 JNI에서 zero-copy로 in-place 수정 가능

---

## 대상 기기

| 모델 | deviceId | SoC | HW AEC | 비고 |
|------|----------|-----|--------|------|
| Galaxy Tab A7 (SM-T500) | RP1A_200720_012 | Snapdragon 662 | **있음** (Qualcomm) | 정상 |
| A20 | 미확인 | Allwinner A523 | 미확인 | 정상 |
| RK3566 (rk3566_t) | TQ3C_230805_001_B2 | RK3566 | **없음** | AEC 문제 기기 |
| YC-102P (rk3566_r) | RD2A_211001_002 | RK3566 | **없음** | WiFi 필요 |

---

## 통화 흐름

```
[슬라이드쇼] ──터치──> [기기 선택] ──발신──> [발신 대기]
                                              │
                          offer + targetDeviceId (RTDB)
                                              │
                                              v
[슬라이드쇼] <──FCM──  [수신 알림] ──> [수신 화면]
                                         │
                                    얼굴 감지 (자동) 또는 터치
                                         │
                                    answer (RTDB)
                                         │
                                    ICE 교환
                                         │
                                    WebRTC P2P 연결
                                         │
                                    [영상통화]
                                         │
                                    한쪽 종료
                                         │
                              status='ended' -> 2초 후 노드 삭제
```

---

## 빌드 & 배포

```bash
# 빌드
flutter build apk --release

# 설치
adb -s <serial> install -r build/app/outputs/flutter-apk/app-release.apk

# 앱 시작
adb -s <serial> shell monkey -p com.example.senior_win -c android.intent.category.LAUNCHER 1

# 로그 확인
adb -s <serial> shell logcat --pid=$(adb -s <serial> shell pidof com.example.senior_win)
```

---

## 주요 의존성 (pubspec.yaml)

| 패키지 | 버전 | 용도 |
|--------|------|------|
| `flutter_webrtc` | 로컬 (plugins/) | WebRTC 영상통화 |
| `firebase_core` | ^4.4.0 | Firebase 초기화 |
| `firebase_database` | ^12.1.3 | RTDB 시그널링/기기등록 |
| `firebase_messaging` | ^16.1.1 | FCM 푸시 알림 |
| `camera` | ^0.11.4 | 얼굴 감지용 카메라 |
| `google_mlkit_face_detection` | ^0.13.2 | ML Kit 얼굴 감지 |
| `just_audio` | ^0.10.5 | 벨소리 재생 |
| `flutter_tts` | ^4.2.5 | 음성 안내 |
| `wakelock_plus` | ^1.4.0 | 화면 꺼짐 방지 |
| `permission_handler` | ^12.0.1 | 권한 요청 |
| `device_info_plus` | ^11.3.3 | 기기 ID 추출 |
