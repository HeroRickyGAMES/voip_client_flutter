import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:sound_stream/sound_stream.dart';

// =======================================================================
// LÓGICA FFI (Ponte para a DLL C++)
// =======================================================================
typedef EncodeULawNative = Void Function(Pointer<Uint8> pcm, Int32 pcmLen, Pointer<Uint8> ulaw);
typedef EncodeULaw = void Function(Pointer<Uint8> pcm, int pcmLen, Pointer<Uint8> ulaw);
typedef DecodeULawNative = Void Function(Pointer<Uint8> ulaw, Int32 ulawLen, Pointer<Uint8> pcm);
typedef DecodeULaw = void Function(Pointer<Uint8> ulaw, int ulawLen, Pointer<Uint8> pcm);

class G711Ffi {
  late EncodeULaw _encodeULaw;
  late DecodeULaw _decodeULaw;
  bool _initialized = false;

  G711Ffi() {
    try {
      final dylib = DynamicLibrary.open('g711.dll');
      _encodeULaw = dylib.lookup<NativeFunction<EncodeULawNative>>('encode_ulaw').asFunction();
      _decodeULaw = dylib.lookup<NativeFunction<DecodeULawNative>>('decode_ulaw').asFunction();
      _initialized = true;
    } catch (e) {
      print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
      print("!!! ERRO CRÍTICO AO CARREGAR g711.dll: $e");
      print("!!! VERIFIQUE SE A DLL ESTÁ EM 'windows/lib' E É 64-BIT.");
      print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
    }
  }

  Uint8List encode(Uint8List pcmSamples) {
    if (!_initialized) return Uint8List(0);
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
    if (!_initialized) return Uint8List(0);
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

// =======================================================================
// CLASSE DO CLIENTE SIP
// =======================================================================
class NativeSipClient {
  final G711Ffi _g711 = G711Ffi();
  String? _username, _domain, _proxyHost;
  int _proxyPort;
  RawDatagramSocket? _socket;
  RawDatagramSocket? _rtpSocket;
  final RecorderStream _recorder = RecorderStream();
  final PlayerStream _player = PlayerStream();
  StreamSubscription? _recorderSubscription;
  String? _remoteRtpHost;
  int? _remoteRtpPort;
  String? _fromTag, _toTag, _callId;
  int _sequenceNumber = Random().nextInt(0xFFFF);
  int _timestamp = Random().nextInt(0xFFFFFFFF);
  final int _ssrc = Random().nextInt(0xFFFFFFFF);
  int _cseq = 1;
  bool _isRegistered = false;
  bool _inCall = false;
  final int _localRtpPort = 4000;
  final Function(String message) onLog;
  final Function() onStateChange;

  bool get isRegistered => _isRegistered;
  bool get inCall => _inCall;

  // --- INÍCIO DA CORREÇÃO ---
  NativeSipClient({
    required this.onLog,
    required this.onStateChange,
    String? username,
    String? domain,
    String? proxyHost,
    int proxyPort = 5060, // Parâmetro público
  })  : _username = username,
        _domain = domain,
        _proxyHost = proxyHost,
        _proxyPort = proxyPort; // Atribuição ao campo privado
  // --- FIM DA CORREÇÃO ---

  Future<void> connect() async {
    if (_proxyHost == null) { onLog('SIP Proxy host não definido.'); return; }
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      onLog('Socket SIP conectado na porta local: ${_socket?.port}');
      _socket?.listen((event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = _socket?.receive();
          if (dg != null) _parseSipResponse(utf8.decode(dg.data));
        }
      });
    } catch (e) { onLog('Erro ao conectar o socket SIP: $e'); }
  }

