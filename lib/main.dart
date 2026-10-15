import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

const _methods = MethodChannel('app.bluetooth.community/methods');
const _events = EventChannel('app.bluetooth.community/events');
const _supportUrl = 'https://wsend.co/967737414884';

void main() => runApp(const BluetoothCommunityApp());

class BluetoothCommunityApp extends StatelessWidget {
  const BluetoothCommunityApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'وصل | تواصل بلوتوث',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff087f8c)),
      useMaterial3: true, scaffoldBackgroundColor: const Color(0xfff5f7f8)),
    home: const HomePage(),
  );
}

class ChatMessage {
  ChatMessage({required this.sender, required this.text, required this.time,
    this.fileName, this.fileBytes, this.mine = false});
  final String sender, text, time;
  final String? fileName;
  final Uint8List? fileBytes;
  final bool mine;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  StreamSubscription? _sub;
  final _name = TextEditingController(text: 'مستخدم');
  final _room = TextEditingController();
  final _message = TextEditingController();
  final _scroll = ScrollController();
  final List<Map<String, dynamic>> _devices = [];
  final List<ChatMessage> _messages = [];
  String _status = 'غير متصل';
  String _roomCode = '';
  String _roomTitle = 'المحادثة';
  String _background = 'فاتح';
  bool _hosting = false, _connected = false, _discovering = false;
  String? _selectedAddress;

  @override void initState() {
    super.initState();
    _sub = _events.receiveBroadcastStream().listen(_onEvent,
      onError: (e) => _toast('خطأ اتصال: $e'));
  }
  @override void dispose() {
    _sub?.cancel(); _name.dispose(); _room.dispose(); _message.dispose(); _scroll.dispose();
    super.dispose();
  }

  void _onEvent(dynamic raw) {
    if (!mounted || raw is! Map) return;
    final e = Map<String, dynamic>.from(raw);
    switch (e['type']) {
      case 'device':
        final address = e['address']?.toString() ?? '';
        if (address.isNotEmpty && !_devices.any((d) => d['address'] == address)) {
          setState(() => _devices.add(e));
        }
        break;
      case 'state':
        setState(() {
          _status = e['message']?.toString() ?? _status;
          _connected = e['connected'] == true;
        });
        break;
      case 'message':
        setState(() => _messages.add(ChatMessage(sender: e['sender']?.toString() ?? 'عضو',
          text: e['text']?.toString() ?? '', time: _clock(), mine: false)));
        _jumpToBottom();
        break;
      case 'file':
        final b64 = e['data']?.toString() ?? '';
        try {
          final bytes = base64Decode(b64);
          setState(() => _messages.add(ChatMessage(sender: e['sender']?.toString() ?? 'عضو',
            text: 'تم استلام ملف', time: _clock(), fileName: e['name']?.toString(),
            fileBytes: bytes)));
        } catch (_) { _toast('تعذر قراءة الملف المستلم'); }
        _jumpToBottom();
        break;
      case 'error': _toast(e['message']?.toString() ?? 'حدث خطأ'); break;
    }
  }

