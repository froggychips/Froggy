---
description: Создаёт ветку phase-*/<slug> и открывает PR с шаблоном по образцу #9–11
argument-hint: "<phase> <slug> [title]"
allowed-tools: Bash, Read
---

Создай ветку и открой PR по конвенции Froggy.

## Аргументы
- `<phase>` — `mem-1`, `mem-2`, …, `mem-5`, `mem-3.1`, `infra`, etc.
- `<slug>` — короткое имя ветки (kebab-case): `pageout`, `kvcache`, `freeze-ranker`.
- `<title>` (опционально) — заголовок PR. Если не передан — выведи имя slug в Title Case.

Если `git status --short` показывает изменения — закоммитить как
WIP перед созданием ветки. **Не пушить main**.

## Шаги
1. `git fetch origin && git checkout -B "phase-<phase>/<slug>" origin/main`
2. (если есть staged изменения) `git commit` или `git stash` пользователю,
   чтобы решил.
3. После того как нужные коммиты на ветке — `git push -u origin "phase-<phase>/<slug>"`.
4. `gh pr create` с шаблоном:

```
## Задача N из <серия>

<краткое описание цели>

## Изменения

### `<Component>` (новое/изменено)
- <bullet>

### Tests
NNN total (+M):
- <test bullet>

### Docs
- ADR <NNNN>-<slug>.md
- README: <что обновлено>

## Что осталось из требований
✅ <требование выполнено>
⚠️ <отложено> — почему

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

5. Вывести URL PR'а пользователю.

## Что НЕ делать
- Не мерджить PR. Это решение пользователя.
- Не force-push'ить.
- Не пушить в main напрямую.
