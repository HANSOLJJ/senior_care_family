import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../config/app_config.dart';
import '../services/auth_service.dart';
import '../services/family_service.dart';
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

  void _watchAllDevices() {
    for (final familyId in widget.familyIds) {
      final sub = FirebaseDatabase.instance
          .ref('families/$familyId/devices')
          .onValue
          .listen((event) {
        final data = event.snapshot.value as Map?;
        bool hasOnline = false;
        if (data != null) {
          for (final entry in data.entries) {
            if (entry.key == AppConfig.deviceId) continue;
            final info = entry.value as Map;
            if (info['online'] == true) {
              hasOnline = true;
              break;
            }
          }
        }
        if (mounted) {
          setState(() {
            _onlineStatus[familyId] = hasOnline;
            _loading = false;
          });
        }
      });
      _subs.add(sub);
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
