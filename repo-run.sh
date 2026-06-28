#!/bin/bash
# ==============================================================================
# === repo-run                                                               ===
# ------------------------------------------------------------------------------
# --- Generic bootstrapper: fetch a (private) git repo and run a script.     ---
# --- Handles SSH-key or token auth for any git host; re-run to update.      ---
# ==============================================================================

set -o pipefail
set -u

readonly SCRIPT_NAME='repo-run'
readonly SCRIPT_VERSION='0.1.0'
readonly SCRIPT_TITLE="${SCRIPT_NAME} v${SCRIPT_VERSION}"

# ==============================================================================
# === Usage                                                                  ===
# ==============================================================================

function usage() {
    cat <<EOF
${SCRIPT_TITLE} - fetch a (private) git repo and run a script from it.

Usage: ${SCRIPT_NAME} --repo <owner/repo> --script <path/in/repo> [options] [-- <args>]

  --repo <r>         owner/repo                         (or LOADER_REPO)   [required]
  --script <p>       script path inside the repo        (or LOADER_SCRIPT) [required]
  --ref <name>       branch or tag           (default: main)
  --host <h>         git host (github.com, gitlab.com, gitea.my.lan, ...)
  --auth <a>         auto | ssh | pat        (default: auto)
  --key <file>       SSH private key file    (implies --auth ssh)
  --ssh-user <u>     SSH user                (default: git)
  --token <t>        access token            (implies --auth pat)
  --token-user <u>   HTTPS userinfo for the token (per-host default)
  --cache <dir>      clone dir   (default: ~/.cache/repo-run/<host>-<owner>-<repo>)
  --url <u>          this loader's own URL (printed in the reusable one-liner)
  --fresh            wipe the cache and clone anew
  -y, --yes          non-interactive; never prompt
  -h, --help         this help
  -- <args>          passed straight through to the script

Run with nothing set and it asks for the missing bits, then prints a ready
one-liner you can reuse. Re-run any time to update.
EOF
}

# ==============================================================================
# === Configuration                                                          ===
# ==============================================================================

# Defaults <- env vars (LOADER_*); flags override these again in parse_args().
repo="${LOADER_REPO:-}"               # owner/repo            (required)
script="${LOADER_SCRIPT:-}"           # script path in repo   (required)
ref="${LOADER_REF:-}"                 # branch/tag            (default: main)
host="${LOADER_HOST:-}"               # git host              (default: github.com)
auth="${LOADER_AUTH:-}"               # auto | ssh | pat      (default: auto)
key_file="${LOADER_KEY:-}"            # SSH private key file  (ssh)
ssh_user="${LOADER_SSH_USER:-}"       # SSH user              (default: git)
token="${LOADER_TOKEN:-}"             # access token          (pat)
token_user="${LOADER_TOKEN_USER:-}"   # HTTPS userinfo for the token (per-host default)
cache_dir="${LOADER_CACHE:-}"         # clone dir             (default: ~/.cache/repo-run/...)
loader_url="${LOADER_URL:-}"          # this loader's own URL (only for the reusable one-liner)
fresh=0                               # wipe the cache before cloning
assume_yes=0                          # non-interactive; never prompt
passthru=()                           # everything after '--' goes to the script

clone_url=''                          # built by resolve_auth
git_ssh=''                            # GIT_SSH_COMMAND used for ssh auth
prompted=0                            # set if any value had to be entered interactively

# ==============================================================================
# === Functions                                                              ===
# ==============================================================================

# ------------------------------------------------------------------------------
# ==  Output (local print_* - same names/look as terminal-utils)              ==
# ------------------------------------------------------------------------------

function print_info()    { printf '[ INFO ] %s\n' "$*"; }
function print_success() { printf '[  OK  ] %s\n' "$*"; }
function print_warning() { printf '[ Warn ] %s\n' "$*" >&2; }
function print_error()   { printf '[FAILED] %s\n' "$*" >&2; }

function is_interactive() { [[ "$assume_yes" -eq 0 && -t 0 && -t 1 ]]; }
function has_command()    { command -v "$1" >/dev/null 2>&1; }

# Cancel/ESC on a prompt lands here. The ui_* helpers run in $() subshells, so an
# `exit` inside them would only end the subshell - the CALLER must catch the non-zero
# return: `x="$(ui_…)" || abort_cancelled`.
function abort_cancelled() { print_info "Aborted."; exit 1; }

