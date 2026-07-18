import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../models/conversation.dart';
import '../services/auth_service.dart';
import '../services/live_session.dart';
import '../services/voice_preference.dart';
import '../utils/wav_encoder.dart';

class LiveScreen extends StatefulWidget {
  final Conversation? conversation;
  const LiveScreen({super.key, this.conversation});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  CameraController? _camera;
  Future<void>? _cameraInit;
  Timer? _frameTimer;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _pcmSub;
  bool _isRecording = false;

  final LiveSession _session = LiveSession();
  StreamSubscription<Object>? _eventSub;

  final AudioPlayer _player = AudioPlayer();
  final BytesBuilder _pcmBuffer = BytesBuilder();
  bool _isAssistantSpeaking = false;

  final List<_Line> _lines = [];
  String _statusText = 'Bağlanıyor…';
  String? _errorText;

  // Gemini Live'ın kullandığı ses adları — Faz 2 TTS'inden ayrı (Puck/Charon/Kore/vs)
  static const _liveVoiceMap = {
    'tr-TR-EmelNeural': 'Aoede', // kadın hissi
    'tr-TR-AhmetNeural': 'Puck', // erkek hissi
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    // Provider okumalarını await'ten önce yap (context async-safe)
    final auth = context.read<AuthService>();
    final voicePref = context.read<VoicePreference>().voice;

    // 1) Kamera
    try {
      final cams = await availableCameras();
      if (cams.isNotEmpty) {
        _camera = CameraController(
          cams.first,
          ResolutionPreset.medium,
          enableAudio: false,
          imageFormatGroup: ImageFormatGroup.jpeg,
        );
        _cameraInit = _camera!.initialize();
        await _cameraInit;
        if (!mounted) return;
        setState(() {});
        _startFrameTimer();
      }
    } catch (e) {
      _appendError('Kamera açılamadı: $e');
    }

    // 2) Live oturum
    final token = auth.accessToken;
    if (token == null) {
      _appendError('Oturum yok — tekrar giriş yap.');
      return;
    }
    final voice = _liveVoiceMap[voicePref] ?? 'Puck';

    _eventSub = _session.events.listen(_onSessionEvent);
    _session.addListener(_onSessionStateChanged);
    await _session.connect(token: token, voice: voice);
  }

  void _onSessionStateChanged() {
    if (!mounted) return;
    setState(() {
      switch (_session.state) {
        case LiveConnectionState.disconnected:
          _statusText = 'Bağlantı kapandı';
          break;
        case LiveConnectionState.connecting:
          _statusText = 'Bağlanıyor…';
          break;
        case LiveConnectionState.connected:
          _statusText = 'Hazır — mikrofona basılı tut';
          break;
        case LiveConnectionState.error:
          _statusText = 'Hata';
          _errorText = _session.errorMessage;
          break;
      }
    });
  }

  void _onSessionEvent(Object event) {
    if (!mounted) return;
    if (event is LiveAudioChunk) {
      _pcmBuffer.add(event.pcm);
      if (!_isAssistantSpeaking) {
        setState(() {
          _isAssistantSpeaking = true;
          _statusText = 'Ahlas konuşuyor…';
        });
      }
    } else if (event is LiveTranscript) {
      setState(() {
        // Aynı role'un peş peşe transcript'lerini birleştir
        if (_lines.isNotEmpty && _lines.last.role == event.role) {
          _lines.last.text += event.text;
        } else {
          _lines.add(_Line(event.role, event.text));
        }
        if (_lines.length > 20) _lines.removeAt(0);
      });
    } else if (event is LiveTurnComplete) {
      _flushAssistantAudio();
    } else if (event is LiveInterrupted) {
      _player.stop();
      _pcmBuffer.clear();
      setState(() {
        _isAssistantSpeaking = false;
        _statusText = 'Kesildi';
      });
    } else if (event is LiveError) {
      _appendError('${event.code}: ${event.message}');
    }
  }

  Future<void> _flushAssistantAudio() async {
    final pcm = _pcmBuffer.toBytes();
    _pcmBuffer.clear();
    setState(() {
      _isAssistantSpeaking = false;
      _statusText = _session.isConnected
          ? 'Hazır — mikrofona basılı tut'
          : 'Bağlantı kapandı';
    });
    if (pcm.isEmpty) return;
    // Gemini Live: 24kHz mono s16le PCM
    final wav = wrapPcmAsWav(pcm, sampleRate: 24000);
    try {
      await _player.stop();
      await _player.play(BytesSource(wav, mimeType: 'audio/wav'));
    } catch (e) {
      _appendError('Ses çalınamadı: $e');
    }
  }

