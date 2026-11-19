#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  cat <<'USAGE'
Usage: bash scripts/install-macos.sh --provider-key-file PATH [options]

  --provider-key-file PATH  Private file containing the provider API key (mode 0600 or 0400)
  --codex-exe PATH          Codex executable (default: codex on PATH)
  --gpt-model ID            GPT model for the live trial (default: the active GPT model)
  --port PORT               Loopback port (default: 60069)
  --provider-base URL       HTTPS Responses base (default: https://open.bigmodel.cn/api/v1)
  --provider-catalog PATH   One-model catalog (default: router/glm-5.3-flash.json)
  -h, --help                Show this help
USAGE
}

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
codex_bin=''
gpt_model=''
port=60069
key_file=''
provider_base='https://open.bigmodel.cn/api/v1'
provider_catalog="$repo_dir/router/glm-5.3-flash.json"
while (( $# )); do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --codex-exe|--gpt-model|--port|--provider-key-file|--provider-base|--provider-catalog)
      [[ $# -ge 2 && -n $2 && $2 != --* ]] || fail "Missing value for $1."
      case $1 in
        --codex-exe) codex_bin=$2 ;;
        --gpt-model) gpt_model=$2 ;;
        --port) port=$2 ;;
        --provider-key-file) key_file=$2 ;;
        --provider-base) provider_base=$2 ;;
        --provider-catalog) provider_catalog=$2 ;;
      esac
      shift 2
      ;;
    *) fail "Unknown option $1. See --help." ;;
  esac
done

[[ $(uname -s) == Darwin ]] || fail 'Run this installer on macOS.'
[[ -n $key_file ]] || fail 'Pass the path to a private API key file with --provider-key-file.'
[[ -z ${OPENAI_BASE_URL:-}${CODEX_BASE_URL:-} ]] || fail 'The launch environment already overrides Codex routing.'

