import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class CardProfile {
  final String id;
  final String name;
  final String action;
  final String target;
  final String created;
  const CardProfile({required this.id, required this.name, required this.action, required this.target, required this.created});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'action': action, 'target': target, 'created': created};
  factory CardProfile.fromJson(Map<String, dynamic> json) => CardProfile(
    id: (json['id'] ?? '').toString(), name: (json['name'] ?? '').toString(),
    action: (json['action'] ?? 'none').toString(), target: (json['target'] ?? '').toString(),
    created: (json['created'] ?? '').toString(),
  );
}

class CardProfileStore {
  static const key = 'lecteur_de_carte_v6_profiles';
  static Future<List<CardProfile>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! List) return [];
      return parsed.whereType<Map>().map((e) => CardProfile.fromJson(Map<String, dynamic>.from(e))).toList();
    } catch (_) { return []; }
  }
  static Future<void> save(List<CardProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    final ok = await prefs.setString(key, jsonEncode(profiles.map((p) => p.toJson()).toList()));
    if (!ok) throw StateError('Enregistrement impossible');
  }
}
