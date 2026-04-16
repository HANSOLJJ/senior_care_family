import 'dart:io';
import 'dart:typed_data';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../firebase_instances_mixin.dart';
import '../network_guard.dart';

/// 영상 알림 데이터 모델 (`Model`)
///
/// RTDB `/families/{fid}/reminders/{rid}` 의 데이터를 Dart 객체로 매핑.
/// Senior 태블릿에서 설정된 시간에 영상/음성을 재생하는 복약 알림.
///
/// - **섹션 구성**:
///   - 속성 — 알림 메타데이터 (제목, 미디어, 스케줄 등)
///   - 팩토리 — fromMap() (RTDB 스냅샷 → Reminder 변환)
///   - 유틸리티 — repeatLabel (반복 주기 한글 변환)
class Reminder {

  // ─── 속성 ───

  /// RTDB push key (알림 고유 ID)
  final String id;

  /// 알림 제목 (예: "혈압약", "비타민")
  final String title;

  /// 미디어 파일 다운로드 URL (Storage)
  final String mediaUrl;

  /// 미디어 유형: "video" (mp4) 또는 "audio" (m4a)
  final String mediaType;

  /// 미디어 재생 길이 (초)
  final int mediaDuration;

  /// 알림 시간 ("HH:mm" 형식, 예: "08:00")
  final String time;

  /// 반복 주기: "daily" | "weekdays" | "weekend" | "custom" | "test_5min"
  final String repeat;

  /// custom 반복 시 요일 목록 (1=월 ~ 7=일)
  final List<int> days;

  /// 알림 활성 여부 (false면 Senior에서 알람 등록 안 함)
  final bool enabled;

  /// 알림 생성자 Firebase UID
  final String createdBy;

  /// 알림 생성자 표시 이름
  final String createdByName;

  /// 생성 시각 (밀리초 타임스탬프)
  final int? createdAt;

  /// 최종 수정 시각 (밀리초 타임스탬프)
  final int? updatedAt;

  // ─── 생성자 ───

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

  // ─── 팩토리 ───

  /// RTDB 스냅샷에서 Reminder 생성 (`Factory`)
  ///
  /// - **Params**:
  ///   - [id] — RTDB push key
  ///   - [map] — RTDB value Map
  /// - **Returns**: `Reminder` — null-safe 기본값 적용
  /// - **호출**: [ReminderService.watchReminders]에서 각 항목 변환
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

  // ─── 유틸리티 ───

  /// 반복 주기를 한글 라벨로 변환 (`Getter`)
  ///
  /// - **Returns**: `String` — "매일", "평일", "주말", "월, 수, 금", "5분 반복" 등
  /// - **호출**: reminder_list_screen.dart, reminder_edit_screen.dart에서 표시용
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
///
/// RTDB 경로: /families/{fid}/reminders/{rid}
/// Storage 경로: /families/{fid}/reminders/{rid}/{rid}.mp4
///
/// 흐름:
///   createReminder() — 영상/음성 파일 Storage 업로드 + RTDB 메타데이터 생성
///   updateReminder() — 제목/시간/반복/활성 상태 수정 (미디어 변경 시 재업로드)
///   deleteReminder() — RTDB 노드 삭제 → CF(onReminderDeleted)가 Storage 자동 삭제
///   getReminders() — 전체 알림 목록 조회 (1회성)
///   watchReminders() — onValue 스트림으로 실시간 감시
///
/// Senior가 미디어 다운로드 완료 시 mediaDownloaded:true 업데이트
/// → CF(onReminderMediaDownloaded)가 Storage 파일 삭제 (임시 버퍼 패턴)
class ReminderService with FirebaseInstancesMixin {

  // ─── 생성 ───

  /// 알림 생성: 미디어 업로드 + RTDB 메타데이터 기록 (`Method`, async)
  ///
  /// - **Params**:
  ///   - [familyId] — 대상 가족 그룹 ID
  ///   - [title] — 알림 제목
  ///   - [time] — 알림 시간 ("HH:mm")
  ///   - [repeat] — 반복 주기
  ///   - [days] — custom 반복 시 요일 목록
  ///   - [mediaFile] — 영상/음성 파일
  ///   - [mediaType] — "video" 또는 "audio"
  ///   - [onProgress] — 업로드 진행률 콜백 (0.0 ~ 1.0)
  /// - **Returns**: `String` — 생성된 reminderId
  /// - **Side Effects**: Storage 업로드 + RTDB 노드 생성
  /// - **호출**: reminder_edit_screen.dart 저장 버튼
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
    final user = auth.currentUser;
    if (user == null) throw Exception('로그인 필요');

    final reminderId = db.ref().push().key!;