node_bin=$(type -P node) || fail 'Install Node.js and put it on PATH.'
[[ $node_bin == /* ]] || node_bin="$PWD/$node_bin"
"$node_bin" --input-type=module -e '
  import * as zlib from "node:zlib";
  if (!import.meta.main || typeof zlib.zstdDecompressSync !== "function") process.exit(1);
' || fail 'Use a Node.js release with import.meta.main and Zstandard support.'
if [[ -z $codex_bin ]]; then
  codex_bin=$(type -P codex) || fail 'Put Codex on PATH or pass --codex-exe.'
fi
[[ $codex_bin == /* ]] || codex_bin="$PWD/$codex_bin"
[[ -f $codex_bin && -x $codex_bin ]] || fail 'Choose an executable Codex CLI with --codex-exe.'

codex_dir=$(cd -- "${CODEX_HOME:-$HOME/.codex}" && pwd -P) || fail 'Select an existing Codex home.'
case "$codex_dir/" in "$repo_dir/"*) fail 'Select a Codex home outside the repository.' ;; esac
auth_file="$codex_dir/auth.json"
[[ -f $auth_file ]] || fail 'The isolated trial requires file-backed Codex sign-in.'
version=$("$codex_bin" --version) || fail 'Could not run the selected Codex binary.'
login_status=$("$codex_bin" login status 2>&1) || fail 'Sign into the target Codex account first.'
case $login_status in
  *ChatGPT*) auth_mode=chatgpt ;;
  *'API key'*) auth_mode=api-key ;;
  *) fail 'Could not identify the target account authentication mode.' ;;
esac

config_source="$codex_dir/config.toml"
if [[ -n ${ORCA_CODEX_HOME:-} && -d $ORCA_CODEX_HOME && $(cd -- "$ORCA_CODEX_HOME" && pwd -P) == "$codex_dir" ]]; then
  config_source="$HOME/.codex/config.toml"
fi
config_path=$config_source
if [[ -e $config_source || -L $config_source ]]; then
  [[ -f $config_source ]] || fail 'The Codex configuration must be a regular file.'
  config_path=$("$node_bin" -p 'require("node:fs").realpathSync(process.argv[1])' "$config_source")
fi
case $config_path in "$repo_dir/"*) fail 'Use a Codex configuration outside the repository.' ;; esac

router_dir="$codex_dir/model-router"
launch_label="local.codex-model-router.$(printf '%s' "$codex_dir" | shasum -a 256 | cut -c 1-12)"
launch_domain="gui/$(id -u)"
launch_job="$launch_domain/$launch_label"
launch_dir="$HOME/Library/LaunchAgents"
launch_plist="$launch_dir/$launch_label.plist"
if [[ -e $launch_plist || -L $launch_plist ]] || launchctl print "$launch_job" >/dev/null 2>&1; then
  fail "A LaunchAgent already exists for this Codex home. Review $launch_plist first."
fi
mkdir "$router_dir" || fail "Review $router_dir before retrying the install."

trial_dir="$router_dir/trial"
config_backup="$router_dir/config.before.toml"
pending_config=''
config_lock=''
plist_created=0
bootstrap_started=0
committed=0
cleanup() {
  set +e
  rm -rf "$trial_dir"
  [[ -z $pending_config ]] || rm -f "$pending_config"
  [[ -z $config_lock ]] || rmdir "$config_lock"
  if (( committed )); then return; fi

  if (( bootstrap_started )) && launchctl print "$launch_job" >/dev/null 2>&1 &&
    ! launchctl bootout "$launch_job"; then
    printf 'Could not stop %s. The LaunchAgent and router files are still installed.\n' "$launch_job" >&2
    return
  fi
  if (( plist_created )) && ! rm -f "$launch_plist"; then return; fi
  local diagnostics
  if diagnostics=$(mktemp -d "$codex_dir/model-router.failed.XXXXXXXX") && mv "$router_dir" "$diagnostics/"; then
    printf 'Setup diagnostics are in %s.\n' "$diagnostics/model-router" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s, %s sign-in, %s\n' "$version" "$auth_mode" "$codex_dir"
mkdir -p "$trial_dir/work"
if [[ -f $config_path ]]; then cp "$config_path" "$config_backup"; fi

checker="$repo_dir/scripts/check-codex.mjs"
options_file="$trial_dir/check-options.json"
"$node_bin" --input-type=module - "$repo_dir" "$router_dir" "$trial_dir" "$codex_dir" "$codex_bin" \
  "$node_bin" "$checker" "$options_file" "$launch_label" "$auth_mode" "$port" "$gpt_model" \
  "$key_file" "$provider_base" "$provider_catalog" <<'NODE'
import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { copyFileSync, lstatSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { isAbsolute, join, relative, resolve } from 'node:path';

const [repo, dir, trialDir, codexHome, codex, node, checker, optionsFile, Label, openaiAuth,
  portText, gptModel, keyFile, providerBase, catalog] = process.argv.slice(2);
const port = Number(portText);
if (!/^[1-9]\d*$/.test(portText) || port < 1024 || port > 65535) {
  throw new Error('Choose a port between 1024 and 65535 with --port');
}
if (!URL.canParse(providerBase) || /[?#]/.test(providerBase)) {
  throw new Error('Use an HTTPS Responses base URL without a query or fragment');
}
const upstream = new URL(providerBase);
if (upstream.protocol !== 'https:' || upstream.username || upstream.password) {
  throw new Error('Use an HTTPS Responses base URL without embedded credentials');
}
const key = lstatSync(resolve(keyFile), { throwIfNoEntry: false });
if (!key?.isFile() || key.uid !== process.getuid() || ![0o600, 0o400].includes(key.mode & 0o777)) {
  throw new Error('Use a regular API key file owned by this user with mode 0600 or 0400');
}
const providerKeyFile = realpathSync(keyFile);
const keyRelativeToRepo = relative(repo, providerKeyFile);
if (!keyRelativeToRepo.startsWith('../') && !isAbsolute(keyRelativeToRepo)) {
  throw new Error('Keep the API key file outside the repository');
}

const readJson = path => JSON.parse(readFileSync(path, 'utf8'));
const writeJson = (path, data) => writeFileSync(path, JSON.stringify(data, null, 2) + '\n');
const { models } = readJson(catalog);
const model = models?.[0];
if (!Array.isArray(models) || models.length !== 1 || typeof model?.slug !== 'string' || !model.slug || model.visibility !== 'list' ||
    (openaiAuth === 'api-key' && !model.supported_in_api)) {
  throw new Error('Use a catalog with one visible third-party model for this sign-in mode');
}

const bundledFile = join(dir, 'openai-models.json');
const options = { codexHome, cwd: join(trialDir, 'work'), gptModel, providerModel: model.slug, bundledFile };
writeJson(optionsFile, options);
const check = mode => execFileSync(node, [checker, mode, codex, optionsFile], {
  encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'],
});
options.gptModel = JSON.parse(check('preflight')).gptModel;
check('bundled');
const bundled = readJson(bundledFile);
if (bundled.models.some(item => item.slug === model.slug)) {
  throw new Error('The provider model ID is already in the OpenAI catalog');
}

const pathPrefix = '/' + randomBytes(24).toString('base64url');
const routing = ['# Codex model router', 'openai_base_url = ' + JSON.stringify(`http://127.0.0.1:${port}${pathPrefix}/v1`)];
if (openaiAuth === 'api-key') {
  if (!bundled.models.some(item => item.slug === options.gptModel && item.supported_in_api)) {
    throw new Error('Choose a GPT model in the bundled OpenAI API catalog with --gpt-model');
  }
  options.mergedFile = join(dir, 'merged-models.json');
  writeJson(options.mergedFile, { ...bundled, models: [...bundled.models, model] });
  routing.push('model_catalog_json = ' + JSON.stringify(options.mergedFile));
}
writeFileSync(join(dir, 'codex-routing.toml'), routing.join('\n') + '\n\n');

const providerCatalogFile = join(dir, 'provider-model.json');
copyFileSync(catalog, providerCatalogFile);
const routerFile = join(dir, 'router.json');
const proxyEnv = Object.fromEntries(['HTTPS_PROXY', 'HTTP_PROXY', 'NO_PROXY', 'https_proxy', 'http_proxy', 'no_proxy']
  .filter(name => process.env[name]).map(name => [name, process.env[name]]));
writeJson(routerFile, {
  port, pathPrefix, openaiAuth, providerBase: upstream.href, providerKeyFile, providerCatalogFile,
  fallbackCatalogFile: bundledFile, logFile: join(dir, 'service.jsonl'),
  ...(Object.keys(proxyEnv).length && { proxyEnv }),
});
writeJson(optionsFile, { ...options, codexHome: trialDir, routerFile });

const string = value => '<string>' + value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;') + '</string>';
writeFileSync(join(dir, 'launch-agent.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>${string(Label)}
  <key>ProgramArguments</key>
  <array>${[node, join(dir, 'router.mjs'), routerFile].map(string).join('')}</array>
  <key>WorkingDirectory</key>${string(dir)}
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key>${string(join(dir, 'service-error.log'))}
</dict>
</plist>
`);
NODE

"$node_bin" --test "$repo_dir/router/router.test.mjs"
cp "$repo_dir/router/router.mjs" "$router_dir/router.mjs"
plutil -lint "$router_dir/launch-agent.plist"
mkdir -p "$launch_dir"
(set -C; : > "$launch_plist") || fail "Review the existing LaunchAgent at $launch_plist."
plist_created=1
cat "$router_dir/launch-agent.plist" > "$launch_plist"
bootstrap_started=1
launchctl bootstrap "$launch_domain" "$launch_plist"

for (( attempt = 0; attempt < 20; attempt++ )); do
  if [[ -s $router_dir/service.jsonl ]] &&
    curl --noproxy '*' --fail --silent --max-time 1 "http://127.0.0.1:$port/health" >/dev/null; then
    break
  fi
  sleep 0.5
done
(( attempt < 20 )) || fail "The router did not become healthy on port $port. Check service-error.log and port availability."

cp "$auth_file" "$trial_dir/auth.json"
"$node_bin" "$checker" trial "$codex_bin" "$options_file"
"$node_bin" --input-type=module - "$router_dir/service.jsonl" <<'NODE'
import { readFileSync } from 'node:fs';
const routes = readFileSync(process.argv[2], 'utf8').trim().split('\n').map(line => JSON.parse(line))
  .filter(entry => entry.path === '/responses' && entry.status === 200).map(entry => entry.route);
if (!/(^|,)openai,(third-party,)+openai(,|$)/.test(routes.join(','))) {
  throw new Error('Router status did not confirm GPT → third-party → GPT');
}
NODE

cat "$router_dir/codex-routing.toml" > "$trial_dir/config.toml"
if [[ -f $config_backup ]]; then cat "$config_backup" >> "$trial_dir/config.toml"; fi
"$node_bin" "$checker" catalog "$codex_bin" "$options_file"
rm -f "$trial_dir/auth.json"

config_dir=$(dirname -- "$config_path")
mkdir -p "$config_dir"
mkdir "$config_path.model-router.lock" || fail 'Another install is updating this Codex configuration.'
config_lock="$config_path.model-router.lock"
if [[ -f $config_backup ]]; then
  [[ -f $config_source ]] &&
    current_path=$("$node_bin" -p 'require("node:fs").realpathSync(process.argv[1])' "$config_source") &&
    [[ $current_path == "$config_path" ]] && cmp -s "$config_backup" "$config_path" ||
    fail 'Codex configuration changed during testing. Retry with the current configuration.'
else
  [[ ! -e $config_source && ! -L $config_source ]] || fail 'Codex configuration appeared during testing. Retry the install.'
fi
pending_config=$(mktemp "$config_dir/.config-router.XXXXXXXX")
cat "$trial_dir/config.toml" > "$pending_config"
trap '' INT TERM
mv -f "$pending_config" "$config_path"
committed=1
printf 'Installed %s\nLaunchAgent plist %s\nUpdated %s\n' "$launch_job" "$launch_plist" "$config_source"
printf 'Open a fresh Codex session from your usual launcher and select the third-party model in /model.\n'
