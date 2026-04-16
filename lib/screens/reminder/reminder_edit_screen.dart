import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/reminder/reminder_service.dart';
import '../../widgets/safe_state_mixin.dart';
import '../../widgets/press_scale.dart';

/// 영상 알림 생성/수정 화면 (`StatefulWidget`)
///
/// existing == null → 신규 생성 모드
/// existing != null → 기존 알림 수정 모드
///
/// 입력 필드:
///   - 제목 (TextField)
///   - 시간 (TimePicker — 오전/오후 12시간 표시)
///   - 반복 주기 (daily, weekdays, weekend, custom, test_5min)
///   - 미디어 파일 (카메라 녹화 / 갤러리에서 영상 선택)
///
/// 저장 시 [ReminderService.createReminder] 또는 [updateReminder] 호출.
/// 미디어는 Storage에 업로드 후 RTDB에 mediaUrl 저장.
///
/// - **섹션 구성**:
///   - 상태 필드 — 입력 값, 미디어 파일, 저장 상태
///   - 라이프사이클 — initState(기존 값 로드), dispose
///   - 계산 속성 — _isEdit, _canSave, _timeString
///   - 미디어 선택 — _pickMedia
///   - 저장 — _save
///   - UI 빌드 — build, _buildMediaPicker, _buildTimePicker, _buildRepeatSelector, _buildDaySelector
class ReminderEditScreen extends StatefulWidget {
  /// 대상 가족 그룹 ID
  final String familyId;

  /// 수정 대상 알림 (null이면 신규 생성)
  final Reminder? existing;

  const ReminderEditScreen({
    super.key,
    required this.familyId,
    this.existing,
  });

  @override
  State<ReminderEditScreen> createState() => _ReminderEditScreenState();
}

/// [ReminderEditScreen]의 `State`
///
/// 알림 생성/수정 폼 관리 + 미디어 업로드 + 저장 처리.
class _ReminderEditScreenState extends State<ReminderEditScreen> with SafeStateMixin {

  // ─── 상태 필드 ───

  /// 알림 CRUD 서비스
  final _service = ReminderService();

  /// 갤러리/카메라 접근 플러그인
  final _picker = ImagePicker();

  /// 제목 입력 컨트롤러
  final _titleController = TextEditingController();

  /// 선택된 알림 시간 (기본: 오전 8시)
  TimeOfDay _time = const TimeOfDay(hour: 8, minute: 0);

  /// 선택된 반복 주기 (기본: 매일)
  String _repeat = 'daily';

  /// custom 반복 시 선택된 요일 목록 (1=월 ~ 7=일)
  List<int> _selectedDays = [];

  /// 새로 선택한 미디어 파일 (null이면 미변경)
  File? _mediaFile;

  /// 미디어 유형: "video" 또는 "audio"
  String _mediaType = 'video';

  /// 기존 미디어 존재 여부 (수정 모드에서 "기존 미디어 유지" 표시용)
  bool _hasExistingMedia = false;

  /// 저장 진행 중 여부
  bool _saving = false;

  /// 미디어 선택(picker) 진행 중 여부 — double-tap 차단
  bool _picking = false;

  /// 업로드 진행률 (0.0 ~ 1.0)
  double _uploadProgress = 0;

  // ─── 라이프사이클 ───

  /// 초기화 — 수정 모드면 기존 값 로드 (`Lifecycle`)
  ///
  /// - **Side Effects**: _titleController, _time, _repeat, _selectedDays, _mediaType, _hasExistingMedia 설정
  /// - **호출**: Flutter 프레임워크
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

  /// 텍스트 컨트롤러 해제 (`Lifecycle`)
  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  // ─── 계산 속성 ───

  /// 수정 모드 여부 (`Getter`)
  bool get _isEdit => widget.existing != null;

  /// 저장 가능 여부 (`Getter`)
  ///
  /// - 제목 비어있으면 불가
  /// - 신규 생성 시 미디어 없으면 불가
  /// - custom 반복 시 요일 미선택이면 불가
  /// - 저장 진행 중이면 불가
  bool get _canSave {
    if (_titleController.text.trim().isEmpty) return false;
    if (!_isEdit && _mediaFile == null) return false;
    if (_repeat == 'custom' && _selectedDays.isEmpty) return false;
    return !_saving;
  }

