#!/usr/bin/env bash
# ======================================================================
#  VPS PANEL v2.2 - instalador y administrador de protocolos para tuneles
#  Compatible con HTTP Custom y apps similares.
#  SSH, Dropbear, SSL, WebSocket, Squid, V2Ray, BadVPN-UDPGW,
#  UDP Custom, SlowDNS, OpenVPN y WireGuard
#  Sistemas: Ubuntu 20.04/22.04/24.04 y Debian 11/12 (como root)
#
#  Uso:
#    bash vps-panel.sh                 registro del VPS (1a vez) + menu ("vpspanel")
#    bash vps-panel.sh --install-all   instalacion completa sin menu
#
#  Valores por defecto: banner SSH desactivado, auto-inicio del panel activado.
#  Los puertos se cambian en Protocolos y se guardan en /etc/vpspanel/ports.conf
#    UDPCUSTOM_URL=<url> vpspanel      (opcional) usar otro binario de udp-custom
#
#  Interfaz: solo caracteres ASCII (sin emojis ni simbolos especiales).
#  Todo el aspecto visual esta en el bloque "Interfaz".
# ======================================================================

set -u
shopt -s extglob
export DEBIAN_FRONTEND=noninteractive
export VPSPANEL_ACTIVE=1

# ------------------------------ Configuracion -------------------------
VERSION=2.2
NAME_MAX=24        # largo maximo del nombre del VPS (se muestra en el titulo)
BASE=${VPSPANEL_BASE:-/etc/vpspanel}
USERDB=$BASE/users.db
V2DB=$BASE/v2ray.db
BANNER=$BASE/banner
CERT=$BASE/cert.pem
DOMAIN_F=$BASE/domain
NAME_F=$BASE/vps.name
REG_F=$BASE/vps.reg
HIDE_F=$BASE/hide.conf     # partes del panel ocultas (una por linea: name, server, services)
V2CFG=/usr/local/etc/v2ray/config.json
V2PATH=/v2ray

PORT_DROPBEAR=${PORT_DROPBEAR:-110}
PORT_SSL=${PORT_SSL:-443}
PORT_WS=${PORT_WS:-80}
PORT_V2RAY=${PORT_V2RAY:-8080}
PORT_BADVPN=${PORT_BADVPN:-7300}
PORT_SQUID=${PORT_SQUID:-3128}
PORT_UDP=${PORT_UDP:-36712}
PORT_SLOWDNS=${PORT_SLOWDNS:-5300}
UDPCUSTOM_URL=${UDPCUSTOM_URL:-}

# Puertos personalizables (Protocolos > Cambiar puerto). PVAR: variable de cada protocolo.
declare -A PVAR=([dropbear]=PORT_DROPBEAR [ssl]=PORT_SSL [badvpn]=PORT_BADVPN [ws]=PORT_WS
                 [squid]=PORT_SQUID [v2ray]=PORT_V2RAY [udp]=PORT_UDP [slowdns]=PORT_SLOWDNS)
declare -A PDEF=([dropbear]=110 [ssl]=443 [badvpn]=7300 [ws]=80
                 [squid]=3128 [v2ray]=8080 [udp]=36712 [slowdns]=5300)
PORT_KEYS=(dropbear ssl ws squid v2ray badvpn udp slowdns)

# UDP Custom: binario x86_64 descargado automaticamente. La URL apunta a un commit
# exacto del repositorio (no a "main") y el archivo se verifica con SHA256 antes de
# instalarlo, asi no puede cambiar sin que el panel se entere.
UDP_BIN_URL=https://raw.githubusercontent.com/Rerechan02/UDP/d0ebcc4b65a4ac3dffc3739df402a36d7297ef08/bin/udp-custom-linux-amd64
UDP_BIN_SHA256=2a1b5584c7947feb5a02e847e09795751024f63ce7137a353c2b9c2a4282d636

