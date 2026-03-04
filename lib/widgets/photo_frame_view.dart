import 'package:flutter/material.dart';

/// 사진을 전체화면으로 표시하고, 이미지 전환 시 페이드 애니메이션을 적용하는 위젯.
/// [imagePath]가 변경되면 AnimatedSwitcher가 자동으로 페이드 전환을 수행한다.
class PhotoFrameView extends StatelessWidget {
  final String imagePath;
  final Duration transitionDuration;

  const PhotoFrameView({
    super.key,
    required this.imagePath,
    this.transitionDuration = const Duration(milliseconds: 800),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: AnimatedSwitcher(
        duration: transitionDuration,
        child: Image.asset(
          imagePath,
          key: ValueKey<String>(imagePath), // key가 바뀌면 페이드 전환 발생
          fit: BoxFit.contain, // 사진 비율 유지, 잘리지 않음
          width: double.infinity,
          height: double.infinity,
        ),
      ),
    );
  }
}