  void _parseSipResponse(String response) {
    onLog('--- SIP Response Recebida ---\n$response\n--------------------');
    final statusCode = int.tryParse(response.split(' ')[1]) ?? 0;
    final cseqHeader = _extractHeader(response, 'CSeq');
    if (cseqHeader == null) return;
    final cseqMethod = cseqHeader.split(' ').last;

    if (cseqMethod == 'REGISTER') {
      _isRegistered = (statusCode == 200);
      onLog(_isRegistered ? 'Registro bem-sucedido!' : 'Falha no registro: $statusCode');
    } else if (cseqMethod == 'INVITE') {
      if (statusCode >= 180 && statusCode < 200) {
        onLog('Chamada tocando (Ringing)...');
        _toTag = _extractHeader(response, 'To')?.split(';tag=')[1];
      } else if (statusCode == 200) {
        onLog('Chamada atendida (200 OK)!');
        _inCall = true;
        _toTag = _extractHeader(response, 'To')?.split(';tag=')[1];
        final sdp = response.substring(response.indexOf('\r\n\r\n') + 4);
        _remoteRtpHost = RegExp(r'c=IN IP4 (.*)', multiLine: true).firstMatch(sdp)?.group(1)?.trim();
        _remoteRtpPort = int.tryParse(RegExp(r'm=audio (\d+)', multiLine: true).firstMatch(sdp)?.group(1)?.trim() ?? '');

        if (_remoteRtpHost != null && _remoteRtpPort != null) {
          onLog('Destino de mídia RTP extraído: $_remoteRtpHost:$_remoteRtpPort');
          _sendAck(response);
          startRtpStream();
        } else {
          onLog('ERRO: Não foi possível extrair IP/Porta RTP da resposta.');
        }
      } else if (statusCode >= 400) {
        onLog('Falha na chamada: $statusCode');
        _inCall = false;
      }
    }
    onStateChange();
  }

  void _sendAck(String okResponse) {
    if (_socket == null || _toTag == null || _fromTag == null || _callId == null) return;

    final toHeader = _extractHeader(okResponse, 'To');
    final contactHeader = _extractHeader(okResponse, 'Contact');
    final contactUriFull = RegExp(r'<sip:[^>]+>').firstMatch(contactHeader ?? '')?.group(0) ?? '';
    final requestUri = contactUriFull.replaceAll('<', '').replaceAll('>', '');
    final requestLine = 'ACK $requestUri SIP/2.0\r\n';

    final via = 'Via: SIP/2.0/UDP ${_socket!.address.address}:${_socket!.port};branch=z9hG4bK.${_generateRandomString(10)}\r\n';
    final from = 'From: <sip:$_username@$_domain>;tag=$_fromTag\r\n';
    final to = '$toHeader\r\n';
    final callId = 'Call-ID: $_callId\r\n';
    final cseq = 'CSeq: ${_extractHeader(okResponse, 'CSeq')!.split(' ')[0]} ACK\r\n';

    final message = requestLine + via + 'Max-Forwards: 70\r\n' + from + to + callId + cseq + 'Content-Length: 0\r\n\r\n';
    _sendMessage(message);
    onLog('>>> Confirmação ACK enviada!');
  }

