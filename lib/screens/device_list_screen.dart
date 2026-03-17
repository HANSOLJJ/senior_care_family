import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../services/auth_service.dart';
import '../services/family_service.dart';
import '../services/pairing_helper.dart';
import 'family_detail_screen.dart';
import 'pairing_screen.dart';

/// 홈 화면 — 가족 1명이면 바로 상세 진입, 2명+이면 가족 목록 표시
class DeviceListScreen extends StatefulWidget {
  final List<String> familyIds;
  final VoidCallback? onAddFamily;

  const DeviceListScreen({super.key, required this.familyIds, this.onAddFamily});

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  final _familyService = FamilyService();
  Map<String, String> _familyNames = {};
  /// familyId → 온라인 기기 존재 여부
  final Map<String, bool> _onlineStatus = {};
  final List<StreamSubscription<DatabaseEvent>> _subs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFamilyNames();
    _watchAllDevices();
  }

  @override
  void didUpdateWidget(DeviceListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.familyIds.length != widget.familyIds.length) {
      for (final sub in _subs) {
        sub.cancel();
      }
      _subs.clear();
      _onlineStatus.clear();
      _loadFamilyNames();
      _watchAllDevices();
    }
  }

  Future<void> _loadFamilyNames() async {
    final names = await _familyService.getFamilyNames();
    if (mounted) setState(() => _familyNames = names);
  }

  // familyId → 해당 가족의 각 기기 online 감시 구독 목록
  final Map<String, List<StreamSubscription>> _deviceOnlineSubs = {};

  void _watchAllDevices() {
    for (final familyId in widget.familyIds) {
      // 1) /families/{fid}/devices/ 목록 감시 (기기 추가/삭제 감지)
      final sub = FirebaseDatabase.instance
          .ref('families/$familyId/devices')
          .onValue
          .listen((event) {
        final data = event.snapshot.value;
        // 기존 기기 online 구독 해제
        for (final s in _deviceOnlineSubs[familyId] ?? []) {
          s.cancel();
        }
        _deviceOnlineSubs[familyId] = [];

        if (data != null && data is Map) {
          // 2) 각 /devices/{did}/online 실시간 감시
          for (final deviceId in data.keys) {
            final onlineSub = FirebaseDatabase.instance
                .ref('devices/$deviceId/online')
                .onValue
                .listen((onlineEvent) {
              _updateOnlineStatus(familyId);
            });
            _deviceOnlineSubs[familyId]!.add(onlineSub);
          }
        }
        // 초기 로딩 완료
        if (mounted) setState(() => _loading = false);
      });
      _subs.add(sub);
    }
  }

  Future<void> _updateOnlineStatus(String familyId) async {
    final devicesSnap = await FirebaseDatabase.instance
        .ref('families/$familyId/devices').get();
    final data = devicesSnap.value;
    bool hasOnline = false;
    if (data != null && data is Map) {
      for (final deviceId in data.keys) {
        final snap = await FirebaseDatabase.instance.ref('devices/$deviceId/online').get();
        if (snap.value == true) {
          hasOnline = true;
          break;
        }
      }
    }
    if (mounted) {
      setState(() => _onlineStatus[familyId] = hasOnline);
    }
  }

  String _familyLabel(String familyId, int index) {
    final name = _familyNames[familyId];
    if (name != null && name.isNotEmpty) return name;
    return '가족 ${index + 1}';
  }

  void _addFamily() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PairingScreen(
          onPairedWithId: (familyId) async {
            await PairingHelper.onPairingComplete(context, familyId);
            if (context.mounted) Navigator.of(context).pop();
            widget.onAddFamily?.call();
            _loadFamilyNames();
          },
        ),
      ),
    );
  }


  void _openFamily(String familyId, String name) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FamilyDetailScreen(
          familyId: familyId,
          familyName: name,
          onAddFamily: () {
            widget.onAddFamily?.call();
            _loadFamilyNames();
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    for (final subs in _deviceOnlineSubs.values) {
      for (final s in subs) {
        s.cancel();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 가족 1명 → 바로 상세 페이지
    if (widget.familyIds.length == 1) {
      final familyId = widget.familyIds[0];
      final name = _familyNames[familyId];
      return FamilyDetailScreen(
        familyId: familyId,
        familyName: name ?? '가족',
        isRoot: true,
        onAddFamily: () {
          widget.onAddFamily?.call();
          _loadFamilyNames();
        },
      );
    }

    // 가족 2명+ → 목록
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('가족 선택'),
        automaticallyImplyLeading: false,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white70),
            color: Colors.grey[900],
            onSelected: (value) {
              if (value == 'add') _addFamily();
              if (value == 'logout') AuthService().signOut();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'add',
                child: Text('가족 추가', style: TextStyle(color: Colors.white)),
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
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: widget.familyIds.length,
              itemBuilder: (context, index) {
                final familyId = widget.familyIds[index];
                final name = _familyLabel(familyId, index);
                final isOnline = _onlineStatus[familyId] ?? false;

                return Card(
                  color: Colors.grey[900],
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    title: Text(
                      name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    trailing: Icon(
                      Icons.circle,
                      color: isOnline ? Colors.green : Colors.grey[600],
                      size: 14,
                    ),
                    onTap: () => _openFamily(familyId, name),
                  ),
                );
              },
            ),
    );
  }
}
