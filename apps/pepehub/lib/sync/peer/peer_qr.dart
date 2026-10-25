import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

String? peerInvitationFromQr(String? raw) {
  if (raw == null || raw.length > 4096) return null;
  try {
    final text = raw.trim(), uri = Uri.parse(text), args = uri.queryParameters;
    final uuid = RegExp(
      r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
    );
    final port = int.tryParse(args['port'] ?? '') ?? 0;
    if (uri.scheme != 'pepehub-peer' ||
        uri.host != 'pair' ||
        uri.path.isNotEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        args['v'] != '1' ||
        !uuid.hasMatch(args['device'] ?? '') ||
        !uuid.hasMatch(args['invite'] ?? '') ||
        (args['host'] ?? '').isEmpty ||
        args['host']!.length > 255 ||
        port < 1 ||
        port > 65535 ||
        base64Url.decode(args['key'] ?? '').length != 32) {
      return null;
    }
    return text;
  } on FormatException {
    return null;
  }
}

class PeerInvitationQr extends StatefulWidget {
  final String code;
  final DateTime? expires;
  const PeerInvitationQr({super.key, required this.code, this.expires});
  @override
  State<PeerInvitationQr> createState() => _PeerInvitationQrState();
}

class _PeerInvitationQrState extends State<PeerInvitationQr> {
  late final deadline =
      widget.expires ?? DateTime.now().add(const Duration(minutes: 5));
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = deadline.difference(DateTime.now()).inSeconds.clamp(0, 300);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (seconds > 0)
          Semantics(
            label: 'QR-код подключения устройства',
            child: QrImageView(
              data: widget.code,
              size: 260,
              backgroundColor: Colors.white,
              padding: const EdgeInsets.all(18),
            ),
          ),
        Text(
          seconds == 0
              ? 'Код истёк. Закройте окно и создайте новый.'
              : 'Осталось ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
        ),
      ],
    );
  }
}

class PeerQrScannerPage extends StatefulWidget {
  const PeerQrScannerPage({super.key});
  @override
  State<PeerQrScannerPage> createState() => _PeerQrScannerPageState();
}

class _PeerQrScannerPageState extends State<PeerQrScannerPage>
    with WidgetsBindingObserver {
  final scanner = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool returned = false;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (returned || !scanner.value.hasCameraPermission) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(scanner.start().catchError((Object _) {}));
    } else {
      unawaited(scanner.stop().catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(scanner.dispose().catchError((Object _) {}));
    super.dispose();
  }

  Future<void> _detected(BarcodeCapture capture) async {
    if (returned) return;
    final code = capture.barcodes
        .map((barcode) => peerInvitationFromQr(barcode.rawValue))
        .whereType<String>()
        .firstOrNull;
    if (code == null) {
      if (mounted) {
        setState(() => error = 'Наведите камеру на код подключения PepeHub.');
      }
      return;
    }
    returned = true;
    try {
      await scanner.stop();
    } catch (_) {
      /* Camera may already be disposed. */
    }
    if (mounted) Navigator.pop(context, code);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Подключить по QR-коду')),
    body: Column(
      children: [
        Expanded(
          child: MobileScanner(
            controller: scanner,
            onDetect: _detected,
            errorBuilder: (context, failure) => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Камера недоступна. Разрешите доступ к камере в настройках Android или вернитесь и вставьте код вручную.',
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Text(error ?? 'Откройте «Создать код» на втором устройстве.'),
        ),
      ],
    ),
  );
}
