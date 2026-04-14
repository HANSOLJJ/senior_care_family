import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Firebase 싱글톤 인스턴스 접근자 모음 (`Mixin`)
///
/// `final FirebaseDatabase _db = FirebaseDatabase.instance;` 같은 보일러플레이트
/// 제거. Service 클래스에 `with FirebaseInstancesMixin` 추가하면 `db`/`auth`/`storage`
/// getter로 즉시 접근 가능.
///
/// 사용:
/// ```
/// class FamilyService with FirebaseInstancesMixin { ... db.ref(...) ... }
/// ```
mixin FirebaseInstancesMixin {
  /// Firebase Realtime Database 싱글톤
  FirebaseDatabase get db => FirebaseDatabase.instance;

  /// Firebase Auth 싱글톤
  FirebaseAuth get auth => FirebaseAuth.instance;

  /// Firebase Storage 싱글톤
  FirebaseStorage get storage => FirebaseStorage.instance;
}
