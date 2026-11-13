#!/data/data/com.termux/files/usr/bin/bash
set -e
cd "$HOME"
if ! command -v gh >/dev/null 2>&1; then echo 'GitHub CLI absent : pkg install gh'; exit 1; fi
if ! gh auth status >/dev/null 2>&1; then echo 'Connexion GitHub manquante : gh auth login'; exit 1; fi
cd lecteur_de_carte
if [ ! -d .git ]; then git init -b main; fi
git config user.name "janintibo-art"
git add .
if ! git diff --cached --quiet; then git commit -m "V1 diagnostic lecteur de carte Android Windows"; fi
if ! gh repo view janintibo-art/lecteur-de-carte >/dev/null 2>&1; then gh repo create janintibo-art/lecteur-de-carte --public --source=. --remote=origin; fi
if ! git remote get-url origin >/dev/null 2>&1; then git remote add origin https://github.com/janintibo-art/lecteur-de-carte.git; fi
git push -u origin main
printf '\nDepot pret : https://github.com/janintibo-art/lecteur-de-carte\n'
