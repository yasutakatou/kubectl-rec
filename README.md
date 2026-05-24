# kubectl-rec

**A local-file recorder for state-changing kubectl operations, implemented as a Bash kubectl plugin**

# Feature

- **Transparent kubectl Wrapping**
  - A small shell function `kubectl()` defined in `kubectl-rec.sh` intercepts every `kubectl` invocation, inspects the first non-flag argument, and routes `apply` / `delete` / `replace` / `patch` through the recorder. All other subcommands (`get`, `logs`, `describe`, …) pass through to the real kubectl unchanged.
- **Full-Path Manifest Tracking**
  - Every manifest passed via `-f` (file, directory, or stdin) or `-k` (kustomize) is resolved to its absolute path and stored in the history index, so you can later answer "which file on disk produced this resource?"
- **Content Snapshots**
  - The exact YAML / JSON applied is copied into `~/.kube/kubectl-history/snapshots/` with a SHA-256-derived filename. For kustomize sources, the rendered output of `kubectl kustomize` is snapshotted instead of just the directory path.
- **JSONL History Index**
  - Each operation is appended as a single JSON line to `history.jsonl`, making the log trivially queryable with `jq`, `grep`, or any line-oriented tool.
- **Context-Aware Metadata**
  - Records timestamp, user, host, working directory, kube-context, cluster name, namespace, full command line, exit code, and the captured stdout / stderr of kubectl.
- **No Cluster-Side Components**
  - Pure local recording — no CRDs, controllers, admission webhooks, or etcd writes. Everything stays under `~/.kube/`.
- **Safe Against Recursion**
  - Shell functions are not inherited by child processes, so when the recorder internally invokes the real `kubectl` binary the wrapping function does not re-fire. No infinite loop, no special escaping needed.

## v0.1

- **Initial release**
  Supports `apply` / `delete` / `replace` / `patch`. Handles `-f <file>`, `-f <dir>` (with `-R`), `-f -` (stdin via a temp file), and `-k <kustomize-dir>` (rendered via `kubectl kustomize`).
- **Snapshot deduplication**
  Snapshot filenames embed the first 12 hex digits of the file's SHA-256, so re-applying an unchanged file does not create duplicate snapshot copies.
- **Plugin compatibility**
  Because the recorder is also installable as `kubectl-rec`, you can call it explicitly as a plugin (`kubectl rec apply -f foo.yaml`) without using the shell function.

# Installation

The tool consists of two files:

```
kubectl-rec       # the recorder binary (Bash script, also usable as a kubectl plugin)
kubectl-rec.sh    # the shell function snippet, to be sourced from .zshrc / .bashrc
```

Put the recorder on your `$PATH`, make it executable, and source the shell function from your shell rc file:

```
cp kubectl-rec /usr/local/bin/
chmod +x /usr/local/bin/kubectl-rec

cp kubectl-rec.sh ~/.kube/
echo 'source ~/.kube/kubectl-rec.sh' >> ~/.zshrc    # zsh users
# echo 'source ~/.kube/kubectl-rec.sh' >> ~/.bashrc  # bash users

mkdir -p ~/.kube/kubectl-history/
exec $SHELL -l
```

Required dependencies:

- bash 3.2+ (default on macOS works)
- jq (`brew install jq` / `apt-get install jq`)
- kubectl
- sha256sum or shasum (either one is fine)

# Configuration

Behavior can be tuned through environment variables. None of them are required.

```
KUBECTL_HISTORY_DIR   Directory where history.jsonl and snapshots/ are stored
                      (default: ~/.kube/kubectl-history)

KUBECTL_BIN           Name or path of the real kubectl binary the recorder calls
                      (default: kubectl, resolved through $PATH)

KUBECTL_REC_DISABLE   When set to 1, the shell function bypasses the recorder
                      and calls the real kubectl directly for that invocation
```

Resulting layout on disk:

```
~/.kube/kubectl-history/
  ├── history.jsonl                                  one operation = one JSON line
  └── snapshots/
      ├── 20260521T102345-5101325e0d96-app.yaml      file source
      └── 20260521T102345-kustomize-prod.yaml        rendered kustomize output
```

# Running the Application

Once the shell function is loaded, you use `kubectl` exactly as you would normally — the recorder kicks in automatically for state-changing subcommands:

```
kubectl apply -f manifests/app.yaml           # recorded
kubectl apply -f manifests/ -R                # recorded (every YAML under the dir)
kubectl apply -k overlays/prod                # recorded (rendered output snapshotted)
kubectl apply -f -                            # recorded (stdin teed to temp file)
kubectl delete -f manifests/app.yaml          # recorded
kubectl replace -f manifests/app.yaml         # recorded
kubectl patch deployment demo -p '{"spec":…}' # recorded

kubectl get pods                              # NOT recorded (passes through)
kubectl logs demo                             # NOT recorded (passes through)
kubectl exec -it demo -- sh                   # NOT recorded (passes through)
```

You can also call the recorder explicitly as a kubectl plugin without going through the shell function:

```
kubectl rec apply -f manifests/app.yaml
```

# History Format

Each operation appends one JSON object to `history.jsonl`:

