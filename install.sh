#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="singbox-bbr-installer"
SERVICE_NAME="sing-box-nav"
BIN_NAME="sing-box"
BIN_PATH="/usr/local/bin/${BIN_NAME}"
INSTALL_DIR="/etc/sing-box-nav"
CONFIG_FILE="${INSTALL_DIR}/config.json"
STATE_FILE="${INSTALL_DIR}/state.env"
CLIENT_FILE="${INSTALL_DIR}/client-info.txt"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
INITD_UNIT="/etc/init.d/${SERVICE_NAME}"
BBR_SYSCTL_FILE="/etc/sysctl.d/99-singbox-bbr.conf"
BBR_MODULES_FILE="/etc/modules-load.d/bbr.conf"
TMP_DIR=""
PACKAGE_MANAGER=""
ARCH=""
LIBC_SUFFIX=""
SERVICE_MANAGER=""

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

log() { printf '%s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERR ] %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 运行这个脚本。"
}

is_linux() {
  [[ "$(uname -s 2>/dev/null || true)" == "Linux" ]]
}

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

pause_if_needed() {
  if is_interactive; then
    printf '\n按 Enter 返回菜单...'
    read -r _
  fi
}

prompt_value() {
  local label="$1"
  local default_value="${2:-}"
  local reply

  if [[ -n "${default_value}" ]]; then
    printf '%s [%s]: ' "${label}" "${default_value}" >&2
  else
    printf '%s: ' "${label}" >&2
  fi
  read -r reply || true
  printf '%s\n' "${reply:-${default_value}}"
}

prompt_port() {
  local default_value="${1:-443}"
  local reply

  while true; do
    reply="$(prompt_value '请输入监听端口' "${default_value}")"
    if [[ "${reply}" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= 65535 )); then
      printf '%s\n' "${reply}"
      return 0
    fi
    warn "监听端口必须是 1 到 65535 之间的整数。"
  done
}

prompt_yes_no() {
  local label="$1"
  local default_answer="${2:-n}"
  local reply

  printf '%s [%s]: ' "${label}" "${default_answer}"
  read -r reply || true
  reply="${reply:-${default_answer}}"
  case "${reply,,}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

backup_file() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    mv "${path}" "${path}.bak-$(date +%Y%m%d%H%M%S)"
  fi
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "${value}"
}

ensure_tmp_dir() {
  if [[ -z "${TMP_DIR}" ]]; then
    TMP_DIR="$(mktemp -d)"
  fi
}

detect_service_manager() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    SERVICE_MANAGER="systemd"
  elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
    SERVICE_MANAGER="openrc"
  else
    SERVICE_MANAGER=""
  fi
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PACKAGE_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PACKAGE_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PACKAGE_MANAGER="yum"
  elif command -v pacman >/dev/null 2>&1; then
    PACKAGE_MANAGER="pacman"
  elif command -v apk >/dev/null 2>&1; then
    PACKAGE_MANAGER="apk"
  else
    PACKAGE_MANAGER=""
  fi
}

install_packages() {
  local packages=("$@")
  [[ "${#packages[@]}" -gt 0 ]] || return 0

  detect_package_manager
  [[ -n "${PACKAGE_MANAGER}" ]] || die "找不到可用的包管理器。"

  case "${PACKAGE_MANAGER}" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y --no-install-recommends "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
    pacman)
      pacman -Sy --noconfirm --needed "${packages[@]}"
      ;;
    apk)
      apk add --no-cache "${packages[@]}"
      ;;
  esac
}

ensure_runtime_tools() {
  local missing=()
  local tool

  for tool in curl tar; do
    command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    install_packages "${missing[@]}" ca-certificates
  fi

  if ! command -v sysctl >/dev/null 2>&1; then
    install_packages procps || true
  fi

  if ! command -v modprobe >/dev/null 2>&1; then
    install_packages kmod || true
  fi
}

service_enable() {
  case "${SERVICE_MANAGER}" in
    systemd)
      systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-update add "${SERVICE_NAME}" default >/dev/null 2>&1 || true
      ;;
    *)
      die "当前系统没有可用的服务管理器。"
      ;;
  esac
}

