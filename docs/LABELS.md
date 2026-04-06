# GitHub Labels

Inventaire des labels actuellement configurés sur `qveys/tm-exclusions`, relevé le `2026-04-06`.

Style: labels avec emoji.

Total: `45` labels.

## Types

| Label | Couleur | Description | Usage / Exemple |
| --- | --- | --- | --- |
| `⚡ Type: Performance` | `#ffd180` | Performance improvements (scan time, runtime, or efficiency). | Optimiser le scan `find` ou réduire les appels `tmutil`. |
| `✨ Type: Enhancement` | `#81c784` | Minor feature request or incremental improvement. | Améliorer `--report-only` ou le format du rapport sans gros changement de périmètre. |
| `❓ Type: Question` | `#ab47bc` | Further information or clarification is requested. | Clarifier le comportement attendu de `--uninstall --force`. |
| `🏗️ Type: Build` | `#b0bec5` | Build, packaging, install, or automation changes. | Changer `Makefile`, l'installation, ou la logique de packaging. |
| `🐞 Type: Bug` | `#d32f2f` | Something isn't working. | `tm-exclusions --dry-run` annonce un mauvais statut ou échoue sur un cas réel. |
| `📚 Type: Documentation` | `#0288d1` | Documentation improvements or additions. | Mettre à jour le README, l'architecture, ou les exemples de configuration. |
| `📦 Type: Dependency` | `#4c6ef5` | Dependency or tooling updates. | Mise à jour d'une action GitHub ou d'un outillage de lint/test. |
| `🔒 Type: Security` | `#d32f2f` | Security fix, hardening, or unsafe behavior review. | Durcir l'installation, les permissions, ou la manipulation des chemins. |
| `🚀 Type: Feature` | `#388e3c` | Major new feature or significant capability. | Ajouter un nouveau mode CLI ou un nouveau type de règle supporté. |
| `🧪 Type: Test` | `#aed581` | Adding, updating, or fixing tests. | Étendre `tests/smoke.bats-like.sh` pour couvrir un nouveau scénario. |
| `🧱 Type: Breaking Change` | `#d32f2f` | Introduces a breaking CLI or behavior change. | Renommer une option CLI ou changer le format de config de façon incompatible. |
| `🧹 Type: Chore` | `#cfd8dc` | Routine maintenance with no product behavior change. | Nettoyage mineur, renommage interne, ou entretien courant du repo. |
| `🧼 Type: Refactor` | `#f48fb1` | Code change that neither fixes a bug nor adds a feature. | Réorganiser les fonctions shell sans modifier le comportement utilisateur. |

## Priorites

| Label | Couleur | Description | Usage / Exemple |
| --- | --- | --- | --- |
| `🔥 Priority: Critical` | `#d32f2f` | Urgent; blocks usage, release, or core maintenance. | Régression qui empêche l'exécution normale du script principal. |
| `🔥 Priority: High` | `#ffb74d` | Important; should be addressed soon. | Défaut d'un mode courant comme `--dry-run` ou `--report-only`. |
| `🔥 Priority: Medium` | `#fff176` | Normal priority. | Amélioration planifiée sans urgence opérationnelle immédiate. |
| `🔥 Priority: Low` | `#b3e5fc` | Can wait; not urgent. | Ajustement cosmétique de sortie ou confort de maintenance. |

## Effort

| Label | Couleur | Description | Usage / Exemple |
| --- | --- | --- | --- |
| `⏱️ Effort: Small` | `#66bb6a` | Quick fix; less than a few hours. | Corriger un message, une option, ou un test isolé. |
| `⏱️ Effort: Medium` | `#ffca28` | Moderate task; a few days. | Ajouter une famille de patterns et sa couverture de test. |
| `⏱️ Effort: Large` | `#ef6c00` | Significant effort; roughly a week. | Revoir la logique de scan dynamique ou d'uninstall. |
| `⏱️ Effort: X-Large` | `#b71c1c` | Major undertaking; multiple weeks. | Introduire une nouvelle architecture ou un mode d'exécution majeur. |

## Statuts

