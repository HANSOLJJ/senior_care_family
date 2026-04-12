import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';

/// Senior 태블릿 디바이스 프로필 (`Model`)
///
/// assets/device_profiles/{model}.json 파일에서 로드.
/// 기기별 디스플레이 해상도, 사진 압축 품질, 저장 한도 등을 정의.
/// Family 앱이 사진 업로드 시 이 프로필 기반으로 리사이즈/압축.
///
/// - **섹션 구성**:
///   - 속성 — 기기 모델, 디스플레이, 사진 압축, 저장 한도
///   - 팩토리 — fromJson() (JSON → DeviceProfile 변환)
///   - 기본값 — fallback (프로필 로드 실패 시 사용)
class DeviceProfile {

  // ─── 속성 ───

  /// Senior 태블릿 모델명 (예: "SM-T500")
  final String model;

  /// 기기 표시 이름 (예: "Galaxy Tab A7")
  final String name;

  /// 디스플레이 가로 해상도 (px)
  final int displayWidth;

  /// 디스플레이 세로 해상도 (px)
  final int displayHeight;

  /// 디스플레이 밀도 (DPI)
  final int displayDensity;

  /// 사진 최대 해상도 — 긴 변 기준 (px, 리사이즈 상한)
  final int maxResolution;

  /// JPEG 압축 품질 (0~100, 높을수록 고화질)
  final int jpegQuality;

  /// 최대 저장 사진 수
  final int maxPhotos;

  /// 최대 총 저장 용량 (MB)
  final int maxTotalMB;

  // ─── 생성자 ───

  /// DeviceProfile 생성자 (`Constructor`)
  ///
  /// - **Params**:
  ///   - [model] — Senior 태블릿 모델명
  ///   - [name] — 기기 표시 이름
  ///   - [displayWidth] — 디스플레이 가로 해상도 (px)
  ///   - [displayHeight] — 디스플레이 세로 해상도 (px)
  ///   - [displayDensity] — 디스플레이 밀도 (DPI)
  ///   - [maxResolution] — 사진 최대 해상도 (px)
  ///   - [jpegQuality] — JPEG 압축 품질 (0~100)
  ///   - [maxPhotos] — 최대 저장 사진 수
  ///   - [maxTotalMB] — 최대 총 저장 용량 (MB)
  const DeviceProfile({
    required this.model,
    required this.name,
    required this.displayWidth,
    required this.displayHeight,
    required this.displayDensity,
    required this.maxResolution,
    required this.jpegQuality,
    required this.maxPhotos,
    required this.maxTotalMB,
  });

  // ─── 팩토리 ───

  /// JSON에서 DeviceProfile 생성 (`Factory`)
  ///
  /// assets/device_profiles/{model}.json 파일의 구조:
  /// ```json
  /// {
  ///   "model": "SM-T500",
  ///   "name": "Galaxy Tab A7",
  ///   "display": { "width": 1920, "height": 1200, "density": 224 },
  ///   "photo": { "maxResolution": 1920, "jpegQuality": 80 },
  ///   "storage": { "maxPhotos": 500, "maxTotalMB": 5000 }
  /// }
  /// ```
  ///
  /// - **Params**:
  ///   - [json] — JSON 디코딩된 Map
  /// - **Returns**: `DeviceProfile` — 파싱된 프로필 인스턴스
  /// - **호출**: [AppConfig.loadDeviceProfile]에서 호출
  factory DeviceProfile.fromJson(Map<String, dynamic> json) {
    final display = json['display'] as Map<String, dynamic>;
    final photo = json['photo'] as Map<String, dynamic>;
    final storage = json['storage'] as Map<String, dynamic>;
    return DeviceProfile(
      model: json['model'] as String,
      name: json['name'] as String,
      displayWidth: display['width'] as int,
      displayHeight: display['height'] as int,
      displayDensity: display['density'] as int,
      maxResolution: photo['maxResolution'] as int,
      jpegQuality: photo['jpegQuality'] as int,
      maxPhotos: storage['maxPhotos'] as int,
      maxTotalMB: storage['maxTotalMB'] as int,
    );
  }

  // ─── 기본값 ───

