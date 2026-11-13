# Lecteur de Carte — V1

Application Flutter Android/Windows pour explorer un lecteur USB à carte à puce.

## V1 : fonctionnalités réellement livrées
- Android : liste des périphériques USB accessibles via USB Host, VID/PID, classes d'interfaces dont CCID (classe 11).
- Windows : détection des lecteurs reconnus dans la classe Windows SmartCardReader via PowerShell.
- Interface sombre et diagnostic copiable.
- Compilation automatique APK de test et dossier EXE Windows via GitHub Actions.

**Non implémentés en V1** : lecture ATR, dialogue CCID, PC/SC, APDU, lecture de contenu, NFC. Aucun accès à des secrets ni contournement de protections.

## Termux
Décompresser le ZIP dans `$HOME` puis `bash ~/lecteur_de_carte/installation-termux.sh`.
Le compte GitHub CLI (`gh auth login`) doit être connecté.

## Téléchargements
GitHub > Actions > Compiler APK et EXE > dernière exécution verte > Artifacts.
Pour Windows, extraire le ZIP et conserver les DLL à côté de l'EXE.

## Prérequis Android
Appareil USB Host/OTG et adaptateur USB-C vers USB-A. Un périphérique listé n'est pas nécessairement encore utilisable en communication carte : ce sera développé dans les prochaines versions.