SSH_PORT=$(awk 'tolower($1)=="port"{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
SSH_PORT=${SSH_PORT:-22}

OVPN_URL=https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
WG_URL=https://raw.githubusercontent.com/angristan/wireguard-install/master/wireguard-install.sh
V2_INSTALL_URL=https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh
BADVPN_REPO=https://github.com/ambrop72/badvpn.git
DNSTT_REPO=https://www.bamsoftware.com/git/dnstt.git
GO_VERSION=1.22.5

declare -A SVC=(
  [ssh]=ssh
  [dropbear]=vps-dropbear
  [ssl]=vps-stunnel
  [badvpn]=vps-badvpn
  [ws]=vps-ws
  [squid]=squid
  [v2ray]=v2ray
  [udp]=udp-custom
  [slowdns]=vps-slowdns
  [openvpn]=openvpn-server@server
  [wireguard]=wg-quick@wg0
)
declare -A INST=(
  [dropbear]=inst_dropbear
  [ssl]=inst_ssl
  [badvpn]=inst_badvpn
  [ws]=inst_ws
  [squid]=inst_squid
  [v2ray]=inst_v2ray
  [udp]=inst_udp
  [slowdns]=inst_slowdns
)
PROTO_KEYS=(dropbear ssl badvpn ws squid v2ray udp slowdns openvpn wireguard)
PROTO_NAMES=("DROPBEAR" "SSL" "BADVPN" "WEBSOCKET" "SQUID"
             "V2RAY" "UDP CUSTOM" "SLOWDNS" "OPENVPN" "WIREGUARD")

# ------------------------------ Interfaz ------------------------------
# Todo el aspecto visual esta en este bloque. Todas las pantallas siguen
# el mismo estilo:
#   - lineas "=" rojas arriba y abajo de cada titulo
#   - menus con el formato "[1] > OPCION" y estados [ON] / [OFF]
#   - amarillo = titulos, verde = activo o correcto, rojo = apagado o peligro
# Solo se usan caracteres ASCII: no hay emojis ni simbolos especiales.

ANCHO=52       # ancho de las lineas (las columnas de datos estan pensadas para este ancho)
FW=12          # ancho de las etiquetas de field() (algunas pantallas lo cambian)
VL=0           # largo visible del ultimo texto medido con vlen()

init_ui() {   # colores: solo si la salida es una terminal (VPSPANEL_COLOR=1 los fuerza)
  if [[ ( -t 1 || -n ${VPSPANEL_COLOR:-} ) && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    RST=$'\e[0m'
    RED=$'\e[1;31m'; GRN=$'\e[1;32m'; YEL=$'\e[1;33m'; BLU=$'\e[1;94m'
    MAG=$'\e[1;35m'; WHT=$'\e[1;37m'; GRY=$'\e[90m'
    BTN_GRAY=$'\e[30;47m'; BTN_RED=$'\e[1;37;41m'; BTN_BLUE=$'\e[1;37;44m'   # botones con fondo
  else
    RST=''; RED=''; GRN=''; YEL=''; BLU=''; MAG=''; WHT=''; GRY=''
    BTN_GRAY=''; BTN_RED=''; BTN_BLUE=''
  fi
  EQ=$(rep = "$ANCHO"); DASH=$(rep - "$ANCHO")
}

rep()  { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }   # repite un caracter n veces
vlen() { local s=${1//$'\e['*([0-9;])m/}; VL=${#s}; }                      # largo visible (sin colores)
cls()  { [[ -t 1 ]] && printf '\e[H\e[2J\e[3J'; return 0; }                # limpia la pantalla

# ---- Lineas y titulos ------------------------------------------------
line_eq()   { printf '%s%s%s\n' "$RED" "$EQ" "$RST"; }     # ====================
line_dash() { printf '%s%s%s\n' "$GRY" "$DASH" "$RST"; }   # --------------------

center() {   # texto [color]  ->  texto centrado en la linea
  local pad=$(( (ANCHO - ${#1}) / 2 ))
  (( pad < 0 )) && pad=0
  printf '%*s%s%s%s\n' "$pad" '' "${2:-$WHT}" "$1" "$RST"
}

title()      { line_eq; center "$1" "${2:-$YEL}"; line_eq; }   # barra, titulo, barra
sub_header() { cls; title "$1"; }                              # pantalla nueva con titulo

section() {   # texto  ->  ============ TEXTO ============
  local n=$(( ANCHO - ${#1} - 2 )) l r
  (( n < 2 )) && n=2
  l=$(( n / 2 )); r=$(( n - l ))
  printf '%s%s%s %s %s%s%s\n' "$RED" "$(rep = "$l")" "$YEL" "$1" "$RED" "$(rep = "$r")" "$RST"
}

# ---- Menus -----------------------------------------------------------
item() {   # numero texto [color]  ->  " [1] > TEXTO"
  printf ' %s%4s%s %s>%s %s%s%s\n' "$GRN" "[$1]" "$RST" "$RED" "$RST" "${3:-$WHT}" "$2" "$RST"
}

onoff() {   # comando [args]  ->  [ON] verde si el comando tiene exito, [OFF] rojo si no
  if "$@"; then printf '%s%-5s%s' "$GRN" '[ON]' "$RST"; else printf '%s%-5s%s' "$RED" '[OFF]' "$RST"; fi
}

item_on() {   # numero texto comando [args]  ->  opcion con su estado al final
  local n=$1 t=$2; shift 2
  item "$n" "$(printf '%-30s' "$t")$(onoff "$@")"
}

menu_end() {   # [texto]  ->  pie de los submenus con el boton [0] > VOLVER
  line_eq
  item 0 " ${1:-VOLVER} " "$BTN_RED"
  line_eq
}

# ---- Datos en columnas -----------------------------------------------
kv()    { printf '%s%-6s%s %s%s%s' "$BLU" "$1" "$RST" "${3:-$WHT}" "$2" "$RST"; }           # ETIQUETA valor [color]
pcell() { printf '%s%-11s%s %s%-5s%s' "$RED" "$1:" "$RST" "$GRN" "$2" "$RST"; }             # ETIQUETA: puerto
field() { printf ' %s%-*s%s %s%s%s\n' "$YEL" "$FW" "$1" "$RST" "${3:-$YEL}" "$2" "$RST"; }  # ETIQUETA valor [color]

row() {   # celda1 [celda2 [celda3]]  ->  celdas en columnas fijas (de 27 y 13 caracteres)
  local out=" $1" sp n
  if [[ -n ${2:-} ]]; then
    vlen "$1"; n=$(( 27 - VL )); (( n < 1 )) && n=1
    printf -v sp '%*s' "$n" ''; out+=$sp$2
    if [[ -n ${3:-} ]]; then
      vlen "$2"; n=$(( 13 - VL )); (( n < 1 )) && n=1
      printf -v sp '%*s' "$n" ''; out+=$sp$3
    fi
  fi
  printf '%s\n' "$out"
}

# ---- Mensajes y entrada ----------------------------------------------
msg()  { printf ' %s%-7s%s %s\n' "$1" "$2" "$RST" "$3"; }   # color etiqueta texto
info() { msg "$BLU" '[INFO]'  "$*"; }
ok()   { msg "$GRN" '[OK]'    "$*"; }
warn() { msg "$YEL" '[AVISO]' "$*"; }
err()  { msg "$RED" '[ERROR]' "$*" >&2; }

pause() {
  local t='>> Presione enter para continuar <<' _
  printf '\n%*s%s%s%s' $(( (ANCHO - ${#t}) / 2 )) '' "$YEL" "$t" "$RST"
  read -r _
}

rd() { local p=$1; shift; read -rp " ${YEL}${p}${RST}" "$@"; }   # pregunta: rd "Texto: " variable

ask() {   # variable  ->  pide la opcion del menu (los numeros se normalizan: 01 pasa a 1)
  local r
  printf ' %sSeleccione una Opcion:%s ' "$YEL" "$RST"
  read -r r || return 1
  [[ $r =~ ^[0-9]+$ ]] && r=$(( 10#$r ))
  printf -v "$1" '%s' "$r"
}

spin() {   # mensaje comando [args...]  ->  ejecuta el comando mostrando "Mensaje..." animado
  local text=$1 pid i=0 rc; shift
  local -a dots=('   ' '.  ' '.. ' '...')
  if [[ ! -t 1 ]]; then info "$text..."; "$@" >/dev/null 2>&1 </dev/null; return $?; fi
  "$@" >/dev/null 2>&1 </dev/null &
  pid=$!
  printf '\e[?25l'
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r %s%-7s%s %s%s' "$BLU" '[INFO]' "$RST" "$text" "${dots[i % 4]}"
    i=$(( i + 1 )); sleep 0.3
  done
  wait "$pid"; rc=$?
  printf '\r\e[K\e[?25h'
  return $rc
}

# ------------------------------ Utilidades ----------------------------
init_fs() {
  mkdir -p "$BASE"
  touch "$USERDB" "$V2DB"
  chmod 600 "$USERDB" "$V2DB"
}

init_env() {
  IP=${VPSPANEL_IP:-$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')}
  OS_NAME=$(grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2)
  OS_NAME=${OS_NAME:-Linux}
  OS_NAME=${OS_NAME% \(*}; OS_NAME=${OS_NAME/GNU\/Linux /}   # "Debian GNU/Linux 12 (bookworm)" -> "Debian 12"
}

preflight() {
  [[ $EUID -eq 0 ]] || { echo "Ejecuta como root."; exit 1; }
  command -v systemctl >/dev/null 2>&1 || { echo "Se requiere systemd."; exit 1; }
}

apt_i() { spin "Instalando $*" apt-get install -y -qq -o DPkg::Lock::Timeout=120 "$@"; }

vps_name() { cat "$NAME_F" 2>/dev/null; }

# Vista del panel: el nombre, los datos del servidor y la lista de servicios se pueden ocultar.
is_hidden()   { grep -qx "$1" "$HIDE_F" 2>/dev/null; }            # name | server | services
toggle_hide() { if is_hidden "$1"; then sed -i "/^$1\$/d" "$HIDE_F"; else echo "$1" >> "$HIDE_F"; fi; }
is_shown()    { ! is_hidden "$1"; }                                # lo contrario de is_hidden

# ----------------------- Funciones base (originales) ------------------
is_on() {
  case $1 in
    openvpn) systemctl is-active --quiet openvpn-server@server || systemctl is-active --quiet openvpn@server ;;
    *) systemctl is-active --quiet "${SVC[$1]}" ;;
  esac
}


get_host() { local d; d=$(cat "$DOMAIN_F" 2>/dev/null); echo "${d:-$IP}"; }

valid_name() { [[ $1 =~ ^[a-z_][a-z0-9_-]{2,30}$ ]]; }

rand_pass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10; }

port_busy() { ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .; }

need_port() { # clave puerto
  is_on "$1" && return 0
  if port_busy "$2"; then
    err "El puerto $2 ya esta en uso por: $(ss -H -ltnp "sport = :$2" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1)"
    return 1
  fi
}

fw_open() { # puerto protocolo
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$1/$2" >/dev/null 2>&1
  fi
  return 0
}

verify() { # clave nombre
  sleep 1
  if is_on "$1"; then ok "${2:-$1} activo"
  else err "${2:-$1} no inicio. Revisa: journalctl -u ${SVC[$1]} -n 30"; return 1; fi
}

mkunit() { # nombre descripcion exec [directivas extra de [Service]]
  local name=$1 desc=$2 exec=$3 extra=${4:-}
  {
    echo "[Unit]"
    echo "Description=$desc"
    echo "After=network-online.target"
    echo "Wants=network-online.target"
    echo
    echo "[Service]"
    echo "Type=simple"
    [[ -n $extra ]] && echo "$extra"
    echo "ExecStart=$exec"
    echo "Restart=always"
    echo "RestartSec=2"
    echo "LimitNOFILE=65535"
    echo
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } > "/etc/systemd/system/$name.service"
  systemctl daemon-reload
  systemctl enable "$name" >/dev/null 2>&1
  systemctl restart "$name"
}

fetch_run() { # url [args...]
  local f; f=$(mktemp)
  if ! curl -fsSL "$1" -o "$f"; then err "No se pudo descargar $1"; rm -f "$f"; return 1; fi
  shift
  bash "$f" "$@"
  local rc=$?
  rm -f "$f"
  return $rc
}

db_set() { # usuario campo valor  (users.db)
  local t; t=$(mktemp)
  U="$1" F="$2" V="$3" awk -F'|' -v OFS='|' '$1==ENVIRON["U"]{$(ENVIRON["F"]+0)=ENVIRON["V"]}1' "$USERDB" > "$t"
  cat "$t" > "$USERDB"; rm -f "$t"
}

install_helpers() {
  cat > /usr/local/bin/vps-limiter <<'EOF'
#!/bin/bash
# Limita conexiones simultaneas por usuario (SSH/Dropbear)
DB=/etc/vpspanel/users.db
[[ -s $DB ]] || exit 0
while IFS='|' read -r u p e l; do
  [[ -n $u && ${l:-0} -gt 0 ]] || continue
  mapfile -t pids < <(ps -u "$u" -o pid=,etimes=,comm= 2>/dev/null \
    | awk '$3=="sshd"||$3=="dropbear"{print $2" "$1}' | sort -rn | awk '{print $2}')
  if (( ${#pids[@]} > l )); then
    kill -9 "${pids[@]:l}" 2>/dev/null
  fi
done < "$DB"
EOF

  cat > /usr/local/bin/vps-cleanup <<'EOF'
#!/bin/bash
# Elimina cuentas SSH y V2Ray expiradas
DB=/etc/vpspanel/users.db
V2DB=/etc/vpspanel/v2ray.db
V2CFG=/usr/local/etc/v2ray/config.json
today=$(date +%F)
if [[ -s $DB ]]; then
  while IFS='|' read -r u p e l; do
    [[ -n $u && $e < $today ]] || continue
    pkill -KILL -u "$u" 2>/dev/null
    userdel -f "$u" 2>/dev/null
    sed -i "/^$u|/d" "$DB"
  done < "$DB"
fi
if [[ -s $V2DB && -f $V2CFG ]]; then
  changed=0
  while IFS='|' read -r n id e; do
    [[ -n $n && $e < $today ]] || continue
    t=$(mktemp)
    if jq --arg em "$n" '.inbounds[0].settings.clients |= map(select(.email != $em))' "$V2CFG" > "$t"; then
      cat "$t" > "$V2CFG"
    fi
    rm -f "$t"
    sed -i "/^$n|/d" "$V2DB"
    changed=1
  done < "$V2DB"
  (( changed )) && systemctl restart v2ray
fi
exit 0
EOF
  chmod 755 /usr/local/bin/vps-limiter /usr/local/bin/vps-cleanup

  cat > /etc/cron.d/vpspanel <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root /usr/local/bin/vps-limiter >/dev/null 2>&1
5 0 * * * root /usr/local/bin/vps-cleanup >/dev/null 2>&1
EOF
  chmod 644 /etc/cron.d/vpspanel
  systemctl enable --now cron >/dev/null 2>&1
}

cfg_ssh() {
  mkdir -p /etc/ssh/sshd_config.d
  grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d' /etc/ssh/sshd_config \
    || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  cat > /etc/ssh/sshd_config.d/00-vpspanel.conf <<EOF
PasswordAuthentication yes
AllowTcpForwarding yes
PermitTunnel yes
UseDNS no
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 3
MaxSessions 100
MaxStartups 100:30:200
Banner $(banner_path)
EOF
  if sshd -t 2>/dev/null; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
  else
    err "Configuracion SSH invalida; se revierte."
    rm -f /etc/ssh/sshd_config.d/00-vpspanel.conf
  fi
}

# ------------------------------ Instaladores --------------------------
mk_selfsigned() { # CN
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=${1:-localhost}" \
    -keyout "$BASE/key.tmp" -out "$BASE/crt.tmp" >/dev/null 2>&1 \
    && cat "$BASE/crt.tmp" "$BASE/key.tmp" > "$CERT"
  rm -f "$BASE/key.tmp" "$BASE/crt.tmp"
  chmod 600 "$CERT"
  is_on ssl && systemctl restart vps-stunnel
  return 0
}

inst_dropbear() {
  ensure_base; need_port dropbear "$PORT_DROPBEAR" || return 1
  info "Instalando Dropbear..."
  apt_i dropbear || { err "Fallo al instalar dropbear"; return 1; }
  systemctl disable --now dropbear >/dev/null 2>&1
  mkdir -p /etc/dropbear
  unit_dropbear
}

unit_dropbear() {   # servicio con el puerto y el banner actuales
  mkunit vps-dropbear "Dropbear SSH" \
    "$(command -v dropbear) -F -E -R -p $PORT_DROPBEAR $(banner_opt) -K 30"
  fw_open "$PORT_DROPBEAR" tcp
  verify dropbear Dropbear
}

inst_ssl() {
  ensure_base; need_port ssl "$PORT_SSL" || return 1
  info "Instalando SSL (stunnel)..."
  apt_i stunnel4 || { err "Fallo al instalar stunnel4"; return 1; }
  systemctl disable --now stunnel4 >/dev/null 2>&1
  [[ -s $CERT ]] || mk_selfsigned "$(get_host)"
  conf_ssl
}

conf_ssl() {   # configuracion y servicio con el puerto actual
  cat > "$BASE/stunnel.conf" <<EOF
foreground = yes
pid =
cert = $CERT
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssl-ssh]
accept = $PORT_SSL
connect = 127.0.0.1:$SSH_PORT
EOF
  mkunit vps-stunnel "Stunnel SSL a SSH" "/usr/bin/stunnel4 $BASE/stunnel.conf"
  fw_open "$PORT_SSL" tcp
  verify ssl "SSL (stunnel)"
}

inst_badvpn() {
  ensure_base; need_port badvpn "$PORT_BADVPN" || return 1
  info "Compilando BadVPN-UDPGW..."
  apt_i build-essential cmake git || { err "Fallo al instalar dependencias de compilacion"; return 1; }
  local t rc; t=$(mktemp -d)
  git clone -q --depth 1 "$BADVPN_REPO" "$t/src" \
    && mkdir "$t/build" \
    && (cd "$t/build" \
        && cmake ../src -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null 2>&1 \
        && make -j"$(nproc)" >/dev/null 2>&1) \
    && install -m755 "$t/build/udpgw/badvpn-udpgw" /usr/local/bin/badvpn-udpgw
  rc=$?
  rm -rf "$t"
  (( rc == 0 )) || { err "Fallo al compilar badvpn-udpgw"; return 1; }
  unit_badvpn
}

unit_badvpn() {
  mkunit vps-badvpn "BadVPN UDPGW" \
    "/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:$PORT_BADVPN --max-clients 1000 --max-connections-for-client 10"
  verify badvpn BadVPN-UDPGW
}

inst_ws() {
  ensure_base; need_port ws "$PORT_WS" || return 1
  info "Instalando proxy WebSocket..."
  cat > /usr/local/bin/vps-ws.py <<'PYEOF'
#!/usr/bin/env python3
"""Proxy HTTP-Upgrade/WebSocket -> TCP local (SSH/Dropbear) para apps de tunel.

Uso: vps-ws.py <puerto_escucha> <puerto_destino_por_defecto> [otros_puertos_permitidos...]
El destino se puede cambiar con la cabecera "X-Real-Host: 127.0.0.1:<puerto>"
(solo localhost y solo los puertos permitidos).
"""
import asyncio
import socket
import sys

LISTEN_PORT = int(sys.argv[1])
DEFAULT_PORT = int(sys.argv[2])
ALLOWED_PORTS = {int(p) for p in sys.argv[2:]}
ALLOWED_HOSTS = {"127.0.0.1", "localhost"}
BUF = 65536
RESPONSE = (b"HTTP/1.1 101 Switching Protocols\r\n"
            b"Upgrade: websocket\r\n"
            b"Connection: Upgrade\r\n\r\n")


def pick_target(data, current):
    host, port = current
    for line in data.split(b"\r\n"):
        if line.lower().startswith(b"x-real-host:"):
            val = line.split(b":", 1)[1].strip().decode("ascii", "ignore")
            h, sep, p = val.rpartition(":")
            if sep and p.isdigit():
                host, port = h, int(p)
            elif val:
                host = val
            break
    if host not in ALLOWED_HOSTS or port not in ALLOWED_PORTS:
        return ("127.0.0.1", DEFAULT_PORT)
    return (host, port)


async def pipe(src, dst):
    try:
        while True:
            chunk = await src.read(BUF)
            if not chunk:
                break
            dst.write(chunk)
            await dst.drain()
    except Exception:
        pass
    finally:
        try:
            dst.close()
        except Exception:
            pass


async def handle(reader, writer):
    sock = writer.get_extra_info("socket")
    if sock is not None:
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
    remote_writer = None
    target = ("127.0.0.1", DEFAULT_PORT)
    try:
        try:
            data = await asyncio.wait_for(reader.read(BUF), 3.0)
        except asyncio.TimeoutError:
            data = b""          # cliente SSH directo: espera el banner del servidor
        else:
            if not data:
                return

        rounds = 0
        while data and not data.startswith(b"SSH-") and rounds < 6:
            target = pick_target(data, target)
            writer.write(RESPONSE)
            await writer.drain()
            rounds += 1
            try:
                data = await asyncio.wait_for(reader.read(BUF), 1.0)
            except asyncio.TimeoutError:
                data = b""
            else:
                if not data:
                    return
        if data and not data.startswith(b"SSH-"):
            data = b""

        r_reader, remote_writer = await asyncio.open_connection(*target)
        if data:
            remote_writer.write(data)
            await remote_writer.drain()
        await asyncio.gather(pipe(reader, remote_writer), pipe(r_reader, writer))
    except Exception:
        pass
    finally:
        for w in (writer, remote_writer):
            if w is not None:
                try:
                    w.close()
                except Exception:
                    pass


async def main():
    server = await asyncio.start_server(handle, "0.0.0.0", LISTEN_PORT,
                                        backlog=1024, reuse_address=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
PYEOF
  chmod 755 /usr/local/bin/vps-ws.py
  unit_ws
}

unit_ws() {
  mkunit vps-ws "Proxy WebSocket a SSH" \
    "$(command -v python3) /usr/local/bin/vps-ws.py $PORT_WS $SSH_PORT $PORT_DROPBEAR"
  fw_open "$PORT_WS" tcp
  verify ws "WebSocket"
}

inst_squid() {
  ensure_base; need_port squid "$PORT_SQUID" || return 1
  info "Instalando Squid..."
  apt_i squid || { err "Fallo al instalar squid"; return 1; }
  conf_squid
}

conf_squid() {
  local ips; ips="127.0.0.1 $IP $(hostname -I)"
  cat > /etc/squid/squid.conf <<EOF
http_port $PORT_SQUID
visible_hostname vps-panel
via off
forwarded_for delete
cache deny all
access_log none
acl self_dst dst $ips
acl tunnel_ports port $SSH_PORT $PORT_DROPBEAR $PORT_WS
http_access allow self_dst tunnel_ports
http_access deny all
EOF
  systemctl enable squid >/dev/null 2>&1
  systemctl restart squid
  fw_open "$PORT_SQUID" tcp
  verify squid Squid
}

inst_v2ray() {
  ensure_base; need_port v2ray "$PORT_V2RAY" || return 1
  info "Instalando V2Ray..."
  fetch_run "$V2_INSTALL_URL" >/dev/null 2>&1 || { err "Fallo al instalar V2Ray"; return 1; }
  [[ -x /usr/local/bin/v2ray ]] || { err "No se encontro /usr/local/bin/v2ray"; return 1; }
  mkdir -p "$(dirname "$V2CFG")"
  cat > "$V2CFG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT_V2RAY,
      "listen": "0.0.0.0",
      "protocol": "vmess",
      "settings": { "clients": [] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$V2PATH" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
  chmod 644 "$V2CFG"
  systemctl enable v2ray >/dev/null 2>&1
  systemctl restart v2ray
  fw_open "$PORT_V2RAY" tcp
  verify v2ray V2Ray
}

inst_slowdns() {
  ensure_base
  local ns ga ipt=/usr/sbin/iptables
  rd "NameServer (NS) del dominio, ej. ns.midominio.com: " ns
  [[ $ns =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { err "NameServer invalido"; return 1; }
  case $(uname -m) in
    x86_64)  ga=amd64 ;;
    aarch64) ga=arm64 ;;
    *) err "Arquitectura no soportada"; return 1 ;;
  esac
  info "Compilando dnstt-server (Go $GO_VERSION)..."
  if [[ ! -x /usr/local/go/bin/go ]]; then
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ga}.tar.gz" -o /tmp/go.tgz \
      || { err "No se pudo descargar Go"; return 1; }
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tgz
    rm -f /tmp/go.tgz
  fi
  rm -rf /tmp/dnstt
  git clone -q "$DNSTT_REPO" /tmp/dnstt || { err "No se pudo clonar dnstt"; return 1; }
  (cd /tmp/dnstt/dnstt-server && /usr/local/go/bin/go build -o /usr/local/bin/dnstt-server .) \
    || { err "Fallo al compilar dnstt-server"; rm -rf /tmp/dnstt; return 1; }
  rm -rf /tmp/dnstt

  mkdir -p "$BASE/slowdns"
  [[ -s $BASE/slowdns/server.key ]] || dnstt-server -gen-key \
    -privkey-file "$BASE/slowdns/server.key" -pubkey-file "$BASE/slowdns/server.pub" >/dev/null
  echo "$ns" > "$BASE/slowdns/ns"

  unit_slowdns
}

unit_slowdns() {   # usa el NameServer guardado
  local ns ipt=/usr/sbin/iptables
  ns=$(<"$BASE/slowdns/ns")
  mkunit vps-slowdns "SlowDNS (dnstt)" \
    "/usr/local/bin/dnstt-server -udp :$PORT_SLOWDNS -privkey-file $BASE/slowdns/server.key $ns 127.0.0.1:$SSH_PORT" \
    "ExecStartPre=-$ipt -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports $PORT_SLOWDNS
ExecStartPre=$ipt -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports $PORT_SLOWDNS
ExecStopPost=-$ipt -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports $PORT_SLOWDNS"
  fw_open 53 udp; fw_open "$PORT_SLOWDNS" udp
  verify slowdns SlowDNS || return 1
  info "NameServer: $ns"
  info "Llave publica: $(cat "$BASE/slowdns/server.pub")"
  info "Registros DNS: A ns1.<dominio> -> $IP  |  NS $ns -> ns1.<dominio>"
}

# ------------------------- Cuentas SSH (originales) -------------------
ssh_create() {
  local u p d l exp
  rd "Usuario: " u
  valid_name "$u" || { err "Usuario invalido (3-31 caracteres: a-z 0-9 _ -)"; return 1; }
  if id "$u" >/dev/null 2>&1; then err "El usuario ya existe"; return 1; fi
  rd "Contrasena [aleatoria]: " p; p=${p:-$(rand_pass)}
  [[ $p != *"|"* && -n $p ]] || { err "La contrasena no puede contener '|'"; return 1; }
  rd "Dias de validez [30]: " d; d=${d:-30}
  [[ $d =~ ^[0-9]+$ ]] || { err "Dias invalidos"; return 1; }
  rd "Limite de conexiones [1]: " l; l=${l:-1}
  [[ $l =~ ^[0-9]+$ ]] || { err "Limite invalido"; return 1; }
  exp=$(date -d "+$d days" +%F)
  useradd -M -s /bin/false -e "$exp" "$u" || { err "No se pudo crear el usuario"; return 1; }
  echo "$u:$p" | chpasswd
  echo "$u|$p|$exp|$l" >> "$USERDB"
  show_ssh_info "$u" "$p" "$exp" "$l"
}

# Dias que faltan para una fecha AAAA-MM-DD (negativo si ya vencio).
today_s() { date -u -d "$(date +%F)" +%s; }   # hoy a las 00:00, en segundos

days_left() {   # fecha hoy_en_segundos
  local s
  s=$(date -u -d "$1" +%s 2>/dev/null) || { echo 0; return; }
  echo $(( (s - $2) / 86400 ))
}

# Tabla de cuentas con numero, vencimiento y dias que faltan (en rojo: vencidas;
# en amarillo: faltan 3 dias o menos). Deja los nombres en ACCT[].
# El archivo puede ser users.db (SSH: con clave y limite) o v2ray.db (V2Ray).
acct_table() {   # archivo
  local db=$1 kind=v2 n p e l d c now
  [[ $db == "$USERDB" ]] && kind=ssh
  ACCT=()
  now=$(today_s)
  if [[ $kind == ssh ]]; then
    printf ' %s%3s  %-16s %-10s %-8s %4s %3s%s\n' "$WHT" N USUARIO CLAVE FECHA DIAS LIM "$RST"
  else
    printf ' %s%3s  %-20s %-8s %4s%s\n' "$WHT" N CUENTA FECHA DIAS "$RST"
  fi
  line_dash
  while IFS='|' read -r n p e l; do
    [[ -n $n ]] || continue
    ACCT+=("$n")
    d=$(days_left "$e" "$now")
    if (( d < 0 )); then c=$RED; elif (( d <= 3 )); then c=$YEL; else c=$GRN; fi
    if [[ $kind == ssh ]]; then
      printf ' %s%3d)%s %-16.16s %-10.10s %s%-8s %4d%s %s%3s%s\n' \
        "$GRN" "${#ACCT[@]}" "$RST" "$n" "$p" "$c" "${e:8:2}/${e:5:2}/${e:2:2}" "$d" "$RST" "$YEL" "${l:--}" "$RST"
    else
      printf ' %s%3d)%s %-20.20s %s%-8s %4d%s\n' \
        "$GRN" "${#ACCT[@]}" "$RST" "$n" "$c" "${e:8:2}/${e:5:2}/${e:2:2}" "$d" "$RST"
    fi
  done < "$db"
}

# Muestra la tabla y deja la cuenta elegida en PICK (por numero o por nombre).
# Devuelve 3 si se cancela (el menu no pide ENTER en ese caso).
pick_account() {   # archivo
  local db=$1 sel n
  PICK=
  grep -q '^[^|]' "$db" 2>/dev/null || { warn "No hay cuentas creadas"; return 1; }
  acct_table "$db"
  printf '\n %sTOTAL: %d   (en rojo: vencidas)%s\n\n' "$BLU" "${#ACCT[@]}" "$RST"
  rd "Numero o nombre (0 = cancelar): " sel || return 3
  sel=${sel//[[:space:]]/}
  [[ -n $sel && $sel != 0 ]] || return 3
  if [[ $sel =~ ^[0-9]+$ ]]; then
    sel=$(( 10#$sel ))
    (( sel == 0 )) && return 3
    (( sel <= ${#ACCT[@]} )) || { err "El numero $sel no esta en la lista"; return 1; }
    PICK=${ACCT[sel-1]}
  else
    for n in "${ACCT[@]}"; do [[ $n == "$sel" ]] && { PICK=$n; break; }; done
    [[ -n $PICK ]] || { err "Cuenta no encontrada"; return 1; }
  fi
  return 0
}

ssh_delete() {
  local u c
  pick_account "$USERDB" || return $?
  u=$PICK
  valid_name "$u" && grep -q "^${u}|" "$USERDB" || { err "Usuario no encontrado"; return 1; }
  rd "Eliminar la cuenta $u? (s/N): " c
  [[ $c == [sS]* ]] || return 3
  pkill -KILL -u "$u" 2>/dev/null
  userdel -f "$u" 2>/dev/null
  sed -i "/^${u}|/d" "$USERDB"
  ok "Usuario $u eliminado"
}

ssh_renew() {
  local u d exp
  pick_account "$USERDB" || return $?
  u=$PICK
  valid_name "$u" && grep -q "^${u}|" "$USERDB" || { err "Usuario no encontrado"; return 1; }
  rd "Dias desde hoy para $u [30]: " d; d=${d:-30}
  [[ $d =~ ^[0-9]+$ ]] || { err "Dias invalidos"; return 1; }
  exp=$(date -d "+$d days" +%F)
  usermod -e "$exp" "$u" && db_set "$u" 3 "$exp" && ok "$u vence el $exp"
}

ssh_passwd() {
  local u p
  rd "Usuario: " u
  valid_name "$u" && grep -q "^${u}|" "$USERDB" || { err "Usuario no encontrado"; return 1; }
  rd "Nueva contrasena [aleatoria]: " p; p=${p:-$(rand_pass)}
  [[ $p != *"|"* && -n $p ]] || { err "La contrasena no puede contener '|'"; return 1; }
  echo "$u:$p" | chpasswd && db_set "$u" 2 "$p" && ok "Nueva contrasena de $u: $p"
}

# ------------------------- Cuentas V2Ray (originales) -----------------
v2_edit() {
  local t; t=$(mktemp)
  if jq "$@" "$V2CFG" > "$t"; then cat "$t" > "$V2CFG"; rm -f "$t"
  else rm -f "$t"; err "No se pudo editar $V2CFG"; return 1; fi
}

v2_link() { # nombre uuid
  local j
  j=$(jq -nc --arg ps "$1" --arg add "$(get_host)" --arg id "$2" --arg port "$PORT_V2RAY" --arg path "$V2PATH" \
    '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",net:"ws",type:"none",host:"",path:$path,tls:""}')
  echo "vmess://$(printf '%s' "$j" | base64 -w0)"
}

v2_need() { [[ -f $V2CFG ]] || { err "V2Ray no esta instalado (Protocolos > V2RAY)."; return 1; }; }


v2_delete() {
  v2_need || return 1
  local n c
  pick_account "$V2DB" || return $?
  n=$PICK
  valid_name "$n" && grep -q "^${n}|" "$V2DB" || { err "Cuenta no encontrada"; return 1; }
  rd "Eliminar la cuenta $n? (s/N): " c
  [[ $c == [sS]* ]] || return 3
  v2_edit --arg em "$n" '.inbounds[0].settings.clients |= map(select(.email != $em))' || return 1
  sed -i "/^${n}|/d" "$V2DB"
  systemctl restart v2ray
  ok "Cuenta $n eliminada"
}

v2_renew() {
  local n d exp t
  pick_account "$V2DB" || return $?
  n=$PICK
  valid_name "$n" && grep -q "^${n}|" "$V2DB" || { err "Cuenta no encontrada"; return 1; }
  rd "Dias desde hoy para $n [30]: " d; d=${d:-30}
  [[ $d =~ ^[0-9]+$ ]] || { err "Dias invalidos"; return 1; }
  exp=$(date -d "+$d days" +%F)
  t=$(mktemp)
  U="$n" V="$exp" awk -F'|' -v OFS='|' '$1==ENVIRON["U"]{$3=ENVIRON["V"]}1' "$V2DB" > "$t"
  cat "$t" > "$V2DB"; rm -f "$t"
  ok "$n vence el $exp"
}

# ------------------------- Protocolos / Herramientas ------------------
proto_action() {
  local k=$1
  case $k in
    openvpn)   fetch_run "$OVPN_URL" ;;
    wireguard) fetch_run "$WG_URL" ;;
    *)
      if is_on "$k"; then
        systemctl disable --now "${SVC[$k]}" >/dev/null 2>&1
        ok "${k^^} detenido"
      elif systemctl cat "${SVC[$k]}" >/dev/null 2>&1; then
        systemctl enable --now "${SVC[$k]}" >/dev/null 2>&1
        verify "$k" "${k^^}"
      else
        "${INST[$k]}"
      fi ;;
  esac
}

# El banner SSH viene DESACTIVADO: solo existe si el archivo $BANNER tiene contenido.
banner_on()   { [[ -s $BANNER ]]; }
banner_path() { if banner_on; then printf '%s' "$BANNER"; else printf 'none'; fi; }
banner_opt()  { banner_on && printf -- '-b %s' "$BANNER"; return 0; }

banner_apply() {   # aplica el estado actual a OpenSSH y a Dropbear
  cfg_ssh
  apply_proto dropbear
  return 0
}

banner_migrate() {   # versiones anteriores creaban un banner con el nombre del VPS
  [[ -s $BANNER && ! -f $BASE/.banner-off ]] || { touch "$BASE/.banner-off"; return 0; }
  local b; b=$(<"$BANNER"); b=${b%$'\n'}
  if [[ $b == "VPS PANEL" || $b == "$(vps_name)" ]]; then
    rm -f "$BANNER"
    [[ -f $BASE/.prep ]] && banner_apply >/dev/null 2>&1
  fi
  touch "$BASE/.banner-off"
}

cfg_banner() {
  ensure_base
  local o l txt
  if banner_on; then
    info "Banner ${GRN}ACTIVADO${RST}. Contenido actual:"; sed 's/^/        /' "$BANNER"
  else
    info "Banner ${RED}DESACTIVADO${RST}"
  fi
  echo
  item 1 "ESCRIBIR O CAMBIAR EL BANNER (LO ACTIVA)"
  item 2 "DESACTIVAR EL BANNER"
  menu_end
  ask o || return 3
  case $o in
    1) echo " Escribe el banner (HTML permitido). Linea vacia para terminar:"
       txt=""
       while IFS= read -r l; do [[ -z $l ]] && break; txt+="$l"$'\n'; done
       [[ -n $txt ]] || { err "Banner vacio"; return 1; }
       printf '%s' "$txt" > "$BANNER"
       banner_apply
       ok "Banner activado" ;;
    2) rm -f "$BANNER"
       banner_apply
       ok "Banner desactivado" ;;
    *) return 3 ;;
  esac
}

cfg_bbr() {
  modprobe tcp_bbr 2>/dev/null
  cat > /etc/sysctl.d/99-vpspanel.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1
  ok "Control de congestion: $(sysctl -n net.ipv4.tcp_congestion_control)"
}

cfg_swap() {
  local s
  rd "Tamano de swap en MB [1024]: " s; s=${s:-1024}
  [[ $s =~ ^[0-9]+$ ]] || { err "Tamano invalido"; return 1; }
  swapoff /swapfile 2>/dev/null; rm -f /swapfile
  fallocate -l "${s}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$s" status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null && swapon /swapfile || { err "No se pudo activar el swap"; return 1; }
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10 >/dev/null
  echo 'vm.swappiness=10' > /etc/sysctl.d/98-vpspanel-swap.conf
  ok "Swap de ${s}MB activo"
}

cfg_cache() {
  sync
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
  apt-get clean >/dev/null 2>&1
  journalctl --vacuum-size=50M >/dev/null 2>&1
  ok "Cache y registros limpiados"
}

cfg_dns() {
  local d1 d2
  rd "DNS primario [1.1.1.1]: " d1; d1=${d1:-1.1.1.1}
  rd "DNS secundario [8.8.8.8]: " d2; d2=${d2:-8.8.8.8}
  if systemctl is-active --quiet systemd-resolved; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNS=%s %s\n' "$d1" "$d2" > /etc/systemd/resolved.conf.d/vpspanel.conf
    systemctl restart systemd-resolved
  else
    chattr -i /etc/resolv.conf 2>/dev/null
    printf 'nameserver %s\nnameserver %s\n' "$d1" "$d2" > /etc/resolv.conf
  fi
  ok "DNS configurados: $d1 $d2"
}

cfg_domain() {
  ensure_base
  local d
  rd "Dominio (vacio = certificado autofirmado con la IP): " d
  if [[ -z $d ]]; then
    rm -f "$DOMAIN_F"
    mk_selfsigned "$IP"
    ok "Certificado autofirmado generado"
    return 0
  fi
  [[ $d =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { err "Dominio invalido"; return 1; }
  apt_i certbot || { err "Fallo al instalar certbot"; return 1; }
  is_on ws && systemctl stop vps-ws
  certbot certonly --standalone -d "$d" --non-interactive --agree-tos --register-unsafely-without-email
  local rc=$?
  systemctl is-enabled --quiet vps-ws 2>/dev/null && systemctl start vps-ws
  (( rc == 0 )) || { err "certbot fallo: verifica que $d apunte a $IP y que el puerto 80 este libre."; return 1; }

  mkdir -p /etc/letsencrypt/renewal-hooks/{pre,post,deploy}
  printf '#!/bin/sh\nsystemctl stop vps-ws 2>/dev/null\nexit 0\n' > /etc/letsencrypt/renewal-hooks/pre/vpspanel.sh
  printf '#!/bin/sh\nsystemctl is-enabled --quiet vps-ws 2>/dev/null && systemctl start vps-ws\nexit 0\n' > /etc/letsencrypt/renewal-hooks/post/vpspanel.sh
  cat > /etc/letsencrypt/renewal-hooks/deploy/vpspanel.sh <<EOF
#!/bin/sh
cat /etc/letsencrypt/live/$d/fullchain.pem /etc/letsencrypt/live/$d/privkey.pem > $CERT
chmod 600 $CERT
systemctl restart vps-stunnel 2>/dev/null
exit 0
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/{pre,post,deploy}/vpspanel.sh
  echo "$d" > "$DOMAIN_F"
  /etc/letsencrypt/renewal-hooks/deploy/vpspanel.sh
  ok "Certificado Let's Encrypt instalado para $d"
}

cfg_root() {
  cat > /etc/ssh/sshd_config.d/01-vpspanel-root.conf <<EOF
PermitRootLogin yes
EOF
  if passwd root; then
    cfg_ssh
    ok "Acceso root por contrasena activado"
  fi
}

restart_services() {
  local k
  for k in ssh "${PROTO_KEYS[@]}"; do
    is_on "$k" && systemctl restart "${SVC[$k]}" && echo "  reiniciado: $k"
  done
  ok "Servicios reiniciados"
}

autostart_on() { grep -q 'vpspanel-autostart' /root/.bashrc 2>/dev/null; }

autostart_enable() {
  autostart_on || echo '[[ $- == *i* && -z "${VPSPANEL_ACTIVE:-}" ]] && vpspanel # vpspanel-autostart' >> /root/.bashrc
}

toggle_autostart() {
  if autostart_on; then
    sed -i '/vpspanel-autostart/d' /root/.bashrc
    ok "Auto-inicio desactivado"
  else
    autostart_enable
    ok "Auto-inicio activado"
  fi
}

autostart_default() {   # primera ejecucion: el auto-inicio queda ACTIVADO
  [[ -f $BASE/.autostart.init ]] && return 0
  if [[ -s $NAME_F ]]; then touch "$BASE/.autostart.init"; return 0; fi   # panel ya en uso: se respeta tu ajuste
  if [[ -x /usr/local/bin/vpspanel ]]; then
    autostart_enable
    touch "$BASE/.autostart.init"
  fi
}

panel_cmd() {   # texto con el que se abre el panel
  if [[ -x /usr/local/bin/vpspanel ]]; then echo vpspanel
  else echo "bash $(readlink -f "$0" 2>/dev/null || echo vps-panel.sh)"; fi
}

show_access() {   # pantalla posterior al primer registro
  local c; c=$(panel_cmd)
  sub_header "REGISTRO COMPLETO"
  if autostart_on; then
    field "AUTO-INICIO:" "ACTIVADO" "$GRN"
    echo " El panel se abre solo al entrar por SSH."
    echo " Si lo desactivas, abrelo con este comando:"
  else
    field "AUTO-INICIO:" "DESACTIVADO" "$RED"
    echo " El panel no se abre solo. Para abrirlo escribe:"
  fi
  echo
  printf ' %s%s%s\n\n' "$YEL" "$c" "$RST"
  echo " Para cambiarlo: Herramientas > Auto-inicio"
  pause
}

# ------------------------------ Desinstalar ---------------------------
uninstall_all() {
  local c s u p
  warn "Se eliminaran el panel y sus servicios."
  warn "Tambien se borraran las cuentas SSH."
  rd "Escribe SI para continuar: " c
  [[ $c == SI ]] || return 0
  while IFS='|' read -r u p _; do
    [[ -n $u ]] || continue
    pkill -KILL -u "$u" 2>/dev/null; userdel -f "$u" 2>/dev/null
  done < "$USERDB"
  for s in vps-dropbear vps-stunnel vps-badvpn vps-ws vps-slowdns udp-custom; do
    systemctl disable --now "$s" >/dev/null 2>&1
    rm -f "/etc/systemd/system/$s.service"
  done
  systemctl disable --now squid v2ray >/dev/null 2>&1
  systemctl daemon-reload
  rm -rf /etc/udp-custom
  rm -f /usr/local/bin/{vps-ws.py,vps-limiter,vps-cleanup,badvpn-udpgw,dnstt-server}
  rm -f /etc/cron.d/vpspanel /etc/sysctl.d/99-vpspanel.conf
  rm -f /etc/ssh/sshd_config.d/00-vpspanel.conf /etc/ssh/sshd_config.d/01-vpspanel-root.conf
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
  autostart_on && sed -i '/vpspanel-autostart/d' /root/.bashrc
  rm -rf "$BASE"
  rm -f /usr/local/bin/vpspanel
  ok "Panel desinstalado (squid y v2ray quedan instalados pero detenidos)."
  exit 0
}


self_install() {
  local me; me=$(readlink -f "$0" 2>/dev/null)
  if [[ -f $me && $me != /usr/local/bin/vpspanel ]]; then
    install -m755 "$me" /usr/local/bin/vpspanel
  fi
}


# ------------------------- Registro del VPS ---------------------------
name_check() {   # nombre -> 0 si sirve; si no, deja el motivo en MSG
  local t=$1 re='^[A-Za-z0-9._ -]+$'
  if [[ -z $t ]]; then MSG="Escribe un nombre."; return 1; fi
  if ! [[ $t =~ $re ]]; then MSG="Usa solo letras, numeros, espacio, punto, guion y guion bajo."; return 1; fi
  if (( ${#t} > NAME_MAX )); then MSG="Es muy largo: maximo $NAME_MAX caracteres."; return 1; fi
  return 0
}

register_vps() {
  local cur name ans first=0 w
  cur=$(vps_name); [[ -n $cur ]] || first=1
  while :; do
    sub_header "REGISTRO DE VPS"
    if (( first )); then
      echo " Este nombre se muestra como titulo del panel."
    else
      echo " Nombre actual: $cur"
      echo " Presiona ENTER para conservarlo."
    fi
    echo " Maximo $NAME_MAX caracteres (letras, numeros, . _ -)"
    echo
    rd "Nombre del VPS: " name || { err "No hay entrada disponible"; return 1; }
    read -ra w <<< "$name"; name="${w[*]:-}"            # quita espacios sobrantes
    if [[ -z $name && -n $cur ]]; then return 0; fi
    if ! name_check "$name"; then
      warn "$MSG"; sleep 2; continue
    fi
    sub_header "REGISTRO DE VPS"
    center "=====>>>> ${name^^} <<<<=====" "$YEL"
    echo
    rd "Confirmar este nombre? [S/n]: " ans || return 1
    [[ $ans == [nN]* ]] && continue
    printf '%s\n' "$name" > "$NAME_F"
    [[ -s $REG_F ]] || date +%d/%m/%Y > "$REG_F"
    echo
    ok "VPS registrado como $name"
    sleep 1
    (( first )) && show_access
    return 0
  done
}

default_name() {   # sin interaccion: usa el hostname
  [[ -s $NAME_F ]] && return 0
  local h; h=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9._-' | cut -c1-$NAME_MAX)
  printf '%s\n' "${h:-VPS}" > "$NAME_F"
  [[ -s $REG_F ]] || date +%d/%m/%Y > "$REG_F"
}

cfg_vpsname() { register_vps; }

# ------------------------- Preparacion del sistema --------------------
ensure_base() {
  [[ -f $BASE/.prep ]] && return 0
  info "Preparando el sistema..."
  spin "Actualizando lista de paquetes" apt-get update -qq
  apt_i curl wget jq git unzip tar openssl iptables ca-certificates cron procps iproute2 python3
  grep -qx /bin/false /etc/shells || echo /bin/false >> /etc/shells
  install_helpers
  cfg_ssh
  touch "$BASE/.prep"
}

# ------------------------------ UDP Custom ----------------------------
# Instalacion 100% automatica: descarga el binario, lo verifica, crea la
# configuracion y el servicio. No hay que copiar ni pegar ningun enlace.
inst_udp() {
  ensure_base
  if ! is_on udp && ss -H -lun "sport = :$PORT_UDP" 2>/dev/null | grep -q .; then
    err "El puerto UDP $PORT_UDP ya esta en uso"; return 1
  fi
  case $(uname -m) in
    x86_64|amd64) ;;
    *) err "UDP Custom solo tiene binario para x86_64 (este servidor es $(uname -m))"; return 1 ;;
  esac

  local dir=/etc/udp-custom tmp url=${UDPCUSTOM_URL:-$UDP_BIN_URL} sum excl
  tmp=$(mktemp)
  if ! spin "Descargando UDP Custom" \
       curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 -o "$tmp" "$url"; then
    err "No se pudo descargar UDP Custom. Revisa la conexion del VPS."
    rm -f "$tmp"; return 1
  fi
  if [[ $(head -c4 "$tmp" | od -An -tx1 | tr -d ' \n') != 7f454c46 ]]; then
    err "El archivo descargado no es un ejecutable valido."
    rm -f "$tmp"; return 1
  fi
  if [[ -z $UDPCUSTOM_URL ]]; then
    sum=$(sha256sum "$tmp" | awk '{print $1}')
    if [[ $sum != "$UDP_BIN_SHA256" ]]; then
      err "La verificacion SHA256 fallo: el archivo no es el esperado. No se instalo."
      rm -f "$tmp"; return 1
    fi
    ok "Binario verificado (SHA256)"
  else
    warn "Se usa una URL personalizada: el binario no se pudo verificar"
  fi

  mkdir -p "$dir"
  systemctl stop udp-custom >/dev/null 2>&1
  install -m755 "$tmp" "$dir/udp-custom"
  rm -f "$tmp"
  conf_udp || return 1
  info "En HTTP Custom: modo UDP Custom, host $(get_host), puerto $PORT_UDP"
}

conf_udp() {   # configuracion y servicio de UDP Custom con el puerto actual
  local dir=/etc/udp-custom excl
  cat > "$dir/config.json" <<EOF
{
  "listen": ":$PORT_UDP",
  "stream_buffer": 33554432,
  "receive_buffer": 83886080,
  "auth": { "mode": "passwords" }
}
EOF
  # Puertos UDP que udp-custom NO debe tomar (DNS, SlowDNS, OpenVPN, WireGuard)
  excl="53,$PORT_SLOWDNS,1194,51820"
  mkunit udp-custom "UDP Custom" "$dir/udp-custom server -exclude $excl" "WorkingDirectory=$dir"
  fw_open "$PORT_UDP" udp
  verify udp "UDP Custom"
}

show_ports_plan() {
  section "PUERTOS A USAR"
  row "$(pcell DROPBEAR "$PORT_DROPBEAR")"  "$(pcell SSL "$PORT_SSL")"
  row "$(pcell WEBSOCKET "$PORT_WS")"       "$(pcell SQUID "$PORT_SQUID")"
  row "$(pcell V2RAY "$PORT_V2RAY")"        "$(pcell BADVPN "$PORT_BADVPN")"
  row "$(pcell 'UDP CUSTOM' "$PORT_UDP")"
}

install_all() {
  ensure_base
  local step n=0 total=7 a
  # Con --install-all (o sin teclado) todo es automatico con los puertos actuales
  if [[ -z ${INSTALL_AUTO:-} && -t 0 ]]; then
    while :; do
      show_ports_plan
      line_eq
      item 1 "INSTALAR AHORA"
      item 2 "CAMBIAR PUERTOS"
      menu_end CANCELAR
      ask a || return 1
      case $a in
        1) break ;;
        2) sub_header "CAMBIAR PUERTOS"; ports_wizard; pause; sub_header "INSTALACION COMPLETA" ;;
        0) return 0 ;;
        *) sub_header "INSTALACION COMPLETA" ;;
      esac
    done
  fi
  for step in "inst_dropbear:Dropbear" "inst_ssl:SSL (stunnel)" "inst_badvpn:BadVPN UDPGW" \
              "inst_ws:WebSocket" "inst_squid:Squid" "inst_v2ray:V2Ray" "inst_udp:UDP Custom"; do
    n=$(( n + 1 ))
    printf '\n %s[%d/%d]%s %s%s%s\n' "$YEL" "$n" "$total" "$RST" "$WHT" "${step#*:}" "$RST"
    "${step%%:*}" || warn "Fallo ${step#*:}. Se continua con el resto."
  done
  echo
  cfg_bbr
  echo
  ok "Instalacion completa. Abre el panel con: $(panel_cmd)"
}

# --------------------------- Cuentas SSH / Dropbear -------------------
show_ssh_info() { # usuario clave expira limite
  local FW=24   # etiquetas mas anchas en esta pantalla
  cls
  title "USUARIO CREADO CON EXITO!" "$GRN"
  field "IP:" "$IP" "$MAG"
  [[ -s $DOMAIN_F ]] && field "DOMINIO:" "$(get_host)"
  field "NOMBRE DE USUARIO:" "$1"
  field "CONTRASENA DE USUARIO:" "$2"
  field "CONEXIONES:" "$4"
  field "EXPIRA EN:" "${3:8:2}/${3:5:2}/${3:0:4}"
  section "PUERTOS"
  row "$(pcell SSH "$SSH_PORT")"      "$(pcell DROPBEAR "$PORT_DROPBEAR")"
  row "$(pcell SSL "$PORT_SSL")"      "$(pcell WEBSOCKET "$PORT_WS")"
  row "$(pcell SQUID "$PORT_SQUID")"  "$(pcell 'UDP CUSTOM' "$PORT_UDP")"
  line_eq
  field "UDPGW:" "127.0.0.1:$PORT_BADVPN" "$GRN"
  printf ' %sPAYLOAD WS:%s\n' "$YEL" "$RST"
  printf ' %sGET / HTTP/1.1[crlf]Host: %s[crlf]Upgrade: websocket[crlf][crlf]%s\n' "$GRN" "$(get_host)" "$RST"
}

ssh_list() {
  grep -q '^[^|]' "$USERDB" 2>/dev/null || { warn "No hay usuarios creados"; return 0; }
  acct_table "$USERDB"
  printf '\n %sTOTAL: %d   (en rojo: vencidos)%s\n' "$BLU" "${#ACCT[@]}" "$RST"
}

ssh_online() {
  local u p e l n tot=0
  printf ' %s%-20s %s%s\n' "$WHT" USUARIO CONEXIONES "$RST"
  line_dash
  while IFS='|' read -r u p e l; do
    [[ -n $u ]] || continue
    n=$(ps -u "$u" -o comm= 2>/dev/null | grep -cE '^(sshd|dropbear)$')
    if (( n > 0 )); then printf ' %-20s %s%s%s\n' "$u" "$GRN" "$n" "$RST"; tot=$(( tot + n )); fi
  done < "$USERDB"
  printf '\n %sTOTAL DE CONEXIONES: %d%s\n' "$BLU" "$tot" "$RST"
}

menu_ssh() {
  ensure_base
  local o n
  while :; do
    n=$(grep -c '^[^|]' "$USERDB" 2>/dev/null); n=${n:-0}
    sub_header "ADMINISTRACION DE USUARIOS SSH"
    field "USUARIOS CREADOS:" "$n" "$GRN"
    line_dash
    item 1 "NUEVO USUARIO SSH"
    item 2 "REMOVER USUARIO" "$RED"
    item 3 "RENOVAR USUARIO" "$GRN"
    item 4 "CAMBIAR CONTRASENA"
    item 5 "DETALLES DE TODOS LOS USUARIOS" "$GRN"
    item 6 "MONITOR DE USUARIOS CONECTADOS"
    item 7 "ELIMINAR USUARIOS VENCIDOS"
    menu_end
    ask o || return
    case $o in
      1) sub_header "NUEVO USUARIO SSH";              ssh_create ;;
      2) sub_header "REMOVER USUARIO";                ssh_delete; [[ $? == 3 ]] && continue ;;
      3) sub_header "RENOVAR USUARIO";                ssh_renew;  [[ $? == 3 ]] && continue ;;
      4) sub_header "CAMBIAR CONTRASENA";             ssh_passwd ;;
      5) sub_header "DETALLES DE TODOS LOS USUARIOS"; ssh_list ;;
      6) sub_header "MONITOR DE USUARIOS CONECTADOS"; ssh_online ;;
      7) sub_header "ELIMINAR USUARIOS VENCIDOS";     /usr/local/bin/vps-cleanup && ok "Usuarios vencidos eliminados" ;;
      0) return ;;
      *) continue ;;
    esac
    pause
  done
}

# ------------------------------ Cuentas V2Ray -------------------------
v2_create() {
  v2_need || return 1
  local n d id exp
  rd "Nombre de la cuenta: " n
  valid_name "$n" || { err "Nombre invalido (3-31 caracteres: a-z 0-9 _ -)"; return 1; }
  if grep -q "^${n}|" "$V2DB"; then err "La cuenta ya existe"; return 1; fi
  rd "Dias de validez [30]: " d; d=${d:-30}
  [[ $d =~ ^[0-9]+$ ]] || { err "Dias invalidos"; return 1; }
  id=$(cat /proc/sys/kernel/random/uuid)
  exp=$(date -d "+$d days" +%F)
  v2_edit --arg id "$id" --arg em "$n" \
    '.inbounds[0].settings.clients += [{"id":$id,"alterId":0,"email":$em}]' || return 1
  echo "$n|$id|$exp" >> "$V2DB"
  systemctl restart v2ray
  cls
  title "CUENTA V2RAY CREADA CON EXITO!" "$GRN"
  field "CUENTA:" "$n"
  field "EXPIRA EN:" "${exp:8:2}/${exp:5:2}/${exp:0:4}"
  field "PUERTO:" "$PORT_V2RAY"
  field "RED:" "ws"
  field "PATH:" "$V2PATH"
  line_eq
  printf ' %sUUID%s\n %s\n\n' "$BLU" "$RST" "$id"
  printf ' %sENLACE%s\n %s\n' "$BLU" "$RST" "$(v2_link "$n" "$id")"
}

v2_list() {
  local n id e c=0 d col now
  now=$(today_s)
  while IFS='|' read -r n id e; do
    [[ -n $n ]] || continue
    d=$(days_left "$e" "$now")
    if (( d < 0 )); then col=$RED; else col=$GRN; fi
    printf ' %s%s%s   %sEXPIRA%s %s%s%s\n' "$WHT" "$n" "$RST" "$BLU" "$RST" "$col" "${e:8:2}/${e:5:2}/${e:0:4}" "$RST"
    printf ' %s\n\n' "$(v2_link "$n" "$id")"
    c=$(( c + 1 ))
  done < "$V2DB"
  (( c )) || echo " (sin cuentas)"
  printf ' %sTOTAL: %d%s\n' "$BLU" "$c" "$RST"
}

menu_v2() {
  ensure_base
  local o n
  while :; do
    n=$(grep -c '^[^|]' "$V2DB" 2>/dev/null); n=${n:-0}
    sub_header "ADMINISTRACION DE CUENTAS V2RAY"
    field "CUENTAS CREADAS:" "$n" "$GRN"
    line_dash
    item 1 "NUEVA CUENTA V2RAY"
    item 2 "REMOVER CUENTA" "$RED"
    item 3 "RENOVAR CUENTA" "$GRN"
    item 4 "DETALLES Y ENLACES DE LAS CUENTAS" "$GRN"
    menu_end
    ask o || return
    case $o in
      1) sub_header "NUEVA CUENTA V2RAY";        v2_create ;;
      2) sub_header "REMOVER CUENTA V2RAY";      v2_delete; [[ $? == 3 ]] && continue ;;
      3) sub_header "RENOVAR CUENTA V2RAY";      v2_renew;  [[ $? == 3 ]] && continue ;;
      4) sub_header "DETALLES DE CUENTAS V2RAY"; v2_list ;;
      0) return ;;
      *) continue ;;
    esac
    pause
  done
}

# ------------------------------ Protocolos ----------------------------
pget() { local v=${PVAR[$1]}; printf '%s' "${!v}"; }

proto_installed() { systemctl cat "${SVC[$1]}" >/dev/null 2>&1; }

save_ports() {
  local k
  {
    for k in "${PORT_KEYS[@]}"; do echo "${PVAR[$k]}=$(pget "$k")"; done
    echo "V2PATH=$V2PATH"
  } > "$BASE/ports.conf"
}

load_ports() {   # lee /etc/vpspanel/ports.conf validando cada linea
  local l k v
  [[ -f $BASE/ports.conf ]] || return 0
  while IFS= read -r l; do
    k=${l%%=*}; v=${l#*=}
    case $k in
      PORT_DROPBEAR|PORT_SSL|PORT_BADVPN|PORT_WS|PORT_SQUID|PORT_V2RAY|PORT_UDP|PORT_SLOWDNS)
        if [[ $v =~ ^[0-9]{1,5}$ ]] && (( 10#$v >= 1 && 10#$v <= 65535 )); then
          printf -v "$k" '%s' "$(( 10#$v ))"
        fi ;;
      V2PATH) [[ $v =~ ^/[A-Za-z0-9._~/-]{1,40}$ ]] && V2PATH=$v ;;
    esac
  done < "$BASE/ports.conf"
  return 0
}

is_udp_key() { [[ $1 == udp || $1 == slowdns ]]; }

port_check() {   # clave puerto -> 0 si sirve (deja el numero en PCHK); si no, el motivo en MSG
  local k=$1 p=$2 o
  if ! [[ $p =~ ^[0-9]{1,5}$ ]] || (( 10#$p < 1 || 10#$p > 65535 )); then MSG="Puerto invalido (1-65535)."; return 1; fi
  p=$(( 10#$p ))
  for o in "${PORT_KEYS[@]}"; do
    [[ $o == "$k" ]] && continue
    if { is_udp_key "$o" && is_udp_key "$k"; } || { ! is_udp_key "$o" && ! is_udp_key "$k"; }; then
      if (( $(pget "$o") == p )); then MSG="Ya lo usa ${o^^} en este panel."; return 1; fi
    fi
  done
  if ! is_udp_key "$k" && (( p == SSH_PORT )); then MSG="Es el puerto SSH del servidor."; return 1; fi
  PCHK=$p
  (( p == $(pget "$k") )) && return 0                       # sin cambios
  if is_udp_key "$k"; then
    if ss -H -lun "sport = :$p" 2>/dev/null | grep -q .; then MSG="El puerto UDP $p ya esta en uso."; return 1; fi
  elif port_busy "$p"; then
    MSG="El puerto $p ya esta en uso por otro programa."; return 1
  fi
  return 0
}

port_set() { printf -v "${PVAR[$1]}" '%s' "$2"; save_ports; }

v2_apply() {   # puerto y path de V2Ray en su config (sin tocar las cuentas)
  [[ -f $V2CFG ]] || return 0
  local t; t=$(mktemp)
  if jq --argjson p "$PORT_V2RAY" --arg w "$V2PATH" \
       '.inbounds[0].port=$p | .inbounds[0].streamSettings.wsSettings.path=$w' "$V2CFG" > "$t"; then
    cat "$t" > "$V2CFG"
  fi
  rm -f "$t"
  systemctl restart v2ray
  fw_open "$PORT_V2RAY" tcp
  verify v2ray V2Ray
}

apply_proto() {   # clave -> reescribe su configuracion con los puertos actuales (solo si esta instalado)
  local k=$1 was=1
  proto_installed "$k" || return 0
  is_on "$k" || was=0
  case $k in
    dropbear) unit_dropbear ;;
    ssl)      conf_ssl ;;
    badvpn)   unit_badvpn ;;
    ws)       unit_ws ;;
    squid)    conf_squid ;;
    v2ray)    v2_apply ;;
    udp)      conf_udp ;;
    slowdns)  [[ -s $BASE/slowdns/ns ]] && unit_slowdns ;;
    *)        return 0 ;;
  esac
  (( was )) || systemctl disable --now "${SVC[$k]}" >/dev/null 2>&1
  return 0
}

