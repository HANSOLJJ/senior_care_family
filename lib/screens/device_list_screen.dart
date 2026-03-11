import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../config/app_config.dart';
import '../services/auth_service.dart';
import '../services/family_service.dart';
import 'outgoing_call_screen.dart';
import 'photo_upload_screen.dart';
import 'pairing_screen.dart';

/// 온라인 기기 목록 화면 — 터치해서 영상통화 발신
class DeviceListScreen extends StatefulWidget {
  final List<String> familyIds;
  final VoidCallback? onAddFamily;

  const DeviceListScreen({super.key, required this.familyIds, this.onAddFamily});

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  final _familyService = FamilyService();
  final Map<String, List<Map<String, dynamic>>> _devicesByFamily = {};
  final List<StreamSubscription<DatabaseEvent>> _subs = [];
  Map<String, String> _familyNames = {};
  bool _loading = true;
  int _currentFamilyIndex = 0;

  String get _currentFamilyId => widget.familyIds[_currentFamilyIndex];
  List<Map<String, dynamic>> get _devices => _devicesByFamily[_currentFamilyId] ?? [];

  @override
  void initState() {
    super.initState();
    _loadFamilyNames();
    _loadAllDevices();
  }

  @override
  void didUpdateWidget(DeviceListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.familyIds.length != widget.familyIds.length) {
      // familyIds 변경 시 리스너 재설정
      for (final sub in _subs) {
        sub.cancel();
      }
      _subs.clear();
      _devicesByFamily.clear();
      if (_currentFamilyIndex >= widget.familyIds.length) {
        _currentFamilyIndex = 0;
      }
      _loadFamilyNames();
      _loadAllDevices();
    }
  }

  Future<void> _loadFamilyNames() async {
    final names = await _familyService.getFamilyNames();
    if (mounted) setState(() => _familyNames = names);
  }

  void _loadAllDevices() {
    for (final familyId in widget.familyIds) {
      _loadDevices(familyId);
    }
  }

  void _loadDevices(String familyId) {
    final ref = FirebaseDatabase.instance.ref('families/$familyId/devices');
    final sub = ref.onValue.listen((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) {
        if (mounted) setState(() {
          _devicesByFamily[familyId] = [];
          _loading = false;
        });
        return;
      }

      final list = <Map<String, dynamic>>[];
      for (final entry in data.entries) {
        final id = entry.key as String;
        if (id == AppConfig.deviceId) continue;

        final info = Map<String, dynamic>.from(entry.value as Map);
        info['id'] = id;
        info['familyId'] = familyId;
        list.add(info);
      }

      list.sort((a, b) {
        final aOnline = a['online'] == true ? 0 : 1;
        final bOnline = b['online'] == true ? 0 : 1;
        if (aOnline != bOnline) return aOnline.compareTo(bOnline);
        return (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString());
      });

      if (mounted) setState(() {
        _devicesByFamily[familyId] = list;
        _loading = false;
      });
    });
    _subs.add(sub);
  }

  /// 가족 그룹 라벨 (사용자 지정 이름 우선)
  String _familyLabel(int index) {
    final familyId = widget.familyIds[index];
    final customName = _familyNames[familyId];
    if (customName != null && customName.isNotEmpty) return customName;
    return '가족 ${index + 1}';
  }

  Widget _buildStorageBar(Map<String, dynamic> device) {
    final total = (device['storageTotal'] as num).toDouble();
    final available = (device['storageAvailable'] as num).toDouble();
    final photoCount = (device['photoCount'] as num?)?.toInt() ?? 0;
    final used = total - available;
    final ratio = total > 0 ? used / total : 0.0;

    String formatSize(double bytes) {
      if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(1)}GB';
      if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(0)}MB';
      return '${bytes.toInt()}B';
    }

    final color = ratio > 0.9 ? Colors.red : ratio > 0.75 ? Colors.orange : Colors.blue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: ratio,
            backgroundColor: Colors.grey[700],
            color: color,
            minHeight: 4,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${formatSize(used)} / ${formatSize(total)} 사용 · 사진 $photoCount장',
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
      ],
    );
  }

  void _confirmUnpair() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('페어링 해제', style: TextStyle(color: Colors.white)),
        content: Text(
          widget.familyIds.length > 1
              ? '"${_familyLabel(_currentFamilyIndex)}" 기기와의 연결을 해제하시겠습니까?'
              : '시니어 기기와의 연결을 해제하시겠습니까?\n다시 연결하려면 페어링 코드를 입력해야 합니다.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              FamilyService().leaveFamily(_currentFamilyId);
            },
            child: const Text('해제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _addFamily() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PairingScreen(
          onPairedWithId: (familyId) async {
            Navigator.of(context).pop();
            await _promptFamilyName(familyId);
            widget.onAddFamily?.call();
            _loadFamilyNames();
          },
        ),
      ),
    );
  }

  Future<void> _promptFamilyName(String familyId) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('가족 이름 지정', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: '예: 부모님, 장인어른',
            hintStyle: TextStyle(color: Colors.grey[600]),
            filled: true,
            fillColor: Colors.grey[800],
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('건너뛰기'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      await _familyService.setFamilyName(familyId, name);
    }
  }

  Future<void> _renameFamilyDialog(int index) async {
    final familyId = widget.familyIds[index];
    final controller = TextEditingController(text: _familyNames[familyId] ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('가족 이름 변경', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: '예: 부모님, 장인어른',
            hintStyle: TextStyle(color: Colors.grey[600]),
            filled: true,
            fillColor: Colors.grey[800],
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      await _familyService.setFamilyName(familyId, name);
      _loadFamilyNames();
    }
  }

  void _callDevice(Map<String, dynamic> device) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OutgoingCallScreen(
          targetDeviceId: device['id'] as String,
          targetDeviceName: (device['name'] ?? device['model'] ?? device['id']) as String,
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasMultipleFamilies = widget.familyIds.length > 1;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('기기 선택'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library, color: Colors.white70),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => PhotoUploadScreen(familyId: _currentFamilyId)),
            ),
            tooltip: '사진 보내기',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white70),
            color: Colors.grey[900],
            onSelected: (value) {
              if (value == 'add') _addFamily();
              if (value == 'unpair') _confirmUnpair();
              if (value == 'logout') AuthService().signOut();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'add',
                child: Text('가족 추가', style: TextStyle(color: Colors.white)),
              ),
              const PopupMenuItem(
                value: 'unpair',
                child: Text('페어링 해제', style: TextStyle(color: Colors.white)),
              ),
              const PopupMenuItem(
                value: 'logout',
                child: Text('로그아웃', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 다중 가족 그룹 탭
          if (hasMultipleFamilies)
            SizedBox(
              height: 48,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: widget.familyIds.length,
                itemBuilder: (context, index) {
                  final isSelected = index == _currentFamilyIndex;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onLongPress: () => _renameFamilyDialog(index),
                      child: ChoiceChip(
                        label: Text(_familyLabel(index)),
                        selected: isSelected,
                        onSelected: (_) => setState(() => _currentFamilyIndex = index),
                        selectedColor: Colors.blue,
                        backgroundColor: Colors.grey[800],
                        labelStyle: TextStyle(
                          color: isSelected ? Colors.white : Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

          // 기기 목록
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: Colors.white))
                : _devices.isEmpty
                    ? const Center(
                        child: Text(
                          '등록된 기기가 없습니다',
                          style: TextStyle(color: Colors.white70, fontSize: 16),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _devices.length,
                        itemBuilder: (context, index) {
                          final device = _devices[index];
                          final isOnline = device['online'] == true;
                          final name = (device['name'] ?? device['model'] ?? '알 수 없음') as String;
                          final model = (device['model'] ?? '') as String;
                          final id = (device['id'] as String);
                          final shortId = id.length > 8 ? id.substring(0, 8) : id;

                          return Card(
                            color: Colors.grey[900],
                            margin: const EdgeInsets.only(bottom: 12),
                            child: ListTile(
                              leading: Icon(
                                Icons.tablet_android,
                                color: isOnline ? Colors.green : Colors.grey,
                                size: 36,
                              ),
                              title: Text(
                                name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '$model ($shortId) ${isOnline ? "• 온라인" : "• 오프라인"}',
                                    style: TextStyle(
                                      color: isOnline ? Colors.green[300] : Colors.grey,
                                      fontSize: 13,
                                    ),
                                  ),
                                  if (device['storageTotal'] != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: _buildStorageBar(device),
                                    ),
                                ],
                              ),
                              trailing: isOnline
                                  ? const Icon(Icons.videocam, color: Colors.green, size: 28)
                                  : const Icon(Icons.videocam_off, color: Colors.grey, size: 28),
                              onTap: isOnline ? () => _callDevice(device) : null,
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
