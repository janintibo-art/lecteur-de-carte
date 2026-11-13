import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class CardProfile {
  final String id;
  final String name;
  final String action;
  final String target;
  final String created;
  final List<String> targets;
  final String cardLabel;

  const CardProfile({
    required this.id,
    required this.name,
    required this.action,
    required this.target,
    required this.created,
    this.targets = const [],
    this.cardLabel = '',
  });

  List<String> get applications {
    if (targets.isNotEmpty) return targets;
    if (action == 'open' && target.trim().isNotEmpty) return [target];
    return [];
  }

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'action': action, 'target': target,
    'created': created, 'targets': targets, 'cardLabel': cardLabel,
  };

  factory CardProfile.fromJson(Map<String, dynamic> json) {
    final oldAction = (json['action'] ?? 'none').toString();
    final oldTarget = (json['target'] ?? '').toString();
    final rawTargets = json['targets'];
    final targets = rawTargets is List
        ? rawTargets.whereType<String>().where((s) => s.trim().isNotEmpty).toList()
        : <String>[];
    return CardProfile(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      action: oldAction,
      target: oldTarget,
      created: (json['created'] ?? '').toString(),
      targets: targets.isEmpty && oldAction == 'open' && oldTarget.isNotEmpty
          ? [oldTarget] : targets,
      cardLabel: (json['cardLabel'] ?? '').toString(),
    );
  }

  CardProfile withCardLabel(String label) => CardProfile(
    id: id, name: name, action: action, target: target,
    created: created, targets: targets, cardLabel: label,
  );
}

class CardProfileStore {
  // Même clé que la V6 pour préserver les profils existants.
  static const key = 'lecteur_de_carte_v6_profiles';

  static Future<List<CardProfile>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return [];
    final parsed = jsonDecode(raw);
    if (parsed is! List) return [];
    return parsed.whereType<Map>().map(
      (p) => CardProfile.fromJson(Map<String, dynamic>.from(p)),
    ).toList();
  }

  static Future<void> save(List<CardProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    final ok = await prefs.setString(
      key, jsonEncode(profiles.map((p) => p.toJson()).toList()));
    if (!ok) throw StateError('Échec de la sauvegarde locale des profils.');
  }
}
