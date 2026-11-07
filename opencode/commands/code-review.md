---
description: upstreamとの差分や指定対象を背景の読み取り専用Agentでレビューする
agent: code-review
model: console-anthropic/claude-opus-5-5#medium
subagent: true
---

コードレビューを開始してください。あなたは専用の読み取り専用サブエージェントです。引数 `$ARGUMENTS` をレビュー対象・effort・オプションとして解釈し、Agentの指示に従ってください。

引数が空なら現在ブランチのupstreamより先のコミットと作業ツリーをレビューします。ファイル・ブランチ・`base...head`・PR番号・URLがあれば対象を指定します。`low` / `medium` / `high` / `max` はレビュー範囲、`--max-findings N|all|default` は最大指摘数です。

レビューAgentは背景で実行され、ファイルを変更しません。`--fix`、`--comment`、`--post` は読み取り専用制約のため実行できず、結果を報告するだけです。`ultra` のクラウドレビューも利用できません。
