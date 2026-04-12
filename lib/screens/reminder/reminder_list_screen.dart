import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/reminder/reminder_service.dart';
import 'reminder_edit_screen.dart';

/// 영상 알림 목록 화면 (`StatefulWidget`)
///
/// RTDB `/families/{fid}/reminders/` 를 onValue 스트림으로 실시간 감시.
/// 각 알림 카드에 제목, 시간, 반복 주기, 활성/비활성 토글 표시.
///
/// - **섹션 구성**:
///   - 데이터 감시 — watchReminders 스트림 구독
///   - 네비게이션 — 추가(ReminderEditScreen), 수정, 삭제
///   - UI — ListView + 빈 상태 + FAB
class ReminderListScreen extends StatefulWidget {
  /// 대상 가족 그룹 ID
  final String familyId;

  const ReminderListScreen({super.key, required this.familyId});

  @override
  State<ReminderListScreen> createState() => _ReminderListScreenState();
}

/// [ReminderListScreen]의 `State`
///
/// ReminderService.watchReminders() 스트림을 구독하여 _reminders 목록 갱신.
class _ReminderListScreenState extends State<ReminderListScreen> {

  // ─── 상태 필드 ───

  /// 알림 CRUD 서비스
  final _service = ReminderService();

  /// watchReminders 스트림 구독 (dispose 시 해제)
  StreamSubscription? _sub;

  /// 현재 알림 목록 (시간순 정렬)
  List<Reminder> _reminders = [];

  /// 초기 로딩 중 여부
  bool _loading = true;

  // ─── 라이프사이클 ───

  /// 초기화 — 알림 스트림 구독 시작 (`Lifecycle`)
  ///
  /// - **Side Effects**: _sub 등록, _reminders 갱신
  /// - **호출**: Flutter 프레임워크
  @override
  void initState() {
    super.initState();
    _sub = _service.watchReminders(widget.familyId).listen((list) {
      if (mounted) setState(() {
        _reminders = list;
        _loading = false;
      });
    });
  }

  /// 스트림 구독 해제 (`Lifecycle`)
  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // ─── 네비게이션 ───

  /// 알림 추가 화면으로 이동 (`Method`, async)
  ///
  /// - **Returns**: `Future<void>`
  /// - **Side Effects**: Navigator push → ReminderEditScreen(생성 모드)
  /// - **호출**: AppBar + 아이콘, 빈 상태 버튼, FAB
  Future<void> _addReminder() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ReminderEditScreen(familyId: widget.familyId),
      ),
    );
    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('알림이 추가되었습니다')),
      );
    }
  }

  /// 알림 수정 화면으로 이동 (`Method`, async)
  ///
  /// - **Params**:
  ///   - [reminder] — 수정할 알림 객체
  /// - **Side Effects**: Navigator push → ReminderEditScreen(수정 모드)
  /// - **호출**: ListTile onTap
  Future<void> _editReminder(Reminder reminder) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ReminderEditScreen(
          familyId: widget.familyId,
          existing: reminder,
        ),
      ),
    );
    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('알림이 수정되었습니다')),
      );
    }
  }

  /// 알림 삭제 확인 다이얼로그 + 삭제 실행 (`Method`, async)
  ///
  /// - **Params**:
  ///   - [reminder] — 삭제할 알림 객체
  /// - **Side Effects**: 확인 시 ReminderService.deleteReminder() → RTDB 노드 삭제
  /// - **호출**: ListTile onLongPress
  Future<void> _deleteReminder(Reminder reminder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('알림 삭제'),
        content: Text('"${reminder.title}" 알림을 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _service.deleteReminder(widget.familyId, reminder.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('알림이 삭제되었습니다')),
        );
      }
    }
  }

  // ─── UI 빌드 ───

  /// 메인 화면 빌드 (`Widget Builder`)
  ///
  /// - **구성**:
  ///   - 로딩 중: CircularProgressIndicator
  ///   - 빈 상태: 아이콘 + 안내 + "알림 추가" 버튼
  ///   - 목록: ListView.builder + _buildReminderTile
  ///
  /// - **Returns**: `Widget` — 전체 화면
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('영상 알림'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _addReminder,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _reminders.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.notifications_none,
                          size: 64, color: Colors.grey.shade400),
                      const SizedBox(height: 16),
                      Text('등록된 알림이 없습니다',
                          style: TextStyle(
                              fontSize: 16, color: Colors.grey.shade600)),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: _addReminder,
                        icon: const Icon(Icons.add),
                        label: const Text('알림 추가'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _reminders.length,
                  itemBuilder: (context, index) =>
                      _buildReminderTile(_reminders[index]),
                ),
    );
  }

  /// 알림 카드 타일 위젯 (`Widget Builder`)
  ///
  /// - **Params**:
  ///   - [reminder] — 표시할 알림 객체
  /// - **Returns**: `Widget` — ListTile (아이콘 + 제목 + 시간/반복 + Switch)
  /// - **동작**:
  ///   - 탭: _editReminder (수정 화면)
  ///   - 길게 누르기: _deleteReminder (삭제 확인)
  ///   - Switch: toggleReminder (ON/OFF 토글)
  Widget _buildReminderTile(Reminder reminder) {
    return ListTile(
      leading: Icon(
        reminder.mediaType == 'video' ? Icons.videocam : Icons.mic,
        color: reminder.enabled ? Colors.deepPurple : Colors.grey,
        size: 32,
      ),
      title: Text(
        reminder.title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: reminder.enabled ? null : Colors.grey,
        ),
      ),
      subtitle: Text(
        '${reminder.repeatLabel}  ${reminder.time}',
        style: TextStyle(
          color: reminder.enabled ? null : Colors.grey,
        ),
      ),
      trailing: Switch(
        value: reminder.enabled,
        onChanged: (v) =>
            _service.toggleReminder(widget.familyId, reminder.id, v),
      ),
      onTap: () => _editReminder(reminder),
      onLongPress: () => _deleteReminder(reminder),
    );
  }
}
