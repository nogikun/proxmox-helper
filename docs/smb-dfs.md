# Proxmox LXC の Samba / DFS ヘルパー

Windows のエクスプローラーと macOS Finder からゲートウェイの SMB 共有を開き、各 LXC の Samba 共有へ移動する構成です。ファイルの実体は対象 LXC に置いたままです。PVE ホストには Samba を入れず、bind mount も追加しません。

## 構成

~~~text
Windows / macOS
      │ SMB: \\<ゲートウェイIP>\containers
      ▼
ゲートウェイ LXC (Samba MSDFS root)
      │ DFS referral: \\<対象IP>\files
      ▼
対象 LXC (Samba share) ── 実ファイル
~~~

ゲートウェイはファイルの保存先ではありません。DFS リンクは対象 LXC の IP と共有名を指します。Samba MSDFS ではルート共有内の小文字シンボリックリンクが参照として使われます。

## 1. Debian LXC を作成する

PVE の Shell でコミュニティの Debian LXC Helper Script を実行します。ウィザードで CTID、固定アドレスまたは DHCP 予約、ストレージを設定してください。

~~~bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/debian.sh)"
~~~

同じ方法でゲートウェイ用を1台、共有用を必要な数だけ作成します。既存の Samba LXC をゲートウェイに使う場合は、新設を省略できます。この Helper Script は LXC を作り、このリポジトリのスクリプトがその後の Samba / DFS 設定を行います。

## 2. スクリプトを PVE に置く

リポジトリを PVE ノードに一度だけ clone します。

~~~bash
git clone https://github.com/nogikun/proxmox-helper.git /opt/proxmox-helper
cd /opt/proxmox-helper
~~~

次のコマンドは PVE の root シェルから実行します。PVE 標準の pct を使い、設定用の一時ファイルだけを LXC に転送します。

## コマンド早見表

以下は PVE ノードの root シェルで実行します。ローカルに clone した場合は次のコマンドで引数のヘルプを表示できます。

~~~bash
bash scripts/smb-dfs.sh gateway --help
bash scripts/smb-dfs.sh add --help
~~~

### gateway: ゲートウェイを初回設定

~~~bash
bash scripts/smb-dfs.sh gateway --ctid 900
~~~

- 必須: --ctid
- 任意: --root-share（既定値 containers）、--root-path（既定値 /srv/dfs/containers）、--user（既定値 dfsuser）
- 実行時に SMB パスワードを2回入力します

### add: 共有 LXC を登録

~~~bash
bash scripts/smb-dfs.sh add --gateway 900 --ctid 901 --ip 192.168.1.21 --name ct-a --share files --path /srv/files
~~~

- 必須: --gateway、--ctid、--ip、--name、--path
- 任意: --share（既定値 files）、--root-share（既定値 containers）、--user（既定値 dfsuser）
- --ip は対象 LXC に現在割り当てられている固定 IPv4 または DHCP 予約アドレス
- 実行時に SMB パスワードを2回入力します

### GitHub の raw URL から起動

このリポジトリの変更を GitHub の main ブランチへ push した後は、clone せずに実行できます。

~~~bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/nogikun/proxmox-helper/main/scripts/smb-dfs.sh)" _ gateway --ctid 900
~~~

~~~bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/nogikun/proxmox-helper/main/scripts/smb-dfs.sh)" _ add --gateway 900 --ctid 901 --ip 192.168.1.21 --name ct-a --share files --path /srv/files
~~~
## 3. ゲートウェイを初回設定する

ゲートウェイ LXC の CTID を指定します。Samba を LXC 内にインストールし、DFS root share containers とユーザー dfsuser を設定します。SMB パスワードを2回入力してください。

~~~bash
bash scripts/smb-dfs.sh gateway --ctid 900
~~~

対象共有への接続にも同じユーザー名とパスワードを使います。パスワードは引数やコマンド履歴に残りません。

## 4. 共有 LXC を追加する