```
{
  "timestamp": "2026-05-21T10:23:45+0900",
  "operation": "apply",
  "user":      "yasutaka",
  "host":      "macbook.local",
  "cwd":       "/Users/yasutaka/projects/myapp",
  "context":   "minikube",
  "cluster":   "minikube",
  "namespace": "default",
  "dry_run":   "",
  "command":   ["kubectl", "apply", "-f", "/Users/yasutaka/projects/myapp/manifests/app.yaml"],
  "sources": [
    {
      "type":     "file",
      "input":    "/Users/yasutaka/projects/myapp/manifests/app.yaml",
      "path":     "/Users/yasutaka/projects/myapp/manifests/app.yaml",
      "sha256":   "5101325e0d96…",
      "snapshot": "/Users/yasutaka/.kube/kubectl-history/snapshots/20260521T102345-5101325e0d96-app.yaml"
    }
  ],
  "exit_code": 0,
  "stdout":    "deployment.apps/demo configured\n",
  "stderr":    ""
}
```

Field reference:

- **timestamp**: ISO 8601 timestamp with timezone offset
- **operation**: One of `apply` / `delete` / `replace` / `patch`
- **command**: The exact argv passed to the real kubectl, with the binary path as `command[0]`
- **sources[].type**: `file` / `kustomize` / `url` / `missing`
- **sources[].input**: The literal argument value the user typed (e.g. `manifests/` or `-`)
- **sources[].path**: Absolute, symlink-resolved path of the manifest on disk
- **sources[].sha256**: SHA-256 of the manifest contents (empty string for `url` and `missing`)
- **sources[].snapshot**: Path of the snapshot copy under `snapshots/`

# Querying History

Because the index is JSONL, line-oriented tools work directly on it:

```
# Last 10 operations, pretty-printed
tail -n 10 ~/.kube/kubectl-history/history.jsonl | jq .

# Every apply against a specific file
jq -c 'select(.operation == "apply" and (.sources[].path | test("manifests/app.yaml")))' \
  ~/.kube/kubectl-history/history.jsonl

# Failed operations only
jq -c 'select(.exit_code != 0) | {ts:.timestamp, op:.operation, err:.stderr}' \
  ~/.kube/kubectl-history/history.jsonl

# Everything I did from the current project directory
jq -c --arg cwd "$(pwd)" 'select(.cwd | startswith($cwd))' \
  ~/.kube/kubectl-history/history.jsonl

# Show the diff between the latest snapshot of app.yaml and the current file
latest=$(jq -r 'select(.sources[].input | endswith("app.yaml")) | .sources[].snapshot' \
  ~/.kube/kubectl-history/history.jsonl | tail -n 1)
diff "$latest" manifests/app.yaml
```

# How It Works

The shell function `kubectl()` in `kubectl-rec.sh` inspects the argv of every `kubectl` call. It walks the arguments, skips global flag values (`--kubeconfig`, `-n`, `--context`, etc.), and takes the first non-flag token as the candidate subcommand. If that token is `apply` / `delete` / `replace` / `patch`, the call is forwarded to `kubectl-rec`; otherwise it is forwarded to the real kubectl via `command kubectl`.

The recorder then does the following:

1. Re-parses argv to find `-f` / `-k` / `-R` / `--dry-run` and the captured operation.
2. If `-f -` was given, stdin is read once into a temp file under `KUBECTL_HISTORY_DIR` and the `-` is rewritten to that temp file path before kubectl is invoked, so stdin content can be both replayed to kubectl and snapshotted.
3. Each `-f` spec is resolved into concrete entries:
   - Files: SHA-256 hashed and copied into `snapshots/`.
   - Directories: enumerated with `find` (one level by default, recursive with `-R`).
   - URLs: recorded as URL only; the response body is not fetched.
4. Each `-k` spec is treated as a kustomize directory; the recorder runs `kubectl kustomize <dir>` and snapshots the rendered output instead of the raw directory.
5. The real kubectl is invoked with the original argv. Its stdout, stderr, and exit code are captured.
6. A single JSON object containing all metadata, sources, and captured output is appended to `history.jsonl`. The recorder then exits with the same exit code as kubectl.

Because shell functions are not inherited by child processes, the recorder calling the real kubectl from within a subprocess does not re-enter the wrapping function — there is no risk of recursion.

# Disabling

To bypass the recorder for a single invocation:

```
KUBECTL_REC_DISABLE=1 kubectl apply -f foo.yaml    # this call only
command kubectl apply -f foo.yaml                   # also bypasses the function
```

To uninstall, remove the `source ~/.kube/kubectl-rec.sh` line from your shell rc file and start a new shell. The `kubectl-rec` binary on `$PATH` is harmless on its own — it never runs unless explicitly called.

# Known Limitations

- The shell function only intercepts kubectl calls from interactive shells that have sourced `kubectl-rec.sh`. Invocations from CI runners, IDE plugins (e.g. the VSCode Kubernetes extension), or other tools that call kubectl directly will bypass the recorder. For full coverage you can install a PATH shim that wraps the real kubectl binary at the OS level.
- URL sources (`-f https://…`) are recorded by URL only; the response body is not snapshotted.
- The subcommand detector uses a simple heuristic — resource names that happen to equal `apply`, `delete`, `replace`, or `patch` are not handled and could be misidentified.
- `history.jsonl` and `snapshots/` grow indefinitely. Rotate them with `logrotate` or a periodic prune script if size becomes a concern.
- `kubectl create -f …` is intentionally not recorded; if you also want to track it, add `create` to `SUPPORTED_OPS_RE` in `kubectl-rec` and to the case statement in `kubectl-rec.sh`.

# License

MIT license