  /// 기본값 프로필 — 프로필 JSON 로드 실패 시 폴백 (`Constant`)
  ///
  /// 중간 사양 기준으로 설정 (1920px, JPEG 80%, 500장, 5GB)
  static const fallback = DeviceProfile(
    model: 'unknown',
    name: 'Unknown Tablet',
    displayWidth: 1920,
    displayHeight: 1200,
    displayDensity: 224,
    maxResolution: 1920,
    jpegQuality: 80,
    maxPhotos: 500,
    maxTotalMB: 5000,
  );
}

/// 앱 설정 싱글톤 (`Singleton`)
///
/// 앱 시작 시 initialize()로 기기 정보 수집.
/// - deviceModel: 현재 Family 폰의 모델명
/// - deviceId: Android=ANDROID_ID, iOS=identifierForVendor
/// - targetDevice: 연결된 Senior 태블릿의 디바이스 프로필 (사진 압축 설정 등)
///
/// Family 기기는 /devices/에 등록하지 않음 — /users/{uid}로만 식별.
///
/// - **섹션 구성**:
///   - 정적 필드 — deviceModel, deviceId, targetDevice
///   - 초기화 — initialize() (기기 정보 수집)
///   - 프로필 로드 — loadDeviceProfile() (Senior 태블릿 프로필)
class AppConfig {

  // ─── 정적 필드 ───

  /// 현재 Family 폰의 모델명 (예: "SM-G991N")
  static String deviceModel = 'unknown';

  /// 현재 Family 폰의 고유 ID (Android: ANDROID_ID, iOS: identifierForVendor)
  static String deviceId = '';

  /// 현재 연결된 Senior 태블릿 프로필 (사진 리사이즈/압축 설정 참조용)
  static DeviceProfile targetDevice = DeviceProfile.fallback;

  // ─── 초기화 ───

  /// 장치 정보 읽기 (`Method`, async)
  ///
  /// Platform 분기로 Android/iOS 각각의 기기 정보를 수집.
  /// Android: MethodChannel로 ANDROID_ID 획득 시도, 실패 시 Build.ID 폴백.
  /// iOS: identifierForVendor 사용.
  ///
  /// - **Params**: 없음
  /// - **Returns**: `Future<void>`
  /// - **Side Effects**:
  ///   - [deviceModel] 설정
  ///   - [deviceId] 설정
  /// - **호출**: [main]에서 앱 시작 시 호출
  static Future<void> initialize() async {
    final deviceInfo = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final android = await deviceInfo.androidInfo;
      deviceModel = android.model;
      try {
        const channel = MethodChannel('com.seniorcare.family/device');
        final androidId = await channel.invokeMethod<String>('getAndroidId');
        deviceId = androidId ?? android.id.replaceAll(RegExp(r'[.#$\[\]]'), '_');
      } catch (e) {
        deviceId = android.id.replaceAll(RegExp(r'[.#$\[\]]'), '_');
        print('ANDROID_ID 가져오기 실패, fallback 사용: $e');
      }
    } else if (Platform.isIOS) {
      final ios = await deviceInfo.iosInfo;
      deviceModel = ios.model;
      deviceId = ios.identifierForVendor ?? 'unknown';
    }
    print('AppConfig: model=$deviceModel, id=$deviceId');
  }

  // ─── 프로필 로드 ───

  /// Senior 태블릿 모델명으로 프로필 로드 (`Method`, async)
  ///
  /// assets/device_profiles/{seniorModel}.json 파일을 읽어 DeviceProfile로 변환.
  /// 파일이 없거나 파싱 실패 시 DeviceProfile.fallback 사용.
  ///
  /// - **Params**:
  ///   - [seniorModel] — Senior 태블릿 모델명 (예: "SM-T500")
  /// - **Returns**: `Future<void>`
  /// - **Side Effects**: [targetDevice] 갱신
  /// - **호출**: Senior 태블릿 연결 시 (기기 상세 화면 등에서)
  static Future<void> loadDeviceProfile(String seniorModel) async {
    try {
      final jsonStr = await rootBundle.loadString(
        'assets/device_profiles/$seniorModel.json',
      );
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      targetDevice = DeviceProfile.fromJson(json);
      print('디바이스 프로필 로드: ${targetDevice.name} (${targetDevice.maxResolution}px)');
    } catch (e) {
      print('디바이스 프로필 없음 ($seniorModel) → 기본값 사용');
      targetDevice = DeviceProfile.fallback;
    }
  }

  // Family 기기는 /devices/에 등록하지 않음.
  // Family 사용자는 /users/{uid}로만 식별.
}
