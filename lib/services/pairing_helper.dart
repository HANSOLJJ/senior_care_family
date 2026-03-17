import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'family_service.dart';

/// 페어링 후 공통 처리: 가족 이름 + 내 이름 설정
class PairingHelper {
  static final _familyService = FamilyService();

  /// 페어링 성공 후 전체 플로우
  /// 1. 가족 이름 설정 다이얼로그
  /// 2. 내 이름 설정 다이얼로그
  /// 3. RTDB _label 업데이트
  static Future<void> onPairingComplete(BuildContext context, String familyId) async {
    await _promptFamilyName(context, familyId);
    if (!context.mounted) return;
    await _promptMyName(context, familyId);
  }

  /// 가족 이름 설정 다이얼로그
  static Future<void> _promptFamilyName(BuildContext context, String familyId) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
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
          onSubmitted: (v) => Navigator.pop(dialogContext, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('건너뛰기'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await _familyService.setFamilyName(familyId, name);
      await FirebaseDatabase.instance
          .ref('families/$familyId/_label')
          .set(name);
    }
  }

  /// 내 이름 설정 다이얼로그
  static Future<void> _promptMyName(BuildContext context, String familyId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final controller = TextEditingController(text: user.displayName ?? '');
    final name = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('내 이름 설정', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: '예: 아들, 딸, 홍길동',
            hintStyle: TextStyle(color: Colors.grey[600]),
            filled: true,
            fillColor: Colors.grey[800],
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
          onSubmitted: (v) => Navigator.pop(dialogContext, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('건너뛰기'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      final uid = user.uid;
      final provider = _getProvider(user);
      final label = '$name ($provider:$uid)';
      await FirebaseDatabase.instance
          .ref('families/$familyId/members/$uid')
          .update({
        'name': name,
        '_label': label,
      });
    }
  }

  static String _getProvider(User user) {
    if (user.uid.startsWith('kakao:')) return 'kakao';
    if (user.uid.startsWith('naver:')) return 'naver';
    for (final info in user.providerData) {
      if (info.providerId == 'apple.com') return 'apple';
      if (info.providerId == 'google.com') return 'google';
    }
    return 'unknown';
  }
}
