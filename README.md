# Krypton
公開鍵によるファイルの暗号化と、秘密鍵によるファイルの復号化を実行するシェルスクリプトです。

## 主な機能
- ファイルおよびフォルダの暗号化・復号化
  - フォルダは zip 形式で自動圧縮してから暗号化します。
- 1Password CLI (`op`) と連携した安全な秘密鍵管理
- 暗号化実行時に手元の秘密鍵で自動検証（インテグラティチェック）を実施

## 技術スタック

| 領域 | 使用技術 |
| -- | -- |
| 言語 | Shell (Bash) |
| 暗号化 | `age` |
| 鍵管理 | 1Password CLI (`op`) |
| 圧縮/解凍 | `zip` / `unzip` |

## セットアップ

### 1. 前提となるCLIのインストール

```bash
# macOS (Homebrew) の場合
brew install age 1password-cli zip unzip
```

### 2. 1Passwordデスクトップアプリのインストール
1Passwordの公式HPよりダウンロードできます。

* [Mac版をダウンロード](https://1password.com/jp/downloads/mac)
* [Windows版をダウンロード](https://1password.com/jp/downloads/windows)

### 3. 1Password CLIとの連携

1. 1Passwordデスクトップアプリを開く
2. **設定** ＞ **開発者** を開く
3. **「1Password CLIと連携」**を有効にする
4. ターミナルで`op signin`を実行し、認証を許可する


### 4. 鍵ペアの生成とスクリプトへの設定

ターミナルで以下を実行し、鍵ペアを生成します。

```bash
age-keygen -o key.txt
```

`key.txt`の内容を確認します。
```text
# created: 2026-10-27T21:50:56+09:00
# public key: age1...
AGE-SECRET-KEY-...
```

1. **公開鍵の設定**: `public key:`に続く`age1...`の文字列をコピーし、`krypton.sh`のAGE_RECIPIENT="..."に貼り付けます。
2. **秘密鍵の設定**: `AGE-SECRET-KEY-...`から始まる文字列は、次の手順5で 1Password に登録します。
  * **この文字列は絶対に他人に教えてはいけません**

> [!CAUTION]
秘密鍵（`AGE-SECRET-KEY-...`）は絶対に他人に教えてはいけません。作業が終わったら `key.txt` は必ず削除してください。

## 5. 1Password への秘密鍵の登録
1Passwordデスクトップアプリより、「個人」保管庫に、以下のセキュアノートを作成します。

* **カテゴリ**: セキュアノート
* **タイトル**: `Krypton Key`
* **フィールド追加**:
  1. 「さらに追加」から パスワード を選択
  2. 生成した秘密鍵（`AGE-SECRET-KEY-...`）をペースト
  3. ラベル名を `secretkey` に変更
  4. 保存


## 6. スクリプトの配置と権限付与
パスの通っているディレクトリ（例: `~/bin` や `~/.local/bin`）に配置し、実行権限を付与します。

```bash
mv krypton.sh ~/bin/krypton
chmod +x ~/bin/krypton
```

## 使い方
> [!WARNING]
**注意**: 暗号化・復号化が成功すると、元のファイル/フォルダはゴミ箱を経由せず完全に削除されます。

初めて使用する際は、必ずダミーファイル等で正常に往復処理が行えるかテストしてください。

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


## ライセンス
[MIT License](LICENSE)
