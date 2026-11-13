import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:android_id/android_id.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://sdectcjfuiswahjfdwme.supabase.co',
    anonKey: 'sb_publishable_pDWa6T015D6fMYOEn5jAIg_Wog39wND',
  );

  final prefs = await SharedPreferences.getInstance();
  final bool isLoggedIn = prefs.getBool('is_logged_in') ?? false;

  runApp(MyApp(isLoggedIn: isLoggedIn));
}

class MyApp extends StatelessWidget {
  final bool isLoggedIn;
  const MyApp({super.key, required this.isLoggedIn});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ANYtoANY',
      theme: ThemeData.dark(useMaterial3: true),
      home: isLoggedIn ? const HomeScreen() : const AuthScreen(),
    );
  }
}

// ================= 1. KIRISH VA OTP =================
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  bool _codeSent = false;
  bool _loading = false;

  Future<void> _sendOtp() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('To\'g\'ri elektron pochta kiriting!')),
      );
      return;
    }

    setState(() => _loading = true);
    try {
      await Supabase.instance.client.auth.signInWithOtp(email: email);
      setState(() => _codeSent = true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pochtangizga tasdiqlash kodi yuborildi!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Xatolik: $e')),
        );
      }
    }
    setState(() => _loading = false);
  }

  Future<void> _verifyOtp() async {
    final email = _emailController.text.trim();
    final code = _otpController.text.trim();
    if (code.isEmpty) return;

    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.auth.verifyOTP(
        email: email,
        token: code,
        type: OtpType.email,
      );

      if (res.user != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('is_logged_in', true);
        await prefs.setString('user_id', res.user!.id);
        await prefs.setString('user_email', email);

        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const HomeScreen()),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Kod xato yoki muddati o\'tgan!')),
        );
      }
    }
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tizimga kirish'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.picture_as_pdf_rounded, size: 72, color: Colors.tealAccent),
            const SizedBox(height: 16),
            const Text(
              'Media & PDF Converter',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _emailController,
              enabled: !_codeSent,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Elektron pochta (Email)',
                prefixIcon: Icon(Icons.email_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            if (_codeSent) ...[
              TextField(
                controller: _otpController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Pochtaga kelgan 6 xonali kod',
                  prefixIcon: Icon(Icons.lock_outline),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
            ],
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)),
                onPressed: _loading ? null : (_codeSent ? _verifyOtp : _sendOtp),
                child: Text(_loading ? 'Kuting...' : (_codeSent ? 'Tasdiqlash va Kirish' : 'Kod Yuborish')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ================= 2. ASOSIY OYNA (KONVERTER, KODEK, PDF O'QUVCHI) =================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  String _deviceId = 'Aniqlanmoqda...';
  int _totalSeconds = 0;
  bool _isPro = false;
  Timer? _usageTimer;

  List<PlatformFile> _selectedFiles = [];
  String _targetFormat = 'mp3';
  String _videoCodec = 'libx264'; // Video kodek (H.264, H.265, VP9)
  bool _isConverting = false;
  int _completedCount = 0;
  String _savedFolderPath = '';

  final List<String> _formats = [
    'mp3', 'wav', 'aac', 'm4a', 'flac',
    'mp4', 'mkv', 'avi', 'mov', 'webm',
    'pdf', 'png', 'jpg'
  ];

  final List> _codecs = [
    {'name': 'H.264 (Standard MP4)', 'val': 'libx264'},
    {'name': 'H.265 / HEVC (Yuqori sifat)', 'val': 'libx265'},
    {'name': 'VP9 (WebM uchun)', 'val': 'libvpx-vp9'},
    {'name': 'Kodekni o\'zgartirmasdan (Kopiya)', 'val': 'copy'},
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initDeviceAndSync();
    _startTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _syncToServer();
    }
  }

  Future<void> _initDeviceAndSync() async {
    const androidIdPlugin = AndroidId();
    final String? id = await androidIdPlugin.getId();
    final prefs = await SharedPreferences.getInstance();

    final String deviceId = id ?? 'unknown_device';
    int localSec = prefs.getInt('total_seconds') ?? 0;
    bool localPro = prefs.getBool('is_pro') ?? false;

    setState(() {
      _deviceId = deviceId;
      _totalSeconds = localSec;
      _isPro = localPro;
    });

    try {
      final String? userId = prefs.getString('user_id');
      final existing = await Supabase.instance.client
          .from('user_profiles')
          .select()
          .or('id.eq.$userId,android_id.eq.$deviceId')
          .limit(1)
          .maybeSingle();

      if (existing != null) {
        final int serverSec = existing['total_seconds'] ?? 0;
        final bool serverPro = existing['is_pro'] ?? false;
        if (serverSec > _totalSeconds) {
          _totalSeconds = serverSec;
          await prefs.setInt('total_seconds', _totalSeconds);
        }
        _isPro = serverPro;
        await prefs.setBool('is_pro', _isPro);
        setState(() {});
      }
    } catch (_) {}
  }

  void _startTimer() {
    _usageTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      setState(() => _totalSeconds += 10);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('total_seconds', _totalSeconds);
      if (_totalSeconds % 60 == 0) _syncToServer();
    });
  }

  Future<void> _syncToServer() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id');
      if (userId != null) {
        await Supabase.instance.client.from('user_profiles').update({
          'total_seconds': _totalSeconds,
          'android_id': _deviceId,
          'updated_at': DateTime.now().toIso8601String(),
        }).eq('id', userId);
      }
    } catch (_) {}
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
    );
    if (result != null) {
      if (!_isPro && result.files.length > 3) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bepul tarifda max 3 ta fayl! 20+ uchun PRO oling.')),
        );
        setState(() => _selectedFiles = result.files.take(3).toList());
      } else {
        setState(() => _selectedFiles = result.files);
      }
    }
  }

  // Oflayn konvertatsiya (Media, Kodek o'zgartirish va PDF/Rasm konvertatsiyasi)
  Future<void> _convertFiles() async {
    if (_selectedFiles.isEmpty) return;
    setState(() {
      _isConverting = true;
      _completedCount = 0;
    });

    Directory? outDir = Directory('/storage/emulated/0/Download');
    if (!await outDir.exists()) {
      outDir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    }
    _savedFolderPath = outDir.path;

    const int batchSize = 4;
    for (int i = 0; i < _selectedFiles.length; i += batchSize) {
      final batch = _selectedFiles.skip(i).take(batchSize);
      await Future.wait(batch.map((file) async {
        if (file.path == null) return;
        final baseName = file.name.replaceAll(RegExp(r'\.[^\.]+$'), '');
        final outPath = '${outDir!.path}/${baseName}_conv.${_targetFormat}';

        String ffmpegCommand = '';
        // Agar video kodek o'zgartirilayotgan bo'lsa
        if (['mp4', 'mkv', 'webm', 'mov'].contains(_targetFormat)) {
          ffmpegCommand = '-y -i "${file.path}" -c:v $_videoCodec -c:a aac "$outPath"';
        } else {
          ffmpegCommand = '-y -i "${file.path}" "$outPath"';
        }

        final session = await FFmpegKit.execute(ffmpegCommand);
        final rc = await session.getReturnCode();
        if (ReturnCode.isSuccess(rc) && mounted) {
          setState(() => _completedCount++);
        }
      }));
    }

    setState(() => _isConverting = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saqlandi: $_savedFolderPath ($_completedCount ta)')),
      );
    }
  }

  // PDF Faylni ilovaning o'zida ochib o'qish oynasi
  void _openPdfViewer(String filePath) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PdfViewerScreen(pdfPath: filePath),
      ),
    );
  }

  void _showTariffModal() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('PRO Tarif (20+ Fayl & Barcha Kodeklar)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('• 20+ faylni bir vaqtda qayta ishlash'),
            const Text('• H.265 va VP9 ilg' 'or video kodeklari'),
            const Text('• PDF va multimedia tahrirlash'),
            const Divider(),
            const Text('Karta / Hisob raqam:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SelectableText('4466 1369 5239 9476', style: TextStyle(color: Colors.tealAccent)),
            const SizedBox(height: 8),
            Text('Sizning ID: $_deviceId', style: const TextStyle(fontSize: 11)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _initDeviceAndSync();
              Navigator.pop(context);
            },
            child: const Text('Statusni yangilash'),
          ),
          ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('Yopish')),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _usageTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ANYtoANY'),
        actions: [
          ActionChip(
            avatar: Icon(Icons.star, color: _isPro ? Colors.amber : Colors.grey),
            label: Text(_isPro ? 'PRO' : 'PRO OLISH'),
            onPressed: _showTariffModal,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.phonelink_setup, color: Colors.tealAccent),
                title: Text('ID: $_deviceId', style: const TextStyle(fontSize: 12)),
                subtitle: Text('Ishlatilgan vaqt: ${_totalSeconds ~/ 60} daqiqa'),
              ),
            ),
            const SizedBox(height: 12),

            // Format va Kodek tanlash
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isConverting ? null : _pickFiles,
                    icon: const Icon(Icons.folder_open),
                    label: Text(_isPro ? 'Fayl tanlash (20+)' : 'Fayl tanlash (Max 3)'),
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: _targetFormat,
                  items: _formats.map((f) => DropdownMenuItem(value: f, child: Text(f.toUpperCase()))).toList(),
                  onChanged: (v) => setState(() => _targetFormat = v!),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Agar video format tanlansa, kodek tanlash chiqadi
            if (['mp4', 'mkv', 'webm', 'mov'].contains(_targetFormat))
              DropdownButtonFormField<String>(
                value: _videoCodec,
                decoration: const InputDecoration(labelText: 'Video Kodekni Tanlang', border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 5)),
                items: _codecs.map((c) => DropdownMenuItem(value: c['val'], child: Text(c['name']!))).toList(),
                onChanged: (v) => setState(() => _videoCodec = v!),
              ),

            const SizedBox(height: 12),
            if (_isConverting)
              LinearProgressIndicator(value: _selectedFiles.isEmpty ? 0 : _completedCount / _selectedFiles.length),

            Expanded(
              child: ListView.builder(
                itemCount: _selectedFiles.length,
                itemBuilder: (ctx, i) {
                  final f = _selectedFiles[i];
                  final isPdf = f.name.endsWith('.pdf');
                  return ListTile(
                    leading: Icon(isPdf ? Icons.picture_as_pdf : Icons.insert_drive_file, color: isPdf ? Colors.redAccent : Colors.teal),
                    title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${(f.size / 1024 / 1024).toStringAsFixed(2)} MB'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isPdf && f.path != null)
                          IconButton(
                            icon: const Icon(Icons.remove_red_eye, color: Colors.blueAccent),
                            tooltip: 'PDF ni ochish',
                            onPressed: () => _openPdfViewer(f.path!),
                          ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _selectedFiles.removeAt(i)),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
                onPressed: (_selectedFiles.isEmpty || _isConverting) ? null : _convertFiles,
                child: Text(_isConverting ? 'Bajarilmoqda...' : 'Konvertatsiya qilish (Oflayn)'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ================= 3. IN-APP PDF VIEWER (PDF O'QUVCHI OYNASI) =================
class PdfViewerScreen extends StatefulWidget {
  final String pdfPath;
  const PdfViewerScreen({super.key, required this.pdfPath});

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  late pdfx.PdfDocument? _pdfDocument;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPdf();
  }

  Future<void> _loadPdf() async {
    try {
      _pdfDocument = await pdfx.PdfDocument.openFile(widget.pdfPath);
    } catch (_) {
      _pdfDocument = null;
    }
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PDF Ko\'rish')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _pdfDocument == null
              ? const Center(child: Text('PDF faylni ochib bo\'lmadi!'))
              : pdfx.PdfView(
                  controller: pdfx.PdfController(
                    document: pdfx.PdfDocument.openFile(widget.pdfPath),
                  ),
                ),
    );
  }
}
