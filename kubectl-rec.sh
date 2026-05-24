# =============================================================================
# kubectl-rec.sh  —  kubectl をシェル関数で透過的にラップして履歴を取る
# -----------------------------------------------------------------------------
# インストール:
#   1) kubectl-rec を PATH の通った場所に配置 (例: /usr/local/bin/kubectl-rec)
#      cp kubectl-rec /usr/local/bin/ && chmod +x /usr/local/bin/kubectl-rec
#
#   2) このファイルを ~/.kube/kubectl-rec.sh などに保存し、シェルの rc から source:
#      echo 'source ~/.kube/kubectl-rec.sh' >> ~/.zshrc    # zsh
#      echo 'source ~/.kube/kubectl-rec.sh' >> ~/.bashrc   # bash
#
#   3) 新しいシェルで以下が動く:
#      kubectl apply -f manifests/app.yaml      ← 自動で記録される
#      kubectl get pods                          ← 素通し (記録されない)
#
# 仕組み:
#   - シェル関数 kubectl() を定義し、argv の最初の non-flag を見て
#     apply / delete / replace / patch なら kubectl-rec に振り、それ以外は
#     `command kubectl` で本物にそのまま渡す。
#   - シェル関数は子プロセスに継承されないので、kubectl-rec の内部で本物の
#     kubectl を呼んでも再帰しない。
#
# 一時的に無効化したいとき:
#   KUBECTL_REC_DISABLE=1 kubectl apply -f foo.yaml
#   または
#   command kubectl apply -f foo.yaml
#
# 履歴の場所:
#   ~/.kube/kubectl-history/history.jsonl
#   ~/.kube/kubectl-history/snapshots/
# =============================================================================

kubectl() {
  # 引数なしならそのまま本物に投げる
  if [ $# -eq 0 ]; then
    command kubectl
    return $?
  fi

  # 明示的無効化フラグ
  if [ "${KUBECTL_REC_DISABLE:-0}" = "1" ]; then
    command kubectl "$@"
    return $?
  fi

  # 最初の non-flag を「サブコマンド候補」として拾う
  # (グローバルフラグの値も大雑把にスキップ)
  local op="" a skip=0
  for a in "$@"; do
    if [ "$skip" = "1" ]; then skip=0; continue; fi
    case "$a" in
      --kubeconfig|--context|-n|--namespace|--cluster|--user|--server|--token|\
--certificate-authority|--client-key|--client-certificate|--as|--as-group|-s)
        skip=1 ;;
      -*) ;;
      *)  op="$a"; break ;;
    esac
  done

  case "$op" in
    apply|delete|replace|patch)
      if command -v kubectl-rec >/dev/null 2>&1; then
        command kubectl-rec "$@"
        return $?
      else
        echo "[kubectl-rec] warn: kubectl-rec not found in PATH; running plain kubectl" >&2
        command kubectl "$@"
        return $?
      fi
      ;;
    *)
      command kubectl "$@"
      return $?
      ;;
  esac
}

# zsh のときは completion も本物にフォールバック (kubectl 公式の completion がそのまま使える)
if [ -n "${ZSH_VERSION:-}" ]; then
  compdef _kubectl kubectl 2>/dev/null || true
fi