  Future<void> startRtpStream() async {
    print('Iniciando fluxo de áudio completo...');
    var status = await Permission.microphone.request();
    if (!status.isGranted) { print('Permissão de microfone negada.'); return; }
    if (_remoteRtpHost == null || _remoteRtpPort == null) return;

    try {
      _rtpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _localRtpPort);
      print('Socket RTP escutando e enviando pela porta ${_rtpSocket!.port}');

      await _recorder.initialize(sampleRate: 8000);
      await _player.initialize(sampleRate: 8000);
      await _recorder.start();
      await _player.start();
      print('🎙️ Microfone e 🔈 Alto-falante inicializados.');

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
      print("ERRO AO INICIAR O FLUXO RTP: $e");
    }
  }

  void stopRtpStream() {
    print('Parando o fluxo de áudio...');
    _recorderSubscription?.cancel();
    _recorderSubscription = null;
    _recorder.stop();
    _player.stop();
    _rtpSocket?.close();
    _rtpSocket = null;
    _inCall = false;
    onLog('Recursos de áudio liberados.');
    onStateChange();
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

  Future<void> register() async {
    if (_socket == null) return;
    _cseq = 1;
    _callId = _generateRandomString(16);
    _fromTag = _generateRandomString(8);
    final branch = 'z9hG4bK.${_generateRandomString(10)}';
    final localIp = _socket!.address.address;
    final localPort = _socket!.port;

    final requestLine = 'REGISTER sip:$_domain SIP/2.0\r\n';
    final headers = [
      'Via: SIP/2.0/UDP $localIp:$localPort;branch=$branch;rport',
      'Max-Forwards: 70',
      'From: <sip:$_username@$_domain>;tag=$_fromTag',
      'To: <sip:$_username@$_domain>',
      'Call-ID: $_callId',
      'CSeq: $_cseq REGISTER',
      'Contact: <sip:$_username@$localIp:$localPort>',
      'Expires: 3600',
      'Content-Length: 0'
    ].join('\r\n') + '\r\n\r\n';

    _sendMessage(requestLine + headers);
  }

  Future<void> makeCall(String destinationUser) async {
    if (!_isRegistered || _socket == null) return;
    _cseq++;
    _callId = _generateRandomString(16);
    _fromTag = _generateRandomString(8);
    final branch = 'z9hG4bK.${_generateRandomString(10)}';
    final localIp = _socket!.address.address;
    final localPort = _socket!.port;

    final sdp = [
      'v=0',
      'o=$_username ${DateTime.now().millisecondsSinceEpoch} 1 IN IP4 $localIp',
      's=Flutter Call',
      'c=IN IP4 $localIp',
      't=0 0',
      'm=audio $_localRtpPort RTP/AVP 0',
      'a=rtpmap:0 PCMU/8000',
      'a=sendrecv',
    ].join('\r\n') + '\r\n';

    final requestLine = 'INVITE sip:$destinationUser@$_domain SIP/2.0\r\n';
    final headers = [
      'Via: SIP/2.0/UDP $localIp:$localPort;branch=$branch;rport',
      'Max-Forwards: 70',
      'From: <sip:$_username@$_domain>;tag=$_fromTag',
      'To: <sip:$destinationUser@$_domain>',
      'Call-ID: $_callId',
      'CSeq: $_cseq INVITE',
      'Contact: <sip:$_username@$localIp:$localPort>',
      'Content-Type: application/sdp',
      'Content-Length: ${utf8.encode(sdp).length}'
    ].join('\r\n') + '\r\n\r\n';

    final message = requestLine + headers + sdp;
    _sendMessage(message);
    onLog(">>> Tentando ligar para $destinationUser...");
  }

  void _sendMessage(String message) {
    if (_socket != null && _proxyHost != null) {
      _socket!.send(utf8.encode(message), InternetAddress(_proxyHost!), _proxyPort);
    }
  }

  void dispose() { stopRtpStream(); _socket?.close(); }
  String _generateRandomString(int len) => String.fromCharCodes(Iterable.generate(len, (_) => 'abcdef0123456789'.codeUnitAt(Random().nextInt(16))));
  String? _extractHeader(String msg, String key) => RegExp('^$key:[ \t]*(.*)', caseSensitive: false, multiLine: true).firstMatch(msg)?.group(1)?.trim();
}

// =======================================================================
// PROVIDER (Gerenciador de Estado)
// =======================================================================
class SipProvider with ChangeNotifier {
  NativeSipClient? _client;
  final List<String> prints = [];
  String _status = 'Desconectado';
  bool get isRegistered => _client?.isRegistered ?? false;
  bool get inCall => _client?.inCall ?? false;
  List<String> get logs => prints;
  String get status => _status;

  void connectAndRegister({
    required String username,
    required String domain,
    required String proxy,
  }) {
    _client?.dispose();

    _status = 'Conectando...';
    prints.clear();

    _client = NativeSipClient(
      username: username,
      domain: domain,
      proxyHost: proxy,
      onLog: (message) {
        if (prints.length >= 200) prints.removeLast();
        prints.insert(0, message);
        notifyListeners();
      },
      onStateChange: _updateStatus,
    );
    _client!.connect().then((_) => _client!.register());
    notifyListeners();
  }

