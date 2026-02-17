#!/usr/bin/env bash
set -euo pipefail

# =========================
# SSH TUN + DNAT Installer
# One script for both roles: iran (client) / khrej (server)
# =========================

GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; NC="\033[0m"

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[-]${NC} $*" >&2; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "This script must be run as root."
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

pkg_install() {
  local pkgs=("$@")
  if have_cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${pkgs[@]}"
  elif have_cmd dnf; then
    dnf install -y "${pkgs[@]}"
  elif have_cmd yum; then
    yum install -y "${pkgs[@]}"
  else
    die "Package manager not found (apt/dnf/yum). Install manually: ${pkgs[*]}"
  fi
}

ask() {
  local prompt="$1" default="${2:-}"
  local ans
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " ans || true
    echo "${ans:-$default}"
  else
    read -r -p "$prompt: " ans || true
    echo "$ans"
  fi
}

ask_yn() {
  local prompt="$1" default="${2:-y}"
  local ans
  local hint="[y/N]"
  [[ "$default" == "y" ]] && hint="[Y/n]"
  read -r -p "$prompt $hint: " ans || true
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

ensure_tun() {
  mkdir -p /dev/net
  if [[ ! -c /dev/net/tun ]]; then
    warn "/dev/net/tun is missing; trying to create it..."
    mknod /dev/net/tun c 10 200 || true
    chmod 666 /dev/net/tun || true
  fi
  modprobe tun || true
  mkdir -p /etc/modules-load.d
  echo "tun" > /etc/modules-load.d/tun.conf
  [[ -c /dev/net/tun ]] || die "/dev/net/tun is still missing. Check kernel/virtualizer settings."
}

sshd_restart() {
  if have_cmd systemctl; then
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
  else
    service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
  fi
}

sshd_test() {
  if have_cmd sshd; then
    sshd -t || die "sshd_config has errors. See output above."
  fi
}

ensure_sshd_tunnel_enabled() {
  local cfg="/etc/ssh/sshd_config"
  [[ -f "$cfg" ]] || die "File $cfg not found."

  cp -a "$cfg" "${cfg}.bak.$(date +%F_%H%M%S)"

  # Append safe overrides (idempotent)
  if ! grep -qiE '^\s*PermitTunnel\s+' "$cfg"; then
    cat >>"$cfg" <<'EOF'

# Added by ssh-tun-dnat installer
PermitTunnel yes
AllowTcpForwarding yes
EOF
  else
    # Replace existing PermitTunnel line
    sed -i -E 's/^\s*PermitTunnel\s+.*/PermitTunnel yes/I' "$cfg"
    if ! grep -qiE '^\s*AllowTcpForwarding\s+' "$cfg"; then
      echo "AllowTcpForwarding yes" >>"$cfg"
    else
      sed -i -E 's/^\s*AllowTcpForwarding\s+.*/AllowTcpForwarding yes/I' "$cfg"
    fi
  fi

  # Optional hardening (won't force unless user says yes)
  if ask_yn "Disable PasswordAuthentication on this server? (recommended if SSH key access works)" "n"; then
    if grep -qiE '^\s*PasswordAuthentication\s+' "$cfg"; then
      sed -i -E 's/^\s*PasswordAuthentication\s+.*/PasswordAuthentication no/I' "$cfg"
    else
      echo "PasswordAuthentication no" >>"$cfg"
    fi
    if grep -qiE '^\s*KbdInteractiveAuthentication\s+' "$cfg"; then
      sed -i -E 's/^\s*KbdInteractiveAuthentication\s+.*/KbdInteractiveAuthentication no/I' "$cfg"
    else
      echo "KbdInteractiveAuthentication no" >>"$cfg"
    fi
  fi

  sshd_test
  sshd_restart
  log "sshd configured (PermitTunnel/AllowTcpForwarding)."
}

detect_wan_if() {
  # best-effort auto detect
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

ports_to_array() {
  # Supports: single port, comma/space list, and ranges (e.g. 443,8443,20000-20010)
  local input="${1//,/ }"
  awk '
    function add_port(p) {
      if (p >= 1 && p <= 65535 && !seen[p]++) print p
    }
    {
      for (i = 1; i <= NF; i++) {
        token = $i
        if (token ~ /^[0-9]+$/) {
          add_port(token + 0)
        } else if (token ~ /^[0-9]+-[0-9]+$/) {
          split(token, a, "-")
          s = a[1] + 0
          e = a[2] + 0
          if (s <= e) {
            for (p = s; p <= e; p++) add_port(p)
          } else {
            for (p = e; p <= s; p++) add_port(p)
          }
        }
      }
    }
  ' <<<"$input" | sort -n
}

write_env() {
  local envdir="/etc/ssh-tun-dnat"
  mkdir -p "$envdir"
  local envfile="$envdir/tun${TUN_ID}.env"
  cat >"$envfile" <<EOF
ROLE=iran
HOST=${HOST}
USER=${USER}
SSH_PORT=${SSH_PORT}
TUN_ID=${TUN_ID}
IP_LOCAL=${IP_LOCAL}
IP_REMOTE=${IP_REMOTE}
MASK=${MASK}
MTU=${MTU}
WAN_IF=${WAN_IF}
TCP_PORTS="${TCP_PORTS_STR}"
UDP_PORTS="${UDP_PORTS_STR}"
MSS_CLAMP=${MSS_CLAMP}
REMOTE_FIREWALL=${REMOTE_FIREWALL}
ENABLE_REMOTE_IP_FORWARD=${ENABLE_REMOTE_IP_FORWARD}
EOF
  chmod 600 "$envfile"
  echo "$envfile"
}

create_local_setup_script() {
  local path="/usr/local/sbin/ssh-tun-dnat-setup.sh"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ENVFILE="${1:-}"
[[ -n "$ENVFILE" && -f "$ENVFILE" ]] || { echo "Usage: $0 /etc/ssh-tun-dnat/tunX.env"; exit 1; }
# shellcheck disable=SC1090
source "$ENVFILE"

log(){ echo "[setup] $*"; }

wait_tun() {
  for _ in $(seq 1 20); do
    ip link show "tun${TUN_ID}" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

ensure_sysctl() {
  mkdir -p /etc/sysctl.d
  cat >/etc/sysctl.d/99-ssh-tun-dnat.conf <<S
net.ipv4.ip_forward=1
S
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

iptables_add() {
  # usage: iptables_add <table> <chain> <rule...>
  local table="$1"; shift
  local chain="$1"; shift
  if iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
    return 0
  fi
  iptables -t "$table" -A "$chain" "$@"
}

remote_exec() {
  ssh -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    "${USER}@${HOST}" "$@"
}

remote_var() {
  printf "%q" "$1"
}

main() {
  wait_tun || { echo "tun${TUN_ID} did not come up."; exit 1; }

  ip addr add "${IP_LOCAL}/${MASK}" dev "tun${TUN_ID}" 2>/dev/null || true
  ip link set "tun${TUN_ID}" up
  ip link set dev "tun${TUN_ID}" mtu "${MTU}" 2>/dev/null || true

  ensure_sysctl

  # Remote setup: assign IP + MTU + (optional) ip_forward + (optional) allow INPUT on tun
  remote_exec \
    "TUN_ID=$(remote_var "$TUN_ID") IP_REMOTE=$(remote_var "$IP_REMOTE") MASK=$(remote_var "$MASK") MTU=$(remote_var "$MTU") TCP_PORTS_STR=$(remote_var "$TCP_PORTS") UDP_PORTS_STR=$(remote_var "$UDP_PORTS") REMOTE_FIREWALL=$(remote_var "$REMOTE_FIREWALL") ENABLE_REMOTE_IP_FORWARD=$(remote_var "$ENABLE_REMOTE_IP_FORWARD") bash -s" <<'RS'
set -euo pipefail

ip addr add "${IP_REMOTE}/${MASK}" dev "tun${TUN_ID}" 2>/dev/null || true
ip link set "tun${TUN_ID}" up
ip link set dev "tun${TUN_ID}" mtu "${MTU}" 2>/dev/null || true

if [[ "$ENABLE_REMOTE_IP_FORWARD" == "1" ]]; then
  mkdir -p /etc/sysctl.d
  cat >/etc/sysctl.d/99-ssh-tun-dnat-remote.conf <<S
net.ipv4.ip_forward=1
S
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
fi

if [[ "$REMOTE_FIREWALL" == "1" ]]; then
  # Allow service ports on tun interface (INPUT)
  to_arr() {
    local input="${1//,/ }"
    awk '
      function add_port(p) {
        if (p >= 1 && p <= 65535 && !seen[p]++) print p
      }
      {
        for (i = 1; i <= NF; i++) {
          token = $i
          if (token ~ /^[0-9]+$/) {
            add_port(token + 0)
          } else if (token ~ /^[0-9]+-[0-9]+$/) {
            split(token, a, "-")
            s = a[1] + 0
            e = a[2] + 0
            if (s <= e) {
              for (p = s; p <= e; p++) add_port(p)
            } else {
              for (p = e; p <= s; p++) add_port(p)
            }
          }
        }
      }
    ' <<<"$input" | sort -n || true
  }
  for p in $(to_arr "$TCP_PORTS_STR"); do
    iptables -C INPUT -i "tun${TUN_ID}" -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
    iptables -A INPUT -i "tun${TUN_ID}" -p tcp --dport "$p" -j ACCEPT
  done
  for p in $(to_arr "$UDP_PORTS_STR"); do
    iptables -C INPUT -i "tun${TUN_ID}" -p udp --dport "$p" -j ACCEPT 2>/dev/null || \
    iptables -A INPUT -i "tun${TUN_ID}" -p udp --dport "$p" -j ACCEPT
  done
fi
RS

  # DNAT on iran: WAN -> IP_REMOTE (over tun)
  to_arr() {
    local input="${1//,/ }"
    awk '
      function add_port(p) {
        if (p >= 1 && p <= 65535 && !seen[p]++) print p
      }
      {
        for (i = 1; i <= NF; i++) {
          token = $i
          if (token ~ /^[0-9]+$/) {
            add_port(token + 0)
          } else if (token ~ /^[0-9]+-[0-9]+$/) {
            split(token, a, "-")
            s = a[1] + 0
            e = a[2] + 0
            if (s <= e) {
              for (p = s; p <= e; p++) add_port(p)
            } else {
              for (p = e; p <= s; p++) add_port(p)
            }
          }
        }
      }
    ' <<<"$input" | sort -n || true
  }

  for p in $(to_arr "$TCP_PORTS"); do
    iptables_add nat PREROUTING -i "$WAN_IF" -p tcp --dport "$p" -j DNAT --to-destination "${IP_REMOTE}"
    iptables_add filter FORWARD -i "$WAN_IF" -o "tun${TUN_ID}" -p tcp --dport "$p" -j ACCEPT
  done

  for p in $(to_arr "$UDP_PORTS"); do
    iptables_add nat PREROUTING -i "$WAN_IF" -p udp --dport "$p" -j DNAT --to-destination "${IP_REMOTE}"
    iptables_add filter FORWARD -i "$WAN_IF" -o "tun${TUN_ID}" -p udp --dport "$p" -j ACCEPT
  done

  # Return traffic for forwarded connections (important when FORWARD policy is DROP)
  iptables_add filter FORWARD -i "tun${TUN_ID}" -o "$WAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # SNAT out tun so return traffic comes back cleanly
  iptables_add nat POSTROUTING -o "tun${TUN_ID}" -j MASQUERADE

  # Optional MSS clamp (helps with low MTU paths)
  if [[ "${MSS_CLAMP}" == "1" ]]; then
    iptables_add mangle FORWARD -o "tun${TUN_ID}" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  fi

  log "Local setup done: tun${TUN_ID} + DNAT/MASQUERADE"
}

main "$@"
EOF
  chmod +x "$path"
  log "Local setup script created: $path"
}

create_systemd_service_iran() {
  local envfile="$1"
  local unit="/etc/systemd/system/ssh-tun${TUN_ID}-dnat.service"
  cat >"$unit" <<EOF
[Unit]
Description=SSH TUN${TUN_ID} + DNAT to khrej (${HOST})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${envfile}

# cleanup old interface if exists
ExecStartPre=-/sbin/ip link del tun${TUN_ID}
ExecStartPre=-/usr/bin/ssh -p ${SSH_PORT} -o BatchMode=yes -o StrictHostKeyChecking=accept-new ${USER}@${HOST} "ip link del tun${TUN_ID} 2>/dev/null || true"

# Keepalive so ssh exits if link is dead (systemd will restart)
ExecStart=/usr/bin/ssh -p ${SSH_PORT} \\
  -o BatchMode=yes \\
  -o ExitOnForwardFailure=yes \\
  -o StrictHostKeyChecking=accept-new \\
  -o ServerAliveInterval=30 \\
  -o ServerAliveCountMax=3 \\
  -w ${TUN_ID}:${TUN_ID} -N ${USER}@${HOST}

ExecStartPost=/usr/local/sbin/ssh-tun-dnat-setup.sh ${envfile}

Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$(basename "$unit")"
  log "systemd service enabled: $(basename "$unit")"
  log "Status: systemctl status $(basename "$unit") --no-pager"
}


verify_tunnel_health() {
  log "Checking tunnel health for tun${TUN_ID} ..."

  local ok_local=0 ok_remote=0
  for _ in $(seq 1 20); do
    if ip link show "tun${TUN_ID}" >/dev/null 2>&1; then
      ok_local=1
      break
    fi
    sleep 1
  done
  [[ "$ok_local" -eq 1 ]] || die "tun${TUN_ID} did not come up on iran. Check service logs: journalctl -u ssh-tun${TUN_ID}-dnat.service -n 100 --no-pager"

  for _ in $(seq 1 20); do
    if ssh -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${USER}@${HOST}" "ip link show tun${TUN_ID} >/dev/null 2>&1"; then
      ok_remote=1
      break
    fi
    sleep 1
  done
  [[ "$ok_remote" -eq 1 ]] || die "tun${TUN_ID} did not come up on khrej. Check sshd/PermitTunnel settings."

  if ping -c 2 -W 2 "$IP_REMOTE" >/dev/null 2>&1; then
    log "Tunnel ping to ${IP_REMOTE} succeeded."
  else
    warn "Tunnel ping to ${IP_REMOTE} failed. ICMP may be blocked; check with:"
    warn "ip a show tun${TUN_ID} && ssh -p ${SSH_PORT} ${USER}@${HOST} 'ip a show tun${TUN_ID}'"
  fi
}

setup_role_khrej() {
  log "Role = khrej (server)"
  pkg_install openssh-server iproute2 iptables
  ensure_tun
  ensure_sshd_tunnel_enabled
  log "khrej is ready."
}

ensure_ssh_key_and_access() {
  pkg_install openssh-client

  if [[ ! -f /root/.ssh/id_ed25519 && ! -f /root/.ssh/id_rsa ]]; then
    warn "No SSH key found; generating one..."
    ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
  fi

  # Try batchmode first
  if ssh -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${USER}@${HOST}" "echo ok" >/dev/null 2>&1; then
    log "SSH key access OK."
    return 0
  fi

  warn "Passwordless login is not enabled yet. Trying ssh-copy-id (may ask for password)..."
  pkg_install openssh-client
  if have_cmd ssh-copy-id; then
    ssh-copy-id -p "$SSH_PORT" "${USER}@${HOST}" || die "ssh-copy-id failed. Add the key manually."
  else
    die "ssh-copy-id is not installed. Check openssh-client."
  fi

  ssh -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${USER}@${HOST}" "echo ok" >/dev/null 2>&1 \
    || die "BatchMode still failed after ssh-copy-id. Check sshd settings on khrej."
  log "SSH key access configured."
}

maybe_configure_remote_khrej_over_ssh() {
  if ask_yn "Configure khrej over SSH now as well? (PermitTunnel + iptables tools)" "y"; then
    log "Configuring khrej over SSH..."
    ssh -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${USER}@${HOST}" "bash -s" <<'EOS'
set -euo pipefail
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y openssh-server iproute2 iptables
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y openssh-server iproute iptables
elif command -v yum >/dev/null 2>&1; then
  yum install -y openssh-server iproute iptables
fi

mkdir -p /dev/net || true
if [[ ! -c /dev/net/tun ]]; then
  mknod /dev/net/tun c 10 200 || true
  chmod 666 /dev/net/tun || true
fi
modprobe tun || true
mkdir -p /etc/modules-load.d
echo tun > /etc/modules-load.d/tun.conf

CFG="/etc/ssh/sshd_config"
cp -a "$CFG" "${CFG}.bak.$(date +%F_%H%M%S)"

if grep -qiE '^\s*PermitTunnel\s+' "$CFG"; then
  sed -i -E 's/^\s*PermitTunnel\s+.*/PermitTunnel yes/I' "$CFG"
else
  printf "\n# Added by ssh-tun-dnat installer\nPermitTunnel yes\n" >>"$CFG"
fi

if grep -qiE '^\s*AllowTcpForwarding\s+' "$CFG"; then
  sed -i -E 's/^\s*AllowTcpForwarding\s+.*/AllowTcpForwarding yes/I' "$CFG"
else
  echo "AllowTcpForwarding yes" >>"$CFG"
fi

sshd -t 2>/dev/null || true
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
echo "remote-ok"
EOS
    log "khrej configured via SSH."
  else
    warn "Remember to run Role=khrej on khrej too, or enable PermitTunnel manually."
  fi
}


collect_iran_config() {
  HOST="$(ask 'khrej server IP/Domain' "${HOST:-khrej}")"
  USER="$(ask 'SSH user on khrej' "${USER:-root}")"
  SSH_PORT="$(ask 'SSH port on khrej' "${SSH_PORT:-22}")"
  TUN_ID="$(ask 'TUN ID (e.g. 5)' "${TUN_ID:-5}")"

  IP_LOCAL="$(ask 'Tunnel IP on iran' "${IP_LOCAL:-192.168.83.1}")"
  IP_REMOTE="$(ask 'Tunnel IP on khrej' "${IP_REMOTE:-192.168.83.2}")"
  MASK="$(ask 'Tunnel mask (CIDR)' "${MASK:-30}")"

  MTU="$(ask 'MTU for tun (1240 is good if you have MTU issues)' "${MTU:-1240}")"

  TCP_PORTS_STR="$(ask 'TCP ports to forward (1 or more: 2096 OR 443,8443 OR 20000-20010)' "${TCP_PORTS_STR:-2096}")"
  UDP_PORTS_STR="$(ask 'UDP ports to forward (empty = none; supports same format)' "${UDP_PORTS_STR:-}")"

  WAN_IF="${WAN_IF:-$(detect_wan_if || true)}"
  WAN_IF="$(ask 'Internet input interface on iran (auto-detected)' "${WAN_IF:-eth0}")"

  MSS_CLAMP="${MSS_CLAMP:-0}"
  if ask_yn "Enable MSS clamp? (helps prevent TLS/WS stalls on low MTU paths)" "$( [[ "${MSS_CLAMP}" == "1" ]] && echo y || echo n )"; then
    MSS_CLAMP=1
  else
    MSS_CLAMP=0
  fi

  REMOTE_FIREWALL="${REMOTE_FIREWALL:-0}"
  if ask_yn "Also open INPUT on khrej for these ports on tun?" "$( [[ "${REMOTE_FIREWALL}" == "1" ]] && echo y || echo n )"; then
    REMOTE_FIREWALL=1
  else
    REMOTE_FIREWALL=0
  fi

  ENABLE_REMOTE_IP_FORWARD="${ENABLE_REMOTE_IP_FORWARD:-0}"
  if ask_yn "Also set net.ipv4.ip_forward=1 on khrej? (usually not required but harmless)" "$( [[ "${ENABLE_REMOTE_IP_FORWARD}" == "1" ]] && echo y || echo n )"; then
    ENABLE_REMOTE_IP_FORWARD=1
  else
    ENABLE_REMOTE_IP_FORWARD=0
  fi
}

pick_existing_envfile() {
  local envdir="/etc/ssh-tun-dnat"
  [[ -d "$envdir" ]] || return 1

  mapfile -t IRAN_ENV_FILES < <(find "$envdir" -maxdepth 1 -type f -name 'tun*.env' | sort)
  [[ "${#IRAN_ENV_FILES[@]}" -gt 0 ]] || return 1

  echo "Existing tunnel profiles:"
  local i
  for i in "${!IRAN_ENV_FILES[@]}"; do
    echo "  $((i+1))) ${IRAN_ENV_FILES[$i]}"
  done

  while true; do
    local sel
    sel="$(ask 'Select profile number to manage (or type n for new profile)' '1')"
    if [[ "$sel" =~ ^[Nn]$ ]]; then
      return 1
    fi
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#IRAN_ENV_FILES[@]} )); then
      SELECTED_ENVFILE="${IRAN_ENV_FILES[$((sel-1))]}"
      return 0
    fi
    warn "Invalid selection."
  done
}

show_profile_summary() {
  local envfile="$1"
  [[ -f "$envfile" ]] || die "Env file not found: $envfile"
  echo "---------------- CURRENT PROFILE ----------------"
  cat "$envfile"
  echo "------------------------------------------------"
}

manage_existing_iran_profile() {
  local envfile="$1"
  [[ -f "$envfile" ]] || die "Env file not found: $envfile"

  # shellcheck disable=SC1090
  source "$envfile"
  local unit="ssh-tun${TUN_ID}-dnat.service"

  while true; do
    echo
    echo "Manage existing profile: tun${TUN_ID}"
    echo "  1) Show current config"
    echo "  2) Restart service"
    echo "  3) Stop service"
    echo "  4) Start service"
    echo "  5) Re-run setup (apply iptables/tun again)"
    echo "  6) Edit and reconfigure this profile"
    echo "  7) Remove this profile and service"
    echo "  8) Exit"

    local action
    action="$(ask 'Choose action' '1')"
    case "$action" in
      1)
        show_profile_summary "$envfile"
        ;;
      2)
        systemctl daemon-reload || true
        systemctl restart "$unit"
        systemctl status "$unit" --no-pager || true
        ;;
      3)
        systemctl stop "$unit"
        systemctl status "$unit" --no-pager || true
        ;;
      4)
        systemctl start "$unit"
        systemctl status "$unit" --no-pager || true
        ;;
      5)
        /usr/local/sbin/ssh-tun-dnat-setup.sh "$envfile"
        ;;
      6)
        local old_tun_id="$TUN_ID"
        local old_unit="$unit"
        local old_envfile="$envfile"

        log "Editing profile tun${TUN_ID} ..."
        collect_iran_config

        ensure_ssh_key_and_access
        maybe_configure_remote_khrej_over_ssh

        # Normalize port inputs
        TCP_PORTS_STR="$(ports_to_array "$TCP_PORTS_STR" | paste -sd, - || true)"
        UDP_PORTS_STR="$(ports_to_array "$UDP_PORTS_STR" | paste -sd, - || true)"

        export HOST USER SSH_PORT TUN_ID IP_LOCAL IP_REMOTE MASK MTU WAN_IF
        export TCP_PORTS_STR UDP_PORTS_STR MSS_CLAMP REMOTE_FIREWALL ENABLE_REMOTE_IP_FORWARD

        create_local_setup_script
        envfile="$(write_env)"
        unit="ssh-tun${TUN_ID}-dnat.service"
        create_systemd_service_iran "$envfile"

        # If TUN ID changed, remove old service/env profile
        if [[ "$old_unit" != "$unit" ]]; then
          systemctl disable --now "$old_unit" 2>/dev/null || true
          rm -f "/etc/systemd/system/$old_unit"
          [[ "$old_envfile" != "$envfile" ]] && rm -f "$old_envfile"
          ip link del "tun${old_tun_id}" 2>/dev/null || true
          systemctl daemon-reload || true
        fi

        verify_tunnel_health
        ;;
      7)
        if ask_yn "Are you sure you want to remove profile tun${TUN_ID} and its service?" "n"; then
          systemctl disable --now "$unit" 2>/dev/null || true
          rm -f "/etc/systemd/system/$unit"
          systemctl daemon-reload || true
          rm -f "$envfile"
          ip link del "tun${TUN_ID}" 2>/dev/null || true
          log "Removed profile tun${TUN_ID}."
          break
        fi
        ;;
      8)
        break
        ;;
      *)
        warn "Invalid action."
        ;;
    esac
  done
}

