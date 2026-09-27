# Proxmox Helper

Proxmox VE の LXC 用ヘルパーと運用ドキュメントです。

- Samba / MSDFS 共有ゲートウェイの手順: docs/smb-dfs.md
- 実行スクリプト: scripts/smb-dfs.sh

このスクリプトは Debian / Ubuntu LXC 内に Samba を設定し、MSDFS ルート LXC に対象共有へのリンクを登録します。PVE ホストには Samba をインストールしません。