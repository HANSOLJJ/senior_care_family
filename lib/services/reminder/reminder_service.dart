import 'dart:io';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// 영상 알림 데이터 모델
class Reminder {
  final String id;
  final String title;
  final String mediaUrl;
  final String mediaType; // "video" | "audio"
  final int mediaDuration; // 초
  final String time; // "HH:mm"
  final String repeat; // "daily" | "weekdays" | "weekend" | "custom"
  final List<int> days; // custom일 때 요일 (1=월 ~ 7=일)
  final bool enabled;
  final String createdBy;
  final String createdByName;
  final int? createdAt;
  final int? updatedAt;

  Reminder({
    required this.id,
    required this.title,
    required this.mediaUrl,
    required this.mediaType,
    this.mediaDuration = 0,
    required this.time,
    required this.repeat,
    this.days = const [],
    this.enabled = true,
    required this.createdBy,
    required this.createdByName,
    this.createdAt,
    this.updatedAt,
  });

  factory Reminder.fromMap(String id, Map<dynamic, dynamic> map) {
    final schedule = map['schedule'] as Map<dynamic, dynamic>? ?? {};
    final daysList = schedule['days'];
    return Reminder(
      id: id,
      title: map['title'] ?? '',
      mediaUrl: map['mediaUrl'] ?? '',
      mediaType: map['mediaType'] ?? 'video',
      mediaDuration: (map['mediaDuration'] ?? 0) as int,
      time: schedule['time'] ?? '08:00',
      repeat: schedule['repeat'] ?? 'daily',
      days: daysList != null ? List<int>.from(daysList) : [],
      enabled: map['enabled'] ?? true,
      createdBy: map['createdBy'] ?? '',
      createdByName: map['createdByName'] ?? '',
      createdAt: map['createdAt'] as int?,
      updatedAt: map['updatedAt'] as int?,
    );
  }

  String get repeatLabel {
    switch (repeat) {
      case 'daily':
        return '매일';
      case 'weekdays':
        return '평일';
      case 'weekend':
        return '주말';
      case 'custom':
        const dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];
        return days.map((d) => dayNames[d]).join(', ');
      case 'test_5min':
        return '5분 반복';
      default:
        return repeat;
    }
  }
}