service_restart() {
  case "${SERVICE_MANAGER}" in
    systemd)
      systemctl restart "${SERVICE_NAME}"
      ;;
    openrc)
      rc-service "${SERVICE_NAME}" restart
      ;;
    *)
      die "当前系统没有可用的服务管理器。"
      ;;
  esac
}

service_is_active() {
  case "${SERVICE_MANAGER}" in
    systemd)
      systemctl is-active --quiet "${SERVICE_NAME}"
      ;;
    openrc)
      rc-service "${SERVICE_NAME}" status >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv7) ARCH="armv7" ;;
    *)
      die "当前架构 $(uname -m) 暂不支持。"
      ;;
  esac

  if grep -qi 'alpine' /etc/os-release 2>/dev/null; then
    LIBC_SUFFIX='-musl'
  else
    LIBC_SUFFIX=''
  fi
}

latest_singbox_version() {
  if [[ -n "${SINGBOX_VERSION:-}" ]]; then
    printf '%s\n' "${SINGBOX_VERSION#v}"
    return 0
  fi

  local api_json tag
  api_json="$(curl -fsSL -H 'User-Agent: Codex' 'https://api.github.com/repos/SagerNet/sing-box/releases/latest')"
  tag="$(printf '%s' "${api_json}" | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -n1 | cut -d'"' -f4)"
  [[ -n "${tag}" ]] || die "无法获取 sing-box 最新版本。"
  printf '%s\n' "${tag#v}"
}

download_singbox_binary() {
  ensure_tmp_dir
  local version archive_url archive_file extract_dir bin_source

  version="$(latest_singbox_version)"
  archive_file="${TMP_DIR}/sing-box-${version}-linux-${ARCH}${LIBC_SUFFIX}.tar.gz"
  archive_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${ARCH}${LIBC_SUFFIX}.tar.gz"
  extract_dir="${TMP_DIR}/sing-box-${version}-linux-${ARCH}${LIBC_SUFFIX}"

  info "下载 sing-box ${version} ..."
  curl -fL --retry 3 --connect-timeout 15 -o "${archive_file}" "${archive_url}"
  tar -xzf "${archive_file}" -C "${TMP_DIR}"

  bin_source="${extract_dir}/${BIN_NAME}"
  [[ -x "${bin_source}" ]] || die "下载包里没有找到可执行文件。"

  backup_file "${BIN_PATH}"
  cp "${bin_source}" "${BIN_PATH}"
  chmod 0755 "${BIN_PATH}"
}

load_state() {
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
  fi
}

write_state() {
  umask 077
  cat > "${STATE_FILE}" <<EOF
NODE_NAME=$(printf '%q' "${NODE_NAME}")
LISTEN_PORT=$(printf '%q' "${LISTEN_PORT}")
SERVER_NAME=$(printf '%q' "${SERVER_NAME}")
PUBLIC_ADDR=$(printf '%q' "${PUBLIC_ADDR}")
UUID_VALUE=$(printf '%q' "${UUID_VALUE}")
PRIVATE_KEY=$(printf '%q' "${PRIVATE_KEY}")
PUBLIC_KEY=$(printf '%q' "${PUBLIC_KEY}")
EOF
  chmod 600 "${STATE_FILE}"
}

write_client_info() {
  {
    printf 'Service: %s\n' "${SERVICE_NAME}"
    printf 'Config: %s\n' "${CONFIG_FILE}"
    printf 'Node: %s\n' "${NODE_NAME}"
    printf 'Listen port: %s\n' "${LISTEN_PORT}"
    printf 'Reality SNI: %s\n' "${SERVER_NAME}"
    printf 'UUID: %s\n' "${UUID_VALUE}"
    printf 'Reality public key: %s\n' "${PUBLIC_KEY}"
    printf '\n'
    if [[ -n "${PUBLIC_ADDR}" ]]; then
      printf 'Client link:\n'
      printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&type=tcp&flow=xtls-rprx-vision#%s\n' \
        "${UUID_VALUE}" \
        "${PUBLIC_ADDR}" \
        "${LISTEN_PORT}" \
        "${SERVER_NAME}" \
        "${PUBLIC_KEY}" \
        "${NODE_NAME}"
    else
      printf 'Client link was skipped because no public address was provided.\n'
    fi
  } > "${CLIENT_FILE}"
}