  void _startFrameTimer() {
    _frameTimer?.cancel();
    _frameTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final cam = _camera;
      if (cam == null || !cam.value.isInitialized) return;
      if (!_session.isConnected) return;
      try {
        // takePicture kısa süreli preview donması yapar — 1fps için tolere edilir
        final XFile shot = await cam.takePicture();
        Uint8List bytes;
        if (kIsWeb) {
          bytes = await shot.readAsBytes();
        } else {
          bytes = await File(shot.path).readAsBytes();
        }
        _session.sendVideoFrame(bytes);
      } catch (_) {
        // Yakalanmayan frame — sonraki tick tekrar dener
      }
    });
  }

  // ---------- Mic PTT ----------

  Future<void> _startPtt() async {
    if (_isRecording) return;
    if (!_session.isConnected) return;
    if (_isAssistantSpeaking) {
      // MVP: assistant konuşurken kesme desteklemiyoruz
      return;
    }
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      _appendError('Mikrofon izni verilmedi.');
      return;
    }
    try {
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ));
      _pcmSub = stream.listen((chunk) {
        _session.sendAudioChunk(chunk);
      });
      setState(() {
        _isRecording = true;
        _statusText = 'Dinliyorum…';
      });
    } catch (e) {
      _appendError('Mikrofon başlatılamadı: $e');
    }
  }

  Future<void> _endPtt() async {
    if (!_isRecording) return;
    try {
      await _recorder.stop();
    } catch (_) {}
    await _pcmSub?.cancel();
    _pcmSub = null;
    _session.endAudioTurn();
    setState(() {
      _isRecording = false;
      _statusText = 'Ahlas dinliyor…';
    });
  }

  void _appendError(String msg) {
    if (!mounted) return;
    setState(() {
      _errorText = msg;
    });
  }

  @override
  void dispose() {
    _frameTimer?.cancel();
    _pcmSub?.cancel();
    _recorder.dispose();
    _eventSub?.cancel();
    _session.removeListener(_onSessionStateChanged);
    _session.dispose();
    _player.dispose();
    _camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Kamera preview arka planda
            Positioned.fill(child: _buildCameraLayer()),

            // Üstte kapatma butonu + status
            _buildTopBar(),

            // Ortada transcript'ler
            _buildTranscriptOverlay(),

            // Altta mic butonu
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 40),
                child: _buildMicButton(),
              ),
            ),

            if (_errorText != null) _buildErrorBanner(),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraLayer() {
    if (_camera == null || !_camera!.value.isInitialized) {
      return Container(
        color: Colors.grey.shade900,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam_off_outlined, size: 64, color: Colors.white54),
              SizedBox(height: 12),
              Text('Kamera bekleniyor…',
                  style: TextStyle(color: Colors.white54)),
            ],
          ),
        ),
      );
    }
    return CameraPreview(_camera!);
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: Row(
        children: [
          _iconChip(
            icon: Icons.close,
            onTap: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  _StatusDot(
                    color: _statusDotColor(),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _statusText,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _statusDotColor() {
    switch (_session.state) {
      case LiveConnectionState.connected:
        if (_isRecording) return Colors.red;
        if (_isAssistantSpeaking) return Colors.blueAccent;
        return Colors.greenAccent;
      case LiveConnectionState.connecting:
        return Colors.amberAccent;
      case LiveConnectionState.error:
        return Colors.redAccent;
      case LiveConnectionState.disconnected:
        return Colors.grey;
    }
  }

  Widget _iconChip({required IconData icon, required VoidCallback onTap}) {
    return InkResponse(
      onTap: onTap,
      radius: 24,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.5),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

  Widget _buildTranscriptOverlay() {
    if (_lines.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: 16,
      right: 16,
      bottom: 160,
      top: 80,
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.bottomLeft,
          child: SingleChildScrollView(
            reverse: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: _lines
                  .map((l) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: (l.role == 'user'
                                    ? Colors.deepPurple
                                    : Colors.blueGrey)
                                .withOpacity(0.75),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            l.text,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 14, height: 1.3),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMicButton() {
    final bg = _isRecording ? Colors.red : Colors.white;
    final fg = _isRecording ? Colors.white : Colors.black;
    return GestureDetector(
      onTapDown: (_) => _startPtt(),
      onTapUp: (_) => _endPtt(),
      onTapCancel: _endPtt,
      child: Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: (_isRecording ? Colors.red : Colors.white)
                  .withOpacity(0.4),
              blurRadius: 24,
              spreadRadius: 4,
            ),
          ],
        ),
        child: Icon(Icons.mic, color: fg, size: 44),
      ),
    );
  }

  Widget _buildErrorBanner() {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 160,
      child: Material(
        color: Colors.redAccent.shade700,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _errorText ?? '',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 18),
                onPressed: () => setState(() => _errorText = null),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Line {
  final String role;
  String text;
  _Line(this.role, this.text);
}

class _StatusDot extends StatelessWidget {
  final Color color;
  const _StatusDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}
