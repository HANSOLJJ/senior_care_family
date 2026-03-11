import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../config/app_config.dart';
import '../services/auth_service.dart';
import '../services/family_service.dart';
import '../services/photo_transfer_service.dart';
import 'outgoing_call_screen.dart';
import 'photo_upload_screen.dart';
import 'monitoring_screen.dart';
import 'pairing_screen.dart';

/// 가족 상세 페이지 — 기기 상태 + 액션 버튼 + 사진 + 멤버
class FamilyDetailScreen extends StatefulWidget {
  final String familyId;
  final String? familyName;

  /// true면 루트 화면 (1가족일 때), false면 목록에서 push됨
  final bool isRoot;
  final VoidCallback? onAddFamily;

  const FamilyDetailScreen({
    super.key,
    required this.familyId,
    this.familyName,
    this.isRoot = false,
    this.onAddFamily,
  });

  @override
  State<FamilyDetailScreen> createState() => _FamilyDetailScreenState();
}

class _FamilyDetailScreenState extends State<FamilyDetailScreen> {
  final _familyService = FamilyService();
  final _photoService = PhotoTransferService();
  final _db = FirebaseDatabase.instance;

  List<Map<String, dynamic>> _devices = [];
  Map<String, dynamic>? _callStatus;
  List<Map<String, dynamic>> _recentPhotos = [];
  List<Map<String, dynamic>> _members = [];
  final List<StreamSubscription<DatabaseEvent>> _subs = [];
  bool _loading = true;

  /// 대표 기기 (첫 번째 Senior 기기)
  Map<String, dynamic>? get _primaryDevice =>
      _devices.isNotEmpty ? _devices.first : null;

  bool get _isOnline => _primaryDevice?['online'] == true;
  bool get _isInCall => _callStatus?['active'] == true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  void _loadData() {
    _watchDevices();
    _watchCallStatus();
    _watchPhotos();
    _loadMembers();
  }

