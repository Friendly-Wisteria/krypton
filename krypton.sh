#!/bin/bash

# エラー・未定義変数・パイプ途中の失敗のいずれでもスクリプトを停止する
set -euo pipefail

# 作成するファイルを自分だけが読める権限にする
umask 077

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/krypton"
CONFIG_FILE="$CONFIG_DIR/config"
AGE_RECIPIENT=""
KEY_REF="op://Personal/Krypton Key/secretkey"

partial=""
tmpdir=""

require_commands() {
    local cmd missing=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        echo "Required command not found: ${missing[*]}" >&2
        exit 1
    fi
}

audit_age_recipient() {
    # 設定ファイルがあればそこから公開鍵を読み取り、なければハードコードされた値を使う
    if [[ -f "$CONFIG_FILE" ]]; then
        AGE_RECIPIENT=$(sed -n 's/^PUBLIC_KEY=//p' "$CONFIG_FILE")
    elif [[ -z "$AGE_RECIPIENT" ]]; then
        # どちらもなければ初期設定を案内して終了
        echo "Config file not found: $CONFIG_FILE" >&2
        echo "Run 'krypton -i' to set up your key pair." >&2
        exit 1
    fi
    echo "Public key: $AGE_RECIPIENT"
    # AGE_RECIPIENTが公開鍵の形式を満たしているかどうかを検証する
    [[ "$AGE_RECIPIENT" =~ ^age1[a-z0-9]+$ ]] || { echo "Invalid AGE_RECIPIENT" >&2; exit 1; }
}

usage() {
  echo "Usage: $0 (-i | -a | -e FILE|DIR | -d FILE)" >&2
  exit 1
}

cleanup() {
    if [[ -n "$partial" ]]; then
        rm -f -- "$partial"
    fi
    if [[ -n "$tmpdir" ]]; then
        rm -rf -- "$tmpdir"
    fi
}
trap cleanup EXIT

file_check() {
    # 入力元がシンボリックリンクでないことを確認する
    [[ ! -L "$1" ]] || { echo "Source is symbolic link: $1" >&2; exit 1; }
    # 元のファイルが見つかれば何もせず、見つからなければfile not foundを表示して終了
    [[ -f "$1" ]] || { echo "File not found: $1" >&2; exit 1; }
    target_check "$2"
}

dir_check() {
    # 入力元がシンボリックリンクでないことを確認する
    [[ ! -L "$1" ]] || { echo "Source is symbolic link: $1" >&2; exit 1; }
    [[ -d "$1" ]] || { echo "Directory not found: $1" >&2; exit 1; }
    # / や . .. のような名前を持たないディレクトリは対象外
    case "$(basename -- "$1")" in
        /|.|..) echo "Unsupported directory: $1" >&2; exit 1 ;;
    esac
    target_check "$2"
}

target_check() {
    # 出力先のファイルが見つからなければ何もせず、見つかればalready existsを表示して終了
    [[ ! -e "$1" ]] || { echo "Already exists: $1" >&2; exit 1; }
    # 出力先にシンボリックリンクが置かれていないことを確認する
    [[ ! -L "$1" ]] || { echo "Target is symbolic link" >&2; exit 1; }
}

remove_original() {
    local in="$1" out="$2"
    # 出力ファイルが存在して空でないことを確認してから元ファイルを削除
    [[ -s "$out" ]] || { echo "Output missing or empty, keeping: $in" >&2; exit 1; }
    if [[ -d "$in" ]]; then
        echo "> Removing original directory: $in"
        rm -rf -- "$in"
    else
        echo "> Removing original file: $in"
        rm -f -- "$in"
    fi
}

