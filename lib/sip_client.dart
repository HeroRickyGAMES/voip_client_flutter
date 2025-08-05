import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sound_stream/sound_stream.dart';

// --- LÓGICA FFI PARA CONVERSAR COM A DLL ---
typedef EncodeULawNative = Void Function(Pointer<Uint8> pcm, Int32 pcmLen, Pointer<Uint8> ulaw);
typedef EncodeULaw = void Function(Pointer<Uint8> pcm, int pcmLen, Pointer<Uint8> ulaw);
typedef DecodeULawNative = Void Function(Pointer<Uint8> ulaw, Int32 ulawLen, Pointer<Uint8> pcm);
typedef DecodeULaw = void Function(Pointer<Uint8> ulaw, int ulawLen, Pointer<Uint8> pcm);

class G711Ffi {
  late EncodeULaw _encodeULaw;
  late DecodeULaw _decodeULaw;

  G711Ffi() {
    final dylib = DynamicLibrary.open('g711.dll');
    _encodeULaw = dylib.lookup<NativeFunction<EncodeULawNative>>('encode_ulaw').asFunction();
    _decodeULaw = dylib.lookup<NativeFunction<DecodeULawNative>>('decode_ulaw').asFunction();
  }

  Uint8List encode(Uint8List pcmSamples) {
    final pcmPtr = calloc<Uint8>(pcmSamples.length);
    pcmPtr.asTypedList(pcmSamples.length).setAll(0, pcmSamples);
    final ulawLen = pcmSamples.length ~/ 2;
    final ulawPtr = calloc<Uint8>(ulawLen);
    _encodeULaw(pcmPtr, pcmSamples.length, ulawPtr);
    final encoded = Uint8List.fromList(ulawPtr.asTypedList(ulawLen));
    calloc.free(pcmPtr);
    calloc.free(ulawPtr);
    return encoded;
  }

  Uint8List decode(Uint8List ulawSamples) {
    final ulawPtr = calloc<Uint8>(ulawSamples.length);
    ulawPtr.asTypedList(ulawSamples.length).setAll(0, ulawSamples);
    final pcmLen = ulawSamples.length * 2;
    final pcmPtr = calloc<Uint8>(pcmLen);
    _decodeULaw(ulawPtr, ulawSamples.length, pcmPtr);
    final decoded = Uint8List.fromList(pcmPtr.asTypedList(pcmLen));
    calloc.free(ulawPtr);
    calloc.free(pcmPtr);
    return decoded;
  }
}

class NativeSipClient {
  final G711Ffi _g711 = G711Ffi();

  String? _username;
  String? _password;
  String? _domain;
  String? _proxyHost;
  int _proxyPort;
  RawDatagramSocket? _socket;
  RawDatagramSocket? _rtpSocket;
  final RecorderStream _recorder = RecorderStream();
  final PlayerStream _player = PlayerStream();
  StreamSubscription? _recorderSubscription;
  String? _remoteRtpHost;
  int? _remoteRtpPort;
  int _sequenceNumber = Random().nextInt(0xFFFF);
  int _timestamp = Random().nextInt(0xFFFFFFFF);
  final int _ssrc = Random().nextInt(0xFFFFFFFF);
  String? _callId;
  String? _localTag;
  String? _remoteTag;
  int _cseq = 1;
  bool _isRegistered = false;
  bool _inCall = false;
  final int _localRtpPort = 4000;
  final Function(String message)? onLog;
  final Function()? onStateChange;

  bool get isRegistered => _isRegistered;
  bool get inCall => _inCall;

  NativeSipClient({this.onLog, this.onStateChange, String? username, String? password, String? domain, String? proxyHost, int proxyPort = 5060})
      : _username = username, _password = password, _domain = domain, _proxyHost = proxyHost, _proxyPort = proxyPort;

  void _log(String message) => onLog?.call(message);