generate_reality_keypair() {
  local output
  output="$("${BIN_PATH}" generate reality-keypair)"
  PRIVATE_KEY="$(printf '%s\n' "${output}" | awk '/PrivateKey/{print $NF; exit}')"
  PUBLIC_KEY="$(printf '%s\n' "${output}" | awk '/PublicKey/{print $NF; exit}')"
  [[ -n "${PRIVATE_KEY}" && -n "${PUBLIC_KEY}" ]] || die "Reality 密钥生成失败。"
}

generate_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '\n' < /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    die "无法生成 UUID。"
  fi
}

ensure_singbox_service_file() {
  detect_service_manager

  case "${SERVICE_MANAGER}" in
    systemd)
      backup_file "${SYSTEMD_UNIT}"
      cat > "${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=sing-box node service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      ;;
    openrc)
      backup_file "${INITD_UNIT}"
      cat > "${INITD_UNIT}" <<EOF
#!/sbin/openrc-run
description="sing-box node service"
command="${BIN_PATH}"
command_args="run -c ${CONFIG_FILE}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
depend() {
  need net
}
EOF
      chmod 0755 "${INITD_UNIT}"
      ;;
    *)
      die "当前系统没有可用的服务管理器。"
      ;;
  esac
}

validate_config() {
  "${BIN_PATH}" check -c "${CONFIG_FILE}" >/dev/null
}

