import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'atr_decoder.dart';
import 'card_profiles.dart';

void main() => runApp(const CardLabApp());

class CardLabApp extends StatelessWidget {
  const CardLabApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Lecteur de Carte',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF27D1BD), brightness: Brightness.dark),
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
  final profileName = TextEditingController();
  final profileTarget = TextEditingController();
  final cardLabelController = TextEditingController();
  final List<String> draftTargets = [];
  List<CardProfile> profiles = [];
  List<Map<String, dynamic>> devices = [];
  final List<Map<String, dynamic>> apduHistory = [];
  AtrReport? report;
  String rawOutput = 'Branche ton lecteur puis lance la détection.';
  String scanMessage = 'En attente';
  String apduResult = 'Aucune commande envoyée.';
  String simulatorMessage = 'Choisis une carte virtuelle pour la simuler.';
  bool busy = false;
  bool apduBusy = false;
  bool profileBusy = false;

  @override
  void initState() {
    super.initState();
    loadProfiles();
  }

  @override
  void dispose() {
    atrController.dispose();
    apduController.dispose();
    profileName.dispose();
    profileTarget.dispose();
    cardLabelController.dispose();
    super.dispose();
  }

  void showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> loadProfiles() async {
    try {
      final loaded = await CardProfileStore.load();
      if (mounted) setState(() => profiles = loaded);
    } catch (e) {
      showMessage('Chargement des profils impossible : $e');
    }
  }

  Future<void> persist(List<CardProfile> next) async {
    await CardProfileStore.save(next);
    if (mounted) setState(() => profiles = next);
  }

  void addDraftTarget() {
    final path = profileTarget.text.trim().replaceAll('"', '');
    if (path.isEmpty || !path.toLowerCase().endsWith('.exe')) {
      showMessage('Choisis un chemin complet vers un fichier .exe.');
      return;
    }
    if (draftTargets.length >= 8) {
      showMessage('Maximum de 8 applications par profil.');
      return;
    }
    if (draftTargets.any((p) => p.toLowerCase() == path.toLowerCase())) {
      showMessage('Ce programme est déjà dans la liste.');
      return;
    }
    setState(() => draftTargets.add(path));
    profileTarget.clear();
  }

  Future<void> pickExe() async {
    if (!Platform.isWindows) {
      showMessage('Le sélecteur de programmes est disponible sur Windows uniquement.');
      return;
    }
    try {
      const script = r'''Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.OpenFileDialog; $d.Filter = 'Applications Windows (*.exe)|*.exe'; $d.Multiselect = $false; if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::Write($d.FileName) }''';
      final process = await Process.run('powershell.exe', [
        '-NoProfile', '-NonInteractive', '-STA', '-Command', script,
      ]);
      if (process.exitCode != 0) throw StateError('${process.stderr}');
      final path = (process.stdout as String).trim();
      if (path.isNotEmpty && mounted) setState(() => profileTarget.text = path);
    } catch (e) {
      showMessage('Sélection impossible : $e');
    }
  }

  Future<void> addProfile() async {
    final name = profileName.text.trim();
    if (name.isEmpty) {
      showMessage('Donne un nom au profil.');
      return;
    }
    if (profileBusy) return;
    setState(() => profileBusy = true);
    try {
      final now = DateTime.now();
      final apps = List<String>.from(draftTargets);
      final profile = CardProfile(
        id: 'SIM-${now.microsecondsSinceEpoch}',
        name: name,
        action: apps.isEmpty ? 'none' : 'open',
        target: apps.isEmpty ? '' : apps.first,
        targets: apps,
        created: now.toIso8601String(),
        cardLabel: cardLabelController.text.trim(),
      );
      await persist([...profiles, profile]);
      if (!mounted) return;
      setState(() {
        draftTargets.clear();
        simulatorMessage = 'Profil virtuel « $name » créé, sans écriture sur une carte.';
      });
      profileName.clear();
      profileTarget.clear();
      cardLabelController.clear();
      showMessage('Profil enregistré localement.');
    } catch (e) {
      showMessage('Enregistrement impossible : $e');
    } finally {
      if (mounted) setState(() => profileBusy = false);
    }
  }

