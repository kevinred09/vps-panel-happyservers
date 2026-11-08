#!/usr/bin/env bash
# ======================================================================
#  VPS PANEL v2.0 - instalador y administrador de protocolos para túneles
#  Compatible con HTTP Custom y apps similares.
#  SSH · Dropbear · SSL · WebSocket · Squid · V2Ray · BadVPN-UDPGW
#  UDP Custom · SlowDNS · OpenVPN · WireGuard
#  Sistemas: Ubuntu 20.04/22.04/24.04 y Debian 11/12 (como root)
#
#  Uso:
#    bash vps-panel.sh                 registro del VPS (1a vez) + menú ("vpspanel")
#    bash vps-panel.sh --install-all   instalación completa sin menú
#
#  Valores por defecto: banner SSH desactivado, auto-inicio del panel activado.
#  Los puertos se cambian en Protocolos y se guardan en /etc/vpspanel/ports.conf
#    UDPCUSTOM_URL=<url> vpspanel      (opcional) usar otro binario de udp-custom
# ======================================================================

set -u
shopt -s extglob
export DEBIAN_FRONTEND=noninteractive
export VPSPANEL_ACTIVE=1

# La interfaz usa caracteres Unicode (marcos y bloques); se necesita un locale UTF-8
if [[ $(locale charmap 2>/dev/null) != UTF-8 ]]; then
  locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$' && export LC_ALL=C.UTF-8
fi
if [[ $(locale charmap 2>/dev/null) == UTF-8 ]]; then UTF=1; else UTF=0; fi

# ------------------------------ Configuración -------------------------
VERSION=2.1
BASE=${VPSPANEL_BASE:-/etc/vpspanel}
USERDB=$BASE/users.db
V2DB=$BASE/v2ray.db
BANNER=$BASE/banner
CERT=$BASE/cert.pem
DOMAIN_F=$BASE/domain
NAME_F=$BASE/vps.name
REG_F=$BASE/vps.reg
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

# UDP Custom: binario x86_64 descargado automáticamente. La URL apunta a un commit
# exacto del repositorio (no a "main") y el archivo se verifica con SHA256 antes de
# instalarlo, así no puede cambiar sin que el panel se entere.
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
# Todo el aspecto visual vive en este bloque: colores, marcos, banner y spinner.
RAMP=(51 45 45 39 39 33 33 69 69 105 105 141 141 177)   # degradado cian -> violeta
GC=()                                  # colores del degradado (se rellena con mk_grad)

