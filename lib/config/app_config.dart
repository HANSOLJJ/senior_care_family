import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:device_info_plus/device_info_plus.dart';

/// Senior 태블릿 디바이스 프로필 (JSON에서 로드)
class DeviceProfile {
  final String model;
  final String name;
  final int displayWidth;
  final int displayHeight;
  final int displayDensity;
  final int maxResolution;
  final int jpegQuality;
  final int maxPhotos;
  final int maxTotalMB;

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

  /// 기본값 (프로필 로드 실패 시)
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

/// 앱 설정 싱글톤
class AppConfig {
  static String deviceModel = 'unknown';
  static String deviceId = '';

  /// 현재 연결된 Senior 태블릿 프로필
  static DeviceProfile targetDevice = DeviceProfile.fallback;

  /// 장치 정보 읽기
  static Future<void> initialize() async {
    final deviceInfo = DeviceInfoPlugin();
    final android = await deviceInfo.androidInfo;
    deviceModel = android.model;
    deviceId = android.id.replaceAll(RegExp(r'[.#$\[\]]'), '_');
    print('AppConfig: model=$deviceModel, id=$deviceId');
  }

  /// Senior 태블릿 모델명으로 프로필 로드
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

  /// Firebase RTDB에 기기 등록 + onDisconnect 설정
  static Future<void> registerDevice() async {
    if (deviceId.isEmpty) return;
    final db = FirebaseDatabase.instance;
    final deviceRef = db.ref('devices/$deviceId');

    await deviceRef.update({
      'model': deviceModel,
      'name': deviceModel,
      'lastSeen': ServerValue.timestamp,
      'online': true,
    });
    await deviceRef.onDisconnect().update({
      'online': false,
      'lastSeen': ServerValue.timestamp,
    });
    print('기기 등록 완료: $deviceModel ($deviceId)');

    db.ref('.info/connected').onValue.listen((event) async {
      final connected = event.snapshot.value as bool? ?? false;
      if (connected) {
        print('RTDB 재연결 → online 복구');
        await deviceRef.update({
          'online': true,
          'lastSeen': ServerValue.timestamp,
        });
        await deviceRef.onDisconnect().update({
          'online': false,
          'lastSeen': ServerValue.timestamp,
        });
      }
    });
  }
}
