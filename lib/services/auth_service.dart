import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart' as kakao;
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/services.dart';

/// 인증 서비스 — 소셜 로그인/로그아웃
class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();
  final FirebaseFunctions _functions = FirebaseFunctions.instance;


  /// 현재 로그인된 사용자
  User? get currentUser => _auth.currentUser;

  /// 로그인 상태 스트림
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // ─── Google ───

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

  static const _naverChannel = MethodChannel('com.seniorcare.family/naver_login');

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

  Future<void> signOut() async {
    try { await _googleSignIn.signOut(); } catch (_) {}
    await _auth.signOut();
    print('로그아웃 완료');
  }

  // ─── 헬퍼 ───

  String _generateNonce([int length = 32]) {
    const charset = '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(length, (_) => charset[random.nextInt(charset.length)]).join();
  }

  String _sha256ofString(String input) {
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
}
