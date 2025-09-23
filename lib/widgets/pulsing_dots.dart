import 'dart:async';
import 'package:flutter/material.dart';

class PulsingDots extends StatefulWidget {
  final double size;
  final Color color;
  final Duration period;
  const PulsingDots({super.key, this.size = 8, this.color = Colors.grey, this.period = const Duration(milliseconds: 900)});

  @override
  State<PulsingDots> createState() => _PulsingDotsState();
}

class _PulsingDotsState extends State<PulsingDots> {
  int _active = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.period ~/ 3, (_) {
      if (!mounted) return;
      setState(() => _active = (_active + 1) % 3);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sizes = List<double>.generate(3, (i) => i == _active ? widget.size * 1.8 : widget.size);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) => AnimatedContainer(
        duration: widget.period ~/ 3,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        width: sizes[i],
        height: sizes[i],
        decoration: BoxDecoration(color: widget.color.withOpacity(0.8), shape: BoxShape.circle),
      )),
    );
  }
}
