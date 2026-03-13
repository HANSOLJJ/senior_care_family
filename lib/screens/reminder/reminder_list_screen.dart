import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/reminder/reminder_service.dart';
import 'reminder_edit_screen.dart';

class ReminderListScreen extends StatefulWidget {
  final String familyId;

  const ReminderListScreen({super.key, required this.familyId});

  @override
  State<ReminderListScreen> createState() => _ReminderListScreenState();
}

class _ReminderListScreenState extends State<ReminderListScreen> {
  final _service = ReminderService();
  StreamSubscription? _sub;
  List<Reminder> _reminders = [];
  bool _loading = true;

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

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

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
