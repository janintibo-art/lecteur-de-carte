import 'dart:async';
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
    title: 'Lecteur de Carte', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF0C1220),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF39DEC6), brightness: Brightness.dark)),
    home: const CardLabHome(),
  );
}

class CardLabHome extends StatefulWidget {
  const CardLabHome({super.key});
  @override
  State<CardLabHome> createState() => _CardLabHomeState();
}

class _CardLabHomeState extends State<CardLabHome> with WidgetsBindingObserver {
  static const channel = MethodChannel('lecteur_de_carte/usb');
  final atrController = TextEditingController();
  final apduController = TextEditingController(text: '00 A4 04 00');
  final profileName = TextEditingController();
  final profileTarget = TextEditingController();
  final cardLabelController = TextEditingController();
  final draftTargets = <String>[];
  final apduHistory = <Map<String, dynamic>>[];
  List<CardProfile> profiles = [];
  List<Map<String, dynamic>> devices = [];
  AtrReport? report;
  String rawOutput = 'Connecte ton lecteur Trust, puis lance une analyse.';
  String scanMessage = 'En attente de lecteur';
  String apduResult = 'Aucun échange APDU.';
  String simulatorMessage = 'Choisis un profil à simuler.';
  String monitoringStatus = 'Surveillance désactivée';
  final monitoringEvents = <String>[];
  Timer? monitorTimer;
  bool monitoring = false;
  bool monitorInitialized = false;
  String lastPresence = '';
  bool busy = false;
  bool apduBusy = false;
  bool profileBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    loadProfiles();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      monitorTimer?.cancel();
      monitorTimer = null;
    } else if (monitoring) {
      scheduleMonitoring();
    }
  }

  @override
  void dispose() {
    monitorTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final c in [atrController, apduController, profileName, profileTarget, cardLabelController]) {
      c.dispose();
    }
    super.dispose();
  }

  void notice(String value) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> loadProfiles() async {
    try {
      final value = await CardProfileStore.load();
      if (mounted) setState(() => profiles = value);
    } catch (e) { notice('Chargement impossible : $e'); }
  }

  Future<void> persist(List<CardProfile> next) async {
    await CardProfileStore.save(next);
    if (mounted) setState(() => profiles = next);
  }

  void scheduleMonitoring() {
    monitorTimer?.cancel();
    if (!monitoring) return;
    monitorTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!busy && !apduBusy && !profileBusy) scan(silent: true);
    });
  }

  void toggleMonitoring(bool enabled) {
    setState(() {
      monitoring = enabled;
      monitoringStatus = enabled ? 'Surveillance active (toutes les 6 secondes)' : 'Surveillance désactivée';
      monitorInitialized = false;
      lastPresence = '';
    });
    if (enabled) { scheduleMonitoring(); scan(silent: true); }
    else { monitorTimer?.cancel(); monitorTimer = null; }
  }

  String presenceSignature(List<Map<String, dynamic>> parsed) {
    final parts = <String>[];
    for (final d in parsed) {
      final name = (d['lecteur'] ?? d['appareil'] ?? 'lecteur').toString();
      final card = (d['carte'] ?? '').toString().toLowerCase();
      // Ne jamais considérer l'ATR comme l'identité unique d'une carte.
      final present = card == 'presente' || card.contains('présente') || card.contains('present') || card == 'connectee';
      final absent = card.contains('absent');
      parts.add('$name:${present && !absent ? 'carte' : 'vide'}');
    }
    parts.sort();
    return parts.join('|');
  }

  void updatePresence(List<Map<String, dynamic>> parsed) {
    if (!monitoring) return;
    final next = presenceSignature(parsed);
    if (!monitorInitialized) {
      monitorInitialized = true;
      lastPresence = next;
      setState(() => monitoringStatus = 'État initial relevé : ${parsed.length} lecteur(s)/périphérique(s)');
      return;
    }
    if (next == lastPresence) return;
    lastPresence = next;
    final event = '${DateTime.now().toLocal().toIso8601String().substring(11, 19)} · Changement détecté : ${next.isEmpty ? 'aucun lecteur' : next}';
    setState(() {
      monitoringStatus = 'Changement de présence détecté';
      monitoringEvents.insert(0, event);
      if (monitoringEvents.length > 20) monitoringEvents.removeLast();
    });
  }

  Future<String> runPcsc(String asset, {String? action}) async {
    final script = await rootBundle.loadString(asset);
    final dir = await Directory.systemTemp.createTemp('lecteur_de_carte_');
    try {
      final file = File('${dir.path}${Platform.pathSeparator}pcsc.ps1');
      await file.writeAsString(script);
      final result = await Process.run('powershell.exe', [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', file.path,
        if (action != null) ...['-Action', action],
      ]);
      if (result.exitCode != 0) throw StateError('${result.stderr}\n${result.stdout}');
      return (result.stdout as String).trim();
    } finally {
      await dir.delete(recursive: true);
    }
  }

  Future<void> scan({bool silent = false}) async {
    if (busy) return;
    setState(() { busy = true; if (!silent) scanMessage = 'Recherche en cours…'; });
    try {
      String output;
      if (Platform.isAndroid) {
        final found = await channel.invokeMethod<List<dynamic>>('scanCards');
        output = const JsonEncoder.withIndent('  ').convert(found ?? []);
      } else if (Platform.isWindows) {
        output = await runPcsc('assets/pcsc_probe.ps1');
      } else { output = 'Plateforme non prise en charge'; }
      final parsed = <Map<String, dynamic>>[];
      try {
        final decoded = jsonDecode(output);
        if (decoded is List) {
          for (final d in decoded) { if (d is Map) parsed.add(d.map((k, v) => MapEntry(k.toString(), v))); }
        } else if (decoded is Map) { parsed.add(decoded.map((k, v) => MapEntry(k.toString(), v))); }
      } on FormatException { /* Diagnostic brut conservé. */ }
      String? atr;
      for (final item in parsed) {
        if (item['ATR'] is String && (item['ATR'] as String).trim().isNotEmpty) {
          atr = item['ATR'] as String; break;
        }
      }
      if (!mounted) return;
      setState(() {
        devices = parsed;
        rawOutput = output.isEmpty ? 'Aucun lecteur détecté.' : output;
        scanMessage = '${parsed.length} lecteur(s) ou périphérique(s) détecté(s)';
        if (atr != null) { atrController.text = atr; report = AtrDecoder.decode(atr); }
        else { atrController.clear(); report = null; }
      });
      updatePresence(parsed);
    } catch (e) {
      if (mounted) setState(() {
        if (!silent) scanMessage = 'Erreur de lecture';
        rawOutput = 'Diagnostic : $e';
        if (monitoring) monitoringStatus = 'Surveillance : lecture impossible ($e)';
      });
    } finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> executeSafeApdu(String action) async {
    if (busy || apduBusy) return;
    setState(() { apduBusy = true; apduResult = 'Communication en cours…'; });
    try {
      Map<String, dynamic> response;
      if (Platform.isAndroid) {
        response = Map<String, dynamic>.from(await channel.invokeMapMethod<String, dynamic>('sendSafeApdu', {'action': action}) ?? {});
      } else if (Platform.isWindows) {
        response = Map<String, dynamic>.from(jsonDecode(await runPcsc('assets/pcsc_apdu.ps1', action: action)) as Map);
      } else { throw UnsupportedError('Plateforme non prise en charge'); }
      final sw = response['sw']?.toString().toUpperCase();
      if (sw != null) response['explication'] = switch (sw) {
        '9000' => 'Commande acceptée', '6A82' => 'Fichier introuvable',
        '6982' => 'Conditions de sécurité non satisfaites',
        '6985' => 'Conditions d’utilisation non satisfaites',
        '6D00' => 'Instruction non prise en charge',
        _ => 'Statut fourni par la carte',
      };
      if (!mounted) return;
      setState(() {
        apduHistory.insert(0, {'date': DateTime.now().toIso8601String(), ...response});
        apduResult = const JsonEncoder.withIndent('  ').convert(response);
      });
    } catch (e) { if (mounted) setState(() => apduResult = 'Erreur : $e'); }
    finally { if (mounted) setState(() => apduBusy = false); }
  }

  void exportDiagnostic() {
    Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert({
      'application': 'Lecteur de Carte V9', 'diagnostic': rawOutput,
      'lecteurs': devices, 'atr': atrController.text, 'journal_apdu': apduHistory,
      'profils_virtuels': profiles.map((p) => p.toJson()).toList(),
      'evenements_presence': monitoringEvents,
    })));
    notice('Diagnostic JSON copié. Attention aux données potentiellement sensibles.');
  }

  void addDraftTarget() {
    final path = profileTarget.text.trim().replaceAll('"', '');
    if (path.isEmpty || !path.toLowerCase().endsWith('.exe')) { notice('Indique un programme .exe.'); return; }
    if (draftTargets.length >= 8) { notice('Maximum de 8 programmes.'); return; }
    if (draftTargets.any((v) => v.toLowerCase() == path.toLowerCase())) { notice('Déjà ajouté.'); return; }
    setState(() => draftTargets.add(path));
    profileTarget.clear();
  }

  Future<void> pickExe() async {
    if (!Platform.isWindows) { notice('Sélecteur disponible sous Windows.'); return; }
    try {
      const cmd = r'''Add-Type -AssemblyName System.Windows.Forms; $d=New-Object System.Windows.Forms.OpenFileDialog; $d.Filter='Applications Windows (*.exe)|*.exe'; if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {[Console]::Write($d.FileName)}''';
      final result = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-STA', '-Command', cmd]);
      if (result.exitCode != 0) throw StateError('${result.stderr}');
      if (mounted && (result.stdout as String).trim().isNotEmpty) setState(() => profileTarget.text = (result.stdout as String).trim());
    } catch (e) { notice('Erreur du sélecteur : $e'); }
  }

  Future<void> addProfile() async {
    final name = profileName.text.trim();
    if (name.isEmpty || profileBusy) { notice('Donne un nom au profil.'); return; }
    setState(() => profileBusy = true);
    try {
      final now = DateTime.now();
      final apps = List<String>.from(draftTargets);
      final item = CardProfile(id: 'SIM-${now.microsecondsSinceEpoch}', name: name,
        action: apps.isEmpty ? 'none' : 'open', target: apps.isEmpty ? '' : apps.first,
        targets: apps, created: now.toIso8601String(), cardLabel: cardLabelController.text.trim());
      await persist([...profiles, item]);
      if (!mounted) return;
      setState(() { draftTargets.clear(); simulatorMessage = 'Profil « $name » créé sans carte physique.'; });
      profileName.clear(); profileTarget.clear(); cardLabelController.clear();
      notice('Carte virtuelle enregistrée.');
    } catch (e) { notice('Enregistrement impossible : $e'); }
    finally { if (mounted) setState(() => profileBusy = false); }
  }

  Future<void> removeProfile(CardProfile profile) async {
    try { await persist(profiles.where((p) => p.id != profile.id).toList()); }
    catch (e) { notice('Suppression impossible : $e'); }
  }

  Future<void> editCardLabel(CardProfile profile) async {
    final controller = TextEditingController(text: profile.cardLabel);
    final label = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Étiquette de carte'),
      content: TextField(controller: controller, maxLength: 64,
        decoration: const InputDecoration(labelText: 'Référence manuelle', helperText: 'Ne constitue pas une preuve d’identité')),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Enregistrer'))],
    ));
    // Le contrôleur appartient au dialogue et est relâché après son retrait.
    if (label == null) return;
    try { await persist(profiles.map((p) => p.id == profile.id ? p.withCardLabel(label) : p).toList()); }
    catch (e) { notice('Modification impossible : $e'); }
  }

  void simulate(CardProfile profile) => setState(() => simulatorMessage =
    'Carte virtuelle : ${profile.name}\nID local : ${profile.id}\n'
    'Référence : ${profile.cardLabel.isEmpty ? 'aucune' : profile.cardLabel}\n'
    '${profile.applications.length} application(s), délai ${profile.delaySeconds} s.\n'
    'Aucune action automatique, aucune authentification réelle.');

  Future<void> launchProfile(CardProfile profile) async {
    if (!Platform.isWindows || profileBusy || !profile.sequenceEnabled || profile.applications.isEmpty) return;
    final approved = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Confirmer les lancements'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${profile.applications.length} programme(s), dans l’ordre, délai ${profile.delaySeconds} s.'),
          const SizedBox(height: 12),
          for (final app in profile.applications) Padding(padding: const EdgeInsets.only(bottom: 8), child: SelectableText(app)),
        ])),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Lancer'))],
    ));
    if (approved != true || !mounted) return;
    setState(() => profileBusy = true);
    final messages = <String>[];
    try {
      for (var i = 0; i < profile.applications.length; i++) {
        if (i > 0 && profile.delaySeconds > 0) await Future<void>.delayed(Duration(seconds: profile.delaySeconds));
        final path = profile.applications[i];
        final file = File(path);
        if (!path.toLowerCase().endsWith('.exe') || !await file.exists()) { messages.add('Introuvable : $path'); continue; }
        try {
          await Process.start(path, const [], mode: ProcessStartMode.detached, workingDirectory: file.parent.path);
          messages.add('Lancé : $path');
        } catch (e) { messages.add('Erreur : $path ($e)'); }
      }
      if (mounted) setState(() => simulatorMessage = messages.join('\n'));
    } finally { if (mounted) setState(() => profileBusy = false); }
  }

  Future<void> updateSequence(CardProfile profile, {List<String>? apps, int? delay, bool? enabled}) async {
    try { await persist(profiles.map((p) => p.id == profile.id
      ? p.withSequence(apps: apps, delay: delay, enabled: enabled) : p).toList()); }
    catch (e) { notice('Modification impossible : $e'); }
  }

  Future<void> moveApp(CardProfile profile, int i, int direction) async {
    final apps = List<String>.from(profile.applications);
    final to = i + direction;
    if (to < 0 || to >= apps.length) return;
    final item = apps.removeAt(i); apps.insert(to, item);
    await updateSequence(profile, apps: apps);
  }

  Future<void> setDelay(CardProfile profile) async {
    final selected = await showDialog<int>(context: context, builder: (ctx) => SimpleDialog(
      title: const Text('Délai entre applications'), children: [
        for (final s in [0, 1, 3, 5, 10, 20, 30]) SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, s), child: Text('$s seconde(s)')),
      ]));
    if (selected != null) await updateSequence(profile, delay: selected);
  }

  Widget panel(String title, Widget child) => Card(margin: const EdgeInsets.symmetric(vertical: 9),
    child: Padding(padding: const EdgeInsets.all(16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12), child],
    )));

  Widget virtualCard(CardProfile profile, int index) {
    const gradients = [
      [Color(0xFF075C69), Color(0xFF142747)],
      [Color(0xFF5D338E), Color(0xFF251A49)],
      [Color(0xFF99502C), Color(0xFF35223A)],
      [Color(0xFF246A47), Color(0xFF172D3D)],
    ];
    final gradient = gradients[index % gradients.length];
    return Container(width: double.infinity, constraints: const BoxConstraints(minHeight: 164),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: gradient),
        border: Border.all(color: Colors.white24),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 14, offset: Offset(0, 6))]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Icon(Icons.memory, color: Colors.white70, size: 34),
          Text('SMART CARD  •  SIMULATION', style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 10)),
        ]),
        const SizedBox(height: 28),
        Text(profile.name.toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)),
        const SizedBox(height: 7),
        Text('${profile.applications.length} action(s) · ${profile.sequenceEnabled ? 'Séquence active' : 'Séquence désactivée'}',
          style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 5),
        Text(profile.cardLabel.isEmpty ? 'Aucune carte physique associée' : 'Étiquette : ${profile.cardLabel}',
          style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ]),
    );
  }

  Widget readerTab() => ListView(padding: const EdgeInsets.all(16), children: [
    const Text('Tableau de bord du lecteur', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
    const SizedBox(height: 6), Text(scanMessage),
    const SizedBox(height: 12),
    FilledButton.icon(onPressed: busy ? null : () => scan(), icon: const Icon(Icons.usb),
      label: Text(busy ? 'Analyse en cours…' : 'Analyser lecteur et carte')),
    panel('Surveillance de présence', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SwitchListTile.adaptive(contentPadding: EdgeInsets.zero,
        title: const Text('Surveiller les insertions/retraits'),
        subtitle: const Text('Uniquement lorsque l’application est ouverte et active.'),
        value: monitoring, onChanged: toggleMonitoring),
      Text(monitoringStatus),
      const SizedBox(height: 8),
      const Text('Surveillance expérimentale : relève les changements d’état, sans identifier de carte ni lancer d’application.'),
      for (final entry in monitoringEvents) Padding(
        padding: const EdgeInsets.only(top: 7), child: SelectableText(entry)),
    ])),
    for (final device in devices) panel('Périphérique / lecteur', Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final entry in device.entries) Padding(padding: const EdgeInsets.symmetric(vertical: 3),
          child: SelectableText('${entry.key} : ${entry.value}')),
      ])),
    panel('Diagnostic technique', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SelectableText(rawOutput), TextButton.icon(onPressed: exportDiagnostic,
        icon: const Icon(Icons.copy), label: const Text('Copier diagnostic JSON')),
    ])),
    const Text('Le lecteur doit prendre en charge PC/SC (Windows) ou CCID USB (Android). Une présence détectée ne prouve pas l’identité de la carte.'),
  ]);

  Widget atrTab() => ListView(padding: const EdgeInsets.all(16), children: [
    const Text('Décodage ATR', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
    const SizedBox(height: 9),
    const Text('L’ATR décrit les paramètres techniques d’une carte, pas son identité unique.'),
    const SizedBox(height: 12),
    TextField(controller: atrController, minLines: 2, maxLines: 4,
      decoration: const InputDecoration(labelText: 'ATR hexadécimal', border: OutlineInputBorder())),
    const SizedBox(height: 8),
    FilledButton.icon(onPressed: () => setState(() => report = AtrDecoder.decode(atrController.text)),
      icon: const Icon(Icons.manage_search), label: const Text('Décoder l’ATR')),
    OutlinedButton.icon(onPressed: () { atrController.text = '3B 00'; setState(() => report = AtrDecoder.decode(atrController.text)); },
      icon: const Icon(Icons.school), label: const Text('Exemple de démonstration')),
    if (report != null) panel('Analyse ISO 7816', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SelectableText(report!.normalized),
      for (final line in report!.lines) Padding(padding: const EdgeInsets.only(top: 8), child: SelectableText(line)),
      for (final warning in report!.warnings) Padding(padding: const EdgeInsets.only(top: 8),
        child: Text('Attention : $warning', style: TextStyle(color: Theme.of(context).colorScheme.error))),
    ])),
  ]);

  Widget apduTab() => ListView(padding: const EdgeInsets.all(16), children: [
    const Text('Laboratoire APDU', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
    const SizedBox(height: 8),
    const Text('Analyse pédagogique locale. Les seules commandes transmissibles sont les deux actions prédéfinies.'),
    const SizedBox(height: 12),
    TextField(controller: apduController, onChanged: (_) => setState(() {}),
      decoration: const InputDecoration(labelText: 'Commande hexadécimale', border: OutlineInputBorder())),
    panel('Interprétation', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final line in ApduExplanation.explain(apduController.text))
        Padding(padding: const EdgeInsets.only(bottom: 7), child: SelectableText(line)),
    ])),
    panel('Échanges avec une carte autorisée', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      FilledButton.icon(onPressed: apduBusy ? null : () => executeSafeApdu('select-mf'),
        icon: const Icon(Icons.touch_app), label: const Text('SELECT MF')),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: apduBusy ? null : () => executeSafeApdu('read-16'),
        icon: const Icon(Icons.visibility), label: const Text('READ BINARY (16 octets)')),
      const SizedBox(height: 10), SelectableText(apduResult),
    ])),
    const Text('Pas de commande d’écriture ou de vérification PIN. Ne partage pas les rapports contenant des données de cartes.'),
  ]);

  Widget profilesTab() => ListView(padding: const EdgeInsets.all(16), children: [
    const Text('Mes cartes virtuelles', style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
    const SizedBox(height: 8),
    const Text('Chaque carte est un profil local. Aucune carte physique n’est programmée, et aucune carte ne déverrouille Windows.'),
    panel('Créer un profil', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: profileName, maxLength: 60,
        decoration: const InputDecoration(labelText: 'Nom de la carte', border: OutlineInputBorder())),
      const SizedBox(height: 9),
      TextField(controller: cardLabelController, maxLength: 64,
        decoration: const InputDecoration(labelText: 'Étiquette facultative', border: OutlineInputBorder())),
      const SizedBox(height: 9),
      TextField(controller: profileTarget,
        decoration: const InputDecoration(labelText: 'Programme Windows (.exe)', border: OutlineInputBorder())),
      const SizedBox(height: 7),
      Wrap(spacing: 7, children: [
        if (Platform.isWindows) OutlinedButton.icon(onPressed: pickExe, icon: const Icon(Icons.folder_open), label: const Text('Parcourir')),
        OutlinedButton.icon(onPressed: addDraftTarget, icon: const Icon(Icons.add), label: const Text('Ajouter')),
      ]),
      for (final target in draftTargets) ListTile(dense: true, title: Text(target, maxLines: 2),
        trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => draftTargets.remove(target)))),
      const SizedBox(height: 9),
      FilledButton.icon(onPressed: profileBusy ? null : addProfile,
        icon: const Icon(Icons.add_card), label: const Text('Créer la carte virtuelle')),
    ])),
    panel('Simulation', SelectableText(simulatorMessage)),
    for (var index = 0; index < profiles.length; index++) ...[
      virtualCard(profiles[index], index),
      panel('Actions du profil', profileActions(profiles[index])),
      const SizedBox(height: 10),
    ],
    if (profiles.isEmpty) const Text('Aucun profil. Crée une carte virtuelle pour essayer.'),
    OutlinedButton.icon(onPressed: exportDiagnostic, icon: const Icon(Icons.copy),
      label: const Text('Copier profils et diagnostic JSON')),
  ]);

  Widget profileActions(CardProfile profile) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('${profile.applications.length} application(s) · délai ${profile.delaySeconds} s'),
    SwitchListTile.adaptive(contentPadding: EdgeInsets.zero, title: const Text('Activer la séquence'),
      subtitle: const Text('Exécution toujours manuelle avec confirmation.'),
      value: profile.sequenceEnabled,
      onChanged: profileBusy ? null : (value) => updateSequence(profile, enabled: value)),
    OutlinedButton.icon(onPressed: () => setDelay(profile), icon: const Icon(Icons.timer), label: const Text('Régler le délai')),
    for (var i = 0; i < profile.applications.length; i++)
      ListTile(contentPadding: EdgeInsets.zero,
        leading: CircleAvatar(radius: 14, child: Text('${i + 1}')),
        title: Text(profile.applications[i], maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Wrap(mainAxisSize: MainAxisSize.min, children: [
          IconButton(tooltip: 'Monter', icon: const Icon(Icons.arrow_upward),
            onPressed: i == 0 ? null : () => moveApp(profile, i, -1)),
          IconButton(tooltip: 'Descendre', icon: const Icon(Icons.arrow_downward),
            onPressed: i == profile.applications.length - 1 ? null : () => moveApp(profile, i, 1)),
          IconButton(tooltip: 'Supprimer l’étape', icon: const Icon(Icons.close),
            onPressed: () { final apps = List<String>.from(profile.applications)..removeAt(i); updateSequence(profile, apps: apps); }),
        ])),
    const SizedBox(height: 7),
    Wrap(spacing: 7, runSpacing: 7, children: [
      OutlinedButton.icon(onPressed: () => simulate(profile),
        icon: const Icon(Icons.play_circle), label: const Text('Simuler')),
      OutlinedButton.icon(onPressed: () => editCardLabel(profile),
        icon: const Icon(Icons.edit_note), label: const Text('Étiquette')),
      if (Platform.isWindows && profile.sequenceEnabled && profile.applications.isNotEmpty)
        FilledButton.icon(onPressed: profileBusy ? null : () => launchProfile(profile),
          icon: const Icon(Icons.launch), label: const Text('Lancer')),
      TextButton.icon(onPressed: () => removeProfile(profile),
        icon: const Icon(Icons.delete_outline), label: const Text('Supprimer le profil')),
    ]),
  ]);

  @override
  Widget build(BuildContext context) => DefaultTabController(length: 4, child: Scaffold(
    appBar: AppBar(title: const Text('LECTEUR DE CARTE · V9'), bottom: const TabBar(
      isScrollable: true, tabs: [Tab(icon: Icon(Icons.usb), text: 'Lecteur'),
        Tab(icon: Icon(Icons.insights), text: 'ATR'),
        Tab(icon: Icon(Icons.code), text: 'APDU'),
        Tab(icon: Icon(Icons.credit_card), text: 'Mes cartes')],
    )),
    body: TabBarView(children: [readerTab(), atrTab(), apduTab(), profilesTab()]),
  ));
}