  void makeCall(String destination) {
    _status = 'Chamando $destination...';
    notifyListeners();
    _client?.makeCall(destination);
  }

  void hangUp() {
    _client?.stopRtpStream();
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

// =======================================================================
// UI (Interface do Usuário)
// =======================================================================
void main() {
  runApp(
    ChangeNotifierProvider(
      create: (context) => SipProvider(),
      child: const SipApp(),
    ),
  );
}

class SipApp extends StatelessWidget {
  const SipApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cliente SIP FFI',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _userController = TextEditingController(text: '1002');
  final _passwordController = TextEditingController(text: '1234');
  final _domainController = TextEditingController(text: '192.168.3.132');
  final _proxyController = TextEditingController(text: '192.168.3.132');
  final _destinationController = TextEditingController(text: '0');

  @override
  void dispose() {
    _userController.dispose();
    _passwordController.dispose();
    _domainController.dispose();
    _proxyController.dispose();
    _destinationController.dispose();
    Provider.of<SipProvider>(context, listen: false).dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SipProvider>(
      builder: (context, sipProvider, child) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Cliente SIP (FFI)'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 16.0),
                child: Icon(
                  sipProvider.isRegistered ? Icons.wifi_tethering : Icons.wifi_tethering_off,
                  color: sipProvider.isRegistered ? Colors.greenAccent : Colors.white54,
                ),
              )
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildConfigSection(sipProvider),
                const SizedBox(height: 24),
                _buildCallSection(sipProvider),
                const SizedBox(height: 24),
                _buildLogSection(sipProvider),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildConfigSection(SipProvider sipProvider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Configuração SIP', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        TextField(controller: _userController, decoration: const InputDecoration(labelText: 'Usuário')),
        const SizedBox(height: 8),
        TextField(controller: _passwordController, decoration: const InputDecoration(labelText: 'Senha'), obscureText: true,),
        const SizedBox(height: 8),
        TextField(controller: _domainController, decoration: const InputDecoration(labelText: 'Domínio')),
        const SizedBox(height: 8),
        TextField(controller: _proxyController, decoration: const InputDecoration(labelText: 'Proxy SIP')),
        const SizedBox(height: 16),
        SizedBox(
          height: 48,
          child: ElevatedButton.icon(
            icon: Icon(sipProvider.isRegistered ? Icons.check : Icons.login),
            label: Text(sipProvider.isRegistered ? 'Registrado' : 'Conectar e Registrar'),
            style: ElevatedButton.styleFrom(
              backgroundColor: sipProvider.isRegistered ? Colors.green : Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              sipProvider.connectAndRegister(
                username: _userController.text,
                domain: _domainController.text,
                proxy: _proxyController.text,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCallSection(SipProvider sipProvider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Ações', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Chip(
          label: Text('Status: ${sipProvider.status}'),
          backgroundColor: sipProvider.isRegistered ? Colors.green.withOpacity(0.3) : Colors.orange.withOpacity(0.3),
        ),
        const SizedBox(height: 16),
        TextField(controller: _destinationController, decoration: const InputDecoration(labelText: 'Número de Destino')),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.call),
                  label: const Text('Ligar'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white),
                  onPressed: (sipProvider.isRegistered && !sipProvider.inCall) ? () {
                    sipProvider.makeCall(_destinationController.text);
                  } : null,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.call_end),
                  label: const Text('Desligar'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                  onPressed: sipProvider.inCall ? () {
                    sipProvider.hangUp();
                  } : null,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLogSection(SipProvider sipProvider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Console de Logs', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Container(
          height: 300,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.3),
            border: Border.all(color: Colors.grey.shade700),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListView.builder(
            reverse: true,
            itemCount: sipProvider.logs.length,
            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                child: Text(
                  sipProvider.logs[index],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}