initialize() {
    # 前提のチェック:
    require_commands age age-keygen op

    # 既存のキーがないかを調べる
    # (未サインインや承認の拒否もここでエラーとして検出され、中断される)
    echo "Searching existing Krypton Key on 1Password..."
    # opは見つからない場合も認証やネットワークのエラーも同じ終了コードを返すため、エラーメッセージで区別する
    local get_err
    if get_err=$(op item get "Krypton Key" --vault Personal 2>&1 >/dev/null); then
        echo ">> Krypton Key has been found"
        echo ""
        # 新しい鍵は作らず、1Passwordの秘密鍵から公開鍵を導出して設定ファイルを復元する
        # (手動で登録した鍵にはpublickeyフィールドがないため、秘密鍵から導出する)
        echo "Restoring public key from 1Password..."
        save_public_key "$(op read "$KEY_REF" | age-keygen -y)"
        exit 0
    fi
    # 「アイテムが存在しない」以外のエラーで鍵を新規作成すると、既存の鍵と重複するおそれがあるため中断する
    if [[ "$get_err" != *"isn't an item"* ]]; then
        echo ">> Failed"
        echo "$get_err" >&2
        echo "Could not determine whether Krypton Key exists. Aborting without creating a new key." >&2
        exit 1
    fi
    echo ">> No Krypton Key found"
    echo ""

    # キーペアを生成
    echo "Generating key pair..."
    local key_pair public_key secret_key
    key_pair=$(age-keygen 2>/dev/null)
    # macOS標準のbash 3.2ではヒアストリング(<<<)が一時ファイルを作るため、printfのパイプで渡す
    public_key=$(printf '%s\n' "$key_pair" | grep '# public key:' | awk '{print $NF}')
    secret_key=$(printf '%s\n' "$key_pair" | grep '^AGE-SECRET-KEY-')
    # JSONに埋め込むため、想定外の文字が含まれていないことを確認する
    [[ "$public_key" =~ ^age1[a-z0-9]+$ ]] || { echo "Failed to generate public key" >&2; exit 1; }
    [[ "$secret_key" =~ ^AGE-SECRET-KEY-[A-Z0-9]+$ ]] || { echo "Failed to generate secret key" >&2; exit 1; }

    # キーペアを1Passwordに登録
    # 秘密鍵をコマンド引数で渡すとpsなどから見えるため、JSONテンプレートを標準入力から渡す
    # (printfはbashの組み込みコマンドなので、引数がプロセス一覧に現れない)
    echo "Registering to 1Password..."
    printf '{"title":"Krypton Key","category":"SECURE_NOTE","fields":[{"id":"publickey","type":"STRING","label":"publickey","value":"%s"},{"id":"secretkey","type":"CONCEALED","label":"secretkey","value":"%s"}]}' \
        "$public_key" "$secret_key" \
        | op item create --vault="Personal" - >/dev/null
    echo ">> OK"
    echo ""
    # 公開鍵をconfigファイルに作成
    save_public_key "$public_key"
}

save_public_key() {
    local public_key="$1"
    # 公開鍵の形式を満たしていなければ書き込まない
    [[ "$public_key" =~ ^age1[a-z0-9]+$ ]] || { echo "Invalid public key: $public_key" >&2; exit 1; }
    mkdir -p -- "$CONFIG_DIR"
    echo "PUBLIC_KEY=$public_key" > "$CONFIG_FILE"
    echo "Saved public key to $CONFIG_FILE"
}

encrypt() {
    # 公開鍵が有効であることをチェック
    audit_age_recipient
    echo "--Encryption--"
    # encrypt file or directoryへのパス
    local in="$1"
    # 末尾のスラッシュを取り除く (dir/ → dir)
    while [[ "$in" == */ && "$in" != "/" ]]; do in="${in%/}"; done
    local out="${in}.age"
    # ageに渡す暗号化対象 (ディレクトリの場合は一時zip)
    local src="$in"

    if [[ -d "$in" && ! -L "$in" ]]; then
        out="${in}.zip.age"
        dir_check "$in" "$out"
        require_commands zip

        # 一時ディレクトリにzipを作成 (シンボリックリンクは辿らずリンクとして格納)
        echo "> Compressing directory..."
        tmpdir="$(mktemp -d)"
        src="$tmpdir/$(basename -- "$in").zip"
        echo "  $in -> $src"
        (cd "$(dirname -- "$in")" && zip -r -q -y "$src" "./$(basename -- "$in")")
    else
        file_check "$in" "$out"
    fi

    # 公開鍵を使って暗号化
    echo "> Encrypting..."
    echo "  $src -> $out"
    partial="$out"
    age -r "$AGE_RECIPIENT" -o "$out" "$src"


    # 手元の秘密鍵で復号して暗号化対象と一致するか検証
    echo "> Verifying secret key..."
    age -d -i <(op read "$KEY_REF") "$out" | cmp -s - "$src" \
        || { echo "Verification failed, keeping: $in" >&2; rm -f -- "$out"; exit 1; }
    partial=""
    # 元のファイルの削除
    remove_original "$in" "$out"
    echo "> Finished!"
    echo "--------------"
}