apply_chain() {   # clave -> la aplica y tambien a los que dependen de su puerto
  local d
  apply_proto "$1"
  case $1 in
    dropbear) for d in ws squid; do apply_proto "$d"; done ;;
    ws)       apply_proto squid ;;
  esac
  return 0
}

proto_port() {   # clave
  local k=$1 v cur; cur=$(pget "$k")
  rd "Nuevo puerto para ${k^^} [$cur]: " v || return 1
  [[ -z $v ]] && { info "Sin cambios"; return 0; }
  port_check "$k" "$v" || { err "$MSG"; return 1; }
  [[ $PCHK == "$cur" ]] && { info "Sin cambios"; return 0; }
  port_set "$k" "$PCHK"
  ok "Puerto de ${k^^}: $PCHK"
  if proto_installed "$k"; then info "Aplicando (se reinician los servicios afectados)..."; apply_chain "$k"; fi
}

ports_wizard() {   # pregunta el puerto de cada protocolo; ENTER conserva el actual
  local k v cur
  local -a ch=()
  printf '\n %sENTER = conservar el valor actual.%s\n\n' "$BLU" "$RST"
  for k in "${PORT_KEYS[@]}"; do
    cur=$(pget "$k")
    while :; do
      rd "$(printf '%-10s' "${k^^}") [$cur]: " v || return 1
      [[ -z $v ]] && break
      if port_check "$k" "$v"; then
        [[ $PCHK != "$cur" ]] && { port_set "$k" "$PCHK"; cur=$PCHK; ch+=("$k"); }
        break
      fi
      warn "$MSG"
    done
  done
  ok "Puertos guardados"
  for k in "${ch[@]}"; do apply_chain "$k"; done
  return 0
}

