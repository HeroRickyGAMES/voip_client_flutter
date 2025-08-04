// lib/sip_client.dart

import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:permission_handler/permission_handler.dart';
import 'package:sound_stream/sound_stream.dart';

class NativeSipClient {
  String? _username;
  String? _password;
  String? _domain;
  String? _proxyHost;
  int _proxyPort;
  RawDatagramSocket? _socket;

  // --- VARIÁVEIS PARA ÁUDIO ---
  RawDatagramSocket? _rtpSocket;
  final RecorderStream _recorder = RecorderStream();
  StreamSubscription? _recorderSubscription;
  String? _remoteRtpHost;
  int? _remoteRtpPort;
  // --- FIM DAS VARIÁVEIS ---

  String? _callId;
  String? _localTag;
  String? _remoteTag;
  int _cseq = 1;
  bool _isRegistered = false;
  bool _inCall = false;

  final String _localRtpIp = '127.0.0.1';
  final int _localRtpPort = 4000;

  final Function(String message)? onLog;
  final Function()? onStateChange;

  bool get isRegistered => _isRegistered;
  bool get inCall => _inCall;

  NativeSipClient({
    String? username,
    String? password,
    String? domain,
    String? proxyHost,
    int proxyPort = 5060,
    this.onLog,
    this.onStateChange,
  })  : _username = username,
        _password = password,
        _domain = domain,
        _proxyHost = proxyHost,
        _proxyPort = proxyPort;

  void _log(String message) {
    onLog?.call(message);
  }

  // --- MÉTODO stopRtpStream CORRIGIDO ---
  void stopRtpStream() {
    _log('Parando o fluxo de áudio...');
    _recorderSubscription?.cancel();
    _recorderSubscription = null;
    _recorder.stop(); // FIX: Chamado diretamente, sem o 'if' incorreto.
    _rtpSocket?.close();
    _rtpSocket = null;
    _inCall = false;
    _log('Recursos de áudio liberados.');
    onStateChange?.call();
  }
  // --- FIM DA CORREÇÃO ---