setup_role_iran() {
  log "Role = iran (client)"

  pkg_install iproute2 iptables openssh-client
  ensure_tun

  if pick_existing_envfile; then
    if ask_yn "An existing profile was found. Manage it now?" "y"; then
      manage_existing_iran_profile "$SELECTED_ENVFILE"
      return 0
    fi
  fi

  collect_iran_config

  # Export for helper creation
  export HOST USER SSH_PORT TUN_ID IP_LOCAL IP_REMOTE MASK MTU WAN_IF
  export TCP_PORTS_STR UDP_PORTS_STR MSS_CLAMP REMOTE_FIREWALL ENABLE_REMOTE_IP_FORWARD

  ensure_ssh_key_and_access
  maybe_configure_remote_khrej_over_ssh

  create_local_setup_script

  # Prepare env file for setup script + systemd unit
  TCP_PORTS_STR="$(ports_to_array "$TCP_PORTS_STR" | paste -sd, - || true)"
  UDP_PORTS_STR="$(ports_to_array "$UDP_PORTS_STR" | paste -sd, - || true)"
  export TCP_PORTS_STR UDP_PORTS_STR

  envfile="$(write_env)"
  create_systemd_service_iran "$envfile"
  verify_tunnel_health

  log "Done ✅"
  echo "-------------------------------------------------"
  echo "Check:"
  echo "  ip a show tun${TUN_ID}"
  echo "  iptables -t nat -vnL PREROUTING | head"
  echo "  systemctl status ssh-tun${TUN_ID}-dnat.service --no-pager"
  echo "-------------------------------------------------"
}

main() {
  require_root
  echo "=== SSH TUN + DNAT Installer ==="
  echo "Roles: iran (client DNAT) / khrej (server PermitTunnel)"

  ROLE="${ROLE:-}"
  if [[ -z "$ROLE" ]]; then
    ROLE="$(ask 'Which server is this script running on? (iran/khrej)' 'iran')"
  fi

  case "$ROLE" in
    khrej) setup_role_khrej ;;
    iran)  setup_role_iran  ;;
    *) die "ROLE must be iran or khrej." ;;
  esac
}

main "$@"
