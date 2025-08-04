// lib/sip_provider.dart

import 'package:flutter/material.dart';
import 'sip_client.dart';

class SipProvider with ChangeNotifier {
  NativeSipClient? _client;

  // OTIMIZAÇÃO: Vamos guardar no máximo 200 logs para não sobrecarregar a UI.
  final List<String> _logs = [];
  final int _maxLogs = 200;

  String _status = 'Desconectado';
  bool get isRegistered => _client?.isRegistered ?? false;
  bool get inCall => _client?.inCall ?? false;

  List<String> get logs => _logs;
  String get status => _status;

  Future<void> connectAndRegister({
    required String username,
    required String password,
    required String domain,
    required String proxy,
  }) async {
    _status = 'Conectando...';
    _logs.clear();
    notifyListeners();

    _client = NativeSipClient(
      username: username,
      password: password,
      domain: domain,
      proxyHost: proxy,
      onLog: (message) {
        // --- LÓGICA DE OTIMIZAÇÃO DE LOG ---
        if (_logs.length >= _maxLogs) {
          // Remove o log mais antigo se a lista estiver cheia
          _logs.removeLast();
        }
        _logs.insert(0, message);
        // --- FIM DA LÓGICA ---
        notifyListeners();
      },
      onStateChange: () {
        _updateStatus();
        notifyListeners();
      },
    );

    await _client!.connect();
    if (_client?.isRegistered == false) {
      await _client!.register();
    }
  }

  Future<void> makeCall(String destination) async {
    if (_client != null && isRegistered) {
      _status = 'Chamando $destination...';
      notifyListeners();
      await _client!.makeCall(destination);
    }
  }

  void hangUp() {
    _client?.stopRtpStream();
    _updateStatus();
    notifyListeners();
  }

  void _updateStatus() {
    if (_client == null || !_client!.isRegistered) {
      _status = 'Desconectado';
    } else if (_client!.inCall) {
      _status = 'Em chamada';
    } else if (_client!.isRegistered) {
      _status = 'Registrado';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _client?.dispose();
    super.dispose();
  }
}