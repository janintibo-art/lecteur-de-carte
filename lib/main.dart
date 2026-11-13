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
  String result = 'Branche ton lecteur puis lance la détection.';
  bool busy = false;

  Future<void> scan() async {
    setState(() { busy = true; result = 'Analyse du lecteur et des cartes…'; });
    try {
      String output;
      if (Platform.isAndroid) {
        final found = await channel.invokeMethod<List<dynamic>>('scanCards');
        output = found == null || found.isEmpty
            ? 'Aucun périphérique USB détecté. Branche le lecteur via un adaptateur OTG.'
            : const JsonEncoder.withIndent('  ').convert(found);
      } else if (Platform.isWindows) {
        final script = await rootBundle.loadString('assets/pcsc_probe.ps1');
        final dir = await Directory.systemTemp.createTemp('lecteur_de_carte_');
        try {
          final file = File('${dir.path}${Platform.pathSeparator}pcsc_probe.ps1');
          await file.writeAsString(script);
          final process = await Process.run('powershell.exe', [
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', file.path,
          ]);
          output = process.exitCode == 0
              ? (process.stdout as String).trim()
              : 'Erreur PC/SC : ${process.stderr}\n${process.stdout}';
        } finally {
          await dir.delete(recursive: true);
        }
      } else {
        output = 'Cette plateforme n’est pas encore prise en charge.';
      }
      if (mounted) setState(() => result = output);
    } catch (e) {
      if (mounted) setState(() => result = 'Échec du diagnostic : $e');
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
      const Text('SMART CARD LAB  •  V3', textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 10),
      const Text('Détection des lecteurs, présence de carte, protocole et ATR disponible.', textAlign: TextAlign.center),
      const SizedBox(height: 25),
      FilledButton.icon(onPressed: busy ? null : scan, icon: const Icon(Icons.usb), label: Text(busy ? 'Analyse en cours…' : 'Analyser lecteur et carte')),
      const SizedBox(height: 20),
      Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Diagnostic technique', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
        const SizedBox(height: 12),
        SelectableText(result),
      ]))),
      const SizedBox(height: 20),
      const Text('Android : autorise le lecteur USB, puis relance l’analyse. Windows : utilise le service Carte à puce (PC/SC).', textAlign: TextAlign.center),
      const SizedBox(height: 12),
      const Text('ATR = réponse initiale de la carte, pas les données personnelles. Aucune information n’est envoyée sur Internet.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
    ])),
  );
}
