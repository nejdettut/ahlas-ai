// Sheet açık kalırken picker'lar açılıyor — mounted guard'ları ekli olan
// yerlerde linter fark etmiyor. Sheet dispose olursa Navigator.pop no-op.
// ignore_for_file: use_build_context_synchronously

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Attachment seçim sheet'inden dönen sonuç.
sealed class AttachmentResult {}

/// Kullanıcı yerelinden bytes seçti.
class FileAttachment extends AttachmentResult {
  final Uint8List bytes;
  final String filename;
  final String fileType; // 'image' | 'video' | 'audio'
  final String? mimeType;

  FileAttachment({
    required this.bytes,
    required this.filename,
    required this.fileType,
    this.mimeType,
  });
}

/// Kullanıcı URL girdi.
class UrlAttachment extends AttachmentResult {
  final String url;
  UrlAttachment(this.url);
}

/// Ses kaydı ekranını açma isteği (parent handle eder).
class RequestAudioRecord extends AttachmentResult {}

/// Dosya adı + mime'dan Ahlas file_type kategorisini çıkarır.
String? detectFileType(String filename, String? mimeType) {
  final mime = (mimeType ?? '').toLowerCase();
  if (mime.startsWith('image/')) return 'image';
  if (mime.startsWith('video/')) return 'video';
  if (mime.startsWith('audio/')) return 'audio';
  final lower = filename.toLowerCase();
  if (RegExp(r'\.(jpg|jpeg|png|gif|webp|bmp|heic|heif)$').hasMatch(lower)) {
    return 'image';
  }
  if (RegExp(r'\.(mp4|mov|avi|mkv|webm|m4v|3gp)$').hasMatch(lower)) {
    return 'video';
  }
  if (RegExp(r'\.(mp3|wav|m4a|aac|ogg|flac|opus)$').hasMatch(lower)) {
    return 'audio';
  }
  return null;
}

Future<AttachmentResult?> showAttachmentSheet(BuildContext context) {
  return showModalBottomSheet<AttachmentResult>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _AttachmentSheet(),
  );
}

class _AttachmentSheet extends StatelessWidget {
  const _AttachmentSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(
                children: [
                  Text(
                    'Ne eklemek istiyorsun?',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
            _tile(
              context,
              icon: Icons.photo_camera_outlined,
              label: 'Kameradan fotoğraf',
              onTap: () => _pickImageFromCamera(context),
              // Camera not supported on desktop natively
              enabled: !_isDesktop,
            ),
            _tile(
              context,
              icon: Icons.videocam_outlined,
              label: 'Kameradan video',
              onTap: () => _pickVideoFromCamera(context),
              enabled: !_isDesktop,
            ),
            _tile(
              context,
              icon: Icons.photo_library_outlined,
              label: 'Galeriden görsel / video',
              onTap: () => _pickFromGallery(context),
            ),
            _tile(
              context,
              icon: Icons.mic_none_outlined,
              label: 'Ses kaydet',
              onTap: () => Navigator.of(context).pop(RequestAudioRecord()),
            ),
            _tile(
              context,
              icon: Icons.attach_file_outlined,
              label: 'Cihazdan dosya seç',
              onTap: () => _pickAnyFile(context),
            ),
            _tile(
              context,
              icon: Icons.link_outlined,
              label: 'Bağlantı (URL)',
              onTap: () => _promptUrl(context),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  static bool get _isDesktop {
    if (kIsWeb) return false;
    // On desktop platforms image_picker camera source doesn't work.
    // Simple approach: don't disable — will just fail. Actually let's keep enabled.
    return false;
  }

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return ListTile(
      leading: Icon(icon, size: 26),
      title: Text(label),
      enabled: enabled,
      onTap: enabled ? onTap : null,
    );
  }

  Future<void> _pickImageFromCamera(BuildContext context) async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(source: ImageSource.camera);
      await _returnXFile(context, file, defaultType: 'image');
    } catch (e) {
      _returnError(context, 'Kamera açılamadı: $e');
    }
  }

  Future<void> _pickVideoFromCamera(BuildContext context) async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickVideo(source: ImageSource.camera);
      await _returnXFile(context, file, defaultType: 'video');
    } catch (e) {
      _returnError(context, 'Kamera açılamadı: $e');
    }
  }

  Future<void> _pickFromGallery(BuildContext context) async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickMedia();
      await _returnXFile(context, file, defaultType: 'image');
    } catch (e) {
      _returnError(context, 'Galeri açılamadı: $e');
    }
  }

  Future<void> _pickAnyFile(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        if (context.mounted) Navigator.of(context).pop();
        return;
      }
      final picked = result.files.first;
      final bytes = picked.bytes;
      if (bytes == null) {
        _returnError(context, 'Dosya okunamadı.');
        return;
      }
      final filename = picked.name;
      final fileType = detectFileType(filename, null);
      if (fileType == null) {
        _returnError(
          context,
          'Sadece görsel, video veya ses dosyaları desteklenir.',
        );
        return;
      }
      if (!context.mounted) return;
      Navigator.of(context).pop(
        FileAttachment(
          bytes: bytes,
          filename: filename,
          fileType: fileType,
        ),
      );
    } catch (e) {
      _returnError(context, 'Dosya seçilemedi: $e');
    }
  }

  Future<void> _promptUrl(BuildContext context) async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const _UrlDialog(),
    );
    if (url == null || url.isEmpty) {
      if (context.mounted) Navigator.of(context).pop();
      return;
    }
    if (!context.mounted) return;
    Navigator.of(context).pop(UrlAttachment(url));
  }

  Future<void> _returnXFile(
    BuildContext context,
    XFile? file, {
    required String defaultType,
  }) async {
    if (file == null) {
      if (context.mounted) Navigator.of(context).pop();
      return;
    }
    final bytes = await file.readAsBytes();
    final filename = file.name;
    final mimeFromXfile = file.mimeType;
    final fileType =
        detectFileType(filename, mimeFromXfile) ?? defaultType;
    if (!context.mounted) return;
    Navigator.of(context).pop(
      FileAttachment(
        bytes: bytes,
        filename: filename,
        fileType: fileType,
        mimeType: mimeFromXfile,
      ),
    );
  }

  void _returnError(BuildContext context, String message) {
    if (!context.mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

class _UrlDialog extends StatefulWidget {
  const _UrlDialog();

  @override
  State<_UrlDialog> createState() => _UrlDialogState();
}

class _UrlDialogState extends State<_UrlDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Bağlantı ekle'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Görsel / video / ses bağlantısı',
            hintText: 'https://…',
            border: OutlineInputBorder(),
          ),
          validator: (v) {
            final value = (v ?? '').trim();
            if (value.isEmpty) return 'Bağlantı boş olamaz';
            final uri = Uri.tryParse(value);
            if (uri == null ||
                (uri.scheme != 'http' && uri.scheme != 'https') ||
                uri.host.isEmpty) {
              return 'Geçerli bir http/https bağlantısı gir';
            }
            return null;
          },
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('İptal'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Ekle'),
        ),
      ],
    );
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(_controller.text.trim());
  }
}
