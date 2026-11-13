import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'atr_decoder.dart';

void main() => runApp(const CardLabApp());

class CardLabApp extends StatelessWidget {
  const CardLabApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Lecteur de Carte',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF27D1BD), brightness: Brightness.dark),
      useMaterial3: true,
    ),
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
  final atrController = TextEditingController();
  final apduController = TextEditingController(text: '00 A4 04 00');
  String rawOutput = 'Branche ton lecteur puis lance la détection.';
  String scanMessage = 'En attente';
  List<Map<String, dynamic>> devices = [];
  AtrReport? report;
  bool busy = false;
  bool apduBusy = false;
  String apduResult = 'Aucune commande envoyée.';
  final List<Map<String, dynamic>> apduHistory = [];


  @override
  void dispose() {
    atrController.dispose();
    apduController.dispose();
    super.dispose();
  }

  void analyzeAtr() {
    setState(() => report = AtrDecoder.decode(atrController.text));
  }

  Future<void> scan() async {
    setState(() { busy = true; scanMessage = 'Recherche en cours…'; });
    try {
      String output;
      if (Platform.isAndroid) {
        final found = await channel.invokeMethod<List<dynamic>>('scanCards');
        output = const JsonEncoder.withIndent('  ').convert(found ?? []);
      } else if (Platform.isWindows) {
        final script = await rootBundle.loadString('assets/pcsc_probe.ps1');
        final dir = await Directory.systemTemp.createTemp('lecteur_de_carte_');
        try {
          final file = File('${dir.path}${Platform.pathSeparator}pcsc_probe.ps1');
          await file.writeAsString(script);
          final process = await Process.run('powershell.exe', [
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', file.path,
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
      final parsed = <Map<String, dynamic>>[];
      try {
        final json = jsonDecode(output);
        if (json is List) {
          for (final d in json) {
            if (d is Map) parsed.add(d.map((k, v) => MapEntry(k.toString(), v)));
          }
        } else if (json is Map) {
          parsed.add(json.map((k, v) => MapEntry(k.toString(), v)));
        }
      } on FormatException {
        // Keep the diagnostic text if the native platform returned an error.
      }
      String? atr;
      for (final device in parsed) {
        final value = device['ATR'];
        if (value is String && value.trim().isNotEmpty) {
          atr = value;
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        rawOutput = output.isEmpty ? 'Aucun lecteur détecté.' : output;
        devices = parsed;
        scanMessage = parsed.isEmpty ? 'Aucun résultat exploitable' : '${parsed.length} périphérique(s) ou lecteur(s)';
        if (atr != null) {
          atrController.text = atr;
          report = AtrDecoder.decode(atr);
        } else {
          atrController.clear();
          report = null;
        }
      });
    } catch (e) {
      if (mounted) setState(() { rawOutput = 'Échec du diagnostic : $e'; scanMessage = 'Erreur'; });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> executeSafeApdu(String action) async {
    if (busy || apduBusy) return;
    setState(() { apduBusy = true; apduResult = 'Communication en cours…'; });
    try {
      Map<String, dynamic> response;
      if (Platform.isAndroid) {
        final received = await channel.invokeMapMethod<String, dynamic>(
          'sendSafeApdu', {'action': action});
        response = Map<String, dynamic>.from(received ?? {});
      } else if (Platform.isWindows) {
        final script = await rootBundle.loadString('assets/pcsc_apdu.ps1');
        final dir = await Directory.systemTemp.createTemp('lecteur_de_carte_apdu_');
        try {
          final file = File('${dir.path}${Platform.pathSeparator}pcsc_apdu.ps1');
          await file.writeAsString(script);
          final process = await Process.run('powershell.exe', [
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', file.path, '-Action', action,
          ]);
          if (process.exitCode != 0) {
            throw Exception('${process.stderr} ${process.stdout}');
          }
          response = Map<String, dynamic>.from(jsonDecode((process.stdout as String).trim()) as Map);
        } finally {
          await dir.delete(recursive: true);
        }
      } else {
        throw UnsupportedError('Plateforme non prise en charge');
      }
      final sw = response['sw']?.toString().toUpperCase();
      if (sw != null) response['explication'] = switch (sw) {
        '9000' => 'Commande acceptée',
        '6A82' => 'Fichier ou application introuvable',
        '6982' => 'Conditions de sécurité non satisfaites',
        '6985' => 'Conditions d’utilisation non satisfaites',
        '6D00' => 'Instruction non prise en charge',
        '6E00' => 'Classe APDU non prise en charge',
        _ => 'Statut renvoyé par la carte (SW1/SW2)',
      };
      if (!mounted) return;
      setState(() {
        apduHistory.insert(0, {'date': DateTime.now().toIso8601String(), ...response});
        apduResult = const JsonEncoder.withIndent('  ').convert(response);
      });
    } catch (e) {
      if (mounted) setState(() => apduResult = 'Erreur de communication : $e');
    } finally {
      if (mounted) setState(() => apduBusy = false);
    }
  }

  void exportDiagnostic() {
    final data = <String, dynamic>{
      'application': 'Lecteur de Carte V5',
      'diagnostic': rawOutput,
      'lecteurs': devices,
      'atr': atrController.text,
      'journal_apdu': apduHistory,
    };
    Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(data)));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Rapport JSON copié : à enregistrer dans un fichier local.')),
    );
  }

  Widget panel(String title, Widget content) => Card(
    margin: const EdgeInsets.symmetric(vertical: 8),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        content,
      ]),
    ),
  );

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('LECTEUR DE CARTE  ·  V5'),
        bottom: const TabBar(tabs: [
          Tab(icon: Icon(Icons.usb), text: 'Lecteur'),
          Tab(icon: Icon(Icons.insights), text: 'ATR'),
          Tab(icon: Icon(Icons.code), text: 'APDU'),
        ]),
      ),
      body: TabBarView(children: [
        ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Diagnostic USB / PC-SC', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(scanMessage),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: busy ? null : scan,
            icon: const Icon(Icons.search),
            label: Text(busy ? 'Analyse en cours…' : 'Analyser lecteur et carte'),
          ),
          for (final device in devices)
            panel('Lecteur / périphérique', Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final entry in device.entries)
                Padding(padding: const EdgeInsets.symmetric(vertical: 3),
                  child: SelectableText('${entry.key} : ${entry.value}'))],
            )),
          panel('Journal technique', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText(rawOutput),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: rawOutput)),
              icon: const Icon(Icons.copy), label: const Text('Copier le diagnostic'),
            ),
          ])),
          OutlinedButton.icon(onPressed: exportDiagnostic, icon: const Icon(Icons.ios_share), label: const Text('Exporter le rapport JSON (copier)')),
          const Text('Android : autorise le port USB puis relance. Windows : PC/SC doit être disponible.'),
        ]),
        ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Explorateur ATR', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('L’ATR est la réponse initiale d’une carte à contact. Il décrit des paramètres techniques, pas l’identité de son titulaire.'),
          const SizedBox(height: 12),
          TextField(
            controller: atrController,
            minLines: 2, maxLines: 4,
            decoration: const InputDecoration(labelText: 'ATR hexadécimal', hintText: '3B 00', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(onPressed: analyzeAtr, icon: const Icon(Icons.manage_search), label: const Text('Décoder l’ATR')),
          OutlinedButton.icon(
            onPressed: () { atrController.text = '3B 00'; analyzeAtr(); },
            icon: const Icon(Icons.school_outlined), label: const Text('Essayer un ATR de démonstration'),
          ),
          if (report != null) panel('Décodage ISO 7816', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText(report!.normalized),
            const SizedBox(height: 8),
            if (report!.protocols.isNotEmpty) Text('Protocoles annoncés : ${report!.protocols.join(', ')}'),
            for (final line in report!.lines) Padding(padding: const EdgeInsets.only(top: 8), child: SelectableText(line)),
            for (final warning in report!.warnings) Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Attention : $warning', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          ])),
        ]),
        ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Laboratoire APDU — analyse et lecture encadrée', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Le champ hexadécimal sert uniquement à l’analyse locale. Seules les deux commandes prédéfinies ci-dessous peuvent être envoyées explicitement.'),
          const SizedBox(height: 12),
          TextField(
            controller: apduController,
            decoration: const InputDecoration(labelText: 'Commande en hexadécimal', border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
          panel('Interprétation', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final line in ApduExplanation.explain(apduController.text))
              Padding(padding: const EdgeInsets.only(bottom: 8), child: SelectableText(line)),
          ])),
          panel('Échange réel avec une carte autorisée', Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('SELECT MF : 00 A4 00 00 02 3F 00. La carte peut refuser cette sélection.'),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: apduBusy ? null : () => executeSafeApdu('select-mf'),
                icon: const Icon(Icons.touch_app),
                label: const Text('Envoyer SELECT MF'),
              ),
              const SizedBox(height: 12),
              const Text('READ BINARY : 00 B0 00 00 10. Lecture de 16 octets uniquement si la carte l’autorise.'),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: apduBusy ? null : () => executeSafeApdu('read-16'),
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Lire 16 octets'),
              ),
              const SizedBox(height: 12),
              SelectableText(apduResult),
              if (apduHistory.isNotEmpty) TextButton.icon(
                onPressed: exportDiagnostic,
                icon: const Icon(Icons.copy),
                label: const Text('Copier rapport et historique JSON'),
              ),
            ],
          )),
          const Text('Utiliser uniquement avec tes cartes ou une autorisation explicite. Aucune écriture ni commande PIN. Les réponses peuvent contenir des données sensibles : ne partage pas les rapports bruts.'),
        ]),
      ]),
    ),
  );
}