/// 영상 알림 CRUD + Storage 서비스
class ReminderService {
  final FirebaseDatabase _db = FirebaseDatabase.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// 알림 생성: 미디어 업로드 + RTDB 쓰기
  Future<String> createReminder({
    required String familyId,
    required String title,
    required String time,
    required String repeat,
    List<int> days = const [],
    required File mediaFile,
    required String mediaType,
    void Function(double progress)? onProgress,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('로그인 필요');

    final reminderId = _db.ref().push().key!;

    // 1. Storage 업로드
    final ext = mediaType == 'video' ? 'mp4' : 'm4a';
    final storagePath = 'families/$familyId/reminders/$reminderId/media.$ext';
    final ref = _storage.ref(storagePath);

    final bytes = await mediaFile.readAsBytes();
    final uploadTask = ref.putData(
      Uint8List.fromList(bytes),
      SettableMetadata(
        contentType: mediaType == 'video' ? 'video/mp4' : 'audio/m4a',
      ),
    );

    uploadTask.snapshotEvents.listen((snapshot) {
      if (snapshot.totalBytes > 0) {
        onProgress?.call(snapshot.bytesTransferred / snapshot.totalBytes);
      }
    });

    await uploadTask;
    final downloadUrl = await ref.getDownloadURL();
    print('Reminder 미디어 업로드: $storagePath');

    // 2. 미디어 길이 측정은 caller가 전달 (image_picker의 duration)

    // 3. RTDB 쓰기
    await _db.ref('families/$familyId/reminders/$reminderId').set({
      'title': title,
      'mediaUrl': downloadUrl,
      'mediaType': mediaType,
      'mediaDuration': 0, // edit screen에서 설정
      'schedule': {
        'time': time,
        'repeat': repeat,
        if (repeat == 'custom') 'days': days,
      },
      'enabled': true,
      'createdBy': user.uid,
      'createdByName': user.displayName ?? '가족',
      'createdAt': ServerValue.timestamp,
      'updatedAt': ServerValue.timestamp,
    });
    print('Reminder 생성: $reminderId');

    return reminderId;
  }

  /// 알림 수정 (미디어 변경 시 재업로드)
  Future<void> updateReminder({
    required String familyId,
    required String reminderId,
    String? title,
    String? time,
    String? repeat,
    List<int>? days,
    File? mediaFile,
    String? mediaType,
    void Function(double progress)? onProgress,
  }) async {
    final updates = <String, dynamic>{
      'updatedAt': ServerValue.timestamp,
    };

    if (title != null) updates['title'] = title;

    if (time != null || repeat != null || days != null) {
      // 기존 schedule 읽어서 merge
      final snapshot = await _db
          .ref('families/$familyId/reminders/$reminderId/schedule')
          .get();
      final existing =
          snapshot.value != null ? Map<String, dynamic>.from(snapshot.value as Map) : <String, dynamic>{};
      if (time != null) existing['time'] = time;
      if (repeat != null) existing['repeat'] = repeat;
      if (days != null) existing['days'] = days;
      if (repeat != null && repeat != 'custom') existing.remove('days');
      updates['schedule'] = existing;
    }

    // 미디어 변경
    if (mediaFile != null && mediaType != null) {
      // 기존 파일 삭제
      try {
        final oldExt = mediaType == 'video' ? 'mp4' : 'm4a';
        await _storage
            .ref('families/$familyId/reminders/$reminderId/media.$oldExt')
            .delete();
      } catch (_) {}

      // 새 파일 업로드
      final ext = mediaType == 'video' ? 'mp4' : 'm4a';
      final storagePath =
          'families/$familyId/reminders/$reminderId/media.$ext';
      final ref = _storage.ref(storagePath);
      final bytes = await mediaFile.readAsBytes();
      final uploadTask = ref.putData(
        Uint8List.fromList(bytes),
        SettableMetadata(
          contentType: mediaType == 'video' ? 'video/mp4' : 'audio/m4a',
        ),
      );

      uploadTask.snapshotEvents.listen((snapshot) {
        if (snapshot.totalBytes > 0) {
          onProgress?.call(snapshot.bytesTransferred / snapshot.totalBytes);
        }
      });

      await uploadTask;
      updates['mediaUrl'] = await ref.getDownloadURL();
      updates['mediaType'] = mediaType;
      print('Reminder 미디어 재업로드: $storagePath');
    }

    await _db.ref('families/$familyId/reminders/$reminderId').update(updates);
    print('Reminder 수정: $reminderId');
  }

  /// 알림 삭제
  Future<void> deleteReminder(String familyId, String reminderId) async {
    // Storage 삭제
    try {
      final listResult = await _storage
          .ref('families/$familyId/reminders/$reminderId')
          .listAll();
      for (final item in listResult.items) {
        await item.delete();
      }
    } catch (e) {
      print('Reminder Storage 삭제 실패: $e');
    }

    // RTDB 삭제
    await _db.ref('families/$familyId/reminders/$reminderId').remove();
    print('Reminder 삭제: $reminderId');
  }

  /// ON/OFF 토글
  Future<void> toggleReminder(
      String familyId, String reminderId, bool enabled) async {
    await _db.ref('families/$familyId/reminders/$reminderId').update({
      'enabled': enabled,
      'updatedAt': ServerValue.timestamp,
    });
    print('Reminder 토글: $reminderId → $enabled');
  }

  /// 실시간 알림 목록 스트림
  Stream<List<Reminder>> watchReminders(String familyId) {
    return _db.ref('families/$familyId/reminders').onValue.map((event) {
      final data = event.snapshot.value;
      if (data == null) return <Reminder>[];
      final map = Map<String, dynamic>.from(data as Map);
      return map.entries.map((e) {
        return Reminder.fromMap(e.key, Map<dynamic, dynamic>.from(e.value as Map));
      }).toList()
        ..sort((a, b) => a.time.compareTo(b.time));
    });
  }
}