対象 LXC を Helper Script で作り、データ用ディレクトリを用意したあと、次の1コマンドを実行します。

~~~bash
bash scripts/smb-dfs.sh add \
  --gateway 900 \
  --ctid 901 \
  --ip 192.168.1.21 \
  --name ct-a \
  --share files \
  --path /srv/files
~~~

- --gateway: DFS ゲートウェイの CTID
- --ctid: Samba 共有を作る対象 LXC の CTID
- --ip: 対象 LXC の固定 IPv4（DHCP なら予約）
- --name: DFS 内に表示する小文字のリンク名
- --share: 対象 LXC で公開する共有名
- --path: 対象 LXC 内の実データディレクトリ

対象ディレクトリがなければ dfsuser 所有で作ります。既存ディレクトリの所有者や権限は再帰変更しません。既存ディレクトリで書き込みできない場合は、権限を手動で整えてから再実行してください。

### 登録結果を確認する

次のコマンドでゲートウェイと対象 LXC の状態、Samba の設定、DFS リンク先を確認できます。

~~~bash
pct status 900
pct status 901
pct exec 900 -- testparm -s --section-name containers --parameter-name 'msdfs root'
pct exec 900 -- ls -l /srv/dfs/containers
pct exec 900 -- readlink /srv/dfs/containers/ct-a
pct exec 901 -- testparm -s --section-name files --parameter-name path
pct exec 901 -- systemctl is-active smbd
~~~

readlink の結果が次のようになれば、ゲートウェイのリンク先は対象共有を指しています。

~~~text
msdfs:192.168.1.21\files
~~~

CTID、IP、共有名、DFS リンク名、パスは実際の値に置き換えてください。

## 5. クライアントから開く

クライアント側で一度だけゲートウェイを開きます。

- Windows: エクスプローラーのアドレス欄に \\192.168.1.10\containers
- macOS: Finder →「移動」→「サーバへ接続」に smb://192.168.1.10/containers

dfsuser と同じパスワードで接続します。共有内の ct-a などを開くと、対象 LXC の共有へ接続します。Windows と macOS の DFS namespace traversal は各 OS のガイドで案内されていますが、この構成の実機動作は未確認です。

## 共有を外す

対象 LXC を削除する前に、ゲートウェイ上の DFS リンクだけを削除します。実体データには触れません。

~~~bash
pct exec 900 -- rm -- /srv/dfs/containers/ct-a
pct exec 900 -- systemctl reload smbd
~~~

## 前提・制約

- PVE ノード上で root として実行し、pct、curl、git が使えること
- ゲートウェイと対象は起動中の Debian / Ubuntu LXC
- ゲートウェイと全対象共有で、同じ SMB ユーザー名・パスワードを使う
- 対象 LXC の IPv4 を固定または DHCP 予約にする。IP が変わった場合は DFS リンクの更新が必要
- LXC 内から apt-get update と Samba インストールができること
- ファイアウォールで SMB TCP 445 をゲートウェイと対象 LXC へ許可すること
- ゲートウェイ設定は最初の1回、対象共有の登録は追加のたびにこのコマンドを実行
- 自動スキャンでの LXC 発見・削除検知はしません。共有ごとに明示して登録します
- 実機 PVE / Windows / Mac への接続検証はしていません。まず1つの共有で確認してください

## 参照

- [Proxmox VE Helper-Scripts (Community Edition)](https://github.com/community-scripts/ProxmoxVE)
- [Proxmox pct コマンド](https://github.com/proxmox/pve-docs/blob/master/generated/pct.1-synopsis.adoc)
- [Samba MSDFS の設定例](https://www.samba.org/samba/docs/using_samba/ch08.html)
- [Samba smb.conf マニュアル](https://www.samba.org/samba/docs/current/man-html/smb.conf.5)
- [Apple: macOS の DFS namespace support](https://support.apple.com/guide/directory-utility/distributed-file-system-namespace-support-ior598b5f4f9/7.0/mac/27)