import 'package:firebase_database/firebase_database.dart';
import 'package:device_info_plus/device_info_plus.dart';

/// 앱 설정 싱글톤
class AppConfig {
  static String deviceModel = 'unknown';
  static String deviceId = '';

  /// 장치 정보 읽기
  static Future<void> initialize() async {
    final deviceInfo = DeviceInfoPlugin();
    final android = await deviceInfo.androidInfo;
    deviceModel = android.model;
    deviceId = android.id.replaceAll(RegExp(r'[.#$\[\]]'), '_');
    print('AppConfig: model=$deviceModel, id=$deviceId');
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
