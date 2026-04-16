import 'package:firebase_database/firebase_database.dart';

/// Senior 기기 온라인 판정 유틸 (`Utility`) — Connection List 패턴 기준
///
/// `/devices/{did}/connections/{sessionId}: true` 자식이 1개라도 있으면 online.
/// Senior가 register 시 UUID sessionId로 child 추가, 끊김 시 onDisconnect로
/// 자기 child만 자동 제거.
///
/// 참조 — 마이그레이션 배경/race 원리: `docs/presence_migration_handover.md`
/// 참조 — 스키마: `docs/RTDB_schema.md`
class PresenceUtil {
  /// (`Utility`, static) Map 기반 online 판정
  ///
  /// `/devices/{did}` 전체 snapshot을 Map으로 읽은 경우 사용.
  ///
  /// - **Params**:
  ///   - [deviceData] — `/devices/{did}` 노드의 Map 전체 (connections 필드 포함 기대)
  /// - **Returns**: `bool` — connections 자식 ≥ 1 이면 true
  static bool isOnlineFromMap(Map? deviceData) {
    if (deviceData == null) return false;
    final conn = deviceData['connections'];
    return conn is Map && conn.isNotEmpty;
  }

  /// (`Utility`, static) Snapshot 기반 online 판정
  ///
  /// `/devices/{did}/connections` 경로를 직접 조회/구독한 snapshot에서 사용.
  ///
  /// - **Params**:
  ///   - [connSnap] — `.ref('devices/$did/connections').get()` 또는 onValue event snapshot
  /// - **Returns**: `bool` — snapshot 존재 + 자식 ≥ 1 이면 true
  static bool isOnlineFromSnapshot(DataSnapshot connSnap) {
    if (!connSnap.exists) return false;
    final value = connSnap.value;
    return value is Map && value.isNotEmpty;
  }
}