init_ui() {
  local cols
  cols=$(tput cols 2>/dev/null); [[ $cols =~ ^[0-9]+$ ]] || cols=${COLUMNS:-56}
  (( cols > 62 )) && cols=62
  (( cols < 40 )) && cols=40
  UW=$cols                 # ancho total de la interfaz
  BW=$(( UW - 2 ))         # ancho de cada marco (1 espacio de margen a la izquierda)
  IW=$(( BW - 4 ))         # ancho útil dentro de un marco
  if (( UW >= 52 )); then TWO=1; else TWO=0; fi   # dos columnas solo si hay espacio

  if [[ ( -t 1 || -n ${VPSPANEL_COLOR:-} ) && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    RST=$'\e[0m';           BOLD=$'\e[1m'
    ACC=$'\e[38;5;45m';     ACC2=$'\e[38;5;141m'
    HI=$'\e[1;38;5;255m';   TXT=$'\e[38;5;252m';  DIM=$'\e[38;5;245m'
    OKC=$'\e[38;5;87m';      ERC=$'\e[38;5;203m';  WRC=$'\e[38;5;221m'
    BRD=$'\e[38;5;37m';     SHC=$'\e[38;5;240m'; IPC=$'\e[1;38;5;219m'
  else
    RST='' BOLD='' ACC='' ACC2='' HI='' TXT='' DIM='' OKC='' ERC='' WRC='' BRD='' SHC='' IPC=''
  fi

  if (( UTF )); then
    GH='─' GV='│' GTL='╭' GTR='╮' GBL='╰' GBR='╯'
    GDOT='●' GRING='○' GFUL='━' GEMP='╌' GBAR='━' GBLK='█' ARW='›' SEP='·'
    SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  else
    GH='-' GV='|' GTL='+' GTR='+' GBL='+' GBR='+'
    GDOT='*' GRING='o' GFUL='#' GEMP='.' GBAR='=' GBLK='#' ARW='>' SEP='-'
    SPIN=('|' '/' '-' '\')
  fi

  # Alias de colores usados por los instaladores
  R=$ERC; G=$OKC; Y=$WRC; M=$ACC2; C=$ACC; W=$HI; N=$RST; LINE=
}

rep() { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }   # carácter n_veces

vlen_set() { local s=${1//$'\e['*([0-9;])m/}; VL=${#s}; }                  # largo visible (sin colores)

mk_grad() {   # ancho -> rellena GC[] con un color por columna
  local w=$1 i k n=${#RAMP[@]}
  GC=()
  for (( i=0; i<w; i++ )); do
    if [[ -n $RST ]]; then k=$(( i * n / w )); printf -v "GC[$i]" '\e[38;5;%sm' "${RAMP[k]}"; else GC[i]=; fi
  done
}

gradient_bar() {
  local i s=' '
  mk_grad "$BW"
  for (( i=0; i<BW; i++ )); do s+="${GC[i]}${GBAR}"; done
  printf '%s%s\n' "$s" "$RST"
}

cls() { [[ -t 1 ]] && printf '\e[H\e[2J\e[3J'; return 0; }

# ---- Marcos --------------------------------------------------------
box_top() {   # titulo
  local t=$1 n fill
  vlen_set "$t"; n=$VL
  fill=$(( BW - 5 - n )); (( fill < 1 )) && fill=1
  printf ' %s%s%s%s %s%s%s %s%s%s%s\n' "$BRD" "$GTL" "$GH" "$RST" "$HI" "$t" "$RST" "$BRD" "$(rep "$GH" "$fill")" "$GTR" "$RST"
}

box_row() {   # texto (puede llevar colores)
  local t=$1 pad
  vlen_set "$t"; pad=$(( BW - 4 - VL )); (( pad < 0 )) && pad=0
  printf ' %s%s%s %s%*s %s%s%s\n' "$BRD" "$GV" "$RST" "$t" "$pad" '' "$BRD" "$GV" "$RST"
}

box_bottom() { printf ' %s%s%s%s%s\n' "$BRD" "$GBL" "$(rep "$GH" $(( BW - 2 )))" "$GBR" "$RST"; }

box_cols() {  # izquierda derecha  (dos columnas; en pantallas angostas, dos filas)
  local l=$1 r=$2 half pad
  if (( TWO )); then
    half=$(( IW / 2 ))
    vlen_set "$l"; pad=$(( half - VL )); (( pad < 1 )) && pad=1
    box_row "$l$(printf '%*s' "$pad" '')$r"
  else
    box_row "$l"; [[ -n $r ]] && box_row "$r"
  fi
  return 0
}

grid() {      # modo(col|row) celda...   reparte celdas en dos columnas
  local mode=$1; shift
  local -a c=("$@")
  local n=${#c[@]} rows i l r
  if (( TWO )); then
    rows=$(( (n + 1) / 2 ))
    for (( i=0; i<rows; i++ )); do
      if [[ $mode == col ]]; then l=${c[i]}; r=${c[i+rows]:-}; else l=${c[2*i]}; r=${c[2*i+1]:-}; fi
      box_cols "$l" "$r"
    done
  else
    for l in "${c[@]}"; do box_row "$l"; done
  fi
}

kv()    { printf '%s%-8s%s %s%s%s' "$DIM" "$1" "$RST" "${3:-$HI}" "$2" "$RST"; }  # etiqueta valor [color]
mcell() { printf '%s%s%s  %s%s%s' "$ACC" "$1" "$RST" "${3:-$TXT}" "$2" "$RST"; } # NN etiqueta [color]
pcell() { printf '%s%-11s%s %s%s%s' "$DIM" "$1" "$RST" "$HI" "$2" "$RST"; }      # etiqueta puerto

bar() {       # porcentaje ancho -> ━━━╌╌╌  (degradado; ámbar desde 60%, rojo desde 85%)
  local p=$1 w=$2 f i k n=${#RAMP[@]} s=''
  (( p > 100 )) && p=100; (( p < 0 )) && p=0
  f=$(( p * w / 100 )); (( p > 0 && f < 1 )) && f=1
  for (( i=0; i<f; i++ )); do
    if [[ -z $RST ]]; then s+=$GFUL
    elif (( p >= 85 )); then s+="${ERC}${GFUL}"
    elif (( p >= 60 )); then s+="${WRC}${GFUL}"
    else k=$(( i * n / w )); printf -v k '\e[38;5;%sm' "${RAMP[k]}"; s+="${k}${GFUL}"; fi
  done
  printf '%s%s%s%s' "$s" "$SHC" "$(rep "$GEMP" $(( w - f )))" "$RST"
}

# ---- Mensajes ------------------------------------------------------
info() { printf '  %s%s%s  %s\n' "$ACC" "$ARW" "$RST" "$*"; }
ok()   { printf '  %s[OK]%s  %s\n' "$OKC" "$RST" "$*"; }
err()  { printf '  %s[ERROR]%s  %s\n' "$ERC" "$RST" "$*" >&2; }
warn() { printf '  %s[!]%s  %s\n' "$WRC" "$RST" "$*"; }
pause() { local _; printf '\n'; read -rp "  ${DIM}Presiona ENTER para continuar...${RST}" _; }

rd()  { local __p; printf -v __p '  %s%s%s %s' "$ACC" "$ARW" "$RST" "$1"; shift; read -rp "$__p" "$@"; }   # pregunta
ask() { local __p; printf -v __p '\n  %s%s%s %s: ' "$ACC" "$ARW" "$RST" "$1"; read -rp "$__p" "$2"; }       # prompt de menú

spin() {      # mensaje comando [args...]  -> ejecuta el comando mostrando un spinner
  local msg=$1 pid i=0 rc; shift
  if [[ ! -t 1 ]]; then info "$msg..."; "$@" >/dev/null 2>&1 </dev/null; return $?; fi
  "$@" >/dev/null 2>&1 </dev/null &
  pid=$!
  printf '\e[?25l'
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s  %s' "$ACC" "${SPIN[i % ${#SPIN[@]}]}" "$RST" "$msg"
    i=$(( i + 1 )); sleep 0.1
  done
  wait "$pid"; rc=$?
  printf '\r\e[K\e[?25h'
  return $rc
}

sub_header() { # titulo de la pantalla
  cls
  gradient_bar
  printf ' %s%s%s  %s%s%s  %s%s%s\n' "$HI" "$(vps_name)" "$RST" "$DIM" "$ARW" "$RST" "$ACC" "$1" "$RST"
  printf ' %s%s%s\n\n' "$DIM" "$(rep "$GH" "$BW")" "$RST"
}

# ---- Banner grande -------------------------------------------------
# Fuente de 5x5; cada letra ocupa 6 columnas (5 + separación), el espacio 3.
declare -A FONT=(
  [A]="01110 10001 11111 10001 10001"  [B]="11110 10001 11110 10001 11110"
  [C]="01111 10000 10000 10000 01111"  [D]="11110 10001 10001 10001 11110"
  [E]="11111 10000 11110 10000 11111"  [F]="11111 10000 11110 10000 10000"
  [G]="01111 10000 10011 10001 01111"  [H]="10001 10001 11111 10001 10001"
  [I]="11111 00100 00100 00100 11111"  [J]="00111 00010 00010 10010 01100"
  [K]="10001 10010 11100 10010 10001"  [L]="10000 10000 10000 10000 11111"
  [M]="10001 11011 10101 10001 10001"  [N]="10001 11001 10101 10011 10001"
  [O]="01110 10001 10001 10001 01110"  [P]="11110 10001 11110 10000 10000"
  [Q]="01110 10001 10101 10010 01101"  [R]="11110 10001 11110 10010 10001"
  [S]="01111 10000 01110 00001 11110"  [T]="11111 00100 00100 00100 00100"
  [U]="10001 10001 10001 10001 01110"  [V]="10001 10001 10001 01010 00100"
  [W]="10001 10001 10101 11011 10001"  [X]="10001 01010 00100 01010 10001"
  [Y]="10001 01010 00100 00100 00100"  [Z]="11111 00010 00100 01000 11111"
  [0]="01110 10011 10101 11001 01110"  [1]="00100 01100 00100 00100 01110"
  [2]="01110 10001 00010 00100 11111"  [3]="11110 00001 01110 00001 11110"
  [4]="10010 10010 11111 00010 00010"  [5]="11111 10000 11110 00001 11110"
  [6]="01110 10000 11110 10001 01110"  [7]="11111 00001 00010 00100 00100"
  [8]="01110 10001 01110 10001 01110"  [9]="01110 10001 01111 00001 01110"
  ["-"]="00000 00000 01110 00000 00000" ["_"]="00000 00000 00000 00000 11111"
  ["."]="00000 00000 00000 00000 00100" ["?"]="01110 10001 00110 00000 00100"
)

banner_width() {   # texto -> REPLY = ancho mínimo en columnas (letra de 8 + 1 de separación)
  local t=${1^^} i x=0
  for (( i=0; i<${#t}; i++ )); do
    if [[ ${t:i:1} == ' ' ]]; then x=$(( x + 5 )); else x=$(( x + 9 )); fi
  done
  REPLY=$x
}

banner_split() {   # texto -> BL[] con 1 o 2 líneas; devuelve 1 si no cabe
  local t=$1 best=-1 bm=9999 i m w1 w2
  BL=()
  banner_width "$t"
  if (( REPLY <= BW )); then BL=("$t"); return 0; fi
  for (( i=1; i<${#t}-1; i++ )); do
    [[ ${t:i:1} == ' ' ]] || continue
    banner_width "${t:0:i}"; w1=$REPLY
    banner_width "${t:i+1}"; w2=$REPLY
    (( w1 <= BW && w2 <= BW )) || continue
    m=$(( w1 > w2 ? w1 : w2 ))
    if (( m < bm )); then bm=$m; best=$i; fi
  done
  (( best < 0 )) && return 1
  BL=("${t:0:best}" "${t:best+1}")
  return 0
}

banner_big() {     # una línea de texto en letras grandes con degradado
  local t=${1^^} i ch g r c x=0 oc lw gap sp cw pad line q='?' src prev col
  local -A lit=()
  local -a bits cmap
  banner_width "$t"
  # Cada columna de la fuente 5x5 se ensancha: letras de 8 columnas, o de 10 si el nombre es corto
  if (( REPLY * 4 / 3 <= BW )); then cmap=(0 0 1 1 2 2 3 3 4 4); gap=2; sp=6
  else                               cmap=(0 0 1 2 2 3 4 4);     gap=1; sp=5; fi
  lw=${#cmap[@]}
  for (( i=0; i<${#t}; i++ )); do
    ch=${t:i:1}
    if [[ $ch == ' ' ]]; then x=$(( x + sp )); continue; fi
    g=${FONT[$ch]:-${FONT[$q]}}
    read -ra bits <<< "$g"
    for (( r=0; r<5; r++ )); do
      for (( oc=0; oc<lw; oc++ )); do
        src=${cmap[oc]}
        [[ ${bits[r]:src:1} == 1 ]] && lit[$r,$(( x + oc ))]=1
      done
    done
    x=$(( x + lw + gap ))
  done
  cw=$(( x - gap )); (( cw < 1 )) && cw=1
  mk_grad "$cw"
  pad=$(( (UW - cw) / 2 )); (( pad < 0 )) && pad=0
  for (( r=0; r<5; r++ )); do
    printf -v line '%*s' "$pad" ''
    prev=''
    for (( c=0; c<cw; c++ )); do
      if [[ -n ${lit[$r,$c]:-} ]]; then
        col=${GC[c]}
        if [[ $col != "$prev" ]]; then line+=$col; prev=$col; fi
        line+=$GBLK
      else
        line+=' '
      fi
    done
    printf '%s%s\n' "$line" "$RST"
  done
}

banner_compact() { # nombre demasiado largo para las letras grandes: una línea espaciada
  local t=${1^^} s="" i n pad
  (( ${#t} > UW / 2 - 1 )) && t=${t:0:$(( UW / 2 - 1 ))}
  n=${#t}
  mk_grad "$n"
  for (( i=0; i<n; i++ )); do s+="${BOLD}${GC[i]}${t:i:1} "; done
  pad=$(( (UW - (2 * n - 1)) / 2 )); (( pad < 0 )) && pad=0
  printf '%*s%s%s\n' "$pad" '' "$s" "$RST"
}

banner_print() {   # nombre
  local l
  if banner_split "$1"; then
    for l in "${BL[@]}"; do banner_big "$l"; done
  else
    banner_compact "$1"
  fi
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
}

preflight() {
  [[ $EUID -eq 0 ]] || { echo "Ejecuta como root."; exit 1; }
  command -v systemctl >/dev/null 2>&1 || { echo "Se requiere systemd."; exit 1; }
}

apt_i() { spin "Instalando $*" apt-get install -y -qq -o DPkg::Lock::Timeout=120 "$@"; }

vps_name() { cat "$NAME_F" 2>/dev/null; }

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
    err "El puerto $2 ya está en uso por: $(ss -H -ltnp "sport = :$2" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1)"
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
  else err "${2:-$1} no inició. Revisa: journalctl -u ${SVC[$1]} -n 30"; return 1; fi
}

mkunit() { # nombre descripción exec [directivas extra de [Service]]
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
# Limita conexiones simultáneas por usuario (SSH/Dropbear)
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
    err "Configuración SSH inválida; se revierte."
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

conf_ssl() {   # configuración y servicio con el puerto actual
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
  apt_i build-essential cmake git || { err "Fallo al instalar dependencias de compilación"; return 1; }
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
"""Proxy HTTP-Upgrade/WebSocket -> TCP local (SSH/Dropbear) para apps de túnel.

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
  [[ -x /usr/local/bin/v2ray ]] || { err "No se encontró /usr/local/bin/v2ray"; return 1; }
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
  [[ $ns =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { err "NameServer inválido"; return 1; }
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
  echo "${Y}NameServer :${N} $ns"
  echo "${Y}Llave pública:${N} $(cat "$BASE/slowdns/server.pub")"
  echo "Registros DNS: A  ns1.<dominio> -> $IP   |   NS  $ns -> ns1.<dominio>"
}

# ------------------------- Cuentas SSH (originales) -------------------
ssh_create() {
  local u p d l exp
  rd "Usuario: " u
  valid_name "$u" || { err "Usuario inválido (3-31 caracteres: a-z 0-9 _ -)"; return 1; }
  if id "$u" >/dev/null 2>&1; then err "El usuario ya existe"; return 1; fi
  rd "Contraseña [aleatoria]: " p; p=${p:-$(rand_pass)}
  [[ $p != *"|"* && -n $p ]] || { err "La contraseña no puede contener '|'"; return 1; }
  rd "Días de validez [30]: " d; d=${d:-30}
  [[ $d =~ ^[0-9]+$ ]] || { err "Días inválidos"; return 1; }
  rd "Límite de conexiones [1]: " l; l=${l:-1}
  [[ $l =~ ^[0-9]+$ ]] || { err "Límite inválido"; return 1; }
  exp=$(date -d "+$d days" +%F)
  useradd -M -s /bin/false -e "$exp" "$u" || { err "No se pudo crear el usuario"; return 1; }
  echo "$u:$p" | chpasswd
  echo "$u|$p|$exp|$l" >> "$USERDB"
  show_ssh_info "$u" "$p" "$exp" "$l"
}

ssh_delete() {
  local u
  rd "Usuario a eliminar: " u
  valid_name "$u" && grep -q "^${u}|" "$USERDB" || { err "Usuario no encontrado"; return 1; }
  pkill -KILL -u "$u" 2>/dev/null
  userdel -f "$u" 2>/dev/null
  sed -i "/^${u}|/d" "$USERDB"
  ok "Usuario $u eliminado"
}

ssh_renew() {
  local u d exp
  rd "Usuario a renovar: " u
  valid_name "$u" && grep -q "^${u}|" "$USERDB" || { err "Usuario no encontrado"; return 1; }
  rd "Días desde hoy [30]: " d; d=${d:-30}
  [[ $d =~ ^[0-9]+$ ]] || { err "Días inválidos"; return 1; }
  exp=$(date -d "+$d days" +%F)
  usermod -e "$exp" "$u" && db_set "$u" 3 "$exp" && ok "$u vence el $exp"
}

ssh_passwd() {
  local u p
  rd "Usuario: " u
  valid_name "$u" && grep -q "^${u}|" "$USERDB" || { err "Usuario no encontrado"; return 1; }
  rd "Nueva contraseña [aleatoria]: " p; p=${p:-$(rand_pass)}
  [[ $p != *"|"* && -n $p ]] || { err "La contraseña no puede contener '|'"; return 1; }
  echo "$u:$p" | chpasswd && db_set "$u" 2 "$p" && ok "Nueva contraseña de $u: $p"
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

v2_need() { [[ -f $V2CFG ]] || { err "V2Ray no está instalado (Protocolos > V2RAY)."; return 1; }; }


v2_delete() {
  v2_need || return 1
  local n
  rd "Cuenta a eliminar: " n
  valid_name "$n" && grep -q "^${n}|" "$V2DB" || { err "Cuenta no encontrada"; return 1; }
  v2_edit --arg em "$n" '.inbounds[0].settings.clients |= map(select(.email != $em))' || return 1
  sed -i "/^${n}|/d" "$V2DB"
  systemctl restart v2ray
  ok "Cuenta $n eliminada"
}

v2_renew() {
  local n d exp t
  rd "Cuenta a renovar: " n
  valid_name "$n" && grep -q "^${n}|" "$V2DB" || { err "Cuenta no encontrada"; return 1; }
  rd "Días desde hoy [30]: " d; d=${d:-30}
  [[ $d =~ ^[0-9]+$ ]] || { err "Días inválidos"; return 1; }
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
    info "Banner ${OKC}ACTIVADO${RST}. Contenido actual:"; sed 's/^/        /' "$BANNER"
  else
    info "Banner ${DIM}DESACTIVADO${RST}: al conectar no se muestra ningún banner."
  fi
  printf '\n  %s01%s  Escribir o cambiar el banner (lo activa)\n' "$ACC" "$RST"
  printf '  %s02%s  Desactivar el banner\n' "$ACC" "$RST"
  printf '  %s00%s  Volver\n' "$ACC" "$RST"
  ask Opción o || return 3
  [[ $o =~ ^[0-9]+$ ]] && o=$(( 10#$o ))
  case $o in
    1) echo "Escribe el banner (HTML permitido). Línea vacía para terminar:"
       txt=""
       while IFS= read -r l; do [[ -z $l ]] && break; txt+="$l"$'\n'; done
       [[ -n $txt ]] || { err "Banner vacío"; return 1; }
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
  ok "Control de congestión: $(sysctl -n net.ipv4.tcp_congestion_control)"
}

cfg_swap() {
  local s
  rd "Tamaño de swap en MB [1024]: " s; s=${s:-1024}
  [[ $s =~ ^[0-9]+$ ]] || { err "Tamaño inválido"; return 1; }
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
  ok "Caché y registros limpiados"
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
  rd "Dominio (vacío = certificado autofirmado con la IP): " d
  if [[ -z $d ]]; then
    rm -f "$DOMAIN_F"
    mk_selfsigned "$IP"
    ok "Certificado autofirmado generado"
    return 0
  fi
  [[ $d =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { err "Dominio inválido"; return 1; }
  apt_i certbot || { err "Fallo al instalar certbot"; return 1; }
  is_on ws && systemctl stop vps-ws
  certbot certonly --standalone -d "$d" --non-interactive --agree-tos --register-unsafely-without-email
  local rc=$?
  systemctl is-enabled --quiet vps-ws 2>/dev/null && systemctl start vps-ws
  (( rc == 0 )) || { err "certbot falló: verifica que $d apunte a $IP y que el puerto 80 esté libre."; return 1; }

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
    ok "Acceso root por contraseña activado"
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

autostart_default() {   # primera ejecución: el auto-inicio queda ACTIVADO
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
  cls; gradient_bar; echo
  printf '  %sREGISTRO COMPLETO%s\n\n' "$HI" "$RST"
  box_top "ACCESO AL PANEL"
  if autostart_on; then
    box_row "${OKC}${GDOT}${RST} ${HI}Auto-inicio ACTIVADO${RST}"
    box_row "${DIM}Se abre solo al entrar por SSH.${RST}"
    box_row "${DIM}Si lo desactivas, ábrelo con:${RST}"
  else
    box_row "${WRC}${GRING}${RST} ${HI}Auto-inicio DESACTIVADO${RST}"
    box_row "${DIM}El panel no abre solo. Escribe:${RST}"
  fi
  box_row ""
  box_row "  ${ACC}${ARW}${RST} ${HI}${c}${RST}"
  box_row ""
  box_row "${DIM}Cambiar: Herramientas > Auto-inicio${RST}"
  box_bottom
  pause
}

# ------------------------------ Desinstalar ---------------------------
uninstall_all() {
  local c s u p
  rd "Escribe SI para eliminar el panel, sus servicios y las cuentas SSH creadas: " c
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
  if ! [[ $t =~ $re ]]; then MSG="Usa solo letras, números, espacio, punto, guion y guion bajo."; return 1; fi
  if ! banner_split "$t"; then
    MSG="No cabe en el banner. Máximo $(( BW / 9 )) letras, o dos palabras de ese largo."
    return 1
  fi
  return 0
}

register_vps() {
  local cur name ans first=0 w
  cur=$(vps_name); [[ -n $cur ]] || first=1
  while :; do
    cls; gradient_bar; echo
    printf '  %sREGISTRO DE VPS%s\n' "$HI" "$RST"
    if (( first )); then
      printf '  %sRegistra este servidor: su nombre aparecerá como banner del panel.%s\n' "$DIM" "$RST"
    else
      printf '  %sNombre actual: %s  (ENTER para conservarlo)%s\n' "$DIM" "$cur" "$RST"
    fi
    printf '  %sMáximo %d letras, o dos palabras de ese largo.%s\n\n' "$DIM" "$(( BW / 9 ))" "$RST"
    rd "Nombre del VPS: " name || { err "No hay entrada disponible"; return 1; }
    read -ra w <<< "$name"; name="${w[*]:-}"            # quita espacios sobrantes
    if [[ -z $name && -n $cur ]]; then return 0; fi
    if ! name_check "$name"; then
      warn "$MSG"; sleep 2; continue
    fi
    cls; gradient_bar; echo
    banner_print "$name"
    echo
    rd "¿Confirmar este nombre? [S/n]: " ans || return 1
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

default_name() {   # sin interacción: usa el hostname
  [[ -s $NAME_F ]] && return 0
  local h; h=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9._-' | cut -c1-9)
  printf '%s\n' "${h:-VPS}" > "$NAME_F"
  [[ -s $REG_F ]] || date +%d/%m/%Y > "$REG_F"
}

cfg_vpsname() { register_vps; }

# ------------------------- Preparación del sistema --------------------
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
# Instalación 100% automática: descarga el binario, lo verifica, crea la
# configuración y el servicio. No hay que copiar ni pegar ningún enlace.
inst_udp() {
  ensure_base
  if ! is_on udp && ss -H -lun "sport = :$PORT_UDP" 2>/dev/null | grep -q .; then
    err "El puerto UDP $PORT_UDP ya está en uso"; return 1
  fi
  case $(uname -m) in
    x86_64|amd64) ;;
    *) err "UDP Custom solo tiene binario para x86_64 (este servidor es $(uname -m))"; return 1 ;;
  esac

  local dir=/etc/udp-custom tmp url=${UDPCUSTOM_URL:-$UDP_BIN_URL} sum excl
  tmp=$(mktemp)
  if ! spin "Descargando UDP Custom" \
       curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 -o "$tmp" "$url"; then
    err "No se pudo descargar UDP Custom. Revisa la conexión del VPS."
    rm -f "$tmp"; return 1
  fi
  if [[ $(head -c4 "$tmp" | od -An -tx1 | tr -d ' \n') != 7f454c46 ]]; then
    err "El archivo descargado no es un ejecutable válido."
    rm -f "$tmp"; return 1
  fi
  if [[ -z $UDPCUSTOM_URL ]]; then
    sum=$(sha256sum "$tmp" | awk '{print $1}')
    if [[ $sum != "$UDP_BIN_SHA256" ]]; then
      err "La verificación SHA256 falló: el archivo no es el esperado. No se instaló."
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

conf_udp() {   # configuración y servicio de UDP Custom con el puerto actual
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
  box_top "PUERTOS A USAR"
  grid row "$(pcell DROPBEAR "$PORT_DROPBEAR")"   "$(pcell SSL "$PORT_SSL")" \
           "$(pcell WEBSOCKET "$PORT_WS")"        "$(pcell SQUID "$PORT_SQUID")" \
           "$(pcell V2RAY "$PORT_V2RAY")"         "$(pcell BADVPN "$PORT_BADVPN")" \
           "$(pcell 'UDP CUSTOM' "$PORT_UDP")"
  box_bottom
}

install_all() {
  ensure_base
  local item n=0 total=7 a
  # Con --install-all (o sin teclado) todo es automático con los puertos actuales
  if [[ -z ${INSTALL_AUTO:-} && -t 0 ]]; then
    show_ports_plan
    while :; do
      printf '\n  %sENTER%s instalar ahora   %sP%s cambiar puertos   %s0%s cancelar\n' "$ACC" "$RST" "$ACC" "$RST" "$ACC" "$RST"
      rd "Opción: " a || return 1
      case ${a,,} in
        "") break ;;
        p)  sub_header "CAMBIAR PUERTOS"; ports_wizard; echo; show_ports_plan ;;
        0)  return 0 ;;
      esac
    done
  fi
  for item in "inst_dropbear:Dropbear" "inst_ssl:SSL (stunnel)" "inst_badvpn:BadVPN UDPGW" \
              "inst_ws:WebSocket" "inst_squid:Squid" "inst_v2ray:V2Ray" "inst_udp:UDP Custom"; do
    n=$(( n + 1 ))
    printf '\n  %s[%d/%d]%s %s%s%s\n' "$ACC2" "$n" "$total" "$RST" "$HI" "${item#*:}" "$RST"
    "${item%%:*}" || warn "${item#*:} no se pudo instalar; se continúa con el resto"
  done
  echo
  cfg_bbr
  echo
  ok "Instalación completa. Abre el panel con: $(panel_cmd)"
}

# --------------------------- Cuentas SSH / Dropbear -------------------
show_ssh_info() { # usuario clave expira limite
  local h; h=$(get_host); h=${h:0:$(( IW - 9 ))}
  echo
  box_top "CUENTA SSH"
  box_row "$(kv Host "$h")"
  box_row "$(kv Usuario "$1")"
  box_row "$(kv Clave "$2")"
  box_cols "$(kv Expira "$3")" "$(kv Limite "$4")"
  box_bottom
  box_top "PUERTOS"
  grid row "$(pcell SSH "$SSH_PORT")" "$(pcell Dropbear "$PORT_DROPBEAR")" \
           "$(pcell SSL "$PORT_SSL")" "$(pcell WebSocket "$PORT_WS")" \
           "$(pcell Squid "$PORT_SQUID")" "$(pcell 'UDP Custom' "$PORT_UDP")"
  box_bottom
  printf '\n  %sUDPGW%s   127.0.0.1:%s\n' "$DIM" "$RST" "$PORT_BADVPN"
  printf '  %sPayload WS%s\n  GET / HTTP/1.1[crlf]Host: %s[crlf]Upgrade: websocket[crlf][crlf]\n' "$DIM" "$RST" "$(get_host)"
}

ssh_list() {
  local u p e l n=0 today col
  today=$(date +%F)
  printf '  %s%-16s %-12s %-11s %s%s\n' "$HI" USUARIO CLAVE EXPIRA LIM "$RST"
  printf '  %s%s%s\n' "$DIM" "$(rep "$GH" $(( UW - 4 )))" "$RST"
  while IFS='|' read -r u p e l; do
    [[ -n $u ]] || continue
    if [[ $e < $today ]]; then col=$ERC; else col=$TXT; fi
    printf '  %s%-16s %-12s %-11s %-3s%s\n' "$col" "$u" "$p" "$e" "$l" "$RST"
    n=$(( n + 1 ))
  done < "$USERDB"
  (( n )) || printf '  %s(sin cuentas)%s\n' "$DIM" "$RST"
  printf '\n  %sTotal: %d   (en rojo: vencidas)%s\n' "$DIM" "$n" "$RST"
}

ssh_online() {
  local u p e l n tot=0
  printf '  %s%-16s %s%s\n' "$HI" USUARIO CONEXIONES "$RST"
  printf '  %s%s%s\n' "$DIM" "$(rep "$GH" $(( UW - 4 )))" "$RST"
  while IFS='|' read -r u p e l; do
    [[ -n $u ]] || continue
    n=$(ps -u "$u" -o comm= 2>/dev/null | grep -cE '^(sshd|dropbear)$')
    if (( n > 0 )); then printf '  %s%-16s%s %s%s%s\n' "$TXT" "$u" "$RST" "$OKC" "$n" "$RST"; tot=$(( tot + n )); fi
  done < "$USERDB"
  printf '\n  %sTotal conexiones: %d%s\n' "$DIM" "$tot" "$RST"
}

menu_ssh() {
  ensure_base
  local o n
  while :; do
    n=$(grep -c . "$USERDB" 2>/dev/null); n=${n:-0}
    sub_header "CUENTAS SSH / DROPBEAR"
    box_top "ACCIONES  ($n cuentas)"
    grid col "$(mcell 01 'Crear cuenta')" "$(mcell 02 'Eliminar cuenta')" \
             "$(mcell 03 'Renovar cuenta')" "$(mcell 04 'Cambiar clave')" \
             "$(mcell 05 'Listar cuentas')" "$(mcell 06 'Conectados')" \
             "$(mcell 07 'Limpiar vencidas')" "$(mcell 00 'Volver')"
    box_bottom
    ask Opción o || return
    [[ $o =~ ^[0-9]+$ ]] && o=$(( 10#$o ))
    case $o in
      1) sub_header "CREAR CUENTA SSH";      ssh_create ;;
      2) sub_header "ELIMINAR CUENTA SSH";   ssh_delete ;;
      3) sub_header "RENOVAR CUENTA SSH";    ssh_renew ;;
      4) sub_header "CAMBIAR CLAVE";         ssh_passwd ;;
      5) sub_header "CUENTAS SSH";           ssh_list ;;
      6) sub_header "USUARIOS CONECTADOS";   ssh_online ;;
      7) sub_header "LIMPIAR VENCIDAS";      /usr/local/bin/vps-cleanup && ok "Cuentas expiradas eliminadas" ;;
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
  valid_name "$n" || { err "Nombre inválido (3-31 caracteres: a-z 0-9 _ -)"; return 1; }
  if grep -q "^${n}|" "$V2DB"; then err "La cuenta ya existe"; return 1; fi
  rd "Días de validez [30]: " d; d=${d:-30}
  [[ $d =~ ^[0-9]+$ ]] || { err "Días inválidos"; return 1; }
  id=$(cat /proc/sys/kernel/random/uuid)
  exp=$(date -d "+$d days" +%F)
  v2_edit --arg id "$id" --arg em "$n" \
    '.inbounds[0].settings.clients += [{"id":$id,"alterId":0,"email":$em}]' || return 1
  echo "$n|$id|$exp" >> "$V2DB"
  systemctl restart v2ray
  echo
  box_top "CUENTA V2RAY"
  box_row "$(kv Cuenta "$n")"
  box_cols "$(kv Expira "$exp")" "$(kv Puerto "$PORT_V2RAY")"
  box_cols "$(kv Red ws)" "$(kv Path "$V2PATH")"
  box_bottom
  printf '\n  %sUUID%s\n  %s\n' "$DIM" "$RST" "$id"
  printf '\n  %sEnlace%s\n  %s\n' "$DIM" "$RST" "$(v2_link "$n" "$id")"
}

v2_list() {
  local n id e c=0 today col
  today=$(date +%F)
  while IFS='|' read -r n id e; do
    [[ -n $n ]] || continue
    if [[ $e < $today ]]; then col=$ERC; else col=$OKC; fi
    printf '  %s%s%s   %sexpira %s%s%s\n' "$HI" "$n" "$RST" "$DIM" "$col" "$e" "$RST"
    printf '  %s%s%s\n\n' "$DIM" "$(v2_link "$n" "$id")" "$RST"
    c=$(( c + 1 ))
  done < "$V2DB"
  (( c )) || printf '  %s(sin cuentas)%s\n' "$DIM" "$RST"
  printf '  %sTotal: %d%s\n' "$DIM" "$c" "$RST"
}

menu_v2() {
  ensure_base
  local o n
  while :; do
    n=$(grep -c . "$V2DB" 2>/dev/null); n=${n:-0}
    sub_header "CUENTAS V2RAY"
    box_top "ACCIONES  ($n cuentas)"
    grid col "$(mcell 01 'Crear cuenta')" "$(mcell 02 'Eliminar cuenta')" \
             "$(mcell 03 'Renovar cuenta')" "$(mcell 04 'Listar / enlaces')" \
             "$(mcell 00 'Volver')"
    box_bottom
    ask Opción o || return
    [[ $o =~ ^[0-9]+$ ]] && o=$(( 10#$o ))
    case $o in
      1) sub_header "CREAR CUENTA V2RAY";    v2_create ;;
      2) sub_header "ELIMINAR CUENTA V2RAY"; v2_delete ;;
      3) sub_header "RENOVAR CUENTA V2RAY";  v2_renew ;;
      4) sub_header "CUENTAS V2RAY";         v2_list ;;
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

load_ports() {   # lee /etc/vpspanel/ports.conf validando cada línea
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

port_check() {   # clave puerto -> 0 si sirve (deja el número en PCHK); si no, el motivo en MSG
  local k=$1 p=$2 o
  if ! [[ $p =~ ^[0-9]{1,5}$ ]] || (( 10#$p < 1 || 10#$p > 65535 )); then MSG="Puerto inválido (1-65535)."; return 1; fi
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
    if ss -H -lun "sport = :$p" 2>/dev/null | grep -q .; then MSG="El puerto UDP $p ya está en uso."; return 1; fi
  elif port_busy "$p"; then
    MSG="El puerto $p ya está en uso por otro programa."; return 1
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

apply_proto() {   # clave -> reescribe su configuración con los puertos actuales (solo si está instalado)
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

apply_chain() {   # clave -> la aplica y también a los que dependen de su puerto
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
  printf '\n  %sENTER = conservar el valor actual.%s\n\n' "$DIM" "$RST"
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
  rd "¿Restaurar los puertos por defecto? (s/N): " c
  [[ $c == [sS] ]] || return 0
  for k in "${PORT_KEYS[@]}"; do printf -v "${PVAR[$k]}" '%s' "${PDEF[$k]}"; done
  V2PATH=/v2ray
  save_ports
  ok "Puertos restaurados"
  for k in dropbear ws squid ssl v2ray badvpn udp slowdns; do apply_proto "$k"; done
}

v2_path_set() {
  local p
  proto_installed v2ray || { err "V2Ray no está instalado."; return 1; }
  rd "Nuevo path de V2Ray [$V2PATH]: " p
  [[ -z $p ]] && { info "Sin cambios"; return 0; }
  [[ $p == /* ]] || p="/$p"
  [[ $p =~ ^/[A-Za-z0-9._~/-]{1,40}$ ]] || { err "Path inválido (letras, números y . _ ~ - /)"; return 1; }
  V2PATH=$p; save_ports
  ok "Path de V2Ray: $V2PATH"
  apply_proto v2ray
  info "Vuelve a copiar los enlaces: Cuentas V2Ray > Listar."
}

slowdns_ns() {
  local ns
  [[ -x /usr/local/bin/dnstt-server ]] || { err "SlowDNS no está instalado."; return 1; }
  info "NameServer actual: $(cat "$BASE/slowdns/ns" 2>/dev/null || echo -)"
  rd "Nuevo NameServer (NS), ej. ns.midominio.com: " ns
  [[ $ns =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { err "NameServer inválido"; return 1; }
  echo "$ns" > "$BASE/slowdns/ns"
  unit_slowdns
}

proto_menu() {   # clave nombre
  local k=$1 nm=$2 o lbl st
  case $k in openvpn|wireguard) sub_header "$nm"; proto_action "$k"; pause; return ;; esac
  while :; do
    if is_on "$k"; then st="${OKC}${GDOT} ACTIVO${RST}"; lbl=Detener
    elif proto_installed "$k"; then st="${DIM}${GRING} DETENIDO${RST}"; lbl=Activar
    else st="${DIM}${GRING} NO INSTALADO${RST}"; lbl=Instalar; fi
    sub_header "$nm"
    box_top "ESTADO"
    box_cols "$(kv Estado "$st")" "$(kv Puerto "$(pget "$k")")"
    [[ $k == v2ray ]]   && box_row "$(kv Path "$V2PATH")"
    [[ $k == slowdns ]] && box_row "$(kv NS "$(cat "$BASE/slowdns/ns" 2>/dev/null || echo -)")"
    box_bottom
    box_top "ACCIONES"
    case $k in
      v2ray)   grid col "$(mcell 01 "$lbl")" "$(mcell 02 'Cambiar puerto')" "$(mcell 03 'Cambiar path')" "$(mcell 00 Volver)" ;;
      slowdns) grid col "$(mcell 01 "$lbl")" "$(mcell 02 'Cambiar puerto')" "$(mcell 03 'Cambiar NameServer')" "$(mcell 00 Volver)" ;;
      *)       grid col "$(mcell 01 "$lbl")" "$(mcell 02 'Cambiar puerto')" "$(mcell 00 Volver)" ;;
    esac
    box_bottom
    ask Opción o || return
    [[ $o =~ ^[0-9]+$ ]] && o=$(( 10#$o ))
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
  local i k n stt prt
  local -a cells
  while :; do
    cells=()
    for i in "${!PROTO_KEYS[@]}"; do
      k=${PROTO_KEYS[i]}
      if is_on "$k"; then stt="${OKC}${GDOT} ON ${RST}"; else stt="${DIM}${GRING} OFF${RST}"; fi
      prt=''; [[ -n ${PVAR[$k]:-} ]] && prt=":$(pget "$k")"
      cells+=( "$(printf '%s%02d%s  %s%-10s%s %s %s%s%s' "$ACC" $(( i + 1 )) "$RST" "$TXT" "${PROTO_NAMES[i]}" "$RST" "$stt" "$DIM" "$prt" "$RST")" )
    done
    sub_header "PROTOCOLOS"
    box_top "ESTADO Y PUERTOS"
    grid col "${cells[@]}"
    box_bottom
    box_top "OPCIONES"
    box_row "$(mcell 11 'Cambiar todos los puertos')"
    box_row "$(mcell 12 'Restaurar puertos por defecto')"
    box_row "$(mcell 00 Volver)"
    box_bottom
    printf '\n  %sElige un protocolo para activarlo, detenerlo o personalizarlo.%s\n' "$DIM" "$RST"
    ask Opción n || return
    [[ $n =~ ^[0-9]+$ ]] && n=$(( 10#$n ))
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
menu_tools() {
  local o a b
  while :; do
    if banner_on; then b="${OKC}${GDOT} ON${RST}"; else b="${DIM}${GRING} OFF${RST}"; fi
    if autostart_on; then a="${OKC}${GDOT} ON${RST}"; else a="${DIM}${GRING} OFF${RST}"; fi
    sub_header "HERRAMIENTAS Y AJUSTES"
    box_top "AJUSTES"
    grid col "$(mcell 01 'Banner SSH') $b" "$(mcell 02 'Aceleración BBR')" \
             "$(mcell 03 'Memoria swap')" "$(mcell 04 'Limpiar caché')" \
             "$(mcell 05 'Configurar DNS')" "$(mcell 06 'Dominio / SSL')" \
             "$(mcell 07 'Clave root')" "$(mcell 08 'Reiniciar servicios')" \
             "$(mcell 09 'Auto-inicio') $a" "$(mcell 10 'Nombre del VPS')"
    box_bottom
    printf '\n  %s00%s  Volver\n' "$ACC" "$RST"
    ask Opción o || return
    [[ $o =~ ^[0-9]+$ ]] && o=$(( 10#$o ))
    case $o in
      1)  sub_header "BANNER SSH"; cfg_banner; [[ $? == 3 ]] && continue ;;
      2)  sub_header "ACELERACION BBR";       cfg_bbr ;;
      3)  sub_header "MEMORIA SWAP";          cfg_swap ;;
      4)  sub_header "LIMPIAR CACHE Y LOGS";  cfg_cache ;;
      5)  sub_header "CONFIGURAR DNS";        cfg_dns ;;
      6)  sub_header "DOMINIO Y CERTIFICADO"; cfg_domain ;;
      7)  sub_header "CLAVE Y ACCESO ROOT";   cfg_root ;;
      8)  sub_header "REINICIAR SERVICIOS";   restart_services ;;
      9)  toggle_autostart ;;
      10) cfg_vpsname; continue ;;
      0)  return ;;
      *)  continue ;;
    esac
    pause
  done
}

# ---------------------------------- Menú ------------------------------
fmt_mb() { local m=$1; if (( m >= 1024 )); then printf '%d.%dG' $(( m / 1024 )) $(( (m % 1024) * 10 / 1024 )); else printf '%dM' "$m"; fi; }

sys_stats() {
  local l1 n mt mu dt du up d h m
  read -r l1 _ < /proc/loadavg
  n=$(nproc 2>/dev/null || echo 1)
  CPU_P=$(awk -v l="$l1" -v n="$n" 'BEGIN{p=l/n*100; if(p>100)p=100; printf "%d", p}')
  CPU_X="carga $l1"
  read -r mt mu < <(free -m | awk '/^Mem:/{print $2, $3}')
  mt=${mt:-0}; mu=${mu:-0}
  RAM_P=$(( mt > 0 ? mu * 100 / mt : 0 ))
  RAM_X="$(fmt_mb "$mu")/$(fmt_mb "$mt")"
  read -r dt du < <(df -Pm / | awk 'NR==2{print $2, $3}')
  dt=${dt:-0}; du=${du:-0}
  DSK_P=$(( dt > 0 ? du * 100 / dt : 0 ))
  DSK_X="$(fmt_mb "$du")/$(fmt_mb "$dt")"
  up=$(cut -d. -f1 /proc/uptime); d=$(( up / 86400 )); h=$(( up % 86400 / 3600 )); m=$(( up % 3600 / 60 ))
  if (( d > 0 )); then UPT="${d}d ${h}h ${m}m"; else UPT="${h}h ${m}m"; fi
}

res_line() {   # etiqueta porcentaje detalle
  local bw=$(( IW - 28 )); (( bw < 6 )) && bw=6
  box_row "$(printf '%s%-6s%s ' "$DIM" "$1" "$RST")$(bar "$2" "$bw") $(printf '%s%3d%%%s %s%s%s' "$HI" "$2" "$RST" "$DIM" "$3" "$RST")"
}

svc_cell() {   # clave etiqueta puerto
  local dot col
  if is_on "$1"; then dot=$GDOT; col=$OKC; else dot=$GRING; col=$DIM; fi
  printf '%s%s%s %s%-10s%s %s%s%s' "$col" "$dot" "$RST" "$TXT" "$2" "$RST" "$DIM" "$3" "$RST"
}

header() {
  local name reg sub sp
  name=$(vps_name); reg=$(cat "$REG_F" 2>/dev/null)
  cls
  gradient_bar
  echo
  banner_print "${name:-VPS PANEL}"
  echo
  sub="ADMINISTRADOR DE VPS  ${SEP}  v${VERSION}"
  sp=$(( (UW - ${#sub}) / 2 )); (( sp < 1 )) && sp=1
  printf '%*s%sADMINISTRADOR DE VPS%s  %s%s%s  %sv%s%s\n\n' "$sp" '' "$HI" "$RST" "$DIM" "$SEP" "$RST" "$ACC2" "$VERSION" "$RST"
  sys_stats
  box_top "SERVIDOR"
  box_cols "$(kv IP "$IP" "$IPC")" "$(kv Hora "$(date +%H:%M:%S)")"
  box_row "$(kv Sistema "${OS_NAME:0:$(( IW - 9 ))}")"
  box_cols "$(kv Registro "${reg:--}")" "$(kv Activo "$UPT")"
  res_line CPU   "$CPU_P" "$CPU_X"
  res_line RAM   "$RAM_P" "$RAM_X"
  res_line DISCO "$DSK_P" "$DSK_X"
  box_bottom
  box_top "SERVICIOS"
  grid row "$(svc_cell ssh SSH "$SSH_PORT")"            "$(svc_cell dropbear DROPBEAR "$PORT_DROPBEAR")" \
           "$(svc_cell ssl SSL "$PORT_SSL")"            "$(svc_cell ws WEBSOCKET "$PORT_WS")" \
           "$(svc_cell squid SQUID "$PORT_SQUID")"      "$(svc_cell v2ray V2RAY "$PORT_V2RAY")" \
           "$(svc_cell badvpn BADVPN "$PORT_BADVPN")"   "$(svc_cell udp 'UDP CUSTOM' "$PORT_UDP")" \
           "$(svc_cell slowdns SLOWDNS "$PORT_SLOWDNS")" "$(svc_cell openvpn OPENVPN -)" \
           "$(svc_cell wireguard WIREGUARD -)"
  box_bottom
  box_top "MENU"
  grid col "$(mcell 01 'Cuentas SSH')" "$(mcell 02 'Cuentas V2Ray')" \
           "$(mcell 03 'Protocolos')" "$(mcell 04 'Herramientas')" \
           "$(mcell 05 'Instalar todo')" "$(mcell 06 'Desinstalar' "$ERC")" \
           "$(mcell 07 'Reiniciar VPS')" "$(mcell 00 'Salir')"
  box_bottom
}

main_menu() {
  local o c
  while :; do
    header
    ask Opción o || exit 0
    [[ $o =~ ^[0-9]+$ ]] && o=$(( 10#$o ))
    case $o in
      1) menu_ssh ;;
      2) menu_v2 ;;
      3) ensure_base; menu_protocols ;;
      4) menu_tools ;;
      5) sub_header "INSTALACION COMPLETA"; install_all; pause ;;
      6) sub_header "DESINSTALAR PANEL"; uninstall_all; pause ;;
      7) rd "¿Reiniciar el VPS ahora? (s/N): " c; [[ $c == [sS] ]] && reboot ;;
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
  trap 'printf "\e[?25h"' EXIT
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
