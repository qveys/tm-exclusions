# GitHub Labels

Inventaire des labels actuellement configurés sur `qveys/tm-exclusions`, relevé le **2026-04-06** et mis à jour avec chaque PR.

Style: labels avec emoji.

Total: `45` labels.

## Auto-labeling

- PRs: `actions/labeler` lit [`.github/labeler.yml`](../.github/labeler.yml) et ajoute **tous** les labels `🧩 Area:*` dont les globs matchent les fichiers modifiés. `sync-labels` est désactivé pour ne pas retirer les autres labels (Types, priorités, etc.) que le labeler ne connaît pas.
- Issues et PRs: le job `classify-by-reference` charge le catalogue depuis ce fichier (`docs/LABELS.md`) et résout dynamiquement les labels (emoji inclus), sans noms codés en dur dans le workflow. Il ajoute autant de labels pertinents que nécessaire sur `Area`, `Type`, `Status`, `Effort`, `Source` et `Ecosystem`, sans supprimer les labels existants.

## Classification Rules (machine-readable)

Single source of truth for auto-labeling rules used by `.github/workflows/triage.yml`.

Schema:
- `groups.<Prefix>.match`: `any` (all matching rules) or `first` (first matching rule only)
- `groups.<Prefix>.rules[]`: `{ "suffix", "patterns" }`
- `extras[]`: additional conditional labels via `when` (`actor_contains`, `text_matches`, `pr_path_matches`)