  Future<void> startRtpStream() async {
    _log('Tentando iniciar o fluxo de áudio...');

    var status = await Permission.microphone.status;
    if (status.isDenied) {
      _log('AVISO: Acesso ao microfone negado. Tentando solicitar...');
      status = await Permission.microphone.request();
    }

    if (!status.isGranted) {
      _log('******************************************************************');
      _log('ALERTA: Permissão de microfone não concedida.');
      _log('Por favor, verifique as Configurações de Privacidade do Windows e');
      _log('permita o acesso ao microfone para este aplicativo.');
      _log('******************************************************************');
    }

    if (_remoteRtpHost == null || _remoteRtpPort == null) {
      _log('Destino RTP desconhecido.');
      return;
    }

    try {
      _rtpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _localRtpPort);
      _log('Socket RTP escutando na porta ${_rtpSocket!.port}');

      await _recorder.initialize();
      await _recorder.start();
      _log('Gravador de áudio inicializado. Capturando microfone...');

      _recorderSubscription = _recorder.audioStream.listen((audioData) {
        _rtpSocket?.send(audioData, InternetAddress(_remoteRtpHost!), _remoteRtpPort!);
      });

      _rtpSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = _rtpSocket!.receive();
          if (dg != null) {
            _log('Pacote RTP recebido de ${dg.address.host}:${dg.port} com ${dg.data.length} bytes.');
          }
        }
      });
    } catch (e) {
      _log("ERRO AO INICIAR O FLUXO RTP: $e");
      _log("Este erro pode ser causado pela falta de permissão de microfone nas configurações do Windows.");
    }
  }

  void dispose() {
    stopRtpStream();
    _socket?.close();
    _log('Sockets fechados.');
  }

  // O resto da classe permanece igual
  Future<void> connect() async {
    if (_proxyHost == null) {
      _log('SIP Proxy host não definido.');
      return;
    }
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _log('Socket SIP conectado à porta local: ${_socket?.port}');
      _socket?.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = _socket?.receive();
          if (dg != null) {
            String response = utf8.decode(dg.data);
            _log('--- SIP Response Recebida de ${dg.address.address}:${dg.port} ---\n$response\n---------------------------------------------------');
            _parseSipResponse(response);
          }
        }
      });
    } catch (e) {
      _log('Erro ao conectar o socket SIP: $e');
      _socket = null;
    }
    onStateChange?.call();
  }

  void _parseSipResponse(String response) {
    final lines = response.split('\r\n');
    if (lines.isEmpty) return;

    final statusLineParts = lines[0].split(' ');
    if (statusLineParts.length < 2) return;

    final statusCode = int.tryParse(statusLineParts[1]);
    if (statusCode == null) return;

    _log('Resposta SIP: $statusCode ${statusLineParts.sublist(2).join(' ')}');
    String cseqMethod = "";

    for (String line in lines) {
      if (line.toLowerCase().startsWith('cseq:')) {
        final cseqParts = line.substring(5).trim().split(' ');
        if (cseqParts.length > 1) {
          cseqMethod = cseqParts[1].toUpperCase();
        }
      }
    }

    if (cseqMethod == 'REGISTER') {
      if (statusCode == 200) {
        _log('Registro bem-sucedido!');
        _isRegistered = true;
      } else {
        _log('Falha no registro: $statusCode');
        _isRegistered = false;
      }
    } else if (cseqMethod == 'INVITE') {
      if (statusCode == 200) {
        _log('Chamada atendida (200 OK)! Iniciando fluxo de mídia...');
        _inCall = true;

        final sdpStartIndex = response.indexOf('\r\n\r\n');
        if (sdpStartIndex != -1) {
          String sdpResponse = response.substring(sdpStartIndex + 4);

          final sdpLines = sdpResponse.split('\r\n');
          for (var line in sdpLines) {
            if (line.startsWith('c=IN IP4')) {
              _remoteRtpHost = line.split(' ').last;
            }
            if (line.startsWith('m=audio')) {
              _remoteRtpPort = int.tryParse(line.split(' ')[1]);
            }
          }

          if (_remoteRtpHost != null && _remoteRtpPort != null) {
            _log('Destino de mídia RTP extraído: $_remoteRtpHost:$_remoteRtpPort');
            startRtpStream();
          } else {
            _log('ERRO: Não foi possível extrair IP/Porta RTP do SDP da resposta.');
          }
        }
      } else if (statusCode >= 400) {
        _log('Falha na chamada: $statusCode');
        _inCall = false;
      }
    }
    onStateChange?.call();
  }

  Future<void> register() async {
    if (_socket == null || _username == null || _domain == null || _proxyHost == null) {
      _log('Não é possível registrar: informações ausentes.');
      return;
    }
    _callId = _generateRandomString(16);
    _localTag = _generateRandomString(8);
    String branch = 'z9hG4bK${_generateRandomString(10)}';
    String localIpForVia = _socket!.address.address;
    int localPortForVia = _socket!.port;
    String requestLine = 'REGISTER sip:$_domain SIP/2.0\r\n';
    List<String> headers = ['Via: SIP/2.0/UDP $localIpForVia:$localPortForVia;branch=$branch;rport', 'Max-Forwards: 70', 'From: <sip:$_username@$_domain>;tag=$_localTag', 'To: <sip:$_username@$_domain>', 'Call-ID: $_callId', 'CSeq: $_cseq REGISTER', 'Contact: <sip:$_username@$localIpForVia:$localPortForVia>', 'Expires: 3600', 'Allow: INVITE, ACK, CANCEL, OPTIONS, BYE, REFER, SUBSCRIBE, NOTIFY, INFO, PUBLISH', 'User-Agent: Dart Native SIP Client 0.2', 'Content-Length: 0', '\r\n'];
    String message = requestLine + headers.join('\r\n');
    _log('Enviando mensagem SIP REGISTER para $_proxyHost:$_proxyPort:\n$message');
    _sendMessage(message);
    _cseq++;
  }

  Future<void> makeCall(String destinationUser) async {
    if (!_isRegistered) {
      _log('Não é possível fazer chamada: cliente não registrado.');
      return;
    }
    if (_socket == null || _username == null || _domain == null || _proxyHost == null) {
      _log('Não é possível fazer chamada: socket não conectado ou informações ausentes.');
      return;
    }
    String callSpecificCallId = _generateRandomString(16);
    String callSpecificLocalTag = _generateRandomString(8);
    _localTag = callSpecificLocalTag;
    _callId = callSpecificCallId;
    _remoteTag = null;
    String branch = 'z9hG4bK${_generateRandomString(10)}';
    String localIpForVia = _socket!.address.address;
    int localPortForVia = _socket!.port;
    List<String> sdpLines = ['v=0', 'o=$_username ${DateTime.now().millisecondsSinceEpoch} ${DateTime.now().millisecondsSinceEpoch + 1} IN IP4 $_localRtpIp', 's=Dart SIP Call', 'c=IN IP4 $_localRtpIp', 't=0 0', 'm=audio $_localRtpPort RTP/AVP 0', 'a=rtpmap:0 PCMU/8000', 'a=sendrecv'];
    String sdpPayload = '${sdpLines.join('\r\n')}\r\n';
    String requestLine = 'INVITE sip:$destinationUser@$_domain SIP/2.0\r\n';
    List<String> headers = ['Via: SIP/2.0/UDP $localIpForVia:$localPortForVia;branch=$branch;rport', 'Max-Forwards: 70', 'From: <sip:$_username@$_domain>;tag=$_localTag', 'To: <sip:$destinationUser@$_domain>', 'Call-ID: $_callId', 'CSeq: $_cseq INVITE', 'Contact: <sip:$_username@$localIpForVia:$localPortForVia>', 'Allow: INVITE, ACK, CANCEL, OPTIONS, BYE, REFER, SUBSCRIBE, NOTIFY, INFO, PUBLISH', 'User-Agent: Dart Native SIP Client 0.2', 'Content-Type: application/sdp', 'Content-Length: ${utf8.encode(sdpPayload).length}', '\r\n'];
    String message = requestLine + headers.join('\r\n') + sdpPayload;
    _log('Enviando mensagem SIP INVITE para $destinationUser@$_domain via $_proxyHost:$_proxyPort:\n$message');
    _sendMessage(message);
    _cseq++;
  }

  void _sendMessage(String message) {
    if (_socket != null && _proxyHost != null) {
      try {
        _socket!.send(utf8.encode(message), InternetAddress(_proxyHost!), _proxyPort);
      } catch (e) {
        _log('Erro ao enviar mensagem SIP: $e');
      }
    } else {
      _log('Não é possível enviar mensagem: socket não conectado ou proxy não definido.');
    }
  }

  String _generateRandomString(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    Random rnd = Random();
    return String.fromCharCodes(Iterable.generate(length, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))));
  }
}