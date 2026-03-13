import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/reminder/reminder_service.dart';

class ReminderEditScreen extends StatefulWidget {
  final String familyId;
  final Reminder? existing; // null이면 신규 생성

  const ReminderEditScreen({
    super.key,
    required this.familyId,
    this.existing,
  });

  @override
  State<ReminderEditScreen> createState() => _ReminderEditScreenState();
}

class _ReminderEditScreenState extends State<ReminderEditScreen> {
  final _service = ReminderService();
  final _picker = ImagePicker();
  final _titleController = TextEditingController();

  TimeOfDay _time = const TimeOfDay(hour: 8, minute: 0);
  String _repeat = 'daily';
  List<int> _selectedDays = [];

  File? _mediaFile;
  String _mediaType = 'video'; // "video" | "audio"
  bool _hasExistingMedia = false;

  bool _saving = false;
  double _uploadProgress = 0;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final r = widget.existing!;
      _titleController.text = r.title;
      final parts = r.time.split(':');
      _time = TimeOfDay(
        hour: int.parse(parts[0]),
        minute: int.parse(parts[1]),
      );
      _repeat = r.repeat;
      _selectedDays = List<int>.from(r.days);
      _mediaType = r.mediaType;
      _hasExistingMedia = true;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  bool get _isEdit => widget.existing != null;

  bool get _canSave {
    if (_titleController.text.trim().isEmpty) return false;
    if (!_isEdit && _mediaFile == null) return false;
    if (_repeat == 'custom' && _selectedDays.isEmpty) return false;
    return !_saving;
  }

  String get _timeString =>
      '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';

  Future<void> _pickMedia({required bool fromCamera}) async {
    final source =
        fromCamera ? ImageSource.camera : ImageSource.gallery;

    // 영상 촬영/선택
    final picked = await _picker.pickVideo(
      source: source,
      maxDuration: const Duration(seconds: 60),
    );
    if (picked == null) return;

    setState(() {
      _mediaFile = File(picked.path);
      _mediaType = 'video';
    });
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);

    try {
      if (_isEdit) {
        await _service.updateReminder(
          familyId: widget.familyId,
          reminderId: widget.existing!.id,
          title: _titleController.text.trim(),
          time: _timeString,
          repeat: _repeat,
          days: _repeat == 'custom' ? _selectedDays : null,
          mediaFile: _mediaFile,
          mediaType: _mediaFile != null ? _mediaType : null,
          onProgress: (p) => setState(() => _uploadProgress = p),
        );
      } else {
        await _service.createReminder(
          familyId: widget.familyId,
          title: _titleController.text.trim(),
          time: _timeString,
          repeat: _repeat,
          days: _repeat == 'custom' ? _selectedDays : [],
          mediaFile: _mediaFile!,
          mediaType: _mediaType,
          onProgress: (p) => setState(() => _uploadProgress = p),
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? '알림 수정' : '알림 추가'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 제목
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: '제목 *',
                hintText: '예: 혈압약',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 24),

            // 미디어
            const Text('영상/음성 *',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _buildMediaPicker(),
            const SizedBox(height: 24),

            // 시간
            const Text('알림 시간',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _buildTimePicker(),
            const SizedBox(height: 24),

            // 반복
            const Text('반복',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _buildRepeatSelector(),
            if (_repeat == 'custom') ...[
              const SizedBox(height: 12),
              _buildDaySelector(),
            ],
            const SizedBox(height: 32),

            // 저장 버튼
            if (_saving && _mediaFile != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: LinearProgressIndicator(value: _uploadProgress),
              ),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _canSave ? _save : null,
                child: Text(_saving ? '저장 중...' : '저장'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMediaPicker() {
    return Column(
      children: [
        if (_mediaFile != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.shade200),
            ),
            child: Row(
              children: [
                Icon(
                  _mediaType == 'video' ? Icons.videocam : Icons.mic,
                  color: Colors.green,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _mediaFile!.path.split('/').last,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => setState(() => _mediaFile = null),
                ),
              ],
            ),
          )
        else if (_hasExistingMedia)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Row(
              children: [
                Icon(
                  _mediaType == 'video' ? Icons.videocam : Icons.mic,
                  color: Colors.blue,
                ),
                const SizedBox(width: 8),
                const Text('기존 미디어 유지 (변경하려면 아래 버튼)'),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _saving ? null : () => _pickMedia(fromCamera: true),
                icon: const Icon(Icons.videocam),
                label: const Text('녹화'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _saving ? null : () => _pickMedia(fromCamera: false),
                icon: const Icon(Icons.folder_open),
                label: const Text('갤러리'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTimePicker() {
    final isPm = _time.hour >= 12;
    final display12 = _time.hourOfPeriod == 0 ? 12 : _time.hourOfPeriod;
    final amPm = isPm ? '오후' : '오전';
    final timeStr = '${display12.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';

    return InkWell(
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: _time,
          initialEntryMode: TimePickerEntryMode.input,
        );
        if (picked != null) setState(() => _time = picked);
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              amPm,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: isPm ? Colors.indigo : Colors.orange.shade800,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              timeStr,
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRepeatSelector() {
    return DropdownButtonFormField<String>(
      initialValue: _repeat,
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
      ),
      items: const [
        DropdownMenuItem(value: 'daily', child: Text('매일')),
        DropdownMenuItem(value: 'weekdays', child: Text('평일 (월~금)')),
        DropdownMenuItem(value: 'weekend', child: Text('주말 (토,일)')),
        DropdownMenuItem(value: 'custom', child: Text('요일 선택')),
        DropdownMenuItem(value: 'test_5min', child: Text('테스트 (5분 반복)')),
      ],
      onChanged: (v) {
        if (v != null) setState(() => _repeat = v);
      },
    );
  }

  Widget _buildDaySelector() {
    const dayNames = ['월', '화', '수', '목', '금', '토', '일'];
    return Wrap(
      spacing: 8,
      children: List.generate(7, (i) {
        final day = i + 1; // 1=월 ~ 7=일
        final selected = _selectedDays.contains(day);
        return FilterChip(
          label: Text(dayNames[i]),
          selected: selected,
          onSelected: (v) {
            setState(() {
              if (v) {
                _selectedDays.add(day);
                _selectedDays.sort();
              } else {
                _selectedDays.remove(day);
              }
            });
          },
        );
      }),
    );
  }
}
