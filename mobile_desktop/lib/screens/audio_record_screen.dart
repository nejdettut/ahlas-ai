import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class AudioRecordResult {
  final Uint8List bytes;
  final String filename;
  final String mimeType;
  final Duration duration;

  const AudioRecordResult({
    required this.bytes,
    required this.filename,
    required this.mimeType,
    required this.duration,
  });
}

enum _RecordState { idle, recording, stopped }

class AudioRecordScreen extends StatefulWidget {
  const AudioRecordScreen({super.key});

  @override
  State<AudioRecordScreen> createState() => _AudioRecordScreenState();
}

class _AudioRecordScreenState extends State<AudioRecordScreen>
    with SingleTickerProviderStateMixin {
  final AudioRecorder _recorder = AudioRecorder();
  late final AnimationController _pulseController;

  _RecordState _state = _RecordState.idle;
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  Uint8List? _recordedBytes;
  String? _error;
  bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseController.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _isBusy = true;
    });
    try {
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        setState(() {
          _isBusy = false;
          _error = 'Mikrofon izni verilmedi.';
        });
        return;
      }

      final path = await _makeRecordingPath();
      const config = RecordConfig(encoder: AudioEncoder.aacLc);
      await _recorder.start(config, path: path);

      _timer?.cancel();
      _elapsed = Duration.zero;
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return;
        setState(() {
          _elapsed = Duration(seconds: t.tick);
        });
      });

      setState(() {
        _isBusy = false;
        _state = _RecordState.recording;
      });
    } catch (e) {
      setState(() {
        _isBusy = false;
        _error = 'Kayıt başlatılamadı: $e';
      });
    }
  }

  Future<String> _makeRecordingPath() async {
    if (kIsWeb) return 'ahlas_${DateTime.now().millisecondsSinceEpoch}.m4a';
    final dir = await getTemporaryDirectory();
    return '${dir.path}/ahlas_${DateTime.now().millisecondsSinceEpoch}.m4a';
  }

  Future<void> _stop() async {
    setState(() => _isBusy = true);
    try {
      _timer?.cancel();
      final path = await _recorder.stop();
      if (path == null) {
        setState(() {
          _isBusy = false;
          _state = _RecordState.idle;
          _error = 'Kayıt alınamadı.';
        });
        return;
      }
      final bytes = await _readBytes(path);
      setState(() {
        _isBusy = false;
        _state = _RecordState.stopped;
        _recordedBytes = bytes;
      });
    } catch (e) {
      setState(() {
        _isBusy = false;
        _state = _RecordState.idle;
        _error = 'Kayıt durdurulamadı: $e';
      });
    }
  }

  Future<Uint8List> _readBytes(String path) async {
    if (kIsWeb) {
      final response = await Dio().get<List<int>>(
        path,
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (data == null) throw Exception('Boş yanıt');
      return Uint8List.fromList(data);
    }
    return await File(path).readAsBytes();
  }

  Future<void> _redo() async {
    setState(() {
      _state = _RecordState.idle;
      _elapsed = Duration.zero;
      _recordedBytes = null;
      _error = null;
    });
  }

  void _send() {
    final bytes = _recordedBytes;
    if (bytes == null) return;
    final filename = 'ahlas_kayit_${DateTime.now().millisecondsSinceEpoch}.m4a';
    Navigator.of(context).pop(
      AudioRecordResult(
        bytes: bytes,
        filename: filename,
        mimeType: 'audio/aac',
        duration: _elapsed,
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ses kaydet'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              Text(
                _fmt(_elapsed),
                style: Theme.of(context).textTheme.displayMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                _labelForState(),
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: scheme.outline,
                    ),
              ),
              const SizedBox(height: 32),
              _buildMicButton(scheme),
              const SizedBox(height: 32),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(color: scheme.error),
                    textAlign: TextAlign.center,
                  ),
                ),
              const Spacer(),
              _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  String _labelForState() {
    switch (_state) {
      case _RecordState.idle:
        return 'Kaydı başlatmak için mikrofona bas';
      case _RecordState.recording:
        return 'Kayıt sürüyor…';
      case _RecordState.stopped:
        return 'Kayıt hazır — dinleyip gönderebilirsin';
    }
  }

  Widget _buildMicButton(ColorScheme scheme) {
    final isRecording = _state == _RecordState.recording;
    final isStopped = _state == _RecordState.stopped;
    final color = isRecording ? Colors.red : scheme.primary;

    VoidCallback? onTap;
    IconData icon;
    if (isStopped) {
      onTap = _redo;
      icon = Icons.refresh;
    } else if (isRecording) {
      onTap = _isBusy ? null : _stop;
      icon = Icons.stop;
    } else {
      onTap = _isBusy ? null : _start;
      icon = Icons.mic;
    }

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, _) {
        final pulse = isRecording
            ? 1.0 + _pulseController.value * 0.08
            : 1.0;
        return Transform.scale(
          scale: pulse,
          child: InkResponse(
            onTap: onTap,
            radius: 60,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  if (isRecording)
                    BoxShadow(
                      color: color.withOpacity(0.35),
                      blurRadius: 20,
                      spreadRadius: 4,
                    ),
                ],
              ),
              child: Icon(icon, size: 56, color: Colors.white),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBottomBar() {
    final isStopped = _state == _RecordState.stopped;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
            label: const Text('İptal'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            onPressed: isStopped ? _send : null,
            icon: const Icon(Icons.send),
            label: const Text('Gönder'),
          ),
        ),
      ],
    );
  }
}
