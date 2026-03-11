import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../config/app_config.dart';
import '../services/auth_service.dart';
import 'outgoing_call_screen.dart';
import 'photo_upload_screen.dart';

/// 온라인 기기 목록 화면 — 터치해서 영상통화 발신
class DeviceListScreen extends StatefulWidget {
  final String familyId;

  const DeviceListScreen({super.key, required this.familyId});

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  List<Map<String, dynamic>> _devices = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  void _loadDevices() {
    // 가족 그룹의 기기만 조회
    final ref = FirebaseDatabase.instance.ref('families/${widget.familyId}/devices');
    ref.onValue.listen((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) {
        if (mounted) setState(() { _devices = []; _loading = false; });
        return;
      }

      final list = <Map<String, dynamic>>[];
      for (final entry in data.entries) {
        final id = entry.key as String;
        // 자기 자신 제외
        if (id == AppConfig.deviceId) continue;

        final info = Map<String, dynamic>.from(entry.value as Map);
        info['id'] = id;
        list.add(info);
      }

      // 온라인 기기 먼저, 이름순 정렬
      list.sort((a, b) {
        final aOnline = a['online'] == true ? 0 : 1;
        final bOnline = b['online'] == true ? 0 : 1;
        if (aOnline != bOnline) return aOnline.compareTo(bOnline);
        return (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString());
      });

      if (mounted) setState(() { _devices = list; _loading = false; });
    });
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
  Widget build(BuildContext context) {
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
              MaterialPageRoute(builder: (_) => PhotoUploadScreen(familyId: widget.familyId)),
            ),
            tooltip: '사진 보내기',
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white70),
            onPressed: () => AuthService().signOut(),
            tooltip: '로그아웃',
          ),
        ],
      ),
      body: _loading
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
    );
  }
}
