import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart' as kakao;
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/services.dart';

/// 인증 서비스 (`Service`) — 소셜 로그인/로그아웃 전담
///
/// 4종 소셜 로그인 지원:
/// - **Google**: GoogleSignIn SDK → Firebase Auth credential
/// - **Apple**: Sign In with Apple → Firebase Auth OAuthProvider (nonce 기반)
/// - **카카오**: 카카오 SDK → Cloud Function(`kakaoCustomToken`) → Firebase Custom Token
/// - **네이버**: MethodChannel 네이티브 SDK → Cloud Function(`naverCustomToken`) → Firebase Custom Token
///
/// 카카오/네이버는 Firebase에서 직접 지원하지 않아 Cloud Functions를 경유하여
/// Custom Token을 발급받은 뒤 `signInWithCustomToken()`으로 최종 로그인한다.
///
/// 로그인 성공 시 `FirebaseAuth.authStateChanges()` 스트림으로 [app.dart]의
/// `StreamBuilder`가 자동 감지하여 라우팅을 전환한다.
///
/// RTDB 경로: 직접 접근 없음 (인증만 담당, RTDB 쓰기는 [FamilyService] 등에서 수행)
class AuthService {
  /// Firebase Auth 싱글턴 인스턴스
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Google 로그인 SDK 인스턴스
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  /// Cloud Functions 인스턴스 (카카오/네이버 Custom Token 발급용)
  final FirebaseFunctions _functions = FirebaseFunctions.instance;


  /// 현재 로그인된 Firebase 사용자 (`Getter`)
  ///
  /// - **Returns**: `User?` — 로그인 상태이면 User, 아니면 null
  User? get currentUser => _auth.currentUser;

  /// 로그인 상태 변경 스트림 (`Stream`)
  ///
  /// - **Returns**: `Stream<User?>` — 로그인/로그아웃 시 새 값 방출
  /// - **호출**: app.dart의 StreamBuilder에서 구독하여 PairingGate 분기
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // ─── Google ───

  /// Google 소셜 로그인 (`Method`, async)
  ///
  /// GoogleSignIn SDK로 사용자 선택 → accessToken + idToken 획득 →
  /// `GoogleAuthProvider.credential()`로 Firebase Auth 로그인.
  ///
  /// - **Returns**: `User?` — 로그인 성공 시 Firebase User, 취소 시 null
  /// - **Side Effects**: Firebase Auth 상태 변경 → authStateChanges 스트림 방출
  /// - **호출**: login_screen.dart의 Google 로그인 버튼
  Future<User?> signInWithGoogle() async {
    final googleUser = await _googleSignIn.signIn();
    if (googleUser == null) return null;

    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final userCredential = await _auth.signInWithCredential(credential);
    print('Google 로그인 성공: ${userCredential.user?.displayName}');
    return userCredential.user;
  }

  // ─── Apple ───

  /// Apple 소셜 로그인 (`Method`, async)
  ///
  /// Sign In with Apple로 identityToken 획득 → OAuthProvider('apple.com')으로
  /// Firebase Auth 로그인. 보안을 위해 rawNonce + SHA256 해시 사용.
  ///
  /// - **Returns**: `User?` — 로그인 성공 시 Firebase User
  /// - **Side Effects**: Firebase Auth 상태 변경 → authStateChanges 스트림 방출
  /// - **호출**: login_screen.dart의 Apple 로그인 버튼 (iOS 전용)
  Future<User?> signInWithApple() async {
    final rawNonce = _generateNonce();
    final nonce = _sha256ofString(rawNonce);

    final appleCredential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: nonce,
    );

    final oauthCredential = OAuthProvider('apple.com').credential(
      idToken: appleCredential.identityToken,
      rawNonce: rawNonce,
    );