ports_reset() {
  local k c
  rd "Restaurar los puertos por defecto? (s/N): " c
  [[ $c == [sS] ]] || return 0
  for k in "${PORT_KEYS[@]}"; do printf -v "${PVAR[$k]}" '%s' "${PDEF[$k]}"; done
  V2PATH=/v2ray
  save_ports
  ok "Puertos restaurados"
  for k in dropbear ws squid ssl v2ray badvpn udp slowdns; do apply_proto "$k"; done
}

v2_path_set() {
  local p
  proto_installed v2ray || { err "V2Ray no esta instalado."; return 1; }
  rd "Nuevo path de V2Ray [$V2PATH]: " p
  [[ -z $p ]] && { info "Sin cambios"; return 0; }
  [[ $p == /* ]] || p="/$p"
  [[ $p =~ ^/[A-Za-z0-9._~/-]{1,40}$ ]] || { err "Path invalido (letras, numeros y . _ ~ - /)"; return 1; }
  V2PATH=$p; save_ports
  ok "Path de V2Ray: $V2PATH"
  apply_proto v2ray
  info "Vuelve a copiar los enlaces: Cuentas V2Ray > Listar."
}

slowdns_ns() {
  local ns
  [[ -x /usr/local/bin/dnstt-server ]] || { err "SlowDNS no esta instalado."; return 1; }
  info "NameServer actual: $(cat "$BASE/slowdns/ns" 2>/dev/null || echo -)"
  rd "Nuevo NameServer (NS), ej. ns.midominio.com: " ns
  [[ $ns =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { err "NameServer invalido"; return 1; }
  echo "$ns" > "$BASE/slowdns/ns"
  unit_slowdns
}

proto_menu() {   # clave nombre
  local k=$1 nm=$2 o lbl st
  case $k in openvpn|wireguard) sub_header "$nm"; proto_action "$k"; pause; return ;; esac
  while :; do
    if is_on "$k"; then st="${GRN}ACTIVO${RST}"; lbl=DETENER
    elif proto_installed "$k"; then st="${RED}DETENIDO${RST}"; lbl=ACTIVAR
    else st="${RED}NO INSTALADO${RST}"; lbl=INSTALAR; fi
    sub_header "$nm"
    field "ESTADO:" "$st"
    field "PUERTO:" "$(pget "$k")" "$GRN"
    [[ $k == v2ray ]]   && field "PATH:" "$V2PATH" "$GRN"
    [[ $k == slowdns ]] && field "NS:" "$(cat "$BASE/slowdns/ns" 2>/dev/null || echo -)" "$GRN"
    line_eq
    item 1 "$lbl $nm"
    item 2 "CAMBIAR PUERTO"
    [[ $k == v2ray ]]   && item 3 "CAMBIAR PATH"
    [[ $k == slowdns ]] && item 3 "CAMBIAR NAMESERVER"
    menu_end
    ask o || return
    case $o in
      1) proto_action "$k" ;;
      2) proto_port "$k" ;;
      3) case $k in v2ray) v2_path_set ;; slowdns) slowdns_ns ;; *) continue ;; esac ;;
      0) return ;;
      *) continue ;;
    esac
    pause
  done
}

menu_protocols() {
  local i k n p
  while :; do
    sub_header "PROTOCOLOS Y PUERTOS"
    for i in "${!PROTO_KEYS[@]}"; do
      k=${PROTO_KEYS[i]}
      p=''; [[ -n ${PVAR[$k]:-} ]] && p=$(pget "$k")
      item "$(( i + 1 ))" "$(printf '%-12s' "${PROTO_NAMES[i]}")$(onoff is_on "$k")  ${GRN}${p}${RST}"
    done
    line_dash
    item 11 "CAMBIAR TODOS LOS PUERTOS"
    item 12 "RESTAURAR PUERTOS POR DEFECTO"
    menu_end
    ask n || return
    case $n in
      0)  return ;;
      11) sub_header "CAMBIAR PUERTOS"; ports_wizard; pause ;;
      12) sub_header "RESTAURAR PUERTOS"; ports_reset; pause ;;
      *)  if [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#PROTO_KEYS[@]} )); then
            proto_menu "${PROTO_KEYS[n-1]}" "${PROTO_NAMES[n-1]}"
          fi ;;
    esac
  done
}

# ------------------------------ Herramientas --------------------------
menu_view() {   # mostrar u ocultar partes de la pantalla principal
  local o
  while :; do
    sub_header "VISTA DEL PANEL"
    item_on 1 "MOSTRAR NOMBRE DEL VPS"        is_shown name
    item_on 2 "MOSTRAR DATOS DEL SERVIDOR"    is_shown server
    item_on 3 "MOSTRAR LISTA DE SERVICIOS"    is_shown services
    menu_end
    ask o || return
    case $o in
      1) toggle_hide name ;;
      2) toggle_hide server ;;
      3) toggle_hide services ;;
      0) return ;;
    esac
  done
}

menu_tools() {
  local o
  while :; do
    sub_header "HERRAMIENTAS Y AJUSTES"
    item_on 1 "BANNER SSH" banner_on
    item    2 "ACELERACION TCP BBR"
    item    3 "MEMORIA SWAP"
    item    4 "LIMPIAR CACHE Y LOGS"
    item    5 "CONFIGURAR DNS"
    item    6 "DOMINIO Y CERTIFICADO SSL"
    item    7 "CLAVE Y ACCESO ROOT"
    item    8 "REINICIAR SERVICIOS"
    item_on 9 "AUTO-INICIO DEL PANEL" autostart_on
    item   10 "NOMBRE DEL VPS"
    item   11 "VISTA DEL PANEL"
    menu_end
    ask o || return
    case $o in
      1)  sub_header "BANNER SSH"; cfg_banner; [[ $? == 3 ]] && continue ;;
      2)  sub_header "ACELERACION TCP BBR";    cfg_bbr ;;
      3)  sub_header "MEMORIA SWAP";           cfg_swap ;;
      4)  sub_header "LIMPIAR CACHE Y LOGS";   cfg_cache ;;
      5)  sub_header "CONFIGURAR DNS";         cfg_dns ;;
      6)  sub_header "DOMINIO Y CERTIFICADO";  cfg_domain ;;
      7)  sub_header "CLAVE Y ACCESO ROOT";    cfg_root ;;
      8)  sub_header "REINICIAR SERVICIOS";    restart_services ;;
      9)  toggle_autostart ;;
      10) cfg_vpsname; continue ;;
      11) menu_view; continue ;;
      0)  return ;;
      *)  continue ;;
    esac
    pause
  done
}

# ---------------------------------- Menu ------------------------------
fmt_mb() { local m=$1; if (( m >= 1024 )); then printf '%d.%dG' $(( m / 1024 )) $(( (m % 1024) * 10 / 1024 )); else printf '%dM' "$m"; fi; }

sys_stats() {   # llena las variables de CPU, RAM, disco y tiempo activo que muestra header()
  local l1 mt mu dt du up d h m
  read -r l1 _ < /proc/loadavg
  CPU_N=$(nproc 2>/dev/null || echo 1)
  CPU_LOAD=$l1
  CPU_P=$(awk -v l="$l1" -v n="$CPU_N" 'BEGIN{p=l/n*100; if(p>100)p=100; printf "%d", p}')
  read -r mt mu < <(free -m | awk '/^Mem:/{print $2, $3}')
  mt=${mt:-0}; mu=${mu:-0}
  RAM_T=$(fmt_mb "$mt"); RAM_U=$(fmt_mb "$mu"); RAM_F=$(fmt_mb $(( mt - mu )))
  RAM_P=$(( mt > 0 ? mu * 100 / mt : 0 ))
  read -r dt du < <(df -Pm / | awk 'NR==2{print $2, $3}')
  dt=${dt:-0}; du=${du:-0}
  DSK_P=$(( dt > 0 ? du * 100 / dt : 0 ))
  up=$(cut -d. -f1 /proc/uptime); d=$(( up / 86400 )); h=$(( up % 86400 / 3600 )); m=$(( up % 3600 / 60 ))
  if (( d > 0 )); then UPT="${d}d ${h}h ${m}m"; else UPT="${h}h ${m}m"; fi
}

pcol() { if (( $1 >= 85 )); then printf '%s' "$RED"; else printf '%s' "$GRN"; fi; }   # rojo desde 85% de uso

# Servicios de la pantalla principal (en este orden) y como se llaman ahi
SVC_KEYS=(ssh dropbear ssl ws squid v2ray badvpn udp slowdns openvpn wireguard)
declare -A SVC_LABEL=([ssh]=SSH [dropbear]=DROPBEAR [ssl]=SSL [ws]=WEBSOCKET [squid]=SQUID [v2ray]=V2RAY
                      [badvpn]=BADVPN [udp]='UDP CUSTOM' [slowdns]=SLOWDNS [openvpn]=OPENVPN [wireguard]=WIREGUARD)

svc_port() {   # clave -> puerto que se muestra (openvpn y wireguard no tienen puerto propio)
  case $1 in
    ssh)               echo "$SSH_PORT" ;;
    openvpn|wireguard) echo "-" ;;
    *)                 pget "$1" ;;
  esac
}

svc_cell() {   # clave  ->  "NOMBRE:  puerto  [ON]"  (verde si esta activo, rojo si no; usa ON[] de header)
  local c=$RED t='[OFF]'
  if [[ -n ${ON[$1]:-} ]]; then c=$GRN; t='[ON]'; fi
  printf '%s%-11s%s %s%-5s%s %s%-5s%s' "$c" "${SVC_LABEL[$1]}:" "$RST" "$WHT" "$(svc_port "$1")" "$RST" "$c" "$t" "$RST"
}

header() {
  local name reg k i a b on=0
  local -A ON=()
  name=$(vps_name); reg=$(cat "$REG_F" 2>/dev/null)
  if is_hidden name || [[ -z $name ]]; then name='VPS PANEL'; fi
  if ! is_hidden services; then
    for k in "${SVC_KEYS[@]}"; do
      if is_on "$k"; then ON[$k]=1; on=$(( on + 1 )); fi
    done
  fi
  is_hidden server || sys_stats

  cls
  # Titulo
  line_eq
  center "=====>>>> ${name^^} <<<<=====" "$YEL"
  center "ADMINISTRADOR DE VPS  v$VERSION"

  # Datos del servidor
  if ! is_hidden server; then
    line_eq
    row "${GRN}SISTEMA${RST}" "${GRN}MEMORIA${RST}" "${GRN}PROCESADOR${RST}"
    row "$(kv S.O.:   "${OS_NAME:0:18}")"      "$(kv RAM:   "$RAM_T" "$GRN")"  "$(kv CPU:   "$CPU_N" "$GRN")"
    row "$(kv IP:     "$IP" "$MAG")"           "$(kv USADA: "$RAM_U" "$GRN")"  "$(kv USO:   "$CPU_P%" "$(pcol "$CPU_P")")"
    row "$(kv FECHA:  "$(date +%d/%m/%y)")"    "$(kv LIBRE: "$RAM_F" "$GRN")"  "$(kv CARGA: "$CPU_LOAD")"
    row "$(kv HORA:   "$(date +%T)")"          "$(kv USO:   "$RAM_P%" "$(pcol "$RAM_P")")"  "$(kv DISCO: "$DSK_P%" "$(pcol "$DSK_P")")"
    row "$(kv ACTIVO: "$UPT")"                 "$(kv REGISTRO: "${reg:--}")"
  fi

  # Servicios: dos columnas (los primeros 6 a la izquierda, el resto a la derecha)
  if ! is_hidden services; then
    section "SERVICIOS ACTIVOS: $on/${#SVC_KEYS[@]}"
    for i in 0 1 2 3 4 5; do
      a=${SVC_KEYS[i]}; b=${SVC_KEYS[i+6]:-}
      if [[ -n $b ]]; then row "$(svc_cell "$a")" "$(svc_cell "$b")"; else row "$(svc_cell "$a")"; fi
    done
  fi

  # Menu
  line_eq
  item 1 "ADMINISTRAR CUENTAS (SSH/DROPBEAR)"
  item 2 "ADMINISTRAR CUENTAS (V2RAY)"
  line_dash
  item 3 "PROTOCOLOS, ESTADO Y PUERTOS"
  item 4 "HERRAMIENTAS (BBR, SWAP, DNS, DOMINIO)"
  item 5 "INSTALAR TODOS LOS PROTOCOLOS"
  line_dash
  item 6 "DESINSTALAR PANEL" "$RED"
  line_eq
  printf ' %s0)%s %s SALIR %s     %s7)%s %s REINICIAR VPS %s\n' "$GRN" "$RST" "$BTN_GRAY" "$RST" "$GRN" "$RST" "$BTN_BLUE" "$RST"
  line_eq
}

main_menu() {
  local o c=''
  while :; do
    header
    ask o || exit 0
    case $o in
      1) menu_ssh ;;
      2) menu_v2 ;;
      3) ensure_base; menu_protocols ;;
      4) menu_tools ;;
      5) sub_header "INSTALACION COMPLETA"; install_all; pause ;;
      6) sub_header "DESINSTALAR PANEL"; uninstall_all; pause ;;
      7) rd "Reiniciar el VPS ahora? (s/N): " c; [[ $c == [sS] ]] && reboot ;;
      0) cls; exit 0 ;;
    esac
  done
}

usage() { echo "Uso: $0 [--install-all]"; }

main() {
  preflight
  init_fs
  load_ports
  init_ui
  trap '[[ -t 1 ]] && printf "\e[?25h\e[0m"' EXIT
  init_env
  self_install
  autostart_default
  banner_migrate
  case "${1:-}" in
    --install-all) default_name; INSTALL_AUTO=1; install_all; exit 0 ;;
    -h|--help)     usage; exit 0 ;;
    "") ;;
    *) usage; exit 1 ;;
  esac
  if [[ ! -s $NAME_F ]]; then
    if [[ -t 0 && -t 1 ]]; then register_vps || exit 1; else default_name; fi
  fi
  main_menu
}

if [[ -z ${VPSPANEL_SOURCE_ONLY:-} ]]; then main "$@"; fi
