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
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "این اسکریپت باید با root اجرا شود."
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
    die "Package manager پیدا نشد (apt/dnf/yum). دستی نصب کن: ${pkgs[*]}"
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
    warn "/dev/net/tun نبود؛ تلاش برای ساخت..."
    mknod /dev/net/tun c 10 200 || true
    chmod 666 /dev/net/tun || true
  fi
  modprobe tun || true
  mkdir -p /etc/modules-load.d
  echo "tun" > /etc/modules-load.d/tun.conf
  [[ -c /dev/net/tun ]] || die "/dev/net/tun هنوز موجود نیست. کرنل/مجازی‌ساز را چک کن."
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
    sshd -t || die "sshd_config مشکل دارد. خروجی بالا را ببین."
  fi
}

ensure_sshd_tunnel_enabled() {
  local cfg="/etc/ssh/sshd_config"
  [[ -f "$cfg" ]] || die "فایل $cfg پیدا نشد."

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
  if ask_yn "روی این سرور PasswordAuthentication رو خاموش کنم؟ (پیشنهادی اگر کلید داری)" "n"; then
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
  log "sshd تنظیم شد (PermitTunnel/AllowTcpForwarding)."
}

detect_wan_if() {
  # best-effort auto detect
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

ports_to_array() {
  # input: "2096,2087  443"
  echo "$1" | tr ', ' '\n' | awk 'NF{print $1}' | grep -E '^[0-9]+$' || true
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
  wait_tun || { echo "tun${TUN_ID} بالا نیامد."; exit 1; }

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
  to_arr() { echo "$1" | tr ', ' '\n' | awk 'NF{print $1}' | grep -E '^[0-9]+$' || true; }
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
  to_arr() { echo "$1" | tr ', ' '\n' | awk 'NF{print $1}' | grep -E '^[0-9]+$' || true; }

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

setup_role_khrej() {
  log "Role = khrej (server)"
  pkg_install openssh-server iproute2 iptables
  ensure_tun
  ensure_sshd_tunnel_enabled
  log "khrej آماده است."
}

ensure_ssh_key_and_access() {
  pkg_install openssh-client

  if [[ ! -f /root/.ssh/id_ed25519 && ! -f /root/.ssh/id_rsa ]]; then
    warn "کلید SSH وجود ندارد؛ می‌سازم..."
    ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
  fi

  # Try batchmode first
  if ssh -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${USER}@${HOST}" "echo ok" >/dev/null 2>&1; then
    log "SSH key access OK."
    return 0
  fi

  warn "ورود بدون پسورد هنوز فعال نیست. تلاش برای ssh-copy-id (ممکن است پسورد بخواهد)..."
  pkg_install openssh-client
  if have_cmd ssh-copy-id; then
    ssh-copy-id -p "$SSH_PORT" "${USER}@${HOST}" || die "ssh-copy-id ناموفق بود. دستی کلید را اضافه کن."
  else
    die "ssh-copy-id نصب نیست. openssh-client را بررسی کن."
  fi

  ssh -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${USER}@${HOST}" "echo ok" >/dev/null 2>&1 \
    || die "بعد از ssh-copy-id هم BatchMode کار نکرد. تنظیمات sshd روی khrej را چک کن."
  log "SSH key access configured."
}

maybe_configure_remote_khrej_over_ssh() {
  if ask_yn "آیا همین الان khrej را هم از راه SSH کانفیگ کنم؟ (PermitTunnel + iptables ابزارها)" "y"; then
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
    warn "پس یادت باشه روی khrej هم Role=khrej اجرا بشه یا دستی PermitTunnel فعال باشه."
  fi
}

setup_role_iran() {
  log "Role = iran (client)"

  pkg_install iproute2 iptables openssh-client
  ensure_tun

  HOST="$(ask 'IP/Domain سرور khrej' 'khrej')"
  USER="$(ask 'SSH user روی khrej' 'root')"
  SSH_PORT="$(ask 'SSH port روی khrej' '22')"
  TUN_ID="$(ask 'TUN ID (مثلاً 5)' '5')"

  IP_LOCAL="$(ask 'IP تونل روی iran' '192.168.83.1')"
  IP_REMOTE="$(ask 'IP تونل روی khrej' '192.168.83.2')"
  MASK="$(ask 'Mask (CIDR) برای تونل' '30')"

  MTU="$(ask 'MTU برای tun (اگر مشکل MTU داشتی 1240 خوبه)' '1240')"

  TCP_PORTS_STR="$(ask 'TCP ports برای فوروارد (comma-separated)' '2096')"
  UDP_PORTS_STR="$(ask 'UDP ports برای فوروارد (خالی=هیچ)' '')"

  WAN_IF="$(detect_wan_if || true)"
  WAN_IF="$(ask 'اینترفیس ورودی اینترنت روی iran (auto-detect شده)' "${WAN_IF:-eth0}")"

  MSS_CLAMP=0
  if ask_yn "MSS clamp فعال شود؟ (برای جلوگیری از گیر کردن TLS/WS با MTU پایین)" "y"; then
    MSS_CLAMP=1
  fi

  REMOTE_FIREWALL=0
  if ask_yn "روی khrej هم اجازه‌ی INPUT برای همین پورت‌ها روی tun باز کنم؟" "y"; then
    REMOTE_FIREWALL=1
  fi

  ENABLE_REMOTE_IP_FORWARD=0
  if ask_yn "روی khrej هم net.ipv4.ip_forward=1 ست شود؟ (معمولاً لازم نیست ولی ضرری ندارد)" "n"; then
    ENABLE_REMOTE_IP_FORWARD=1
  fi

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

  log "تمام ✅"
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
    ROLE="$(ask 'این اسکریپت روی کدام سرور اجرا می‌شود؟ (iran/khrej)' 'iran')"
  fi

  case "$ROLE" in
    khrej) setup_role_khrej ;;
    iran)  setup_role_iran  ;;
    *) die "ROLE باید iran یا khrej باشد." ;;
  esac
}

main "$@"
