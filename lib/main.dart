import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const CardLabApp());

class CardLabApp extends StatelessWidget {
  const CardLabApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Lecteur de Carte',
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF27D1BD), brightness: Brightness.dark), useMaterial3: true),
    home: const CardLabHome(),
  );
}

class CardLabHome extends StatefulWidget {
  const CardLabHome({super.key});
  @override
  State<CardLabHome> createState() => _CardLabHomeState();
}

class _CardLabHomeState extends State<CardLabHome> {
  static const channel = MethodChannel('lecteur_de_carte/usb');
  String result = 'Clique sur « Rechercher le lecteur » pour commencer.';
  bool busy = false;

  Future<void> scan() async {
    setState(() { busy = true; result = 'Recherche en cours…'; });
    try {
      if (Platform.isAndroid) {
        final found = await channel.invokeMethod<List<dynamic>>('listUsbReaders');
        const encoder = JsonEncoder.withIndent('  ');
        setState(() => result = found == null || found.isEmpty
          ? 'Aucun périphérique USB détecté. Branche le lecteur avec un adaptateur OTG.'
          : encoder.convert(found));
      } else if (Platform.isWindows) {
        final powershell = await Process.run('powershell.exe', [
          '-NoProfile', '-NonInteractive', '-Command',
          r"$ErrorActionPreference='Stop'; Get-PnpDevice -Class SmartCardReader | Select-Object FriendlyName,Status,InstanceId | ConvertTo-Json -Depth 3",
        ]);
        final output = (powershell.stdout as String).trim();
        setState(() => result = powershell.exitCode == 0
          ? (output.isEmpty ? 'Aucun lecteur de carte PC/SC détecté.' : output)
          : 'Erreur PowerShell : ${powershell.stderr}');
      } else {
        setState(() => result = 'Plateforme non prise en charge dans cette première version.');
      }
    } catch (e) {
      setState(() => result = 'Échec de la détection : $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('LECTEUR DE CARTE'), centerTitle: true),
    body: SafeArea(child: ListView(padding: const EdgeInsets.all(20), children: [
      const Icon(Icons.credit_card, size: 70, color: Color(0xFF27D1BD)),
      const SizedBox(height: 14),
      const Text('SMART CARD LAB  •  V1', textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 10),
      const Text('Diagnostic du matériel USB et préparation du laboratoire ISO 7816.', textAlign: TextAlign.center),
      const SizedBox(height: 25),
      FilledButton.icon(onPressed: busy ? null : scan, icon: const Icon(Icons.usb), label: const Text('Rechercher le lecteur')),
      const SizedBox(height: 20),
      Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Résultat du diagnostic', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
        const SizedBox(height: 12),
        SelectableText(result),
      ]))),
      const SizedBox(height: 20),
      const Text('À venir : ATR, protocole PC/SC et CCID, commandes APDU autorisées, export des analyses.', textAlign: TextAlign.center),
      const SizedBox(height: 14),
      const Text('Les informations privées des cartes ne sont pas collectées ni envoyées sur Internet.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
    ])),
  );
}
