import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'family_service.dart';

/// 페어링 후 공통 처리 헬퍼 (`Utility`, static) — 가족 이름 + 내 이름 설정
///
/// 페어링 성공 직후 호출되어 두 개의 다이얼로그를 순차 표시한다:
///   1. [_promptFamilyName] — "부모님", "장인어른" 등 가족 그룹 라벨 입력
///   2. [_promptMyName] — "아들", "딸" 등 자기 이름 입력 (RTDB members/{uid}/name 업데이트)
///
/// 두 다이얼로그 모두 "건너뛰기" 가능 — 나중에 설정할 수 있음.
///
/// RTDB 경로:
///   - `/users/{uid}/familyNames/{familyId}` — 가족 그룹 사용자 지정 이름
///   - `/families/{familyId}/_label` — Console 가독성용 가족 라벨
///   - `/families/{familyId}/members/{uid}/name` — 멤버 표시 이름
///   - `/families/{familyId}/members/{uid}/_label` — Console 가독성용 멤버 라벨
///
/// 호출 위치: app.dart → _PairingGate, device_list_screen.dart → _addFamily()
class PairingHelper {
  /// FamilyService 인스턴스 (가족 이름 저장용)
  static final _familyService = FamilyService();

  // ─── 메인 플로우 ───

  /// 페어링 성공 후 전체 플로우 실행 (`Method`, async, static)
  ///
  /// 가족 이름 설정 다이얼로그 → 내 이름 설정 다이얼로그를 순차 표시.
  /// 첫 다이얼로그 종료 후 context가 unmounted이면 두 번째는 건너뛴다.
  ///
  /// - **Params**:
  ///   - [context] — BuildContext (다이얼로그 표시용)
  ///   - [familyId] — 페어링 완료된 가족 그룹 ID
  /// - **Side Effects**:
  ///   - RTDB `/users/{uid}/familyNames/{fid}` 기록 (가족 이름)
  ///   - RTDB `/families/{fid}/_label` 업데이트
  ///   - RTDB `/families/{fid}/members/{uid}/name`, `_label` 업데이트 (내 이름)
  /// - **호출**: app.dart → _PairingGate, device_list_screen.dart → _addFamily()
  static Future<void> onPairingComplete(BuildContext context, String familyId) async {
    await _promptFamilyName(context, familyId);
    if (!context.mounted) return;
    await _promptMyName(context, familyId);
  }

  // ─── 가족 이름 다이얼로그 ───

  /// 가족 이름 설정 다이얼로그 표시 (`Method`, async, static, private)
  ///
  /// 다크 테마 AlertDialog로 가족 그룹의 사용자 지정 라벨을 입력받는다.
  /// "건너뛰기" 선택 시 null 반환되어 이름 설정 없이 진행.
  ///
  /// - **Params**:
  ///   - [context] — BuildContext
  ///   - [familyId] — 대상 가족 그룹 ID
  /// - **Side Effects**:
  ///   - RTDB `/users/{uid}/familyNames/{fid}` 에 이름 저장 ([FamilyService.setFamilyName])
  ///   - RTDB `/families/{fid}/_label` 에 동일 이름 저장
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

  // ─── 내 이름 다이얼로그 ───

  /// 내 이름 설정 다이얼로그 표시 (`Method`, async, static, private)
  ///
  /// 다크 테마 AlertDialog로 가족 그룹 내 자신의 표시 이름을 입력받는다.
  /// 기본값은 Firebase Auth의 displayName.
  /// 입력된 이름으로 RTDB 멤버 노드의 name과 _label을 업데이트.
  ///
  /// - **Params**:
  ///   - [context] — BuildContext
  ///   - [familyId] — 대상 가족 그룹 ID
  /// - **Side Effects**:
  ///   - RTDB `/families/{fid}/members/{uid}/name` 업데이트
  ///   - RTDB `/families/{fid}/members/{uid}/_label` 업데이트
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
      await FirebaseDatabase.instance
          .ref('families/$familyId/members/$uid')
          .update({
        'name': name,
      });
    }
  }

  // ─── 헬퍼 ───

}
