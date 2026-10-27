#!/bin/bash

# やりたいこと
# ageによる暗号化と復号化
#
# コマンド設計
# 暗号化: ./krypton.sh -e (対象ファイル or ディレクトリのパス)
# 暗号化したファイルは、対象ファイルと同じディレクトリに出力される
# ディレクトリを指定した場合は、zipで圧縮してから暗号化する (dir → dir.zip.age)
# 元のファイルは削除される (ゴミ箱ではなく、完全削除)
#
# 復号化: ./krypton.sh -d (暗号化ファイルのパス)
# 復号化したファイルは、対象ファイルと同じディレクトリに出力される
# .zip.ageの場合は、復号してから解凍する (dir.zip.age → dir)
# 元のファイルは削除される (ゴミ箱ではなく、完全削除)

# エラー・未定義変数・パイプ途中の失敗のいずれでもスクリプトを停止する
set -euo pipefail

# 作成するファイルを自分だけが読める権限にする
umask 077

AGE_RECIPIENT="age1vekkrgkqkh9smgnf880x0clx0tlu2xgpvkkq5fdvh37kk7yzv5esg9m3hx"
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

usage() {
  echo "Usage: $0 (-e FILE|DIR | -d FILE)" >&2
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

encrypt() {
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

while getopts ":e:d:" opt; do
    case "$opt" in
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
    encrypt) encrypt "$file" ;;
    decrypt) decrypt "$file" ;;
esac
