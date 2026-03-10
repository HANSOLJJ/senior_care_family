import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';

/// 소셜 로그인 화면
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final AuthService _auth = AuthService();
  bool _loading = false;
  String? _error;


  Future<void> _handleSignIn(String provider, Future<User?> Function() signInFn) async {
    setState(() { _loading = true; _error = null; });
    try {
      final user = await signInFn();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.family_restroom, color: Colors.white, size: 80),
                const SizedBox(height: 24),
                const Text(
                  'Senior Care Family',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '가족과 함께하는 시니어 케어',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 48),

                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),

                if (_loading)
                  const CircularProgressIndicator(color: Colors.white)
                else ...[
                  // Google 로그인
                  _LoginButton(
                    label: 'Google로 로그인',
                    color: Colors.white,
                    textColor: Colors.black87,
                    icon: Icons.g_mobiledata,
                    onTap: () => _handleSignIn('Google', _auth.signInWithGoogle),
                  ),
                  const SizedBox(height: 12),

                  // Apple 로그인 (준비 중)
                  _LoginButton(
                    label: 'Apple로 로그인',
                    color: Colors.white,
                    textColor: Colors.black87,
                    icon: Icons.apple,
                    onTap: () => _handleSignIn('Apple', _auth.signInWithApple),
                  ),
                  const SizedBox(height: 12),

                  // 카카오 로그인
                  _LoginButton(
                    label: '카카오로 로그인',
                    color: const Color(0xFFFEE500),
                    textColor: Colors.black87,
                    icon: Icons.chat_bubble,
                    onTap: () => _handleSignIn('카카오', _auth.signInWithKakao),
                  ),
                  const SizedBox(height: 12),

                  // 네이버 로그인
                  _LoginButton(
                    label: '네이버로 로그인',
                    color: const Color(0xFF03C75A),
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

class _LoginButton extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;
  final IconData icon;
  final VoidCallback onTap;

  const _LoginButton({
    required this.label,
    required this.color,
    required this.textColor,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
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
    );
  }
}