<!-- label-rules:start -->
```json
{
  "version": 1,
  "groups": {
    "Area": {
      "match": "any",
      "rules": [
        { "suffix": "CI", "patterns": ["\\.github\\b", "(^|/)workflows?/", "\\b(ci|pipeline|github actions?|actions/)\\b"] },
        { "suffix": "Tests", "patterns": ["(^|/)tests?/", "\\b(test|spec|coverage|smoke|bats)\\b"] },
        { "suffix": "Core", "patterns": ["\\btm_exclusions\\.sh\\b", "\\btm-exclusions\\b", "\\b(cli|runtime|shell script|bash script)\\b"] },
        { "suffix": "Config", "patterns": ["(^|/)config/", "\\b(default\\.conf|configuration|settings?)\\b"] },
        { "suffix": "Hooks", "patterns": ["\\.githooks", "\\bgithooks?\\b", "\\bpre-commit\\b", "\\bcommit-msg\\b"] },
        { "suffix": "Docs", "patterns": ["(^|/)docs/", "\\breadme\\.md\\b", "\\bchangelog\\b", "\\bdocumentation\\b", "\\breadme\\b"] },
        { "suffix": "Build", "patterns": ["\\bmakefile\\b", "\\bbuild\\b", "\\brelease\\b", "\\bpackag(e|ing)\\b", "\\binstall(ation)?\\b"] }
      ]
    },
    "Type": {
      "match": "any",
      "rules": [
        { "suffix": "Security", "patterns": ["\\b(security|vulnerabilit|cve|hardening|permission|privilege|sandbox)\\b"] },
        { "suffix": "Bug", "patterns": ["\\b(bug|broken|regression|crash|doesn'?t work|does not work|error|hotfix|fix)\\b"] },
        { "suffix": "Breaking Change", "patterns": ["\\b(breaking|incompatible|semver major|bc[!:])\\b"] },
        { "suffix": "Feature", "patterns": ["\\b(feature|new mode|new option|implement support|user story)\\b"] },
        { "suffix": "Enhancement", "patterns": ["\\b(enhancement|improvement|polish|incremental)\\b"] },
        { "suffix": "Documentation", "patterns": ["\\b(documentation|doc update|readme|guide)\\b"] },
        { "suffix": "Test", "patterns": ["\\b(test|tests|testing|spec|coverage|smoke test)\\b"] },
        { "suffix": "Build", "patterns": ["\\b(build|packaging|installer|makefile|release pipeline)\\b"] },
        { "suffix": "Dependency", "patterns": ["\\b(dependabot|dependency|renovate|bump(\\s+deps?)?)\\b"] },
        { "suffix": "Performance", "patterns": ["\\b(performance|perf|slow|faster|optimi[sz]e|latency|speed)\\b"] },
        { "suffix": "Refactor", "patterns": ["\\b(refactor|cleanup|reorganize|rename)\\b"] },
        { "suffix": "Chore", "patterns": ["\\b(chore|maintenance|housekeeping|format|lint|prettier|whitespace)\\b"] },
        { "suffix": "Question", "patterns": ["\\b(question|how (do|to|can)|is it possible|clarif)\\b", "\\?\\s*$"] }
      ]
    },
    "Status": {
      "match": "first",
      "rules": [
        { "suffix": "Blocked", "patterns": ["\\b(blocked|blocking|cannot proceed|dependency)\\b"] },
        { "suffix": "Duplicate", "patterns": ["\\b(duplicate|already reported|same as)\\b"] },
        { "suffix": "Fixed", "patterns": ["\\b(fixed|resolved|done)\\b"] },
        { "suffix": "In Progress", "patterns": ["\\b(in progress|wip|working on)\\b"] },
        { "suffix": "Invalid", "patterns": ["\\b(invalid|not reproducible|cannot reproduce)\\b"] },
        { "suffix": "Needs Info", "patterns": ["\\b(needs info|more info|missing info|steps to reproduce)\\b"] },
        { "suffix": "On Hold", "patterns": ["\\b(on hold|paused|deferred)\\b"] },
        { "suffix": "Ready", "patterns": ["\\b(ready to merge|ready)\\b"] },
        { "suffix": "Review Needed", "patterns": ["\\b(review needed|needs review|please review)\\b"] },
        { "suffix": "Won't Fix", "patterns": ["\\b(won't fix|wont fix|not planned)\\b"] }
      ]
    },
    "Effort": {
      "match": "first",
      "rules": [
        { "suffix": "X-Large", "patterns": ["\\b(x-large|xl|extra large|multiple weeks)\\b"] },
        { "suffix": "Large", "patterns": ["\\b(large|big|significant|about a week)\\b"] },
        { "suffix": "Medium", "patterns": ["\\b(medium|moderate|few days)\\b"] },
        { "suffix": "Small", "patterns": ["\\b(small|quick fix|few hours|minor)\\b"] }
      ]
    }
  },
  "extras": [
    {
      "when": "actor_contains",
      "value": "dependabot",
      "label": { "prefix": "Source", "suffix": "Dependabot" }
    },
    {
      "when": "pr_path_matches",
      "patterns": ["\\.github/workflows/"],
      "label": { "prefix": "Ecosystem", "suffix": "github-actions" }
    },
    {
      "when": "text_matches",
      "patterns": ["\\b(github actions?|actions/)\\b"],
      "label": { "prefix": "Ecosystem", "suffix": "github-actions" }
    }
  ]
}
```
<!-- label-rules:end -->

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

## Priorités

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
| `🕰️ Automation: Stale issue` | `#cfd8dc` | Marque une issue sans activité récente (bot stale). | Appliqué automatiquement lors du tri des issues inactives, avant fermeture éventuelle. |
| `🕰️ Automation: Stale pull request` | `#cfd8dc` | Marque une PR sans activité récente (bot stale). | Appliqué automatiquement lors du tri des PR inactives, avant fermeture éventuelle. |

## Meta et Source

| Label | Couleur | Description | Usage / Exemple |
| --- | --- | --- | --- |
| `🤖 Source: Dependabot` | `#0366d6` | Automated updates created by Dependabot. | PR ouverte automatiquement par Dependabot. |
| `🧰 Ecosystem: github-actions` | `#2088ff` | Changes related to GitHub Actions maintenance or updates. | Mise à jour d'une action `actions/*` ou d'un workflow GitHub. |
| `🧷 Meta: Good First Issue` | `#7e57c2` | Good entry point for newcomers. | Petite amélioration isolée, bien cadrée et simple à tester. |
| `🧷 Meta: Help Wanted` | `#26a69a` | Extra attention or external help is welcome. | Sujet utile mais pas prioritaire pour le mainteneur seul. |
| `🧷 Meta: Needs Discussion` | `#f06292` | Requires discussion or a decision before coding. | Arbitrage sur le périmètre, la stratégie, ou l'UX CLI. |
