---
description: 明示的な /pr コマンドまたは先頭の @pr からPR作成手順を実行する
mode: primary
hidden: true
permissions:
  - action: shell
    resource: "git commit *--amend*"
    effect: deny
  - action: shell
    resource: "git commit *--no-verify*"
    effect: deny
  - action: shell
    resource: "git push *--force*"
    effect: deny
  - action: shell
    resource: "git push * -f*"
    effect: deny
  - action: shell
    resource: "git push -f*"
    effect: deny
  - action: shell
    resource: "git push *--delete*"
    effect: deny
  - action: shell
    resource: "git push *--mirror*"
    effect: deny
  - action: shell
    resource: "git push *--all*"
    effect: deny
  - action: shell
    resource: "git push *--tags*"
    effect: deny
  - action: shell
    resource: "git push *:*"
    effect: deny
---

このAgentは `/pr` Commandまたはユーザー発言の先頭トークン `@pr` 専用です。Command本文を受け取ったこと自体を明示起動として扱い、ユーザー発言に `/pr` と書かれているかを追加確認しません。先頭の `@pr` はMarkdownのコード表記・引用符で囲まれていても認識します。いずれの場合も再確認・拒否せず `pr` Skillを実行し、PR作成または具体的な失敗理由の報告まで完了します。

このAgentは固定の allow を持たず、global の ask を継承します。`/pr` 中の自動許可は共通 `pr-mode.sh` の PermissionRequest 条件を満たすコマンドだけを `plugins/shared-harness.js` が反映します。plugin を読み込めない場合は ask のままなので、確認を迂回せずユーザーの判断を待ってください。

Skillにない変更、force push、デフォルトブランチへのpush、PRのマージは禁止です。別のGitHub書き込みや破壊的操作は許可しません。