  void stopRtpStream() {
    _log('Parando o fluxo de áudio...');
    _recorderSubscription?.cancel();
    _recorderSubscription = null;
    _recorder.stop();
    _player.stop();
    _rtpSocket?.close();
    _rtpSocket = null;
    _inCall = false;
    _log('Recursos de áudio liberados.');
    onStateChange?.call();
  }

  Future<void> startRtpStream() async {
    _log('Iniciando fluxo de áudio completo (Mic/Alto-falante)...');
    var status = await Permission.microphone.request();
    if (!status.isGranted) {
      _log('Permissão de microfone negada.');
      return;
    }
    if (_remoteRtpHost == null || _remoteRtpPort == null) return;

    try {
      _rtpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _localRtpPort);
      _log('Socket RTP escutando e enviando pela porta ${_rtpSocket!.port}');

      await _recorder.initialize(sampleRate: 8000);
      await _player.initialize(sampleRate: 8000);
      await _recorder.start();
      await _player.start();
      _log('🎙️ Microfone e 🔈 Alto-falante inicializados.');

      _recorderSubscription = _recorder.audioStream.listen((audioData) {
        var encoded = _g711.encode(audioData as Uint8List);
        var rtpPacket = _createRtpPacket(encoded, 0);
        _rtpSocket?.send(rtpPacket, InternetAddress(_remoteRtpHost!), _remoteRtpPort!);
      });

      _rtpSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = _rtpSocket!.receive();
          if (dg != null && dg.data.length > 12) {
            var g711Payload = dg.data.sublist(12);
            var decoded = _g711.decode(g711Payload);
            _player.audioStream.add(decoded);
          }
        }
      });
    } catch (e) {
      _log("ERRO AO INICIAR O FLUXO RTP: $e");
    }
  }

  Uint8List _createRtpPacket(Uint8List payload, int payloadType) {
    var header = ByteData(12);
    header.setUint8(0, 0x80);
    header.setUint8(1, payloadType);
    header.setUint16(2, _sequenceNumber++);
    header.setUint32(4, _timestamp);
    header.setUint32(8, _ssrc);
    _timestamp += 160;
    var packet = BytesBuilder();
    packet.add(header.buffer.asUint8List());
    packet.add(payload);
    return packet.toBytes();
  }

  void dispose() { stopRtpStream(); _socket?.close(); _log('Sockets fechados.'); }

  Future<void> connect() async {
    if (_proxyHost == null) { _log('SIP Proxy host não definido.'); return; }
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _log('Socket SIP conectado à porta local: ${_socket?.port}');
      _socket?.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = _socket?.receive();
          if (dg != null) {
            String response = utf8.decode(dg.data);
            _parseSipResponse(response);
          }
        }
      });
    } catch (e) { _log('Erro ao conectar o socket SIP: $e'); _socket = null; }
    onStateChange?.call();
  }

  void _parseSipResponse(String response) {
    _log('--- SIP Response Recebida ---\n$response\n--------------------');
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
        if (cseqParts.length > 1) { cseqMethod = cseqParts[1].toUpperCase(); }
      }
    }
    if (cseqMethod == 'REGISTER') {
      if (statusCode == 200) { _log('Registro bem-sucedido!'); _isRegistered = true;
      } else { _log('Falha no registro: $statusCode'); _isRegistered = false; }
    } else if (cseqMethod == 'INVITE') {
      if (statusCode == 200) {
        _log('Chamada atendida (200 OK)! Iniciando fluxo de mídia...');
        _inCall = true;
        final sdpStartIndex = response.indexOf('\r\n\r\n');
        if (sdpStartIndex != -1) {
          String sdpResponse = response.substring(sdpStartIndex + 4);
          final sdpLines = sdpResponse.split('\r\n');
          for (var line in sdpLines) {
            if (line.startsWith('c=IN IP4')) { _remoteRtpHost = line.split(' ').last; }
            if (line.startsWith('m=audio')) { _remoteRtpPort = int.tryParse(line.split(' ')[1]); }
          }
          if (_remoteRtpHost != null && _remoteRtpPort != null) {
            _log('Destino de mídia RTP extraído: $_remoteRtpHost:$_remoteRtpPort');
            startRtpStream();
          } else { _log('ERRO: Não foi possível extrair IP/Porta RTP do SDP da resposta.'); }
        }
      } else if (statusCode >= 400) { _log('Falha na chamada: $statusCode'); _inCall = false; }
    }
    onStateChange?.call();
  }

  Future<void> register() async {
    if (_socket == null || _username == null || _domain == null || _proxyHost == null) { _log('Não é possível registrar.'); return; }
    _cseq = 1;
    _callId = _generateRandomString(16);
    _localTag = _generateRandomString(8);
    String branch = 'z9hG4bK${_generateRandomString(10)}';
    String localIpForVia = _socket!.address.address;
    int localPortForVia = _socket!.port;
    String requestLine = 'REGISTER sip:$_domain SIP/2.0\r\n';
    List<String> headers = ['Via: SIP/2.0/UDP $localIpForVia:$localPortForVia;branch=$branch;rport', 'Max-Forwards: 70', 'From: <sip:$_username@$_domain>;tag=$_localTag', 'To: <sip:$_username@$_domain>', 'Call-ID: $_callId', 'CSeq: $_cseq REGISTER', 'Contact: <sip:$_username@$localIpForVia:$localPortForVia>', 'Expires: 3600', 'Content-Length: 0', '\r\n'];
    String message = requestLine + headers.join('\r\n');
    _sendMessage(message);
  }

  Future<void> makeCall(String destinationUser) async {
    if (!_isRegistered) { _log('Não é possível fazer chamada: cliente não registrado.'); return; }
    if (_socket == null || _username == null || _domain == null || _proxyHost == null) { _log('Não é possível fazer chamada: socket não conectado.'); return; }
    _cseq++;
    _callId = _generateRandomString(16);
    _localTag = _generateRandomString(8);
    String branch = 'z9hG4bK${_generateRandomString(10)}';
    String localIpForVia = _socket!.address.address;
    // --- LINHA CORRIGIDA/ADICIONADA AQUI ---
    int localPortForVia = _socket!.port;
    List<String> sdpLines = ['v=0', 'o=$_username ${DateTime.now().millisecondsSinceEpoch} ${DateTime.now().millisecondsSinceEpoch + 1} IN IP4 $localIpForVia', 's=Dart SIP Call', 'c=IN IP4 $localIpForVia', 't=0 0', 'm=audio $_localRtpPort RTP/AVP 0', 'a=rtpmap:0 PCMU/8000', 'a=sendrecv'];
    String sdpPayload = '${sdpLines.join('\r\n')}\r\n';
    String requestLine = 'INVITE sip:$destinationUser@$_domain SIP/2.0\r\n';
    List<String> headers = ['Via: SIP/2.0/UDP $localIpForVia:$localPortForVia;branch=$branch;rport', 'Max-Forwards: 70', 'From: <sip:$_username@$_domain>;tag=$_localTag', 'To: <sip:$destinationUser@$_domain>', 'Call-ID: $_callId', 'CSeq: $_cseq INVITE', 'Contact: <sip:$_username@$localIpForVia:$localPortForVia>', 'Content-Type: application/sdp', 'Content-Length: ${utf8.encode(sdpPayload).length}', '\r\n'];
    String message = requestLine + headers.join('\r\n') + sdpPayload;
    _sendMessage(message);
  }

  void _sendMessage(String message) {
    if (_socket != null && _proxyHost != null) {
      try { _socket!.send(utf8.encode(message), InternetAddress(_proxyHost!), _proxyPort); }
      catch (e) { _log('Erro ao enviar mensagem SIP: $e'); }
    } else { _log('Não é possível enviar mensagem.'); }
  }

  String _generateRandomString(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    Random rnd = Random();
    return String.fromCharCodes(Iterable.generate(length, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))));
  }
}