function print_banner() {
    # print_banner <title> [width] - a framed banner sized to width (default 80).
    local title="$1" width="${2:-80}" bar
    printf -v bar '%*s' "$width" ''; bar="${bar// /=}"
    printf '%s\n=== %-*s ===\n%s\n' "$bar" "$((width - 8))" "$title" "$bar"
}

# ------------------------------------------------------------------------------
# ==  UI prompts (whiptail when available, plain read otherwise)              ==
# ------------------------------------------------------------------------------

function ui_input() {
    # ui_input <title> <prompt> <default> -> echoes the entered value (or default).
    local title="$1" prompt="$2" def="$3"
    if has_command whiptail; then
        whiptail --title "$title" --inputbox "$prompt" 10 74 "$def" \
            --backtitle "$SCRIPT_TITLE" 3>&1 1>&2 2>&3
    else
        local v; read -r -p "$prompt [$def]: " v </dev/tty; printf '%s' "${v:-$def}"
    fi
}

function ui_menu() {
    # ui_menu <title> <prompt> <tag1> <label1> ... -> echoes the chosen tag.
    local title="$1" prompt="$2"; shift 2
    if has_command whiptail; then
        local items=(); while [[ $# -gt 0 ]]; do items+=("$1" "$2"); shift 2; done
        whiptail --title "$title" --menu "$prompt" 20 74 10 "${items[@]}" \
            --backtitle "$SCRIPT_TITLE" 3>&1 1>&2 2>&3
    else
        local tags=() n=1; printf '%s\n' "$prompt" >&2
        while [[ $# -gt 0 ]]; do printf '  %s) %s  %s\n' "$n" "$1" "$2" >&2; tags+=("$1"); shift 2; ((n++)) || true; done
        local sel; read -r -p "Choice [1-$((n - 1))]: " sel </dev/tty
        [[ "$sel" =~ ^[0-9]+$ ]] && printf '%s' "${tags[$((sel - 1))]:-}"
    fi
}

function ui_password() {
    # ui_password <title> <prompt> -> echoes the entered secret (hidden input).
    local title="$1" prompt="$2"
    if has_command whiptail; then
        whiptail --title "$title" --passwordbox "$prompt" 10 74 \
            --backtitle "$SCRIPT_TITLE" 3>&1 1>&2 2>&3
    else
        local s; read -r -s -p "$prompt " s </dev/tty; printf '\n' >&2; printf '%s' "$s"
    fi
}

# ------------------------------------------------------------------------------
# ==  Auth helpers                                                            ==
# ------------------------------------------------------------------------------

function list_ssh_keys() {
    # --------------------------------------------------------------------------
    # Lists the usable private SSH keys under ~/.ssh.
    #
    # Description:
    #   Skips .pub files and the config/known_hosts/authorized_keys files, and keeps
    #   only files ssh-keygen recognizes as a key.
    #
    # Usage:    list_ssh_keys
    # Outputs:  one private-key path per line on stdout.
    # Returns:  0 (no output when ~/.ssh is absent or empty).
    # --------------------------------------------------------------------------
    local f base
    [[ -d "$HOME/.ssh" ]] || return 0
    for f in "$HOME/.ssh"/*; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        [[ "$base" == *.pub ]] && continue
        case "$base" in known_hosts*|config|config.local|authorized_keys) continue ;; esac
        ssh-keygen -l -f "$f" >/dev/null 2>&1 && printf '%s\n' "$f"
    done
}

function ssh_auth_works() {
    # --------------------------------------------------------------------------
    # Tests whether SSH authentication to the host succeeds.
    #
    # Usage:    ssh_auth_works
    # Globals:  reads key_file, ssh_user, host.
    # Returns:  0 if the (given or agent) key authenticates to the host, else 1.
    # --------------------------------------------------------------------------
    local cmd='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10'
    [[ -n "$key_file" ]] && cmd+=" -i $key_file -o IdentitiesOnly=yes"
    $cmd -T "${ssh_user:-git}@$host" 2>&1 | grep -qiE 'successfully authenticated|welcome'
}

function token_userinfo() {
    # --------------------------------------------------------------------------
    # Builds the HTTPS userinfo (user:token) for the access token, per platform.
    #
    # Description:
    #   GitHub wants `x-access-token:<tok>`, GitLab `oauth2:<tok>`; Gitea and most
    #   self-hosted forges accept the bare token as userinfo. Override via --token-user.
    #
    # Usage:    token_userinfo
    # Globals:  reads token_user, token, host.
    # Outputs:  the userinfo string on stdout.
    # --------------------------------------------------------------------------
    if [[ -n "$token_user" ]]; then printf '%s:%s' "$token_user" "$token"; return; fi
    case "$host" in
        github.com)        printf 'x-access-token:%s' "$token" ;;
        gitlab.*|*gitlab*) printf 'oauth2:%s' "$token" ;;
        *)                 printf '%s' "$token" ;;
    esac
}

# ------------------------------------------------------------------------------
# ==  Steps (input -> summary -> execute)                                     ==
# ------------------------------------------------------------------------------

function parse_args() {
    # --------------------------------------------------------------------------
    # Fills the configuration globals from command-line flags.
    #
    # Usage:     parse_args "$@"
    # Arguments: the script's positional parameters; '--' ends option parsing and
    #            the rest is captured in passthru[] for the script.
    # Globals:   sets repo/script/ref/host/auth/key_file/ssh_user/token/token_user/
    #            cache_dir/loader_url/fresh/assume_yes/passthru.
    # Returns:   0; aborts via print_error on an unknown option.
    # --------------------------------------------------------------------------
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)       repo="$2"; shift 2 ;;
            --script)     script="$2"; shift 2 ;;
            --ref)        ref="$2"; shift 2 ;;
            --host)       host="$2"; shift 2 ;;
            --auth)       auth="$2"; shift 2 ;;
            --key)        key_file="$2"; auth='ssh'; shift 2 ;;
            --ssh-user)   ssh_user="$2"; shift 2 ;;
            --token)      token="$2"; auth='pat'; shift 2 ;;
            --token-user) token_user="$2"; shift 2 ;;
            --cache)      cache_dir="$2"; shift 2 ;;
            --url)        loader_url="$2"; shift 2 ;;
            --fresh)      fresh=1; shift ;;
            -y|--yes)     assume_yes=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            --)           shift; passthru=("$@"); break ;;
            *)            print_error "Unknown option: $1  (try --help)"; exit 1 ;;
        esac
    done
}

function fill_missing_input() {
    # --------------------------------------------------------------------------
    # Resolves the required/defaulted values - prompting for missing ones when
    # interactive, then applying defaults and validating.
    #
    # Usage:    fill_missing_input
    # Globals:  may set repo/host/ref/script/auth/ssh_user/cache_dir.
    # Returns:  0; aborts via print_error when repo/script stay empty.
    # --------------------------------------------------------------------------
    # auth/ssh_user are advanced / resolved later - default them quietly.
    auth="${auth:-auto}"; ssh_user="${ssh_user:-git}"
    # Guided prompts only when a REQUIRED value (repo/script) is missing - then walk
    # through everything still empty, incl. the optional host/ref. If repo + script
    # are both given, the optional fields just take their defaults (no prompts at all).
    if is_interactive && { [[ -z "$repo" ]] || [[ -z "$script" ]]; }; then
        [[ -n "$host"   ]] || { prompted=1; host="$(ui_input 'Host' 'Git host (github.com, gitlab.com, gitea.my.lan, ...):' 'github.com')" || abort_cancelled; }
        [[ -n "$repo"   ]] || { prompted=1; repo="$(ui_input 'Repository' 'owner/repo:' '')" || abort_cancelled; }
        [[ -n "$ref"    ]] || { prompted=1; ref="$(ui_input 'Ref' 'Branch or tag:' 'main')" || abort_cancelled; }
        [[ -n "$script" ]] || { prompted=1; script="$(ui_input 'Script' 'Script to run inside the repo (e.g. install.sh, tools/deploy.sh):' 'install.sh')" || abort_cancelled; }
    fi
    ref="${ref:-main}"; host="${host:-github.com}"
    [[ -n "$repo"  ]] || { print_error "no repo given (--repo owner/repo or LOADER_REPO)"; exit 1; }
    [[ -n "$script" ]] || { print_error "no script given (--script path or LOADER_SCRIPT)"; exit 1; }
    [[ -n "$cache_dir" ]] || cache_dir="$HOME/.cache/repo-run/${host}-${repo//\//-}"
}

function resolve_auth() {
    # --------------------------------------------------------------------------
    # Decides the auth method (ssh vs pat) and builds the clone URL.
    #
    # Description:
    #   In 'auto' mode it prefers an SSH key that already authenticates, else a token,
    #   else (interactive) it asks. For ssh it may let the user pick a key from ~/.ssh.
    #
    # Usage:    resolve_auth
    # Globals:  reads auth/token/key_file/ssh_user/host/repo; sets auth/key_file/
    #           token/clone_url/git_ssh.
    # Returns:  0; aborts via print_error when no method can be established.
    # --------------------------------------------------------------------------
    if [[ "$auth" == auto ]]; then
        if   [[ -n "$token" ]]; then auth='pat'
        elif ssh_auth_works;    then auth='ssh'; print_info "using SSH (key already authenticates to $host)"
        elif is_interactive; then
            auth="$(ui_menu 'Repository access' "How should I authenticate to $host for '$repo'?" \
                       ssh 'Use an SSH key' pat 'Use an access token (PAT)')" || abort_cancelled
        else
            print_error "no working SSH key and no --token, and not interactive. Provide --token or --key."
            exit 1
        fi
    fi

    case "$auth" in
        ssh)
            if [[ -z "$key_file" ]] && ! ssh_auth_works && is_interactive; then
                local keys=() args=() k
                mapfile -t keys < <(list_ssh_keys)
                if [[ ${#keys[@]} -gt 0 ]]; then
                    for k in "${keys[@]}"; do args+=("$k" ""); done
                    key_file="$(ui_menu 'Select SSH key' 'Private key to use:' "${args[@]}")" || abort_cancelled
                fi
            fi
            if [[ -n "$key_file" ]]; then
                [[ -f "$key_file" ]] || { print_error "SSH key not found: $key_file"; exit 1; }
                git_ssh="ssh -i $key_file -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
            else
                git_ssh="ssh -o StrictHostKeyChecking=accept-new"
            fi
            clone_url="${ssh_user}@${host}:${repo}.git"
            ;;
        pat)
            [[ -n "$token" ]] || token="$(ui_password 'Access token' "Token for $repo on $host (input hidden):")" || abort_cancelled
            [[ -n "$token" ]] || { print_error "no token provided"; exit 1; }
            clone_url="https://$(token_userinfo)@${host}/${repo}.git"
            ;;
        *)  print_error "unknown auth method: $auth (use auto|ssh|pat)"; exit 1 ;;
    esac
}

function command_flags() {
    # --------------------------------------------------------------------------
    # The shared option string for the resolved settings (no program prefix).
    #
    # Description:
    #   Every relevant option is spelled out (host/repo/ref/script, plus auth/
    #   ssh-user/key/passthru when they apply) so it reproduces this run exactly.
    #   The token is shown as a <PAT> placeholder - never the real secret.
    #
    # Usage:    flags="$(command_flags)"
    # Globals:  reads host/repo/ref/script/auth/ssh_user/key_file/passthru.
    # Outputs:  the option string (with a leading space) on stdout.
    # --------------------------------------------------------------------------
    local f=" --host '$host' --repo '$repo' --ref '$ref' --script '$script'"
    [[ "$auth" != auto ]]    && f+=" --auth $auth"
    [[ "$ssh_user" != git ]] && f+=" --ssh-user '$ssh_user'"
    [[ -n "$key_file" ]]     && f+=" --key '$key_file'"
    [[ "$auth" == pat ]]     && f+=" --token '<PAT>'"
    if [[ ${#passthru[@]} -gt 0 ]]; then
        f+=" --"; local p; for p in "${passthru[@]}"; do f+=" '$p'"; done
    fi
    printf '%s' "$f"
}

function confirm_command() {
    # --------------------------------------------------------------------------
    # Shows the command - both as a direct call and as a curl load+run one-liner -
    # and asks whether to proceed, in a single dialog. Auth is resolved afterwards,
    # so no secret ever appears here.
    #
    # Usage:    confirm_command
    # Globals:  calls command_flags; reads $0/SCRIPT_NAME/loader_url.
    # Outputs:  both command variants to the console (scrollback for copy/paste).
    # Returns:  0 to proceed; aborts via abort_cancelled on No/Cancel/ESC.
    # --------------------------------------------------------------------------
    local flags prog direct via_curl
    flags="$(command_flags)"
    prog="$0"; [[ -f "$prog" ]] || prog="$SCRIPT_NAME"   # real path when run locally; else the installed name
    direct="${prog}${flags}"
    via_curl="bash <(curl -fsSL '${loader_url:-<your-loader-url>}')${flags}"

    # Both variants to the console (copyable; whiptail restores the screen on exit).
    printf '\n'; print_info 'Command - copy whichever variant you need:'
    printf '\n    # direct (this loader):\n    %s\n' "$direct"
    printf '\n    # via curl (load + run, e.g. from a Gist):\n    %s\n\n' "$via_curl"

    if has_command whiptail; then
        whiptail --title 'Proceed?' --backtitle "$SCRIPT_TITLE" \
            --yesno "$(printf 'This is the command:\n\n%s\n\n(The curl load+run variant is printed in the terminal.)\n\nProceed with this command?' "$direct")" 16 78 \
            || abort_cancelled
    else
        local a; read -r -p 'Proceed with this command? [Y/n]: ' a </dev/tty
        [[ ! "$a" =~ ^[Nn] ]] || abort_cancelled
    fi
}

function clone_or_update() {
    # --------------------------------------------------------------------------
    # Shallow-clones the repo at <ref> into the cache, or updates an existing clone.
    #
    # Usage:    clone_or_update
    # Globals:  reads fresh/cache_dir/git_ssh/clone_url/ref/repo/host/auth.
    # Returns:  0; aborts via print_error on a clone/update failure.
    # --------------------------------------------------------------------------
    [[ "$fresh" -eq 1 ]] && rm -rf "$cache_dir"
    mkdir -p "$(dirname "$cache_dir")"

    if [[ -d "$cache_dir/.git" ]]; then
        print_info "updating clone: $cache_dir ($ref)"
        GIT_SSH_COMMAND="$git_ssh" git -C "$cache_dir" remote set-url origin "$clone_url"
        if ! { GIT_SSH_COMMAND="$git_ssh" git -C "$cache_dir" fetch --depth 1 origin "$ref" >/dev/null 2>&1 \
               && git -C "$cache_dir" checkout -q FETCH_HEAD 2>/dev/null; }; then
            print_error "could not update the clone (auth? ref '$ref'?)"; exit 1
        fi
    else
        print_info "cloning $repo ($ref) from $host -> $cache_dir"
        if ! GIT_SSH_COMMAND="$git_ssh" git clone --quiet --depth 1 --branch "$ref" "$clone_url" "$cache_dir"; then
            print_error "clone failed (auth? repo/ref correct? a private repo needs an SSH key or --token)"; exit 1
        fi
    fi
    # Never leave a token baked into the clone's remote.
    [[ "$auth" == pat ]] && git -C "$cache_dir" remote set-url origin "https://${host}/${repo}.git" 2>/dev/null
}

function run_script() {
    # --------------------------------------------------------------------------
    # Runs the chosen script from the freshly cloned repo, passing through extra args.
    #
    # Usage:    run_script
    # Globals:  reads cache_dir/script/passthru.
    # Returns:  the script's exit code; aborts if the file is missing.
    # --------------------------------------------------------------------------
    local script_path="$cache_dir/$script" rc
    [[ -f "$script_path" ]] || { print_error "script not found in repo: $script"; exit 1; }
    print_info "running: $script ${passthru[*]}"
    printf '\n'
    bash "$script_path" "${passthru[@]}"; rc=$?
    printf '\n'
    print_info "done (script exit $rc). Re-run this loader any time to update."
    return "$rc"
}

# ==============================================================================
# === Prepare & Initialize                                                   ===
# ==============================================================================

parse_args "$@"
has_command git || { print_error "git is not installed - install it first (e.g. sudo apt install -y git)"; exit 1; }

# ==============================================================================
# === Main Execution Flow                                                     ===
# ==============================================================================

# 1) input - gather the basics (prompt for missing values when interactive)
fill_missing_input
print_info "repo=$repo ref=$ref script=$script host=$host"

# 2) only if something had to be entered: show the command + ask whether to proceed
#    (everything given on the CLI/env -> nothing to re-print, just go)
[[ "$prompted" -eq 1 ]] && confirm_command

# 3) resolve auth (ssh key or token) - only once the user decided to proceed
resolve_auth

# 4) execute: clone/update then run the script
clone_or_update
run_script