  void _watchDevices() {
    final sub = _db.ref('families/${widget.familyId}/devices').onValue.listen((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) {
        if (mounted) setState(() { _devices = []; _loading = false; });
        return;
      }

      final list = <Map<String, dynamic>>[];
      for (final entry in data.entries) {
        final id = entry.key as String;
        if (id == AppConfig.deviceId) continue;
        final info = Map<String, dynamic>.from(entry.value as Map);
        info['id'] = id;
        list.add(info);
      }

      // 온라인 기기 우선
      list.sort((a, b) {
        final aOn = a['online'] == true ? 0 : 1;
        final bOn = b['online'] == true ? 0 : 1;
        return aOn.compareTo(bOn);
      });

      if (mounted) setState(() { _devices = list; _loading = false; });
    });
    _subs.add(sub);
  }

  void _watchCallStatus() {
    final sub = _db.ref('families/${widget.familyId}/callStatus').onValue.listen((event) {
      final data = event.snapshot.value;
      if (mounted) {
        setState(() {
          _callStatus = data is Map ? Map<String, dynamic>.from(data) : null;
        });
      }
    });
    _subs.add(sub);
  }

  void _watchPhotos() {
    final sub = _photoService.watchPhotoSync(widget.familyId).listen((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) {
        if (mounted) setState(() => _recentPhotos = []);
        return;
      }

      final photos = <Map<String, dynamic>>[];
      for (final entry in data.entries) {
        final info = Map<String, dynamic>.from(entry.value as Map);
        info['id'] = entry.key;
        // done 상태만 표시
        if (info['status'] == 'done' && info['thumbnail'] != null) {
          photos.add(info);
        }
      }

      // 최신순 정렬, 최대 10장
      photos.sort((a, b) =>
          ((b['createdAt'] as num?) ?? 0).compareTo((a['createdAt'] as num?) ?? 0));
      if (photos.length > 10) photos.removeRange(10, photos.length);

      if (mounted) setState(() => _recentPhotos = photos);
    });
    _subs.add(sub);
  }

  Future<void> _loadMembers() async {
    final members = await _familyService.getFamilyMembers(widget.familyId);
    if (mounted) setState(() => _members = members);
  }

  // ─── 액션 ───

  void _callDevice() {
    final device = _primaryDevice;
    if (device == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OutgoingCallScreen(
          targetDeviceId: device['id'] as String,
          targetDeviceName: (device['name'] ?? device['model'] ?? device['id']) as String,
        ),
      ),
    );
  }

  void _monitorDevice() {
    final device = _primaryDevice;
    if (device == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MonitoringScreen(
          targetDeviceId: device['id'] as String,
          targetDeviceName: (device['name'] ?? device['model'] ?? device['id']) as String,
        ),
      ),
    );
  }

  void _openPhotos() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhotoUploadScreen(familyId: widget.familyId),
      ),
    );
  }

  void _openVideoReminder() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('영상 알림 기능 준비 중입니다')),
    );
  }

  void _confirmUnpair() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('페어링 해제', style: TextStyle(color: Colors.white)),
        content: const Text(
          '시니어 기기와의 연결을 해제하시겠습니까?\n다시 연결하려면 페어링 코드를 입력해야 합니다.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _familyService.leaveFamily(widget.familyId);
              if (!widget.isRoot) Navigator.of(context).pop();
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

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    super.dispose();
  }

  // ─── UI ───

  @override
  Widget build(BuildContext context) {
    final title = widget.familyName ?? '가족';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(title),
        automaticallyImplyLeading: !widget.isRoot,
        actions: [
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
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDeviceStatusCard(),
                  const SizedBox(height: 20),
                  _buildActionButtons(),
                  const SizedBox(height: 24),
                  if (_recentPhotos.isNotEmpty) ...[
                    _buildRecentPhotos(),
                    const SizedBox(height: 24),
                  ],
                  if (_members.isNotEmpty) _buildMembersSection(),
                ],
              ),
            ),
    );
  }

  Widget _buildDeviceStatusCard() {
    final device = _primaryDevice;
    if (device == null) {
      return Card(
        color: Colors.grey[900],
        child: const Padding(
          padding: EdgeInsets.all(20),
          child: Center(
            child: Text(
              '등록된 기기가 없습니다',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
          ),
        ),
      );
    }

    // 상태 결정
    final Color statusColor;
    final IconData statusIcon;
    final String statusText;

    if (_isInCall) {
      statusColor = Colors.orange;
      statusIcon = Icons.videocam;
      final callerName = _callStatus?['callerName'] ?? '';
      statusText = callerName.isNotEmpty ? '통화 중 — $callerName' : '통화 중';
    } else if (_isOnline) {
      statusColor = Colors.green;
      statusIcon = Icons.check_circle;
      statusText = '온라인';
    } else {
      statusColor = Colors.grey;
      statusIcon = Icons.circle_outlined;
      statusText = '오프라인';
    }

    return Card(
      color: Colors.grey[900],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(statusIcon, color: statusColor, size: 20),
                const SizedBox(width: 8),
                Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  (device['name'] ?? device['model'] ?? '') as String,
                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                ),
              ],
            ),
            if (device['storageTotal'] != null) ...[
              const SizedBox(height: 12),
              _buildStorageBar(device),
            ],
          ],
        ),
      ),
    );
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
        const SizedBox(height: 4),
        Text(
          '${formatSize(used)} / ${formatSize(total)} 사용 · 사진 $photoCount장',
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildActionButtons() {
    final canCall = _isOnline && !_isInCall;
    final callLabel = _isInCall ? '통화 중' : '영상통화';

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _actionButton(
          icon: Icons.videocam,
          label: callLabel,
          color: canCall ? Colors.green : Colors.grey[700]!,
          onTap: canCall ? _callDevice : null,
        ),
        _actionButton(
          icon: Icons.camera_outdoor,
          label: '모니터링',
          color: canCall ? Colors.orange : Colors.grey[700]!,
          onTap: canCall ? _monitorDevice : null,
        ),
        _actionButton(
          icon: Icons.photo_library,
          label: '사진 보내기',
          color: Colors.blue,
          onTap: _openPhotos,
        ),
        _actionButton(
          icon: Icons.movie,
          label: '영상 알림',
          color: Colors.purple,
          onTap: _openVideoReminder,
        ),
      ],
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    final isDisabled = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 100,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: isDisabled ? Colors.grey[900] : color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDisabled ? Colors.grey[800]! : color.withValues(alpha: 0.4),
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: isDisabled ? Colors.grey[600] : color, size: 28),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: isDisabled ? Colors.grey[600] : Colors.white,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentPhotos() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              '최근 보낸 사진',
              style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold),
            ),
            GestureDetector(
              onTap: _openPhotos,
              child: const Text(
                '더보기',
                style: TextStyle(color: Colors.blue, fontSize: 13),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 80,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _recentPhotos.length,
            itemBuilder: (context, index) {
              final photo = _recentPhotos[index];
              final thumbStr = photo['thumbnail'] as String? ?? '';
              if (thumbStr.isEmpty) return const SizedBox.shrink();

              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: _openPhotos,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      base64Decode(thumbStr),
                      width: 80,
                      height: 80,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 80,
                        height: 80,
                        color: Colors.grey[800],
                        child: const Icon(Icons.broken_image, color: Colors.grey),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMembersSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '가족 멤버',
          style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: _members.map((m) {
            final name = (m['name'] ?? '알 수 없음') as String;
            final role = (m['role'] ?? '') as String;
            return Chip(
              avatar: const Icon(Icons.person, size: 18, color: Colors.white70),
              label: Text(
                role == 'senior' ? '$name (시니어)' : name,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              backgroundColor: Colors.grey[800],
              side: BorderSide.none,
            );
          }).toList(),
        ),
      ],
    );
  }
}
