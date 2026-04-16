import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import '../widgets/press_scale.dart';

/// 소셜 로그인 화면 (`StatefulWidget`)
///
/// Google, Apple, 카카오, 네이버 4종 로그인 지원.
/// 로그인 성공 시 FirebaseAuth 상태 변경 → app.dart의 StreamBuilder가 자동 감지.
///
/// - **섹션 구성**:
///   - 상태 필드 — 로딩, 에러
///   - 로그인 처리 — _handleSignIn (공통 핸들러)
///   - UI — 로고 + 타이틀 + 에러 + 로그인 버튼 4개
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

/// [LoginScreen]의 `State`
///
/// _handleSignIn()으로 각 provider 로그인 실행, 로딩/에러 상태 관리.
class _LoginScreenState extends State<LoginScreen> {

  // ─── 상태 필드 ───

  /// 인증 서비스 인스턴스
  final AuthService _auth = AuthService();

  /// 로그인 진행 중 로딩 표시
  bool _loading = false;

  /// 로그인 실패 시 에러 메시지 (null이면 에러 없음)
  String? _error;

  // ─── 로그인 처리 ───

  /// 공통 로그인 핸들러 (`Method`, async)
  ///
  /// provider 이름과 로그인 함수를 받아 실행.
  /// 성공 시 FirebaseAuth.authStateChanges() 스트림이
  /// app.dart에서 자동으로 감지하여 PairingGate로 전환.
  ///
  /// - **Params**:
  ///   - [provider] — provider 이름 ("Google", "Apple", "카카오", "네이버")
  ///   - [signInFn] — AuthService의 로그인 함수 참조
  /// - **Returns**: `Future<void>`
  /// - **Side Effects**: [_loading], [_error] 상태 변경
  /// - **호출**: 각 _LoginButton의 onTap
  Future<void> _handleSignIn(String provider, Future<User?> Function() signInFn) async {
    if (_loading) return; // double-tap 차단 (이미 진행 중이면 무시)
    HapticFeedback.lightImpact();
    setState(() { _loading = true; _error = null; });
    try {
      final user = await signInFn();
      // 사용자가 로그인 취소한 경우 (user == null)
      if (user == null && mounted) {
        setState(() { _loading = false; });
      }
    } catch (e) {
      print('$provider 로그인 실패: $e');
      if (mounted) {
        setState(() { _loading = false; _error = '$provider 로그인 실패: $e'; });
      }
    }
  }

  // ─── UI 빌드 ───

  /// 메인 화면 빌드 (`Widget Builder`)
  ///
  /// - **구성**:
  ///   - 로고 아이콘 + 앱 타이틀 + 서브타이틀
  ///   - 에러 메시지 (있을 때만)
  ///   - 로딩 스피너 또는 로그인 버튼 4개
  ///
  /// - **Returns**: `Widget` — 전체 화면 (검은 배경)
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // ─── 로고 + 타이틀 ───
                Icon(Icons.family_restroom, color: cs.primary, size: 80),
                const SizedBox(height: 24),
                const Text(
                  'Senior Care Family',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '가족과 함께하는 시니어 케어',
                  style: TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 48),

                // ─── 에러 메시지 ───
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      _error!,
                      style: TextStyle(color: cs.error, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),

                // ─── 로딩 or 로그인 버튼 4개 ───
                if (_loading)
                  const CircularProgressIndicator()
                else ...[
                  _LoginButton(
                    label: 'Google로 로그인',
                    color: Colors.white,
                    textColor: Colors.black87,
                    icon: Icons.g_mobiledata,
                    onTap: () => _handleSignIn('Google', _auth.signInWithGoogle),
                  ),
                  const SizedBox(height: 12),
                  _LoginButton(
                    label: 'Apple로 로그인',
                    color: Colors.white,
                    textColor: Colors.black87,
                    icon: Icons.apple,
                    onTap: () => _handleSignIn('Apple', _auth.signInWithApple),
                  ),
                  const SizedBox(height: 12),
                  _LoginButton(
                    label: '카카오로 로그인',
                    color: const Color(0xFFFEE500),  // 카카오 브랜드 컬러
                    textColor: Colors.black87,
                    icon: Icons.chat_bubble,
                    onTap: () => _handleSignIn('카카오', _auth.signInWithKakao),
                  ),
                  const SizedBox(height: 12),
                  _LoginButton(
                    label: '네이버로 로그인',
                    color: const Color(0xFF03C75A),  // 네이버 브랜드 컬러
                    textColor: Colors.white,
                    icon: Icons.north_east,
                    onTap: () => _handleSignIn('네이버', _auth.signInWithNaver),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 소셜 로그인 버튼 공통 위젯 (`StatelessWidget`)
///
/// 전체 너비, 48px 높이의 ElevatedButton.
/// provider별 배경색 + 아이콘 + 텍스트.
class _LoginButton extends StatelessWidget {
  /// 버튼 텍스트 (예: "Google로 로그인")
  final String label;

  /// 버튼 배경색 (provider 브랜드 컬러)
  final Color color;

  /// 텍스트 + 아이콘 색상
  final Color textColor;

  /// 좌측 아이콘
  final IconData icon;

  /// 클릭 핸들러 (_handleSignIn 호출)
  final VoidCallback onTap;

  const _LoginButton({
    required this.label,
    required this.color,
    required this.textColor,
    required this.icon,
    required this.onTap,
  });

  /// 버튼 빌드 (`Widget Builder`)
  ///
  /// - **Returns**: `Widget` — 전체 너비 ElevatedButton.icon
  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: ElevatedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, color: textColor, size: 24),
          label: Text(
            label,
            style: TextStyle(color: textColor, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
    );
  }
}
