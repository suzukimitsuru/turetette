# Claude Code 向けプロジェクト指針

## プロジェクト概要

## 進め方の原則

- 道のりと現在位置の図は docs/roadmap.html に置く。進捗があったら、README.md と docs/roadmap.html を同時に更新する
- 会話・文書は日本語を基本とする

## 制約

- Claude Code からの応答・報告は日本語で行う
- Markdown の形式
  - `npx -y markdownlint-cli2 "**/*.md" "#node_modules"`で問題が報告されない事とする
  - インデントは空白文字で2文字とする
  - 表はテキストの状態でインデントで桁を合わせる事とする
- HTML の形式
  - 文書ファイル(`.md`)や文書の置き場(`docs/` 等)に本文・見出し・図の注記・SVG の文字で言及したら、その箇所を `<a href="...">` のリンクにする事とする
  - 図(SVG)の中の項目は `<rect>` と `<text>` をまとめて `a.node` で包む事とする。下線は付けず、hover で枠と文字を `--accent` に変えて手掛かりとする
  - リンク先は HTML から見た相対パスで書く事とする(例: `docs/roadmap.html` から `docs/watch-alarm-design.md` を指すなら `href="watch-alarm-design.md"`)
  - ファイル名の空白は `%20` に置き換える事とする(日本語はそのまま書き、読める形で残す)
  - 表示する文字は元の表記(例: `docs/watch-alarm-design.md`)のまま変えない事とする
  - 対応する `.md` が無い項目はリンクにしない事とする
  - 文書を追加・改名したら、HTML のリンク切れが無いか確かめる事とする
