#!/bin/bash

# やりたいこと
# ageによる暗号化と復号化
#
# コマンド設計
# 暗号化: ./krypton.sh -e (対象ファイルのパス)
# 暗号化したファイルは、対象ファイルと同じディレクトリに出力される
# 元のファイルは削除される (ゴミ箱ではなく、完全削除)
#
# 復号化: ./krypton.sh -d (暗号化ファイルのパス)
# 復号化したファイルは、対象ファイルと同じディレクトリに出力される
# 元のファイルは削除される (ゴミ箱ではなく、完全削除)

# エラー・未定義変数・パイプ途中の失敗のいずれでもスクリプトを停止する
set -euo pipefail

# 作成するファイルを自分だけが読める権限にする
umask 077

AGE_RECIPIENT="age1vekkrgkqkh9smgnf880x0clx0tlu2xgpvkkq5fdvh37kk7yzv5esg9m3hx"
KEY_REF="op://Personal/Krypton Key/secretkey"

partial=""

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
  echo "Usage: $0 (-e FILE | -d FILE)" >&2
  exit 1
}

cleanup() {
    if [[ -n "$partial" ]]; then
        rm -f -- "$partial"
    fi
}
trap cleanup EXIT

file_check() {
    # 入力元がシンボリックリンクでないことを確認する
    [[ ! -L "$1" ]] || { echo "Source is symbolic link: $1" >&2; exit 1; }
    # 元のファイルが見つかれば何もせず、見つからなければfile not foundを表示して終了
    [[ -f "$1" ]] || { echo "File not found: $1" >&2; exit 1; }
    # 出力先のファイルが見つからなければ何もせず、見つかればalready existsを表示して終了
    [[ ! -e "$2" ]] || { echo "Already exists: $2" >&2; exit 1; }
    # 出力先にシンボリックリンクが置かれていないことを確認する
    [[ ! -L "$2" ]] || { echo "Target is symbolic link" >&2; exit 1; }
}

remove_original() {
    local in="$1" out="$2"
    # 出力ファイルが存在して空でないことを確認してから元ファイルを削除
    [[ -s "$out" ]] || { echo "Output missing or empty, keeping: $in" >&2; exit 1; }
    echo "> Removing original file: $in"
    rm -f -- "$in"
}

encrypt() {
    echo "--Encryption--"
    # encrypt fileへのパス
    local in="$1"
    local out="${in}.age"

    file_check "$in" "$out"

    # 公開鍵を使って暗号化
    echo "> Encrypting..."
    echo "  $in -> $out"
    partial="$out"
    age -r "$AGE_RECIPIENT" -o "$out" "$in"


    # 手元の秘密鍵で復号して元ファイルと一致するか検証
    echo "> Verifying secret key..."
    age -d -i <(op read "$KEY_REF") "$out" | cmp -s - "$in" \
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