| Label | Couleur | Description | Usage / Exemple |
| --- | --- | --- | --- |
| `🚦 Status: Blocked` | `#e53935` | Blocked by an external dependency or constraint. | En attente d'un comportement macOS ou d'une validation externe. |
| `🚦 Status: Duplicate` | `#cfd8dc` | This issue or pull request already exists elsewhere. | Sujet déjà couvert par une autre issue. |
| `🚦 Status: Fixed` | `#0e8a16` | Implemented and verified. | Correctif mergé et validé avec `make test`. |
| `🚦 Status: In Progress` | `#4fc3f7` | Currently being worked on. | Une PR active traite déjà le sujet. |
| `🚦 Status: Invalid` | `#eceff1` | Not reproducible or not aligned with project scope. | Signalement non reproductible ou hors du périmètre du projet. |
| `🚦 Status: Needs Info` | `#ff8a65` | More information is required from the reporter or stakeholder. | Il manque le contexte, la config, ou les étapes de reproduction. |
| `🚦 Status: On Hold` | `#90a4ae` | Work paused for now; revisit later. | Le sujet reste ouvert mais n'est pas traité tout de suite. |
| `🚦 Status: Ready` | `#00c853` | Ready to merge or ship. | La PR est prête, il ne reste qu'à merger. |
| `🚦 Status: Review Needed` | `#ffd54f` | Work is done; review is pending. | Le code est prêt mais attend une revue. |
| `🚦 Status: Won't Fix` | `#ffffff` | Will not be worked on by decision or design. | Cas assumé ou coût jugé non pertinent. |

## Areas

| Label | Couleur | Description | Usage / Exemple |
| --- | --- | --- | --- |
| `🧩 Area: Build` | `#90a4ae` | Makefile, install flow, packaging, and release plumbing. | Changements dans `Makefile` ou le flux d'installation. |
| `🧩 Area: CI` | `#ededed` | CI/CD and GitHub Actions workflows. | Fichiers sous `.github/workflows/`. |
| `🧩 Area: Config` | `#26a69a` | Default rules and configuration handling. | `config/default.conf` ou parsing de config custom. |
| `🧩 Area: Core` | `#1d76db` | Core CLI script and runtime behavior. | `tm_exclusions.sh` et la logique métier principale. |
| `🧩 Area: Docs` | `#039be5` | README, changelog, architecture, and guidance docs. | `README.md`, `CHANGELOG.md`, ou docs d'architecture. |
| `🧩 Area: Hooks` | `#8d6e63` | Local Git hooks and branch hygiene tooling. | Fichiers sous `.githooks/`. |
| `🧩 Area: Tests` | `#7cb342` | Smoke tests and test helpers. | `tests/smoke.bats-like.sh` et `tests/test_helpers.sh`. |

## Automation

| Label | Couleur | Description | Usage / Exemple |
| --- | --- | --- | --- |
| `🕰️ Automation: Stale issue` | `#cfd8dc` | Marque une issue sans activité récente (bot stale). | Appliqué par [`.github/workflows/stale.yml`](../.github/workflows/stale.yml) avant fermeture éventuelle. |
| `🕰️ Automation: Stale pull request` | `#cfd8dc` | Marque une PR sans activité récente (bot stale). | Appliqué par [`.github/workflows/stale.yml`](../.github/workflows/stale.yml) avant fermeture éventuelle. |

## Meta et Source

| Label | Couleur | Description | Usage / Exemple |
| --- | --- | --- | --- |
| `🤖 Source: Dependabot` | `#0366d6` | Automated updates created by Dependabot. | PR ouverte automatiquement par Dependabot. |
| `🧰 Ecosystem: github-actions` | `#2088ff` | Changes related to GitHub Actions maintenance or updates. | Mise à jour d'une action `actions/*` ou d'un workflow GitHub. |
| `🧷 Meta: Good First Issue` | `#7e57c2` | Good entry point for newcomers. | Petite amélioration isolée, bien cadrée et simple à tester. |
| `🧷 Meta: Help Wanted` | `#26a69a` | Extra attention or external help is welcome. | Sujet utile mais pas prioritaire pour le mainteneur seul. |
| `🧷 Meta: Needs Discussion` | `#f06292` | Requires discussion or a decision before coding. | Arbitrage sur le périmètre, la stratégie, ou l'UX CLI. |