    // 1. Storage 업로드
    final ext = mediaType == 'video' ? 'mp4' : 'm4a';
    final storagePath = 'families/$familyId/reminders/$reminderId/$reminderId.$ext';
    final ref = storage.ref(storagePath);

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
    final reminderRef = db.ref('families/$familyId/reminders/$reminderId');
    await writeOrTimeout(
      () => reminderRef.set({
        'title': title,
        'mediaUrl': downloadUrl,
        'mediaType': mediaType,
        'mediaDuration': 0,
        'schedule': {
          'time': time,
          'repeat': repeat,
          if (repeat == 'custom') 'days': days,
        },
        'enabled': true,
        'createdBy': user.uid,
        'mediaDownloaded': false,
        'createdAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
      }),
      label: '알림 생성',
      onTimeoutCleanup: () => reminderRef.remove(),
    );
    print('Reminder 생성: $reminderId');

    return reminderId;
  }

  // ─── 수정 ───

  /// 알림 수정 — 미디어 변경 시 재업로드 (`Method`, async)
  ///
  /// 제목/시간/반복만 변경 시 RTDB update만 수행.
  /// mediaFile이 전달되면 기존 Storage 파일 삭제 후 재업로드 + mediaDownloaded=false 리셋.
  ///
  /// - **Params**:
  ///   - [familyId], [reminderId] — 대상 식별
  ///   - [title], [time], [repeat], [days] — 변경할 필드 (null이면 미변경)
  ///   - [mediaFile], [mediaType] — 미디어 변경 시 전달
  ///   - [onProgress] — 재업로드 진행률 콜백
  /// - **Side Effects**: RTDB update + (선택) Storage 재업로드
  /// - **호출**: reminder_edit_screen.dart 저장 버튼
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
      final snapshot = await db
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
      // 기존 파일 전체 삭제 (파일명이 바뀔 수 있으므로 폴더 내 전부)
      try {
        final listResult = await storage
            .ref('families/$familyId/reminders/$reminderId')
            .listAll();
        for (final item in listResult.items) {
          await item.delete();
        }
      } catch (_) {}

      // 새 파일 업로드
      final ext = mediaType == 'video' ? 'mp4' : 'm4a';
      final storagePath =
          'families/$familyId/reminders/$reminderId/$reminderId.$ext';
      final ref = storage.ref(storagePath);
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
      updates['mediaDownloaded'] = false; // Senior 재다운로드 필요
      print('Reminder 미디어 재업로드: $storagePath');
    }

    await db.ref('families/$familyId/reminders/$reminderId').update(updates);
    print('Reminder 수정: $reminderId');
  }

  // ─── 삭제 ───

  /// 알림 삭제 — RTDB 노드 제거 (`Method`, async)
  ///
  /// RTDB 노드 삭제 → CF(onReminderDeleted)가 Storage 삭제
  /// → Senior onValue 감지 → 알람 취소 + 로컬 미디어 삭제
  ///
  /// - **Params**:
  ///   - [familyId] — 가족 그룹 ID
  ///   - [reminderId] — 삭제할 알림 ID
  /// - **Side Effects**: RTDB 노드 삭제 → CF 트리거
  /// - **호출**: reminder_list_screen.dart 스와이프 삭제
  Future<void> deleteReminder(String familyId, String reminderId) async {
    await db.ref('families/$familyId/reminders/$reminderId').remove();
    print('Reminder 삭제: $reminderId');
  }

  // ─── 토글 ───

  /// 알림 ON/OFF 토글 (`Method`, async)
  ///
  /// - **Params**:
  ///   - [familyId] — 가족 그룹 ID
  ///   - [reminderId] — 토글 대상 알림 ID
  ///   - [enabled] — true(활성) / false(비활성)
  /// - **Side Effects**: RTDB enabled + updatedAt 업데이트
  /// - **호출**: reminder_list_screen.dart Switch 위젯
  Future<void> toggleReminder(
      String familyId, String reminderId, bool enabled) async {
    await db.ref('families/$familyId/reminders/$reminderId').update({
      'enabled': enabled,
      'updatedAt': ServerValue.timestamp,
    });
    print('Reminder 토글: $reminderId → $enabled');
  }

  // ─── 실시간 감시 ───

  /// 알림 목록 실시간 스트림 (`Stream`)
  ///
  /// onValue로 전체 스냅샷을 구독하여 Reminder 리스트로 변환.
  /// 시간순 정렬 (time 오름차순).
  ///
  /// - **Params**:
  ///   - [familyId] — 감시 대상 가족 그룹 ID
  /// - **Returns**: `Stream<List<Reminder>>` — 알림 목록 스트림
  /// - **호출**: reminder_list_screen.dart에서 구독
  Stream<List<Reminder>> watchReminders(String familyId) {
    return db.ref('families/$familyId/reminders').onValue.map((event) {
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
