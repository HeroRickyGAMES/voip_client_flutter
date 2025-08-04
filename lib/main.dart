import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'sip_provider.dart';

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
      title: 'Cliente SIP Flutter',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.dark,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
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
  // Controllers para os campos de texto
  final _userController = TextEditingController(text: '1002');
  final _passwordController = TextEditingController(text: '1234');
  final _domainController = TextEditingController(text: '192.168.3.132');
  final _proxyController = TextEditingController(text: '192.168.3.132');
  final _destinationController = TextEditingController(text: '1001');

  @override
  void dispose() {
    // Limpeza dos controllers
    _userController.dispose();
    _passwordController.dispose();
    _domainController.dispose();
    _proxyController.dispose();
    _destinationController.dispose();
    // Limpeza do provider
    Provider.of<SipProvider>(context, listen: false).dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // O Consumer garante que a UI seja reconstruída quando o estado mudar
    return Consumer<SipProvider>(
      builder: (context, sipProvider, child) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Cliente SIP (Experimental)'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 16.0),
                child: Icon(
                  sipProvider.isRegistered ? Icons.wifi_tethering : Icons.wifi_tethering_off,
                  color: sipProvider.isRegistered ? Colors.greenAccent : Colors.redAccent,
                ),
              )
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Os métodos de construção são chamados aqui, de dentro da classe
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

  // -- MÉTODOS DE CONSTRUÇÃO DE WIDGETS (HELPERS) --
  // Todos os métodos abaixo estão DENTRO da classe _HomePageState
  // e, portanto, têm acesso ao 'context' e aos controllers.

  /// Constrói a seção de configuração do SIP.
  Widget _buildConfigSection(SipProvider sipProvider) {
    bool isConnected = sipProvider.isRegistered;
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
            icon: Icon(isConnected ? Icons.check : Icons.login),
            label: Text(isConnected ? 'Conectado' : 'Conectar e Registrar'),
            style: ElevatedButton.styleFrom(
              backgroundColor: isConnected ? Colors.green : Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
            ),
            onPressed: isConnected ? null : () {
              sipProvider.connectAndRegister(
                username: _userController.text,
                password: _passwordController.text,
                domain: _domainController.text,
                proxy: _proxyController.text,
              );
            },
          ),
        ),
      ],
    );
  }

  /// Constrói a seção de ações de chamada.
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

  /// Constrói a seção da console de logs.
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