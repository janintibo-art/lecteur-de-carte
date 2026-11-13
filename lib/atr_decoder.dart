class AtrReport {
  final String normalized;
  final List<String> lines;
  final List<String> warnings;
  final List<String> protocols;
  const AtrReport(this.normalized, this.lines, this.warnings, this.protocols);
}

class AtrDecoder {
  static AtrReport decode(String hex) {
    final cleaned = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (cleaned.isEmpty) {
      return const AtrReport('', ['Aucun ATR à analyser.'], [], []);
    }
    if (cleaned.length.isOdd) {
      return const AtrReport('', [], ['Nombre impair de chiffres hexadécimaux.'], []);
    }
    final bytes = <int>[];
    for (var i = 0; i < cleaned.length; i += 2) {
      bytes.add(int.parse(cleaned.substring(i, i + 2), radix: 16));
    }
    final normalized = bytes.map(_hex).join(' ');
    final lines = <String>[];
    final warnings = <String>[];
    final protocols = <String>[];
    if (bytes.length < 2) {
      return AtrReport(normalized, lines, ['ATR incomplet : TS et T0 nécessaires.'], protocols);
    }
    final ts = bytes[0];
    lines.add('TS : ${_hex(ts)} — ${ts == 0x3B ? 'convention directe' : ts == 0x3F ? 'convention inverse' : 'valeur inhabituelle'}');
    if (ts != 0x3B && ts != 0x3F) warnings.add('TS non reconnu pour un ATR ISO 7816 classique.');
    final t0 = bytes[1];
    final historicalCount = t0 & 0x0F;
    lines.add('T0 : ${_hex(t0)} — $historicalCount octet(s) historique(s)');
    var y = t0 >> 4;
    var offset = 2;
    var group = 1;
    var hasNonzeroProtocol = false;
    var hasTd = false;
    while (y != 0 && group <= 16) {
      var nextY = 0;
      for (final field in const [1, 2, 4, 8]) {
        if ((y & field) == 0) continue;
        final fieldName = switch (field) { 1 => 'TA', 2 => 'TB', 4 => 'TC', _ => 'TD' };
        if (offset >= bytes.length) {
          warnings.add('ATR tronqué pendant la lecture de $fieldName$group.');
          return AtrReport(normalized, lines, warnings, protocols);
        }
        final value = bytes[offset++];
        if (field == 8) {
          hasTd = true;
          final p = value & 0x0F;
          final name = 'T=$p';
          if (!protocols.contains(name)) protocols.add(name);
          if (p != 0) hasNonzeroProtocol = true;
          nextY = value >> 4;
          lines.add('TD$group : ${_hex(value)} — annonce $name et groupe suivant ${nextY == 0 ? 'absent' : 'présent'}');
        } else if (group == 1 && field == 1) {
          lines.add('TA1 : ${_hex(value)} — Fi=${value >> 4}, Di=${value & 15} (indices, pas fréquence calculée)');
        } else if (group == 1 && field == 4) {
          lines.add('TC1 : ${_hex(value)} — octets de garde supplémentaires');
        } else {
          lines.add('$fieldName$group : ${_hex(value)} — paramètre d’interface');
        }
      }
      y = nextY;
      group++;
    }
    if (group > 16 && y != 0) warnings.add('Trop de groupes d’interface dans cet ATR.');
    if (!hasTd) protocols.add('T=0');
    if (offset + historicalCount > bytes.length) {
      warnings.add('Octets historiques incomplets : ${bytes.length - offset} sur $historicalCount.');
      return AtrReport(normalized, lines, warnings, protocols);
    }
    if (historicalCount > 0) {
      lines.add('Historique : ${bytes.sublist(offset, offset + historicalCount).map(_hex).join(' ')}');
      lines.add('Les octets historiques ne constituent pas une identification fiable de la carte.');
    }
    offset += historicalCount;
    if (hasNonzeroProtocol) {
      if (offset < bytes.length) {
        var xor = 0;
        for (var i = 1; i <= offset; i++) xor ^= bytes[i];
        lines.add('TCK : ${_hex(bytes[offset])} — ${xor == 0 ? 'contrôle XOR valide' : 'contrôle XOR incorrect'}');
        if (xor != 0) warnings.add('Somme de contrôle TCK invalide.');
        offset++;
      } else {
        warnings.add('TCK attendu mais absent.');
      }
    }
    if (offset < bytes.length) warnings.add('${bytes.length - offset} octet(s) supplémentaire(s) non interprété(s).');
    return AtrReport(normalized, lines, warnings, protocols);
  }

  static String _hex(int value) => value.toRadixString(16).padLeft(2, '0').toUpperCase();
}

class ApduExplanation {
  static List<String> explain(String input) {
    final cleaned = input.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (cleaned.isEmpty || cleaned.length.isOdd) return ['Saisir des octets hexadécimaux complets.'];
    final b = <int>[];
    for (var i = 0; i < cleaned.length; i += 2) {
      b.add(int.parse(cleaned.substring(i, i + 2), radix: 16));
    }
    if (b.length < 4) return ['En-tête APDU incomplet (CLA INS P1 P2).'];
    String h(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
    final lines = <String>['CLA ${h(b[0])} — classe', 'INS ${h(b[1])} — instruction', 'P1 ${h(b[2])}, P2 ${h(b[3])} — paramètres'];
    final instruction = switch (b[1]) {
      0xA4 => 'SELECT (sélection)',
      0xB0 => 'READ BINARY (lecture)',
      0xB2 => 'READ RECORD (lecture)',
      0xCA => 'GET DATA (lecture)',
      0xC0 => 'GET RESPONSE (réponse)',
      0x20 => 'VERIFY (authentification : ne pas lancer sans autorisation)',
      0xD6 => 'UPDATE BINARY (écriture : déconseillée)',
      _ => 'Instruction dépendante de la carte',
    };
    lines.add('Sens courant : $instruction');
    if (b.length == 4) lines.add('Cas 1 : en-tête seul');
    if (b.length == 5) lines.add('Cas 2 court : Le=${b[4] == 0 ? 256 : b[4]}');
    if (b.length > 5) lines.add('Corps APDU : ${b.length - 4} octets (structure à vérifier selon ISO 7816-4)');
    lines.add('Analyse locale uniquement : aucune commande envoyée à une carte.');
    return lines;
  }
}