install_sing_box_node() {
  require_root
  is_linux || die "这个脚本只适用于 Linux。"

  ensure_runtime_tools
  detect_arch
  detect_service_manager
  [[ -n "${SERVICE_MANAGER}" ]] || die "未检测到 systemd 或 OpenRC，无法注册 sing-box 服务。"

  mkdir -p "${INSTALL_DIR}"
  load_state

  NODE_NAME="$(prompt_value '请输入节点名称' "${NODE_NAME:-sing-box-node}")"
  LISTEN_PORT="$(prompt_port "${LISTEN_PORT:-443}")"
  SERVER_NAME="$(prompt_value '请输入 Reality 的 SNI 域名' "${SERVER_NAME:-www.cloudflare.com}")"
  PUBLIC_ADDR="$(prompt_value '请输入客户端地址（公网 IP 或域名，可留空）' "${PUBLIC_ADDR:-}")"

  if prompt_yes_no '是否重新生成 UUID 和 Reality 密钥' 'n'; then
    UUID_VALUE="$(generate_uuid)"
    generate_reality_keypair
  else
    if [[ -z "${UUID_VALUE:-}" ]]; then
      UUID_VALUE="$(generate_uuid)"
    fi
    if [[ -z "${PRIVATE_KEY:-}" || -z "${PUBLIC_KEY:-}" ]]; then
      generate_reality_keypair
    fi
  fi

  download_singbox_binary

  backup_file "${CONFIG_FILE}"
  backup_file "${CLIENT_FILE}"

  cat > "${CONFIG_FILE}" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "node-reality",
      "listen": "::",
      "listen_port": ${LISTEN_PORT},
      "users": [
        {
          "uuid": "$(json_escape "${UUID_VALUE}")",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$(json_escape "${SERVER_NAME}")",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$(json_escape "${SERVER_NAME}")",
            "server_port": 443
          },
          "private_key": "$(json_escape "${PRIVATE_KEY}")",
          "short_id": [
            ""
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF

  validate_config
  ensure_singbox_service_file
  service_enable
  service_restart

  write_state
  write_client_info

  info "sing-box 已安装完成。"
  info "服务名: ${SERVICE_NAME}"
  info "配置文件: ${CONFIG_FILE}"
  info "客户端信息: ${CLIENT_FILE}"
  service_is_active && info "服务状态: running" || warn "服务未处于运行状态。"
}

set_file_key_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local line

  line="${key} = ${value}"
  mkdir -p "$(dirname "${file}")"
  touch "${file}"

  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${file}"; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*$|${line}|" "${file}"
  else
    printf '%s\n' "${line}" >> "${file}"
  fi
}

rewrite_modules_load_file() {
  mkdir -p "$(dirname "${BBR_MODULES_FILE}")"
  local tmp_file
  tmp_file="$(mktemp)"

  if [[ -f "${BBR_MODULES_FILE}" ]]; then
    grep -vE '^[[:space:]]*(tcp_bbr|bbr)([[:space:]]*=.*)?[[:space:]]*$' "${BBR_MODULES_FILE}" > "${tmp_file}" || true
  fi

  printf 'tcp_bbr\n' >> "${tmp_file}"
  mv "${tmp_file}" "${BBR_MODULES_FILE}"
}

bbr_runtime_probe() {
  local available
  if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr >/dev/null 2>&1 || modprobe bbr >/dev/null 2>&1 || true
  fi

  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if printf '%s\n' "${available}" | tr ' ' '\n' | grep -qx bbr; then
    return 0
  fi

  return 1
}

choose_qdisc() {
  if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
    printf '%s\n' fq
    return 0
  fi
  if sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1; then
    printf '%s\n' fq_codel
    return 0
  fi
  printf '%s\n' fq
}

install_bbr() {
  require_root
  is_linux || die "这个脚本只适用于 Linux。"

  ensure_runtime_tools

  local qdisc
  qdisc="$(choose_qdisc)"

  rewrite_modules_load_file
  set_file_key_value "${BBR_SYSCTL_FILE}" "net.core.default_qdisc" "${qdisc}"
  set_file_key_value "${BBR_SYSCTL_FILE}" "net.ipv4.tcp_congestion_control" "bbr"

  sysctl --system >/dev/null 2>&1 || sysctl -p "${BBR_SYSCTL_FILE}" >/dev/null 2>&1 || true

  if bbr_runtime_probe; then
    info "BBR 已启用。"
  else
    warn "BBR 配置已写入，但当前内核尚未进入 bbr 状态。"
    warn "如果内核不支持或模块未加载，可能需要更换内核或重启后再确认。"
  fi

  info "sysctl 文件: ${BBR_SYSCTL_FILE}"
  info "modules-load 文件: ${BBR_MODULES_FILE}"
  info "当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  info "当前 qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
}

show_status() {
  detect_service_manager
  printf '\n== sing-box ==\n'
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
    printf '服务名: %s\n' "${SERVICE_NAME}"
    printf '服务管理器: %s\n' "${SERVICE_MANAGER:-unknown}"
    if service_is_active; then
      printf '服务状态: running\n'
    else
      printf '服务状态: stopped\n'
    fi
    printf '节点名: %s\n' "${NODE_NAME:-unknown}"
    printf '端口: %s\n' "${LISTEN_PORT:-unknown}"
    printf 'SNI: %s\n' "${SERVER_NAME:-unknown}"
    printf '配置: %s\n' "${CONFIG_FILE}"
    if [[ -f "${CLIENT_FILE}" ]]; then
      printf '\n%s\n' "---- client info ----"
      sed -n '1,200p' "${CLIENT_FILE}"
    fi
  else
    printf '未安装。\n'
  fi

  printf '\n== BBR ==\n'
  printf '当前拥塞控制: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  printf '当前 qdisc: %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  if [[ -f "${BBR_SYSCTL_FILE}" ]]; then
    printf 'sysctl 文件: %s\n' "${BBR_SYSCTL_FILE}"
  fi
}

show_banner() {
  printf '\n%s\n' "========================================"
  printf '%s\n' "  Sing-box / BBR Navigator"
  printf '%s\n' "========================================"
  printf '%s\n' "1) 安装 sing-box 节点"
  printf '%s\n' "2) 安装 / 启用 BBR"
  printf '%s\n' "3) 查看状态"
  printf '%s\n' "0) 退出"
  printf '%s\n' "========================================"
}

menu() {
  while true; do
    show_banner
    printf '请选择: '
    local choice
    read -r choice || exit 0
    case "${choice}" in
      1)
        install_sing_box_node
        pause_if_needed
        ;;
      2)
        install_bbr
        pause_if_needed
        ;;
      3)
        show_status
        pause_if_needed
        ;;
      0|q|Q)
        exit 0
        ;;
      *)
        warn "无效选项，请重新输入。"
        pause_if_needed
        ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage: ${APP_NAME} [-l|--menu]

Options:
  -l, --menu   Open the interactive menu
  -h, --help   Show this help

Examples:
  bash install.sh -l
EOF
}

main() {
  case "${1:-}" in
    -l|--menu|'')
      menu
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