decrypt() {
    echo "--Decryption--"
    local in="$1"
    [[ "${in##*.}" == "age" ]] || { echo ".age file required" >&2; exit 1; }
    local out="${in%.*}" # 元のファイル名から拡張子を取り除く

    if [[ "$out" == *.zip ]]; then
        decrypt_zip "$in" "${out%.zip}"
        return
    fi

    # 入力元と出力先のチェック
    file_check "$in" "$out"
    # 復号化
    echo "> Decrypting..."
    echo "  $in -> $out"
    partial="$out"
    age -d -i <(op read "$KEY_REF") -o "$out" "$in"
    partial=""
    # 元のファイルの削除
    remove_original "$in" "$out"
    echo "> Finished!"
    echo "--------------"
}

decrypt_zip() {
    local in="$1" out="$2"

    file_check "$in" "$out"
    require_commands unzip

    # 出力先と同じ場所に作業ディレクトリを作り、復号と解凍はその中で行う
    tmpdir="$(mktemp -d "$(dirname -- "$in")/.krypton.XXXXXX")" # 入力元のファイルのディレクトリ直下の".krypton.XXXXXX"(Xはランダムな英数字)というフォルダのパス
    local zip="$tmpdir/archive.zip" # 一時ディレクトリの下の、archive.zipというファイルのパス
    local extracted="$tmpdir/extracted" # 一時ディレクトリの下の、extractedというフォルダのパス

    # 入力元の.ageファイルを、一時フォルダ内にarchive.zipとして復号化
    echo "> Decrypting..."
    echo "  $in -> $zip"
    age -d -i <(op read "$KEY_REF") -o "$zip" "$in"

    # archive.zipの内容を、extractedフォルダに展開する
    echo "> Extracting..."
    mkdir -- "$extracted"
    unzip -q "$zip" -d "$extracted"

    # トップレベルがディレクトリ1つだけならそれを、そうでなければ展開先ごと出力にする
    local result="$extracted" top
    if [[ "$(find "$extracted" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]]; then # extracted直下に、ファイルまたはフォルダが一つだけの時
        top="$(find "$extracted" -mindepth 1 -maxdepth 1)" # top をそのファイルまたはディレクトリとする
        if [[ -d "$top" && ! -L "$top" ]]; then
            result="$top" # topがシンボリックでなければ、resultをtopにする
        fi
    fi

    # 解凍中に出力先が作られていないか再確認してから移動
    target_check "$out"
    echo "  -> $out"
    mv -- "$result" "$out" # 展開の結果を、outのパスに移動する
    # 元のファイルの削除
    remove_original "$in" "$out"
    echo "> Finished!"
    echo "--------------"
}

# メインループ
echo "=========================="
echo "** Krypton File Encrypt **"
echo "=========================="



mode=""
file=""



while getopts ":aie:d:" opt; do
    case "$opt" in
        a) [[ -z "$mode" ]] || usage; mode="audit" ;;
        i) [[ -z "$mode" ]] || usage; mode="init" ;;
        e) [[ -z "$mode" ]] || usage; mode="encrypt"; file="$OPTARG" ;;
        d) [[ -z "$mode" ]] || usage; mode="decrypt"; file="$OPTARG" ;;
        :) echo "Option -$OPTARG requires a file" >&2; usage ;;
        \?) echo "Unknown option: -$OPTARG" >&2; usage ;;
    esac
done
shift $((OPTIND - 1))
[[ $# -eq 0 ]] || usage

[[ -n "$mode" ]] || usage

require_commands age op

case "$mode" in
    audit) audit_age_recipient ;;
    init) initialize ;;
    encrypt) encrypt "$file" ;;
    decrypt) decrypt "$file" ;;
esac