  Future<void> removeProfile(CardProfile profile) async {
    try {
      await persist(profiles.where((p) => p.id != profile.id).toList());
    } catch (e) {
      showMessage('Suppression impossible : $e');
    }
  }

  Future<void> editCardLabel(CardProfile profile) async {
    final controller = TextEditingController(text: profile.cardLabel);
    final label = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Référence de la future carte'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Étiquette manuelle uniquement : aucun identifiant matériel lu, aucune authentification.'),
          const SizedBox(height: 12),
          TextField(controller: controller, maxLength: 64,
            decoration: const InputDecoration(labelText: 'Référence / surnom')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Enregistrer')),
        ],
      ),
    );
    // Le contrôleur n'est plus utilisé après la fermeture du dialogue.
    if (label == null) return;
    try {
      await persist(profiles.map((p) => p.id == profile.id
          ? p.withCardLabel(label) : p).toList());
    } catch (e) {
      showMessage('Association impossible : $e');
    }
  }

  void simulate(CardProfile profile) {
    setState(() => simulatorMessage =
      'Carte virtuelle : ${profile.name}\nID local : ${profile.id}\n'
      'Référence déclarée : ${profile.cardLabel.isEmpty ? 'aucune' : profile.cardLabel}\n'
      '${profile.applications.length} application(s) configurée(s). Délai : ${profile.delaySeconds} s.\n'
      'Simulation uniquement. Rien n’est exécuté automatiquement.');
  }

  Future<void> launchProfile(CardProfile profile) async {
    if (!Platform.isWindows) {
      showMessage('Exécution réservée à Windows.');
      return;
    }
    if (profileBusy || profile.applications.isEmpty || !profile.sequenceEnabled) {
      showMessage('Aucune application à lancer.');
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmer les lancements'),
        content: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${profile.applications.length} programme(s) seront lancés dans l’ordre. Délai : ${profile.delaySeconds} s. Confirmer ?'),
            const SizedBox(height: 12),
            for (final path in profile.applications) Padding(
              padding: const EdgeInsets.only(bottom: 8), child: SelectableText(path)),
          ],
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Lancer')),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() => profileBusy = true);
    final messages = <String>[];
    try {
      for (var index = 0; index < profile.applications.length; index++) {
        if (index > 0 && profile.delaySeconds > 0) {
          await Future<void>.delayed(Duration(seconds: profile.delaySeconds));
        }
        final path = profile.applications[index];
        final file = File(path);
        if (!path.toLowerCase().endsWith('.exe') || !await file.exists()) {
          messages.add('Introuvable : $path');
          continue;
        }
        try {
          await Process.start(path, const [],
            mode: ProcessStartMode.detached, workingDirectory: file.parent.path);
          messages.add('Lancé : $path');
        } catch (e) {
          messages.add('Erreur : $path — $e');
        }
      }
      if (mounted) setState(() => simulatorMessage = messages.join('\n'));
    } finally {
      if (mounted) setState(() => profileBusy = false);
    }
  }

  Future<void> moveApplication(CardProfile profile, int index, int direction) async {
    if (profileBusy) return;
    final apps = List<String>.from(profile.applications);
    final destination = index + direction;
    if (index < 0 || destination < 0 || destination >= apps.length) return;
    final item = apps.removeAt(index);
    apps.insert(destination, item);
    try {
      await persist(profiles.map((p) => p.id == profile.id
          ? p.withSequence(apps: apps) : p).toList());
    } catch (e) { showMessage('Ordre non enregistré : $e'); }
  }

  Future<void> setSequenceDelay(CardProfile profile) async {
    final selected = await showDialog<int>(context: context, builder: (ctx) =>
      SimpleDialog(title: const Text('Délai entre applications'), children: [
        for (final seconds in const [0, 1, 3, 5, 10, 20, 30])
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, seconds),
            child: Text('$seconds seconde(s)'),
          ),
      ]));
    if (selected == null) return;
    try {
      await persist(profiles.map((p) => p.id == profile.id
          ? p.withSequence(delay: selected) : p).toList());
    } catch (e) { showMessage('Délai non enregistré : $e'); }
  }

  Future<void> toggleSequence(CardProfile profile, bool enabled) async {
    try {
      await persist(profiles.map((p) => p.id == profile.id
          ? p.withSequence(enabled: enabled) : p).toList());
    } catch (e) { showMessage('Modification impossible : $e'); }
  }

  Future<void> removeApplication(CardProfile profile, int index) async {
    final apps = List<String>.from(profile.applications)..removeAt(index);
    try {
      await persist(profiles.map((p) => p.id == profile.id
          ? p.withSequence(apps: apps) : p).toList());
    } catch (e) { showMessage('Programme non supprimé : $e'); }
  }

  void analyzeAtr() => setState(() => report = AtrDecoder.decode(atrController.text));

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
          output = process.exitCode == 0 ? (process.stdout as String).trim() :
            'Erreur PC/SC : ${process.stderr}\n${process.stdout}';
        } finally { await dir.delete(recursive: true); }
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
      } on FormatException { /* Conserver le texte natif. */ }
      String? atr;
      for (final device in parsed) {
        final value = device['ATR'];
        if (value is String && value.trim().isNotEmpty) { atr = value; break; }
      }
      if (!mounted) return;
      setState(() {
        rawOutput = output.isEmpty ? 'Aucun lecteur détecté.' : output;
        devices = parsed;
        scanMessage = parsed.isEmpty ? 'Aucun résultat exploitable' : '${parsed.length} périphérique(s) ou lecteur(s)';
        if (atr != null) {
          atrController.text = atr;
          report = AtrDecoder.decode(atr);
        } else { atrController.clear(); report = null; }
      });
    } catch (e) {
      if (mounted) setState(() { rawOutput = 'Échec du diagnostic : $e'; scanMessage = 'Erreur'; });
    } finally { if (mounted) setState(() => busy = false); }
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
          if (process.exitCode != 0) throw Exception('${process.stderr} ${process.stdout}');
          response = Map<String, dynamic>.from(
            jsonDecode((process.stdout as String).trim()) as Map);
        } finally { await dir.delete(recursive: true); }
      } else { throw UnsupportedError('Plateforme non prise en charge'); }
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
    } finally { if (mounted) setState(() => apduBusy = false); }
  }

  void exportDiagnostic() {
    final data = <String, dynamic>{
      'application': 'Lecteur de Carte V8', 'diagnostic': rawOutput,
      'lecteurs': devices, 'atr': atrController.text,
      'journal_apdu': apduHistory,
      'profils_virtuels': profiles.map((p) => p.toJson()).toList(),
    };
    Clipboard.setData(ClipboardData(
      text: const JsonEncoder.withIndent('  ').convert(data)));
    showMessage('Rapport JSON copié dans le presse-papiers.');
  }

  Widget panel(String title, Widget content) => Card(
    margin: const EdgeInsets.symmetric(vertical: 8),
    child: Padding(padding: const EdgeInsets.all(16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12), content],
    )),
  );

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 4,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('LECTEUR DE CARTE  ·  V8'),
        bottom: const TabBar(isScrollable: true, tabs: [
          Tab(icon: Icon(Icons.usb), text: 'Lecteur'),
          Tab(icon: Icon(Icons.insights), text: 'ATR'),
          Tab(icon: Icon(Icons.code), text: 'APDU'),
          Tab(icon: Icon(Icons.credit_card), text: 'Programmer'),
        ]),
      ),
      body: TabBarView(children: [
        ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Diagnostic USB / PC-SC',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8), Text(scanMessage), const SizedBox(height: 12),
          FilledButton.icon(onPressed: busy ? null : scan,
            icon: const Icon(Icons.search),
            label: Text(busy ? 'Analyse en cours…' : 'Analyser lecteur et carte')),
          for (final device in devices) panel('Lecteur / périphérique', Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final entry in device.entries)
              Padding(padding: const EdgeInsets.symmetric(vertical: 3),
                child: SelectableText('${entry.key} : ${entry.value}'))],
          )),
          panel('Journal technique', Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              SelectableText(rawOutput), const SizedBox(height: 8),
              TextButton.icon(onPressed: () => Clipboard.setData(
                ClipboardData(text: rawOutput)),
                icon: const Icon(Icons.copy), label: const Text('Copier le diagnostic')),
            ])),
          OutlinedButton.icon(onPressed: exportDiagnostic,
            icon: const Icon(Icons.ios_share), label: const Text('Copier rapport JSON')),
          const Text('Android : autorise le port USB. Windows : service PC/SC requis.'),
        ]),
        ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Explorateur ATR',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('L’ATR contient des paramètres techniques, pas l’identité du titulaire.'),
          const SizedBox(height: 12),
          TextField(controller: atrController, minLines: 2, maxLines: 4,
            decoration: const InputDecoration(labelText: 'ATR hexadécimal',
              hintText: '3B 00', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          FilledButton.icon(onPressed: analyzeAtr, icon: const Icon(Icons.manage_search),
            label: const Text('Décoder l’ATR')),
          OutlinedButton.icon(onPressed: () {
              atrController.text = '3B 00'; analyzeAtr();
            }, icon: const Icon(Icons.school_outlined),
            label: const Text('ATR de démonstration')),
          if (report != null) panel('Décodage ISO 7816', Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              SelectableText(report!.normalized), const SizedBox(height: 8),
              if (report!.protocols.isNotEmpty)
                Text('Protocoles : ${report!.protocols.join(', ')}'),
              for (final line in report!.lines) Padding(
                padding: const EdgeInsets.only(top: 8), child: SelectableText(line)),
              for (final warning in report!.warnings) Padding(
                padding: const EdgeInsets.only(top: 8), child: Text(
                  'Attention : $warning',
                  style: TextStyle(color: Theme.of(context).colorScheme.error))),
            ])),
        ]),
        ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Laboratoire APDU',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Analyse locale d’APDU. Seules deux commandes prédéfinies sont envoyées.'),
          const SizedBox(height: 12),
          TextField(controller: apduController,
            decoration: const InputDecoration(labelText: 'Commande hexadécimale',
              border: OutlineInputBorder()), onChanged: (_) => setState(() {})),
          panel('Interprétation', Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final line in ApduExplanation.explain(apduController.text))
                Padding(padding: const EdgeInsets.only(bottom: 8),
                  child: SelectableText(line)),
            ])),
          panel('Échange avec une carte autorisée', Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('SELECT MF : 00 A4 00 00 02 3F 00'),
              const SizedBox(height: 8),
              FilledButton.icon(onPressed: apduBusy ? null : () => executeSafeApdu('select-mf'),
                icon: const Icon(Icons.touch_app), label: const Text('Envoyer SELECT MF')),
              const SizedBox(height: 12),
              const Text('READ BINARY : 00 B0 00 00 10 (16 octets)'),
              const SizedBox(height: 8),
              OutlinedButton.icon(onPressed: apduBusy ? null : () => executeSafeApdu('read-16'),
                icon: const Icon(Icons.visibility_outlined), label: const Text('Lire 16 octets')),
              const SizedBox(height: 12), SelectableText(apduResult),
              if (apduHistory.isNotEmpty) TextButton.icon(onPressed: exportDiagnostic,
                icon: const Icon(Icons.copy), label: const Text('Copier historique JSON')),
            ])),
          const Text('Utilise uniquement les cartes autorisées. Ne partage pas les données brutes.'),
        ]),
        ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Automatisations et cartes virtuelles',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('V8 : séquences ordonnées, délai et activation par profil. '
            'Les actions nécessitent un clic et une confirmation sur Windows. '
            'Aucune écriture physique ni connexion Windows déverrouillée.'),
          panel('Créer un profil', Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(controller: profileName, maxLength: 60,
                decoration: const InputDecoration(labelText: 'Nom du profil',
                  hintText: 'Carte Gaming', border: OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(controller: cardLabelController, maxLength: 64,
                decoration: const InputDecoration(labelText: 'Référence facultative de la future carte',
                  hintText: 'Carte blanche n°1', border: OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(controller: profileTarget,
                decoration: const InputDecoration(labelText: 'Programme Windows (.exe)',
                  hintText: r'C:\Program Files\Logiciel\app.exe',
                  border: OutlineInputBorder())),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (Platform.isWindows) OutlinedButton.icon(onPressed: pickExe,
                  icon: const Icon(Icons.folder_open), label: const Text('Parcourir...')),
                OutlinedButton.icon(onPressed: addDraftTarget,
                  icon: const Icon(Icons.add), label: const Text('Ajouter ce programme')),
              ]),
              if (draftTargets.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final target in draftTargets) ListTile(
                  dense: true, title: Text(target),
                  trailing: IconButton(icon: const Icon(Icons.close),
                    onPressed: () => setState(() => draftTargets.remove(target))),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(onPressed: profileBusy ? null : addProfile,
                icon: const Icon(Icons.add_card),
                label: const Text('Enregistrer le profil virtuel')),
            ])),
          panel('Simulation', Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              SelectableText(simulatorMessage),
              const SizedBox(height: 8),
              const Text('Une référence manuelle ou un ATR ne prouve pas '
                'l’identité d’une carte et ne doit pas servir de clé de sécurité.'),
            ])),
          if (profiles.isEmpty) const Text('Aucun profil enregistré pour le moment.'),
          for (final profile in profiles) panel(profile.name, Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              SelectableText('ID local : ${profile.id}'),
              if (profile.cardLabel.isNotEmpty)
                Text('Référence : ${profile.cardLabel}'),
              const SizedBox(height: 6),
              Text('${profile.applications.length} étape(s) · intervalle ${profile.delaySeconds} s'),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Séquence activée'),
                subtitle: const Text('Le lancement reste manuel avec confirmation.'),
                value: profile.sequenceEnabled,
                onChanged: profileBusy ? null : (enabled) => toggleSequence(profile, enabled),
              ),
              OutlinedButton.icon(
                onPressed: () => setSequenceDelay(profile),
                icon: const Icon(Icons.timer_outlined),
                label: const Text('Régler le délai'),
              ),
              for (var i = 0; i < profile.applications.length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(radius: 15, child: Text('${i + 1}')),
                  title: Text(profile.applications[i], maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                  subtitle: const Text('Lancement Windows manuel'),
                  trailing: Wrap(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(tooltip: 'Monter', icon: const Icon(Icons.arrow_upward),
                      onPressed: i == 0 ? null : () => moveApplication(profile, i, -1)),
                    IconButton(tooltip: 'Descendre', icon: const Icon(Icons.arrow_downward),
                      onPressed: i == profile.applications.length - 1
                        ? null : () => moveApplication(profile, i, 1)),
                    IconButton(tooltip: 'Retirer', icon: const Icon(Icons.close),
                      onPressed: () => removeApplication(profile, i)),
                  ]),
                ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(onPressed: () => simulate(profile),
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Simuler l’insertion')),
                OutlinedButton.icon(onPressed: () => editCardLabel(profile),
                  icon: const Icon(Icons.edit_note), label: const Text('Référence carte')),
                if (Platform.isWindows && profile.applications.isNotEmpty && profile.sequenceEnabled)
                  FilledButton.icon(onPressed: profileBusy ? null : () => launchProfile(profile),
                    icon: const Icon(Icons.launch),
                    label: const Text('Lancer les applications')),
                TextButton.icon(onPressed: () => removeProfile(profile),
                  icon: const Icon(Icons.delete_outline), label: const Text('Supprimer')),
              ]),
            ])),
          OutlinedButton.icon(onPressed: exportDiagnostic,
            icon: const Icon(Icons.copy), label: const Text('Copier profils en JSON')),
        ]),
      ]),
    ),
  );
}