  /// 선택된 시간을 "HH:mm" 문자열로 변환 (`Getter`)
  String get _timeString =>
      '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';

  // ─── 미디어 선택 ───

  /// 카메라/갤러리에서 영상 선택 (`Method`, async)
  ///
  /// - **Params**:
  ///   - [fromCamera] — true면 카메라 녹화, false면 갤러리 선택
  /// - **Side Effects**: _mediaFile, _mediaType 갱신
  /// - **호출**: _buildMediaPicker 내 버튼
  Future<void> _pickMedia({required bool fromCamera}) async {
    if (_picking || _saving) return; // double-tap 차단
    _picking = true;
    HapticFeedback.lightImpact();
    try {
      final source =
          fromCamera ? ImageSource.camera : ImageSource.gallery;

      final picked = await _picker.pickVideo(
        source: source,
        maxDuration: const Duration(seconds: 60),
      );
      if (picked == null) return;

      setState(() {
        _mediaFile = File(picked.path);
        _mediaType = 'video';
      });
    } finally {
      _picking = false;
    }
  }

  // ─── 저장 ───

  /// 알림 저장 — 생성 또는 수정 실행 (`Method`, async)
  ///
  /// - **Side Effects**:
  ///   - 신규: ReminderService.createReminder() → Storage 업로드 + RTDB 생성
  ///   - 수정: ReminderService.updateReminder() → (선택) Storage 재업로드 + RTDB 수정
  ///   - 성공 시 Navigator.pop(true) → 목록 화면 SnackBar
  /// - **호출**: 저장 버튼 onPressed
  Future<void> _save() async {
    if (!_canSave) return;
    HapticFeedback.lightImpact();
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
      safeSetState(() => _saving = false);
    }
  }

  // ─── UI 빌드 ───

  /// 메인 화면 빌드 (`Widget Builder`)
  ///
  /// - **구성**: 제목 입력 → 미디어 선택 → 시간 선택 → 반복 선택 → (요일 선택) → 저장 버튼
  /// - **Returns**: `Widget` — Scaffold + ScrollView 폼
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
            // 제목 입력
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

            // 미디어 선택
            const Text('영상/음성 *',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _buildMediaPicker(),
            const SizedBox(height: 24),

            // 시간 선택
            const Text('알림 시간',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _buildTimePicker(),
            const SizedBox(height: 24),

            // 반복 주기
            const Text('반복',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _buildRepeatSelector(),
            if (_repeat == 'custom') ...[
              const SizedBox(height: 12),
              _buildDaySelector(),
            ],
            const SizedBox(height: 32),

            // 업로드 프로그레스 + 저장 버튼
            if (_saving && _mediaFile != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: LinearProgressIndicator(value: _uploadProgress),
              ),
            PressScale(
              onTap: _canSave ? _save : null,
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _canSave ? _save : null,
                  child: Text(_saving ? '저장 중...' : '저장'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 미디어 선택 영역 위젯 (`Widget Builder`)
  ///
  /// - 새 파일 선택됨: 파일명 + 제거 버튼 (초록색 컨테이너)
  /// - 기존 미디어 유지: "기존 미디어 유지" 안내 (파란색 컨테이너)
  /// - 녹화 / 갤러리 선택 버튼 2개
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
              child: PressScale(
                onTap: _saving ? null : () => _pickMedia(fromCamera: true),
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : () => _pickMedia(fromCamera: true),
                  icon: const Icon(Icons.videocam),
                  label: const Text('녹화'),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: PressScale(
                onTap: _saving ? null : () => _pickMedia(fromCamera: false),
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : () => _pickMedia(fromCamera: false),
                  icon: const Icon(Icons.folder_open),
                  label: const Text('갤러리'),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 시간 선택 위젯 — 오전/오후 12시간 표시 (`Widget Builder`)
  ///
  /// 탭하면 TimePicker 다이얼로그 표시.
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

  /// 반복 주기 드롭다운 선택 위젯 (`Widget Builder`)
  ///
  /// 옵션: 매일, 평일, 주말, 요일 선택, 테스트(5분 반복)
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

  /// 요일 선택 칩 위젯 — custom 반복 시만 표시 (`Widget Builder`)
  ///
  /// FilterChip 7개 (월~일), 선택/해제 토글.
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