  String _clock() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }
  void _toast(String s) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s))); }
  void _jumpToBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
  });
  String _makeCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(6, (_) => chars[r.nextInt(chars.length)]).join();
  }

  Future<void> _createRoom() async {
    final code = _makeCode();
    try {
      await _methods.invokeMethod('startHost', {'code': code, 'name': _name.text.trim().isEmpty ? 'منشئ المجموعة' : _name.text.trim()});
      setState(() { _roomCode = code; _hosting = true; _roomTitle = 'غرفة $code'; _messages.clear(); });
      _toast('تم تشغيل الغرفة. فعّل ظهور الجهاز للآخرين عند طلب النظام.');
    } on PlatformException catch (e) { _toast(e.message ?? 'تعذر إنشاء الغرفة'); }
  }
  Future<void> _scan() async {
    setState(() { _devices.clear(); _discovering = true; });
    try {
      await _methods.invokeMethod('discover');
      _toast('جارٍ البحث عن أجهزة بلوتوث قريبة...');
    } on PlatformException catch (e) { _toast(e.message ?? 'تعذر البحث'); }
    await Future.delayed(const Duration(seconds: 12));
    if (mounted) setState(() => _discovering = false);
  }
  Future<void> _joinRoom() async {
    if (_selectedAddress == null) { _toast('اختر جهاز المنشئ أولاً'); return; }
    final code = _room.text.trim().toUpperCase();
    if (code.length != 6) { _toast('أدخل رمز الاقتران المكوّن من 6 أحرف'); return; }
    try {
      await _methods.invokeMethod('connect', {'address': _selectedAddress, 'code': code,
        'name': _name.text.trim().isEmpty ? 'مشارك' : _name.text.trim()});
      setState(() { _roomCode = code; _hosting = false; _roomTitle = 'غرفة $code'; _messages.clear(); });
    } on PlatformException catch (e) { _toast(e.message ?? 'تعذر الاتصال'); }
  }
  Future<void> _send() async {
    final value = _message.text.trim();
    if (value.isEmpty || !_connected) return;
    try {
      await _methods.invokeMethod('sendMessage', {'text': value, 'sender': _name.text.trim()});
      setState(() => _messages.add(ChatMessage(sender: _name.text.trim().isEmpty ? 'أنا' : _name.text.trim(),
        text: value, time: _clock(), mine: true)));
      _message.clear(); _jumpToBottom();
    } on PlatformException catch (e) { _toast(e.message ?? 'تعذر إرسال الرسالة'); }
  }
  Future<void> _sendFile() async {
    if (!_connected) { _toast('اتصل بغرفة أولاً'); return; }
    try {
      final result = await FilePicker.platform.pickFiles(withData: true);
      if (result == null || result.files.isEmpty) return;
      final f = result.files.single;
      final bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (bytes == null) { _toast('تعذر قراءة الملف'); return; }
      if (bytes.length > 4 * 1024 * 1024) { _toast('الحد الحالي للملف 4 ميغابايت لضمان النقل المستقر'); return; }
      await _methods.invokeMethod('sendFile', {'name': f.name, 'data': base64Encode(bytes), 'sender': _name.text.trim()});
      setState(() => _messages.add(ChatMessage(sender: 'أنا', text: 'تم إرسال ملف', time: _clock(), fileName: f.name, fileBytes: bytes)));
      _jumpToBottom();
    } on PlatformException catch (e) { _toast(e.message ?? 'تعذر إرسال الملف'); }
  }
  Future<void> _saveFile(ChatMessage m) async {
    if (m.fileBytes == null || m.fileName == null) return;
    try {
      final path = await _methods.invokeMethod<String>('saveFile', {'name': m.fileName, 'data': base64Encode(m.fileBytes!)});
      _toast(path == null ? 'تم حفظ الملف' : 'حُفظ الملف في: $path');
    } catch (e) { _toast('تعذر حفظ الملف: $e'); }
  }
  Future<void> _disconnect() async {
    try { await _methods.invokeMethod('disconnect'); } catch (_) {}
    setState(() { _connected = false; _hosting = false; _status = 'غير متصل'; });
  }

  @override Widget build(BuildContext context) {
    final bg = _background == 'أخضر' ? const Color(0xffe5f3e9) : _background == 'أزرق' ? const Color(0xffe7effb) : const Color(0xfff5f7f8);
    return Scaffold(
      appBar: AppBar(title: const Text('وصل • تواصل بلوتوث'), actions: [
        IconButton(tooltip: 'الإعدادات', icon: const Icon(Icons.settings), onPressed: _settings),
      ]),
      body: Column(children: [
        Container(width: double.infinity, color: const Color(0xff087f8c), padding: const EdgeInsets.all(12),
          child: Row(children: [Icon(_connected ? Icons.bluetooth_connected : Icons.bluetooth, color: Colors.white),
            const SizedBox(width: 10), Expanded(child: Text(_status, style: const TextStyle(color: Colors.white))),
            if (_connected) TextButton(onPressed: _disconnect, child: const Text('قطع الاتصال', style: TextStyle(color: Colors.white))) ])),
        if (!_connected) Expanded(child: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'اسم المستخدم', prefixIcon: Icon(Icons.person), border: OutlineInputBorder())),
          const SizedBox(height: 16),
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('إنشاء غرفة جديدة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6), const Text('أنشئ غرفة، ثم شارك رمز الاقتران مع الأعضاء. يعمل المنشئ كمركز تمرير للرسائل.'),
            const SizedBox(height: 12), SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _createRoom, icon: const Icon(Icons.add_link), label: const Text('إنشاء غرفة بلوتوث'))),
            if (_hosting && _roomCode.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: SelectableText('رمز الغرفة: $_roomCode', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 3))),
          ]))),
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('الانضمام إلى غرفة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6), const Text('ابحث عن جهاز المنشئ القريب، ثم أدخل الرمز الذي أعطاك إياه.'),
            const SizedBox(height: 12), SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: _discovering ? null : _scan, icon: const Icon(Icons.bluetooth_searching), label: Text(_discovering ? 'جارٍ البحث...' : 'البحث عن أجهزة قريبة'))),
            if (_devices.isNotEmpty) ...[
              const SizedBox(height: 8), const Text('الأجهزة المكتشفة'),
              ..._devices.map((d) => RadioListTile<String>(dense: true, contentPadding: EdgeInsets.zero,
                value: d['address'].toString(), groupValue: _selectedAddress, onChanged: (v) => setState(() => _selectedAddress = v),
                title: Text(d['name']?.toString().isNotEmpty == true ? d['name'].toString() : 'جهاز بلوتوث'),
                subtitle: Text(d['address'].toString()))),
            ],
            const SizedBox(height: 8), TextField(controller: _room, textCapitalization: TextCapitalization.characters, maxLength: 6,
              decoration: const InputDecoration(labelText: 'رمز الاقتران', border: OutlineInputBorder(), prefixIcon: Icon(Icons.key))),
            SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _joinRoom, icon: const Icon(Icons.login), label: const Text('دخول الغرفة'))),
          ]))),
          const SizedBox(height: 12),
          const Text('مهم: فعّل Bluetooth واسمح بالأذونات المطلوبة. الاتصال هنا عبر Bluetooth Classic، ويجب أن يكون الجهازان قريبين.'),
        ]))
        else Expanded(child: Container(color: bg, child: Column(children: [
          Padding(padding: const EdgeInsets.all(12), child: Row(children: [
            CircleAvatar(child: Icon(_hosting ? Icons.groups : Icons.chat)),
            const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_roomTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(_hosting ? 'أنت منشئ الغرفة • شارك الرمز $_roomCode' : 'متصل عبر Bluetooth', style: const TextStyle(fontSize: 12)),
            ])),
            IconButton(onPressed: _sendFile, tooltip: 'إرسال ملف', icon: const Icon(Icons.attach_file)),
          ])),
          const Divider(height: 1),
          Expanded(child: _messages.isEmpty ? const Center(child: Text('لا توجد رسائل بعد.\nابدأ المحادثة الآن.', textAlign: TextAlign.center))
            : ListView.builder(controller: _scroll, padding: const EdgeInsets.all(12), itemCount: _messages.length,
              itemBuilder: (context, i) {
                final m = _messages[i];
                return Align(alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft, child: Container(
                  constraints: const BoxConstraints(maxWidth: 320), margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.all(11), decoration: BoxDecoration(color: m.mine ? const Color(0xffccefe8) : Colors.white, borderRadius: BorderRadius.circular(14)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (!m.mine) Text(m.sender, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xff087f8c), fontSize: 12)),
                    if (m.fileName != null) Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.insert_drive_file), const SizedBox(width: 6), Flexible(child: Text(m.fileName!)),
                      IconButton(icon: const Icon(Icons.save_alt), onPressed: () => _saveFile(m)),
                    ]) else Text(m.text),
                    Align(alignment: Alignment.bottomRight, child: Text(m.time, style: const TextStyle(fontSize: 10, color: Colors.black54))),
                  ]),
                ));
              })),
          SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(8, 6, 8, 8), child: Row(children: [
            IconButton(onPressed: _sendFile, icon: const Icon(Icons.attach_file)),
            Expanded(child: TextField(controller: _message, minLines: 1, maxLines: 4, onSubmitted: (_) => _send(),
              decoration: InputDecoration(hintText: 'اكتب رسالة...', filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)))),
            const SizedBox(width: 6), IconButton.filled(onPressed: _send, icon: const Icon(Icons.send)),
          ]))),
        ]))),
      ]),
      floatingActionButton: FloatingActionButton.small(heroTag: 'support', onPressed: () => _methods.invokeMethod('openUrl', {'url': _supportUrl}), child: const Icon(Icons.support_agent)),
    );
  }

  void _settings() {
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) =>
      Padding(padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 24), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('الإعدادات', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 14), TextField(controller: _name, decoration: const InputDecoration(labelText: 'اسم المستخدم', border: OutlineInputBorder(), prefixIcon: Icon(Icons.person))),
        const SizedBox(height: 16), const Text('خلفية المحادثة'),
        const SizedBox(height: 8), Wrap(spacing: 8, children: ['فاتح', 'أخضر', 'أزرق'].map((b) => ChoiceChip(label: Text(b), selected: _background == b, onSelected: (_) { setState(() => _background = b); setSheet(() {}); })).toList()),
        const SizedBox(height: 12), ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.support_agent), title: const Text('التواصل مع فريق الدعم عبر واتساب'), onTap: () { Navigator.pop(ctx); _methods.invokeMethod('openUrl', {'url': _supportUrl}); }),
        const Text('المراسلات والملفات تنتقل عبر Bluetooth فقط. رابط الدعم يفتح واتساب عند الضغط عليه.', style: TextStyle(color: Colors.black54, fontSize: 12)),
      ])));
  }
}