    final userCredential = await _auth.signInWithCredential(oauthCredential);
    print('Apple 로그인 성공: ${userCredential.user?.displayName}');
    return userCredential.user;
  }

  // ─── 카카오 ───

  /// 카카오 소셜 로그인 (`Method`, async)
  ///
  /// 카카오톡 설치 여부에 따라 앱 로그인 / 웹 계정 로그인 분기.
  /// accessToken을 Cloud Function(`kakaoCustomToken`)에 전달하여
  /// Firebase Custom Token을 발급받고 `signInWithCustomToken()`으로 최종 로그인.
  ///
  /// - **Returns**: `User?` — 로그인 성공 시 Firebase User (uid: `kakao:{kakaoId}`)
  /// - **Side Effects**: Firebase Auth 상태 변경, Cloud Function 1회 호출
  /// - **호출**: login_screen.dart의 카카오 로그인 버튼
  Future<User?> signInWithKakao() async {
    // 디버그: 실제 키 해시 출력
    final keyHash = await kakao.KakaoSdk.origin;
    print('카카오 SDK origin (keyHash): $keyHash');

    // 카카오 로그인 (카카오톡 설치 여부에 따라 분기)
    kakao.OAuthToken token;
    if (await kakao.isKakaoTalkInstalled()) {
      token = await kakao.UserApi.instance.loginWithKakaoTalk();
    } else {
      token = await kakao.UserApi.instance.loginWithKakaoAccount();
    }

    print('카카오 access token 획득');

    // Cloud Function 호출 → Firebase Custom Token
    final result = await _functions.httpsCallable('kakaoCustomToken').call({
      'accessToken': token.accessToken,
    });

    final customToken = result.data['customToken'] as String;
    final userCredential = await _auth.signInWithCustomToken(customToken);
    print('카카오 로그인 성공: ${userCredential.user?.uid}');
    return userCredential.user;
  }

  // ─── 네이버 ───

  /// 네이버 네이티브 SDK와 통신하는 MethodChannel
  ///
  /// flutter_naver_login 플러그인 대신 네이티브 SDK를 직접 사용.
  /// Android: `MainActivity`에서 `com.seniorcare.family/naver_login` 채널 등록.
  static const _naverChannel = MethodChannel('com.seniorcare.family/naver_login');

  /// 네이버 소셜 로그인 (`Method`, async)
  ///
  /// MethodChannel로 네이티브 Naver SDK 호출 → accessToken 획득 →
  /// Cloud Function(`naverCustomToken`)에 전달하여 Firebase Custom Token 발급 →
  /// `signInWithCustomToken()`으로 최종 로그인.
  ///
  /// - **Returns**: `User?` — 로그인 성공 시 Firebase User (uid: `naver:{naverId}`)
  /// - **Side Effects**: Firebase Auth 상태 변경, Cloud Function 1회 호출
  /// - **호출**: login_screen.dart의 네이버 로그인 버튼
  Future<User?> signInWithNaver() async {
    final result = await _naverChannel.invokeMapMethod<String, dynamic>('logIn');
    final accessToken = result?['accessToken'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw Exception('네이버 access token 없음');
    }
    print('네이버 access token 획득');

    // Cloud Function 호출 → Firebase Custom Token
    final res = await _functions.httpsCallable('naverCustomToken').call({
      'accessToken': accessToken,
    });

    final customToken = res.data['customToken'] as String;
    final userCredential = await _auth.signInWithCustomToken(customToken);
    print('네이버 로그인 성공: ${userCredential.user?.uid}');
    return userCredential.user;
  }

  // ─── 로그아웃 ───

  /// 로그아웃 (`Method`, async)
  ///
  /// Google SDK 로그아웃 (실패해도 무시) + Firebase Auth 로그아웃.
  /// 카카오/네이버는 Firebase Auth signOut만으로 충분 (Custom Token 방식).
  ///
  /// - **Side Effects**: Firebase Auth 상태 변경 → authStateChanges 스트림에 null 방출
  /// - **호출**: device_list_screen.dart 우상단 로그아웃 버튼
  Future<void> signOut() async {
    try { await _googleSignIn.signOut(); } catch (_) {}
    await _auth.signOut();
    print('로그아웃 완료');
  }

  // ─── 헬퍼 ───

  /// 암호학적으로 안전한 랜덤 nonce 문자열 생성 (`Utility`)
  ///
  /// Apple 로그인의 replay attack 방지를 위해 사용.
  ///
  /// - **Params**:
  ///   - [length] — nonce 길이 (기본 32)
  /// - **Returns**: `String` — 영숫자 + 특수문자로 구성된 랜덤 문자열
  String _generateNonce([int length = 32]) {
    const charset = '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(length, (_) => charset[random.nextInt(charset.length)]).join();
  }

  /// 문자열의 SHA256 해시 계산 (`Utility`)
  ///
  /// Apple 로그인 시 rawNonce를 해싱하여 Apple 서버에 전달.
  ///
  /// - **Params**:
  ///   - [input] — 해시할 원본 문자열
  /// - **Returns**: `String` — 16진수 SHA256 해시 문자열
  String _sha256ofString(String input) {
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
}
