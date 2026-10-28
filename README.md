# Krypton
公開鍵によるファイルの暗号化と、秘密鍵によるファイルの復号化を実行するシェルスクリプトです。

## 主な機能
- ファイルおよびフォルダの暗号化・復号化
  - フォルダは zip 形式で自動圧縮してから暗号化します。
- 1Password CLI (`op`) と連携した安全な秘密鍵管理
- 暗号化実行時に手元の秘密鍵で自動検証（インテグリティチェック）を実施

## 技術スタック

| 領域 | 使用技術 |
| -- | -- |
| 言語 | Shell (Bash) |
| 暗号化 | `age` |
| 鍵管理 | 1Password CLI (`op`) |
| 圧縮/解凍 | `zip` / `unzip` |

## 動作環境
macOS を前提としています。Windows には対応していません。

## セットアップ

### 1. 前提となるCLIのインストール

```bash
# macOS (Homebrew) の場合
brew install age 1password-cli zip unzip
```

### 2. 1Passwordデスクトップアプリのインストール
1Passwordの公式HPよりダウンロードできます。

* [Mac版をダウンロード](https://1password.com/jp/downloads/mac)

### 3. 1Password CLIとの連携

1. 1Passwordデスクトップアプリを開く
2. **設定** ＞ **開発者** を開く
3. **「1Password CLIと連携」**を有効にする
4. ターミナルで`op signin`を実行し、認証を許可する


### 4. スクリプトの配置と権限付与
パスの通っているディレクトリ（例: `~/.local/bin`）に配置し、実行権限を付与します。

```bash
mv krypton.sh ~/.local/bin/krypton
chmod +x ~/.local/bin/krypton
```

### 5. 初期設定 (`-i`)
ターミナルで以下を実行します。

```bash
krypton -i
```

以下の処理が自動で行われます。

1. 1Password CLI にサインインしているかを確認します。
2. 鍵ペアを生成し、1Password の「個人」保管庫にセキュアノート `Krypton Key` として登録します。
   * `secretkey` フィールド: 秘密鍵（`AGE-SECRET-KEY-...`）
   * `publickey` フィールド: 公開鍵（`age1...`）
3. 公開鍵を設定ファイル `~/.config/krypton/config` に保存します。

秘密鍵はファイルに書き出されず、1Password にのみ保存されます。

> [!NOTE]
1Password にすでに `Krypton Key` がある場合は、新しい鍵は作成されません。代わりに、登録済みの秘密鍵から公開鍵を導出して `~/.config/krypton/config` を作り直します。別の Mac でセットアップする場合や、設定ファイルを消してしまった場合も、`krypton -i` を実行すれば復元できます。

> [!CAUTION]
`Krypton Key` を 1Password から削除すると、それまでに暗号化したファイルは二度と復号できなくなります。

### 公開鍵の保存場所について
公開鍵は `~/.config/krypton/config` に以下の形式で保存されます（`XDG_CONFIG_HOME` を設定している場合は `$XDG_CONFIG_HOME/krypton/config`）。

```text
PUBLIC_KEY=age1...
```

設定ファイルを使わずに、公開鍵をスクリプトに直接書き込むこともできます。`krypton` の `AGE_RECIPIENT="..."` に公開鍵を貼り付ければ、`~/.config/krypton/config` は削除しても構いません。

```bash
AGE_RECIPIENT="age1..."
```

なお、設定ファイルがある場合は、スクリプトに書き込んだ値よりも設定ファイルの値が優先されます。

## 使い方
> [!WARNING]
**注意**: 暗号化・復号化が成功すると、元のファイル/フォルダはゴミ箱を経由せず完全に削除されます。初めて使用する際は、必ずダミーファイル等で正常に往復処理が行えるかテストしてください。

### 暗号化 (`-e`)
```bash
krypton -e /path/to/target/file
```
* **ファイル指定時**: 同一ディレクトリに ファイル名.age が生成され、元のファイルは削除されます。
* **フォルダ指定時**: 同一ディレクトリに フォルダ名.zip.age が生成され、元のフォルダは削除されます。

### 復号化 (`-d`)
```bash
krypton -d /path/to/target/encrypted/file.age
```

* 元のファイルと同じディレクトリに復号化されたファイル（または展開されたフォルダ）が生成され、暗号化ファイル（`.age`）は削除されます。

### 公開鍵の確認 (`-a`)
```bash
krypton -a
```

* 暗号化に使われる公開鍵を表示し、正しい形式かどうかを検証します。


## 免責事項
本スクリプトは個人用に作成したもので、第三者によるセキュリティ監査は受けていません。利用によって生じたデータの損失などについて、作者は責任を負いかねます。重要なデータは、別途バックアップを取ったうえでご利用ください。

## ライセンス
[MIT License](LICENSE)
