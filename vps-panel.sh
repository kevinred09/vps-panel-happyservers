#!/usr/bin/env bash
# ======================================================================
#  VPS PANEL v2.0 - instalador y administrador de protocolos para túneles
#  Compatible con HTTP Custom y apps similares.
#  SSH · Dropbear · SSL · WebSocket · Squid · V2Ray · BadVPN-UDPGW
#  UDP Custom · SlowDNS · OpenVPN · WireGuard
#  Sistemas: Ubuntu 20.04/22.04/24.04 y Debian 11/12 (como root)
#
#  En el primer inicio pide el registro del VPS (nombre y tema de color)
#  y dibuja un banner con ese nombre en todas las pantallas.
#
#  Uso:
#    bash vps-panel.sh                 menú interactivo (instala "vpspanel")
#    bash vps-panel.sh --install-all   instalación completa sin menú
#    bash vps-panel.sh --register      repetir el registro del VPS
#    UDPCUSTOM_URL=<url> vpspanel      URL del binario udp-custom
#
#  Variables opcionales: NO_COLOR=1 (sin colores), VPSPANEL_TRUECOLOR=1
#  (degradados de 24 bits si la terminal los soporta).
# ======================================================================

set -u
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export VPSPANEL_ACTIVE=1
shopt -s extglob

# Locale UTF-8: necesario para dibujar el banner y las cajas.
for _l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  if [[ $(LC_ALL=$_l locale charmap 2>/dev/null) == UTF-8 ]]; then
    export LC_ALL=$_l LANG=$_l
    break
  fi
done
unset _l

[[ $EUID -eq 0 ]] || { echo "Ejecuta como root."; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo "Se requiere systemd."; exit 1; }
# ------------------------------ Configuración -------------------------
PANEL_VER=2.0
BASE=/etc/vpspanel
USERDB=$BASE/users.db
V2DB=$BASE/v2ray.db
BANNER=$BASE/banner
CERT=$BASE/cert.pem
DOMAIN_F=$BASE/domain
CONF=$BASE/vps.conf
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

SSH_PORT=$(awk 'tolower($1)=="port"{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
SSH_PORT=${SSH_PORT:-22}

OVPN_URL=https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
WG_URL=https://raw.githubusercontent.com/angristan/wireguard-install/master/wireguard-install.sh
V2_INSTALL_URL=https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh
BADVPN_REPO=https://github.com/ambrop72/badvpn.git
DNSTT_REPO=https://www.bamsoftware.com/git/dnstt.git
GO_VERSION=1.22.5

mkdir -p "$BASE"
touch "$USERDB" "$V2DB"
chmod 600 "$USERDB" "$V2DB"


# ============================== INTERFAZ ==============================
ML="  "        # margen izquierdo
FLASH=""       # aviso de una sola vez, se muestra sobre el prompt
T_COLS=80; T_ROWS=30; UW=62; IW=58; CW=28; TWO_COL=1

if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then UI_COLOR=1; else UI_COLOR=0; fi
COLOR_MODE=auto    # auto | 24 | 256  (se guarda en el registro)
TRUECOLOR=0
set_colormode() { # aplica COLOR_MODE a TRUECOLOR
  case $COLOR_MODE in
    24)  TRUECOLOR=1 ;;
    256) TRUECOLOR=0 ;;
    *)   TRUECOLOR=0
         if [[ ${COLORTERM:-} == *truecolor* || ${COLORTERM:-} == *24bit* || ${VPSPANEL_TRUECOLOR:-0} == 1 ]]; then
           TRUECOLOR=1
         fi ;;
  esac
}
set_colormode

if (( UI_COLOR )); then
  N=$'\e[0m'; BD=$'\e[1m'
  DIM=$'\e[38;5;245m'; BRD=$'\e[38;5;240m'; WHT=$'\e[39m'
  GRN=$'\e[38;5;42m'; RED=$'\e[38;5;203m'; YEL=$'\e[38;5;221m'
  T_INFO=$'\e[1;48;5;31;38;5;255m INFO  \e[0m'
  T_OK=$'\e[1;48;5;35;38;5;16m  OK   \e[0m'
  T_ERR=$'\e[1;48;5;160;38;5;255m ERROR \e[0m'
  T_WRN=$'\e[1;48;5;178;38;5;16m AVISO \e[0m'
else
  N=''; BD=''; DIM=''; BRD=''; WHT=''; GRN=''; RED=''; YEL=''
  T_INFO='[INFO] '; T_OK='[ OK ] '; T_ERR='[ERROR]'; T_WRN='[AVISO]'
fi

# ---- Temas de color: nombre|inicio|medio|fin (RGB) ----
THEMES=(
  "Aurora|0,230,170|0,160,255|140,90,255"
  "Ciber|0,229,255|80,140,255|205,100,255"
  "Fuego|255,225,80|255,140,40|255,60,100"
  "Oceano|110,245,210|40,175,235|50,90,225"
  "Atardecer|255,200,100|255,100,150|165,85,235"
  "Esmeralda|190,245,100|60,215,130|0,160,175"
)
TH_R=(0 0 0); TH_G=(0 0 0); TH_B=(0 0 0); TH_NAME=""
A1=''; A2=''; A3=''
GRAD=(); GRADD=()
BAN_KEY=''; BAN_RAW=(); BAN_ROWS=(); BAN_W=0; BAN_KIND=1; SIDE_USED=0; SIDE=()
VPS_NAME=""; VPS_NAME_UP="VPS PANEL"; VPS_THEME=1; VPS_DATE=""; VPS_DATE_TXT="-"
OS_NAME=""

rgb_fg() { # r g b -> REPLY (secuencia de color de primer plano)
  if (( ! UI_COLOR )); then REPLY=''; return 0; fi
  if (( TRUECOLOR )); then
    REPLY=$'\e[38;2;'"$1;$2;$3"m
  else
    local r=$1 g=$2 b=$3
    (( r = r < 48 ? 0 : (r < 115 ? 1 : (r - 35) / 40) ))
    (( g = g < 48 ? 0 : (g < 115 ? 1 : (g - 35) / 40) ))
    (( b = b < 48 ? 0 : (b < 115 ? 1 : (b - 35) / 40) ))
    REPLY=$'\e[38;5;'"$(( 16 + 36 * r + 6 * g + b ))"m
  fi
}

apply_theme() { # índice (1..n)
  local i=${1:-1} entry c0 c1 c2
  (( i >= 1 && i <= ${#THEMES[@]} )) || i=1
  VPS_THEME=$i
  entry=${THEMES[i-1]}
  TH_NAME=${entry%%|*}
  IFS='|' read -r _ c0 c1 c2 <<< "$entry"
  IFS=, read -r 'TH_R[0]' 'TH_G[0]' 'TH_B[0]' <<< "$c0"
  IFS=, read -r 'TH_R[1]' 'TH_G[1]' 'TH_B[1]' <<< "$c1"
  IFS=, read -r 'TH_R[2]' 'TH_G[2]' 'TH_B[2]' <<< "$c2"
  rgb_fg "${TH_R[0]}" "${TH_G[0]}" "${TH_B[0]}"; A1=$REPLY
  rgb_fg "${TH_R[1]}" "${TH_G[1]}" "${TH_B[1]}"; A2=$REPLY
  rgb_fg "${TH_R[2]}" "${TH_G[2]}" "${TH_B[2]}"; A3=$REPLY
  rgb_fg $(( TH_R[1] * 55 / 100 )) $(( TH_G[1] * 55 / 100 )) $(( TH_B[1] * 55 / 100 )); BRD=$REPLY
  BAN_KEY=''
}

mkgrad() { # n -> GRAD[0..n-1] y GRADD[0..n-1] (variante oscura para la sombra)
  local n=$1 i p t s r g b
  GRAD=(); GRADD=()
  for (( i = 0; i < n; i++ )); do
    if (( n > 1 )); then p=$(( i * 1000 / (n - 1) )); else p=0; fi
    if (( p < 500 )); then s=0; t=$(( p * 2 )); else s=1; t=$(( (p - 500) * 2 )); fi
    r=$(( TH_R[s] + (TH_R[s+1] - TH_R[s]) * t / 1000 ))
    g=$(( TH_G[s] + (TH_G[s+1] - TH_G[s]) * t / 1000 ))
    b=$(( TH_B[s] + (TH_B[s+1] - TH_B[s]) * t / 1000 ))
    rgb_fg "$r" "$g" "$b"; GRAD[i]=$REPLY
    rgb_fg $(( r * 60 / 100 )) $(( g * 60 / 100 )) $(( b * 60 / 100 )); GRADD[i]=$REPLY
  done
}

# ---- Tamaño de la terminal y diseño adaptable ----
term_size() {
  T_COLS=$(tput cols 2>/dev/null) || T_COLS=80
  T_ROWS=$(tput lines 2>/dev/null) || T_ROWS=30
  [[ $T_COLS =~ ^[0-9]+$ ]] || T_COLS=80
  [[ $T_ROWS =~ ^[0-9]+$ ]] || T_ROWS=30
  UW=$(( T_COLS - 4 ))
  (( UW > 66 )) && UW=66
  (( UW < 24 )) && UW=24
  IW=$(( UW - 4 ))
  if (( IW >= 56 )); then TWO_COL=1; CW=$(( (IW - 2) / 2 )); else TWO_COL=0; CW=$IW; fi
}

cls() { if (( UI_COLOR )); then printf '\e[H\e[2J'; fi; return 0; }

# ---- Medición y relleno (ignora los códigos de color) ----
vlen() { local s=$1; s=${s//$'\e'\[*([0-9;])m/}; REPLY=${#s}; }
padr() { local s=${1:0:$2}; printf -v REPLY '%s%*s' "$s" $(( $2 - ${#s} )) ''; }          # texto plano
padv() { vlen "$1"; local pad=$(( $2 - REPLY )); (( pad < 0 )) && pad=0; printf -v REPLY '%s%*s' "$1" "$pad" ''; }  # con color
rep()  { if (( $2 > 0 )); then printf -v REPLY '%*s' "$2" ''; REPLY=${REPLY// /$1}; else REPLY=''; fi; }
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; REPLY=$s; }

# ---- Mensajes ----
info() { printf '%s%s %s\n' "$ML" "$T_INFO" "$*"; }
ok()   { printf '%s%s %s\n' "$ML" "$T_OK" "$*"; }
err()  { printf '%s%s %s\n' "$ML" "$T_ERR" "$*" >&2; }
warn() { printf '%s%s %s\n' "$ML" "$T_WRN" "$*"; }
flash_ok()   { FLASH="$T_OK $*"; }
flash_warn() { FLASH="$T_WRN $*"; }

note() { # párrafo ajustado al ancho, en gris
  local -a words=(); local w line=''
  read -ra words <<< "$*"
  for w in "${words[@]}"; do
    if [[ -n $line ]] && (( ${#line} + ${#w} + 1 > IW )); then
      printf '%s%s%s%s\n' "$ML" "$DIM" "$line" "$N"; line=$w
    else
      line=${line:+$line }$w
    fi
  done
  [[ -n $line ]] && printf '%s%s%s%s\n' "$ML" "$DIM" "$line" "$N"
  return 0
}

ask() { # variable "etiqueta" ["sugerencia"]
  local __v=$1 __p="$ML${A1}${BD}›${N} ${WHT}$2${N}" __r=''
  [[ -n ${3:-} ]] && __p+=" ${DIM}[$3]${N}"
  __p+="${DIM}:${N} "
  if ! read -rp "$__p" __r; then
    [[ -n $__r ]] || { echo; exit 0; }
  fi
  printf -v "$__v" '%s' "$__r"
}

pause() { local _x; printf '\n%s%s›%s %sPresiona ENTER para continuar...%s ' "$ML" "$A1" "$N" "$DIM" "$N"; read -r _x || true; }

prompt_opt() { # lee la opción en O (número sin ceros a la izquierda)
  if [[ -n $FLASH ]]; then printf '\n%s%s\n' "$ML" "$FLASH"; FLASH=''; fi
  printf '\n%s%s%s›%s %s%sOpción%s%s:%s ' "$ML" "$A1" "$BD" "$N" "$BD" "$WHT" "$N" "$DIM" "$N"
  IFS= read -r O || { echo; exit 0; }
  O=${O//[[:space:]]/}
  if [[ $O =~ ^[0-9]{1,6}$ ]]; then O=$(( 10#$O )); fi
}

spin() { # mensaje comando [args...]  -> ejecuta en segundo plano con un indicador
  local msg=$1 pid rc i=0 fr='|/-\'
  shift
  if (( ! UI_COLOR )); then "$@" >/dev/null 2>&1; return; fi
  "$@" >/dev/null 2>&1 &
  pid=$!
  printf '\e[?25l'
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s%s%s%s %s\e[K' "$ML" "$A1" "${fr:i++%4:1}" "$N" "$msg"
    sleep 0.1
  done
  wait "$pid"; rc=$?
  printf '\r\e[K\e[?25h'
  return "$rc"
}

# ---- Cajas ----
box_top() { # título
  local t=$1
  rep "─" $(( UW - ${#t} - 5 ))
  printf '%s%s╭─%s %s%s%s %s%s╮%s\n' "$ML" "$BRD" "$N" "$BD$A3" "$t" "$N" "$BRD" "$REPLY" "$N"
}
box_bot() { rep "─" $(( UW - 2 )); printf '%s%s╰%s╯%s\n' "$ML" "$BRD" "$REPLY" "$N"; }
box_row() { # contenido (puede llevar colores)
  local pad
  vlen "$1"; pad=$(( IW - REPLY )); (( pad < 0 )) && pad=0
  printf '%s%s│%s %s%*s %s│%s\n' "$ML" "$BRD" "$N" "$1" "$pad" '' "$BRD" "$N"
}
box_blank() { box_row ''; }
pair_row() { if (( TWO_COL )); then box_row "$1  $2"; else box_row "$1"; box_row "$2"; fi; }

krowc() { # etiqueta valor_coloreado
  padr "$1" 11
  box_row "${DIM}${REPLY}${N}$2"
}
krow() { krowc "$1" "${BD}${WHT}$2${N}"; } # etiqueta valor

box_ports() { # etiqueta "Nombre valor"...  (reparte los elementos en filas que caben en la caja)
  local label=$1 plain='' col='' it w=$(( IW - 11 ))
  shift
  for it in "$@"; do
    if [[ -n $plain ]] && (( ${#plain} + 3 + ${#it} > w )); then
      krowc "$label" "$col"; label=''; plain=''; col=''
    fi
    if [[ -n $plain ]]; then plain+='   '; col+='   '; fi
    plain+=$it; col+="${WHT}${it% *} ${A1}${it##* }${N}"
  done
  [[ -n $plain ]] && krowc "$label" "$col"
  return 0
}

kv() { # etiqueta valor_coloreado -> REPLY (ancho CW)
  local l
  padr "$1" 8; l=$REPLY
  padv "$2" $(( CW - 8 )); REPLY="${DIM}${l}${N}${REPLY}"
}

bar() { # porcentaje ancho -> REPLY (ancho visible = $2)
  local p=$1 w=$2 f e col s1 s2
  (( p > 100 )) && p=100
  (( p < 0 )) && p=0
  f=$(( p * w / 100 )); e=$(( w - f ))
  if (( p >= 85 )); then col=$RED; elif (( p >= 60 )); then col=$YEL; else col=$GRN; fi
  rep "█" "$f"; s1=$REPLY; rep "░" "$e"; s2=$REPLY
  REPLY="${col}${s1}${BRD}${s2}${N}"
}

section() { # título [etiqueta derecha]
  local t=$1 tag a b f
  if (( $# >= 2 )); then tag=$2; else tag="$VPS_NAME_UP v$PANEL_VER"; fi
  a=${#t}; b=${#tag}
  f=$(( UW - 4 - a - b ))
  if (( b > 0 && f < 3 )); then tag=''; b=0; fi
  if (( b > 0 )); then
    rep "─" "$f"
    printf '\n%s%s▌%s %s%s%s %s%s%s %s%s%s\n' "$ML" "$A1" "$N" "$BD$WHT" "$t" "$N" "$BRD" "$REPLY" "$N" "$A3" "$tag" "$N"
  else
    rep "─" $(( UW - 3 - a ))
    printf '\n%s%s▌%s %s%s%s %s%s%s\n' "$ML" "$A1" "$N" "$BD$WHT" "$t" "$N" "$BRD" "$REPLY" "$N"
  fi
}

back_line() { printf '\n%s%s%s00%s  %s%s%s\n' "$ML" "$RED" "$BD" "$N" "$DIM" "${1:-Volver al menú principal}" "$N"; }

# ---- Rejilla de opciones (dos columnas, orden por columnas) ----
MG_NUM=(); MG_LAB=(); MG_ST=()

cell() { # num etiqueta [estado: on|off|none]  -> REPLY (ancho CW)
  local n=$1 l=$2 s=${3-} nc=$A1 lc=$WHT st='' lw
  case $s in
    on)   st="${GRN}●${N} ${GRN}ON${N} " ;;
    off)  st="${RED}●${N} ${RED}OFF${N}" ;;
    none) st="${BRD}○ ---${N}"; nc=$BRD; lc=$DIM ;;
  esac
  if [[ -n $st ]]; then lw=$(( CW - 10 )); else lw=$(( CW - 4 )); fi
  padr "$l" "$lw"
  REPLY="${nc}${BD}${n}${N}  ${lc}${REPLY}${N}"
  [[ -n $st ]] && REPLY+=" $st"
  return 0
}

menu_grid() {
  local n=${#MG_NUM[@]} rows i j left right blank
  if (( TWO_COL )); then
    rows=$(( (n + 1) / 2 ))
    printf -v blank '%*s' "$CW" ''
    for (( i = 0; i < rows; i++ )); do
      cell "${MG_NUM[i]}" "${MG_LAB[i]}" "${MG_ST[i]-}"; left=$REPLY
      j=$(( i + rows ))
      if (( j < n )); then cell "${MG_NUM[j]}" "${MG_LAB[j]}" "${MG_ST[j]-}"; right=$REPLY; else right=$blank; fi
      box_row "$left  $right"
    done
  else
    for (( i = 0; i < n; i++ )); do
      cell "${MG_NUM[i]}" "${MG_LAB[i]}" "${MG_ST[i]-}"; box_row "$REPLY"
    done
  fi
}

# ---- Fuentes del banner ----
declare -A FB=() FBW=() FS=() FSW=()

load_fonts() {
  local c w r0 r1 r2 r3 r4 r5 k r
  # fuente grande: caracter|ancho|6 filas
  while IFS='|' read -r c w r0 r1 r2 r3 r4 r5; do
    FBW["$c"]=$w
    k=0
    for r in "$r0" "$r1" "$r2" "$r3" "$r4" "$r5"; do
      while (( ${#r} < w )); do r+=' '; done
      FB["$c:$k"]=$r
      k=$(( k + 1 ))
    done
  done <<'FONT_BIG'
A|8| █████╗|██╔══██╗|███████║|██╔══██║|██║  ██║|╚═╝  ╚═╝
B|8|██████╗|██╔══██╗|██████╔╝|██╔══██╗|██████╔╝|╚═════╝
C|8| ██████╗|██╔════╝|██║|██║|╚██████╗| ╚═════╝
D|8|██████╗|██╔══██╗|██║  ██║|██║  ██║|██████╔╝|╚═════╝
E|8|███████╗|██╔════╝|█████╗|██╔══╝|███████╗|╚══════╝
F|8|███████╗|██╔════╝|█████╗|██╔══╝|██║|╚═╝
G|9| ██████╗|██╔════╝|██║  ███╗|██║   ██║|╚██████╔╝| ╚═════╝
H|8|██╗  ██╗|██║  ██║|███████║|██╔══██║|██║  ██║|╚═╝  ╚═╝
I|3|██╗|██║|██║|██║|██║|╚═╝
J|8|     ██╗|     ██║|     ██║|██   ██║|╚█████╔╝| ╚════╝
K|8|██╗  ██╗|██║ ██╔╝|█████╔╝|██╔═██╗|██║  ██╗|╚═╝  ╚═╝
L|8|██╗|██║|██║|██║|███████╗|╚══════╝
M|11|███╗   ███╗|████╗ ████║|██╔████╔██║|██║╚██╔╝██║|██║ ╚═╝ ██║|╚═╝     ╚═╝
N|10|███╗   ██╗|████╗  ██║|██╔██╗ ██║|██║╚██╗██║|██║ ╚████║|╚═╝  ╚═══╝
O|9| ██████╗|██╔═══██╗|██║   ██║|██║   ██║|╚██████╔╝| ╚═════╝
P|8|██████╗|██╔══██╗|██████╔╝|██╔═══╝|██║|╚═╝
Q|9| ██████╗|██╔═══██╗|██║   ██║|██║▄▄ ██║|╚██████╔╝| ╚══▀▀═╝
R|8|██████╗|██╔══██╗|██████╔╝|██╔══██╗|██║  ██║|╚═╝  ╚═╝
S|8|███████╗|██╔════╝|███████╗|╚════██║|███████║|╚══════╝
T|9|████████╗|╚══██╔══╝|   ██║|   ██║|   ██║|   ╚═╝
U|9|██╗   ██╗|██║   ██║|██║   ██║|██║   ██║|╚██████╔╝| ╚═════╝
V|9|██╗   ██╗|██║   ██║|██║   ██║|╚██╗ ██╔╝| ╚████╔╝|  ╚═══╝
W|10|██╗    ██╗|██║    ██║|██║ █╗ ██║|██║███╗██║|╚███╔███╔╝| ╚══╝╚══╝
X|8|██╗  ██╗|╚██╗██╔╝| ╚███╔╝| ██╔██╗|██╔╝ ██╗|╚═╝  ╚═╝
Y|9|██╗   ██╗|╚██╗ ██╔╝| ╚████╔╝|  ╚██╔╝|   ██║|   ╚═╝
Z|8|███████╗|╚══███╔╝|  ███╔╝| ███╔╝|███████╗|╚══════╝
0|9| ██████╗|██╔═████╗|██║██╔██║|████╔╝██║|╚██████╔╝| ╚═════╝
1|4| ██╗|███║|╚██║| ██║| ██║| ╚═╝
2|8|██████╗|╚════██╗| █████╔╝|██╔═══╝|███████╗|╚══════╝
3|8|██████╗|╚════██╗| █████╔╝| ╚═══██╗|██████╔╝|╚═════╝
4|8|██╗  ██╗|██║  ██║|███████║|╚════██║|     ██║|     ╚═╝
5|8|███████╗|██╔════╝|███████╗|╚════██║|███████║|╚══════╝
6|9| ██████╗|██╔════╝|███████╗|██╔═══██╗|╚██████╔╝| ╚═════╝
7|8|███████╗|╚════██║|    ██╔╝|   ██╔╝|   ██║|   ╚═╝
8|8| █████╗|██╔══██╗|╚█████╔╝|██╔══██╗|╚█████╔╝| ╚════╝
9|8| █████╗|██╔══██╗|╚██████║| ╚═══██║| █████╔╝| ╚════╝
-|6|||█████╗|╚════╝||
_|8|||||███████╗|╚══════╝
.|3|||||██╗|╚═╝
 |3||||||
FONT_BIG
  # fuente compacta: caracter|5 filas de píxeles (se dibuja con medios bloques)
  while IFS='|' read -r c r0 r1 r2 r3 r4; do
    FSW["$c"]=${#r0}
    FS["$c:0"]=$r0; FS["$c:1"]=$r1; FS["$c:2"]=$r2; FS["$c:3"]=$r3; FS["$c:4"]=$r4
  done <<'FONT_SMALL'
A|.#.|#.#|###|#.#|#.#
B|##.|#.#|##.|#.#|##.
C|.##|#..|#..|#..|.##
D|##.|#.#|#.#|#.#|##.
E|###|#..|##.|#..|###
F|###|#..|##.|#..|#..
G|.##|#..|#.#|#.#|.##
H|#.#|#.#|###|#.#|#.#
I|###|.#.|.#.|.#.|###
J|..#|..#|..#|#.#|.#.
K|#.#|#.#|##.|#.#|#.#
L|#..|#..|#..|#..|###
M|#...#|##.##|#.#.#|#...#|#...#
N|#..#|##.#|#.##|#..#|#..#
O|###|#.#|#.#|#.#|###
P|##.|#.#|##.|#..|#..
Q|###|#.#|#.#|###|..#
R|##.|#.#|##.|#.#|#.#
S|.##|#..|.#.|..#|##.
T|###|.#.|.#.|.#.|.#.
U|#.#|#.#|#.#|#.#|###
V|#.#|#.#|#.#|#.#|.#.
W|#...#|#...#|#.#.#|##.##|#...#
X|#.#|#.#|.#.|#.#|#.#
Y|#.#|#.#|.#.|.#.|.#.
Z|###|..#|.#.|#..|###
0|###|#.#|#.#|#.#|###
1|.#.|##.|.#.|.#.|###
2|##.|..#|.#.|#..|###
3|##.|..#|.#.|..#|##.
4|#.#|#.#|###|..#|..#
5|###|#..|##.|..#|##.
6|.##|#..|###|#.#|###
7|###|..#|.#.|.#.|.#.
8|###|#.#|###|#.#|###
9|###|#.#|###|..#|##.
-|...|...|###|...|...
_|...|...|...|...|###
.|.|.|.|.|#
 |..|..|..|..|..
FONT_SMALL
}

paint() { # texto [bitono] -> REPLY con degradado por columna (usa GRAD / GRADD)
  local s=$1 two=${2:-0} x ch out=''
  for (( x = 0; x < ${#s}; x++ )); do
    ch=${s:x:1}
    if [[ $ch == ' ' ]]; then out+=' '
    elif (( two )) && [[ $ch != '█' ]]; then out+="${GRADD[x]}$ch"
    else out+="${GRAD[x]}$ch"
    fi
  done
  REPLY=$out$N
}

big_width() { local s=$1 i ch w t=0; for (( i = 0; i < ${#s}; i++ )); do ch=${s:i:1}; w=${FBW["$ch"]:-0}; t=$(( t + w )); done; REPLY=$t; }

small_render() { # nombre -> BAN_RAW[0..2]; REPLY = ancho
  local s=$1 t i ch w x a b ta tb row
  BAN_RAW=()
  for (( t = 0; t < 3; t++ )); do
    row=''
    for (( i = 0; i < ${#s}; i++ )); do
      ch=${s:i:1}
      w=${FSW["$ch"]:-0}
      (( w > 0 )) || continue
      a=${FS["$ch:$(( 2 * t ))"]}
      if (( t < 2 )); then b=${FS["$ch:$(( 2 * t + 1 ))"]}; else b=''; fi
      for (( x = 0; x < w; x++ )); do
        ta=${a:x:1}; tb=${b:x:1}; tb=${tb:-.}
        case $ta$tb in
          '##') row+='█' ;;
          '#.') row+='▀' ;;
          '.#') row+='▄' ;;
          *)    row+=' ' ;;
        esac
      done
      row+=' '
    done
    BAN_RAW[t]=${row% }
  done
  REPLY=${#BAN_RAW[0]}
}

build_banner() { # arma BAN_ROWS según el nombre, el tema y el tamaño de la terminal
  local key="$VPS_NAME_UP|$VPS_THEME|$T_COLS|$T_ROWS"
  [[ $key == "$BAN_KEY" ]] && return 0
  BAN_KEY=$key
  local s=$VPS_NAME_UP w r i ch line
  BAN_RAW=(); BAN_ROWS=(); BAN_W=0; BAN_KIND=1
  big_width "$s"; w=$REPLY
  if (( T_ROWS >= 30 && w > 0 && w + 4 <= T_COLS )); then        # banner grande (6 filas)
    for (( r = 0; r < 6; r++ )); do
      line=''
      for (( i = 0; i < ${#s}; i++ )); do ch=${s:i:1}; line+=${FB["$ch:$r"]-}; done
      BAN_RAW[r]=$line
    done
    mkgrad "$w"
    for r in "${!BAN_RAW[@]}"; do paint "${BAN_RAW[r]}" 1; BAN_ROWS[r]=$REPLY; done
    BAN_W=$w; BAN_KIND=3
    return 0
  fi
  small_render "$s"; w=$REPLY                                    # banner compacto (3 filas)
  if (( w > 0 && w + 4 <= T_COLS )); then
    mkgrad "$w"
    for r in "${!BAN_RAW[@]}"; do paint "${BAN_RAW[r]}" 0; BAN_ROWS[r]=$REPLY; done
    BAN_W=$w; BAN_KIND=2
    return 0
  fi
  line=''                                                        # una sola línea con letras espaciadas
  for (( i = 0; i < ${#s}; i++ )); do line+="${s:i:1} "; done
  line=${line% }; line=${line:0:T_COLS-4}
  w=${#line}
  mkgrad "$w"; paint "$line" 0
  BAN_ROWS=("$BD$REPLY"); BAN_W=$w; BAN_KIND=1
}

gbar() { # carácter ancho  -> barra con degradado
  local ch=$1 n=$2 i out=''
  mkgrad "$n"
  for (( i = 0; i < n; i++ )); do out+="${GRAD[i]}$ch"; done
  printf '%s%s%s\n' "$ML" "$out" "$N"
}

side_lines() { # panel de datos a la derecha del banner grande
  local pw vw now
  pw=$(( UW - BAN_W - 4 )); vw=$(( pw - 10 )); (( vw < 8 )) && vw=8
  printf -v now '%(%H:%M:%S)T' -1
  SIDE=(
    "${BD}${WHT}ADMINISTRADOR DE VPS${N}"
    "${A1}${BD}v${PANEL_VER}${N}  ${DIM}Panel de túneles${N}"
    "${DIM}REGISTRO${N}  ${WHT}${VPS_DATE_TXT}${N}"
    "${DIM}IP${N}        ${WHT}${IP:0:vw}${N}"
    "${DIM}SO${N}        ${WHT}${OS_NAME:0:vw}${N}"
    "${DIM}HORA${N}      ${WHT}${now}${N}"
  )
}

draw_logo() { # [1 = con panel lateral si cabe]
  local want=${1:-0} hw r pw line
  build_banner
  hw=$(( BAN_W > UW ? BAN_W : UW ))
  pw=$(( UW - BAN_W - 4 ))
  SIDE_USED=0
  gbar "▄" "$hw"
  if (( want && BAN_KIND == 3 && pw >= 24 )); then
    SIDE_USED=1
    side_lines
    for (( r = 0; r < ${#BAN_ROWS[@]}; r++ )); do
      printf '%s%s  %s│%s %s\n' "$ML" "${BAN_ROWS[r]}" "$A2" "$N" "${SIDE[r]}"
    done
  else
    for line in "${BAN_ROWS[@]}"; do printf '%s%s%s\n' "$ML" "$line" "$N"; done
  fi
  gbar "▀" "$hw"
}

info_band() { # título + datos en dos líneas (cuando no hay panel lateral)
  local now l r gap a b
  printf -v now '%(%H:%M:%S)T' -1
  l="${BD}${WHT}ADMINISTRADOR DE VPS${N}  ${A1}${BD}v${PANEL_VER}${N}"
  r="${DIM}HORA${N} ${WHT}${now}${N}"
  vlen "$l"; a=$REPLY; vlen "$r"; b=$REPLY
  gap=$(( UW - a - b ))
  if (( gap >= 2 )); then
    printf '%s%s%*s%s\n' "$ML" "$l" "$gap" '' "$r"
    printf '%s%sIP%s %s%s%s   %sSO%s %s%s%s\n' "$ML" "$DIM" "$N" "$WHT" "${IP:0:20}" "$N" "$DIM" "$N" "$WHT" "$OS_NAME" "$N"
  else   # terminal angosta: título arriba, datos abajo
    printf '%s%s\n' "$ML" "$l"
    printf '%s%sIP%s %s%s%s   %sHORA%s %s%s%s\n' "$ML" "$DIM" "$N" "$WHT" "${IP:0:20}" "$N" "$DIM" "$N" "$WHT" "$now" "$N"
  fi
}

draw_header() {
  term_size; cls
  draw_logo 1
  (( SIDE_USED )) || info_band
}

# ------------------------------ Utilidades ----------------------------
if (( UI_COLOR )); then printf '\r%s%sIniciando panel...%s' "$ML" "$DIM" "$N"; fi
IP=$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
if (( UI_COLOR )); then printf '\r\e[K'; fi
OS_NAME=$(. /etc/os-release 2>/dev/null; echo "${NAME%% *} ${VERSION_ID:-}")

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
PROTO_LABELS=("Dropbear" "SSL / Stunnel" "BadVPN UDPGW" "WebSocket" "Squid Proxy"
              "V2Ray" "UDP Custom" "SlowDNS" "OpenVPN" "WireGuard")

apt_i() { spin "Instalando ${1}${2:+ y dependencias}" apt-get install -y -qq "$@"; }

is_on() {
  case $1 in
    openvpn) systemctl is-active --quiet openvpn-server@server || systemctl is-active --quiet openvpn@server ;;
    *) systemctl is-active --quiet "${SVC[$1]}" ;;
  esac
}

get_host() { local d; d=$(cat "$DOMAIN_F" 2>/dev/null); echo "${d:-$IP}"; }

valid_name() { [[ $1 =~ ^[a-z_][a-z0-9_-]{2,30}$ ]]; }

rand_pass() { tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 10; }

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

# ------------------------- Preparación del sistema --------------------
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
Banner $BANNER
EOF
  if sshd -t 2>/dev/null; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
  else
    err "Configuración SSH inválida; se revierte."
    rm -f /etc/ssh/sshd_config.d/00-vpspanel.conf
  fi
}

ensure_base() {
  [[ -f $BASE/.prep ]] && return 0
  info "Preparando el sistema..."
  spin "Actualizando lista de paquetes" apt-get update -qq
  apt_i curl wget jq git unzip tar openssl iptables ca-certificates cron procps iproute2 python3
  grep -qx /bin/false /etc/shells || echo /bin/false >> /etc/shells
  [[ -s $BANNER ]] || printf '%s\n' "${VPS_NAME:-VPS PANEL}" > "$BANNER"
  install_helpers
  cfg_ssh
  touch "$BASE/.prep"
  ok "Sistema preparado"
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
  mkunit vps-dropbear "Dropbear SSH" \
    "$(command -v dropbear) -F -E -R -p $PORT_DROPBEAR -b $BANNER -K 30"
  fw_open "$PORT_DROPBEAR" tcp
  verify dropbear Dropbear
}

inst_ssl() {
  ensure_base; need_port ssl "$PORT_SSL" || return 1
  info "Instalando SSL (stunnel)..."
  apt_i stunnel4 || { err "Fallo al instalar stunnel4"; return 1; }
  systemctl disable --now stunnel4 >/dev/null 2>&1
  [[ -s $CERT ]] || mk_selfsigned "$(get_host)"
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

build_badvpn() { # directorio temporal
  local t=$1
  git clone -q --depth 1 "$BADVPN_REPO" "$t/src" \
    && mkdir "$t/build" \
    && (cd "$t/build" \
        && cmake ../src -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null 2>&1 \
        && make -j"$(nproc)" >/dev/null 2>&1) \
    && install -m755 "$t/build/udpgw/badvpn-udpgw" /usr/local/bin/badvpn-udpgw
}

inst_badvpn() {
  ensure_base; need_port badvpn "$PORT_BADVPN" || return 1
  info "Compilando BadVPN-UDPGW..."
  apt_i build-essential cmake git || { err "Fallo al instalar dependencias de compilación"; return 1; }
  local t rc; t=$(mktemp -d)
  spin "Compilando BadVPN-UDPGW (puede tardar)" build_badvpn "$t"
  rc=$?
  rm -rf "$t"
  (( rc == 0 )) || { err "Fallo al compilar badvpn-udpgw"; return 1; }
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
  mkunit vps-ws "Proxy WebSocket a SSH" \
    "$(command -v python3) /usr/local/bin/vps-ws.py $PORT_WS $SSH_PORT $PORT_DROPBEAR"
  fw_open "$PORT_WS" tcp
  verify ws "WebSocket"
}

inst_squid() {
  ensure_base; need_port squid "$PORT_SQUID" || return 1
  info "Instalando Squid..."
  apt_i squid || { err "Fallo al instalar squid"; return 1; }
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
  spin "Descargando e instalando V2Ray" fetch_run "$V2_INSTALL_URL" || { err "Fallo al instalar V2Ray"; return 1; }
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

inst_udp() {
  ensure_base
  local f=$BASE/udp.url
  [[ -z $UDPCUSTOM_URL && -s $f ]] && UDPCUSTOM_URL=$(<"$f")
  if [[ -z $UDPCUSTOM_URL ]]; then
    ask UDPCUSTOM_URL "URL del binario udp-custom (linux $(uname -m))"
  fi
  [[ $UDPCUSTOM_URL =~ ^https?:// ]] || { err "URL inválida"; return 1; }
  echo "$UDPCUSTOM_URL" > "$f"
  info "Descargando UDP Custom..."
  mkdir -p /etc/udp-custom
  spin "Descargando UDP Custom" curl -fsSL "$UDPCUSTOM_URL" -o /etc/udp-custom/udp-custom || { err "Descarga fallida"; return 1; }
  chmod +x /etc/udp-custom/udp-custom
  cat > /etc/udp-custom/config.json <<EOF
{
  "listen": ":$PORT_UDP",
  "stream_buffer": 33554432,
  "receive_buffer": 83886080,
  "auth": { "mode": "passwords" }
}
EOF
  mkunit udp-custom "UDP Custom" \
    "/etc/udp-custom/udp-custom server -exclude 53,$PORT_SLOWDNS" \
    "WorkingDirectory=/etc/udp-custom"
  fw_open "$PORT_UDP" udp
  verify udp "UDP Custom"
}

build_dnstt() { (cd /tmp/dnstt/dnstt-server && /usr/local/go/bin/go build -o /usr/local/bin/dnstt-server .); }

inst_slowdns() {
  ensure_base
  local ns ga ipt=/usr/sbin/iptables
  ask ns "NameServer (NS) del dominio" "ej. ns.midominio.com"
  [[ $ns =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { err "NameServer inválido"; return 1; }
  case $(uname -m) in
    x86_64)  ga=amd64 ;;
    aarch64) ga=arm64 ;;
    *) err "Arquitectura no soportada"; return 1 ;;
  esac
  info "Compilando dnstt-server (Go $GO_VERSION)..."
  if [[ ! -x /usr/local/go/bin/go ]]; then
    spin "Descargando Go $GO_VERSION" curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ga}.tar.gz" -o /tmp/go.tgz \
      || { err "No se pudo descargar Go"; return 1; }
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tgz
    rm -f /tmp/go.tgz
  fi
  rm -rf /tmp/dnstt
  spin "Clonando dnstt" git clone -q "$DNSTT_REPO" /tmp/dnstt || { err "No se pudo clonar dnstt"; return 1; }
  spin "Compilando dnstt-server" build_dnstt \
    || { err "Fallo al compilar dnstt-server"; rm -rf /tmp/dnstt; return 1; }
  rm -rf /tmp/dnstt

  mkdir -p "$BASE/slowdns"
  [[ -s $BASE/slowdns/server.key ]] || dnstt-server -gen-key \
    -privkey-file "$BASE/slowdns/server.key" -pubkey-file "$BASE/slowdns/server.pub" >/dev/null
  echo "$ns" > "$BASE/slowdns/ns"

  mkunit vps-slowdns "SlowDNS (dnstt)" \
    "/usr/local/bin/dnstt-server -udp :$PORT_SLOWDNS -privkey-file $BASE/slowdns/server.key $ns 127.0.0.1:$SSH_PORT" \
    "ExecStartPre=-$ipt -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports $PORT_SLOWDNS
ExecStartPre=$ipt -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports $PORT_SLOWDNS
ExecStopPost=-$ipt -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports $PORT_SLOWDNS"
  fw_open 53 udp; fw_open "$PORT_SLOWDNS" udp
  verify slowdns SlowDNS || return 1
  echo
  printf '%s%sNameServer%s     %s%s%s\n' "$ML" "$DIM" "$N" "$BD" "$ns" "$N"
  printf '%s%sLlave pública%s\n' "$ML" "$DIM" "$N"
  printf '%s%s%s%s\n' "$ML" "$BD" "$(cat "$BASE/slowdns/server.pub")" "$N"
  echo
  note "Registros DNS: A ns1.<dominio> -> $IP | NS $ns -> ns1.<dominio>"
}

install_all() {
  ensure_base
  inst_dropbear; inst_ssl; inst_badvpn; inst_ws; inst_squid; inst_v2ray
  cfg_bbr
  [[ -n $UDPCUSTOM_URL ]] && inst_udp
  echo
  ok "Instalación completa. Ejecuta: vpspanel"
}


# --------------------------- Cuentas SSH / Dropbear -------------------
show_ssh_info() { # usuario clave expira limite
  local host; host=$(get_host)
  echo
  box_top "CUENTA SSH CREADA"
  krow "Host / IP" "$host"
  krow "Usuario" "$1"
  krow "Clave" "$2"
  krow "Expira" "$3"
  krow "Límite" "$4 conexión(es)"
  box_blank
  box_ports "Puertos" "SSH $SSH_PORT" "Dropbear $PORT_DROPBEAR" "SSL $PORT_SSL" "WS $PORT_WS" \
    "Squid $PORT_SQUID" "UDP Custom $PORT_UDP" "UDPGW 127.0.0.1:$PORT_BADVPN"
  box_bot
  echo
  printf '%s%sPayload WebSocket%s\n' "$ML" "$DIM" "$N"
  printf '%sGET / HTTP/1.1[crlf]Host: %s[crlf]Upgrade: websocket[crlf][crlf]\n' "$ML" "$host"
}

ssh_create() {
  local u p d l exp
  ask u "Usuario"
  valid_name "$u" || { err "Usuario inválido (3-31 caracteres: a-z 0-9 _ -)"; return 1; }
  if id "$u" >/dev/null 2>&1; then err "El usuario ya existe"; return 1; fi
  ask p "Contraseña" "aleatoria si queda vacío"; p=${p:-$(rand_pass)}
  [[ $p != *"|"* && -n $p ]] || { err "La contraseña no puede contener '|'"; return 1; }
  ask d "Días de validez" 30; d=${d:-30}
  [[ $d =~ ^[0-9]+$ ]] || { err "Días inválidos"; return 1; }
  ask l "Límite de conexiones" 1; l=${l:-1}
  [[ $l =~ ^[0-9]+$ ]] || { err "Límite inválido"; return 1; }
  exp=$(date -d "+$d days" +%F)
  useradd -M -s /bin/false -e "$exp" "$u" || { err "No se pudo crear el usuario"; return 1; }
  echo "$u:$p" | chpasswd
  echo "$u|$p|$exp|$l" >> "$USERDB"
  show_ssh_info "$u" "$p" "$exp" "$l"
}

ssh_delete() {
  local u
  ask u "Usuario a eliminar"
  valid_name "$u" && grep -q "^${u}|" "$USERDB" || { err "Usuario no encontrado"; return 1; }
  pkill -KILL -u "$u" 2>/dev/null
  userdel -f "$u" 2>/dev/null
  sed -i "/^${u}|/d" "$USERDB"
  ok "Usuario $u eliminado"
}

ssh_renew() {
  local u d exp
  ask u "Usuario a renovar"
  valid_name "$u" && grep -q "^${u}|" "$USERDB" || { err "Usuario no encontrado"; return 1; }
  ask d "Días desde hoy" 30; d=${d:-30}
  [[ $d =~ ^[0-9]+$ ]] || { err "Días inválidos"; return 1; }
  exp=$(date -d "+$d days" +%F)
  usermod -e "$exp" "$u" && db_set "$u" 3 "$exp" && ok "$u vence el $exp"
}

ssh_passwd() {
  local u p
  ask u "Usuario"
  valid_name "$u" && grep -q "^${u}|" "$USERDB" || { err "Usuario no encontrado"; return 1; }
  ask p "Nueva contraseña" "aleatoria si queda vacío"; p=${p:-$(rand_pass)}
  [[ $p != *"|"* && -n $p ]] || { err "La contraseña no puede contener '|'"; return 1; }
  echo "$u:$p" | chpasswd && db_set "$u" 2 "$p" && ok "Nueva contraseña de $u: $p"
}

ssh_list() {
  local u p e l i wu=7 wp=5 hdr row lim t0 ts days dcol dtxt
  local -a US=() PS=() ES=() LS=()
  while IFS='|' read -r u p e l; do
    [[ -n $u ]] || continue
    US+=("$u"); PS+=("$p"); ES+=("$e"); LS+=("$l")
    (( ${#u} > wu )) && wu=${#u}
    (( ${#p} > wp )) && wp=${#p}
  done < "$USERDB"
  if (( ${#US[@]} == 0 )); then warn "No hay cuentas SSH creadas."; return 0; fi
  t0=$(date -d "$(date +%F)" +%s)
  padr USUARIO "$wu"; hdr=$REPLY
  padr CLAVE "$wp"; hdr+="  $REPLY  EXPIRA      LIM  DIAS"
  printf '%s%s%s%s\n' "$ML" "$A1$BD" "$hdr" "$N"
  rep "─" "${#hdr}"; printf '%s%s%s%s\n' "$ML" "$BRD" "$REPLY" "$N"
  for i in "${!US[@]}"; do
    padr "${US[i]}" "$wu"; row=$REPLY
    padr "${PS[i]}" "$wp"; row+="  $REPLY"
    printf -v lim '%3s' "${LS[i]}"
    row+="  ${ES[i]}  $lim"
    if ts=$(date -d "${ES[i]}" +%s 2>/dev/null); then
      days=$(( (ts - t0) / 86400 ))
      if (( days < 0 )); then dcol=$RED; dtxt="vencida"
      elif (( days <= 5 )); then dcol=$YEL; dtxt=$days
      else dcol=$GRN; dtxt=$days; fi
    else
      dcol=$DIM; dtxt="-"
    fi
    printf '%s%s%s%s  %s%s%s\n' "$ML" "$WHT" "$row" "$N" "$dcol" "$dtxt" "$N"
  done
  echo
  printf '%s%sTotal:%s %s cuenta(s)\n' "$ML" "$DIM" "$N" "${#US[@]}"
}

ssh_online() {
  local u p e l n tot=0 rows=0
  printf '%s%s%-16s %s%s\n' "$ML" "$A1$BD" USUARIO CONEXIONES "$N"
  rep "─" 28; printf '%s%s%s%s\n' "$ML" "$BRD" "$REPLY" "$N"
  while IFS='|' read -r u p e l; do
    [[ -n $u ]] || continue
    n=$(ps -u "$u" -o comm= 2>/dev/null | grep -cE '^(sshd|dropbear)$')
    if (( n > 0 )); then
      printf '%s%-16s %s%s%s\n' "$ML" "$u" "$GRN" "$n" "$N"
      tot=$((tot + n)); rows=$((rows + 1))
    fi
  done < "$USERDB"
  (( rows )) || printf '%s%sNadie conectado en este momento.%s\n' "$ML" "$DIM" "$N"
  echo
  printf '%s%sTotal conexiones:%s %s\n' "$ML" "$DIM" "$N" "$tot"
}

menu_ssh() {
  ensure_base
  while :; do
    draw_header
    section "CUENTAS SSH / DROPBEAR"
    echo
    MG_NUM=(01 02 03 04 05 06 07)
    MG_LAB=("Crear cuenta" "Eliminar cuenta" "Renovar cuenta" "Cambiar contraseña"
            "Listar cuentas" "Usuarios conectados" "Eliminar expirados")
    MG_ST=()
    box_top "ADMINISTRAR"
    menu_grid
    box_bot
    back_line
    prompt_opt
    case $O in
      1) run_screen "CREAR CUENTA SSH" ssh_create ;;
      2) run_screen "ELIMINAR CUENTA SSH" ssh_delete ;;
      3) run_screen "RENOVAR CUENTA SSH" ssh_renew ;;
      4) run_screen "CAMBIAR CONTRASEÑA" ssh_passwd ;;
      5) run_screen "CUENTAS SSH" ssh_list ;;
      6) run_screen "USUARIOS CONECTADOS" ssh_online ;;
      7) run_screen "ELIMINAR EXPIRADOS" ssh_clean ;;
      0) return ;;
      *) flash_warn "Opción no válida." ;;
    esac
  done
}

ssh_clean() { /usr/local/bin/vps-cleanup && ok "Cuentas expiradas eliminadas"; }

run_screen() { # título comando [args...]: pantalla con cabecera, ejecuta y espera ENTER
  local t=$1
  shift
  draw_header
  section "$t"
  echo
  "$@"
  pause
}

# ------------------------------ Cuentas V2Ray -------------------------
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

v2_create() {
  v2_need || return 1
  local n d id exp
  ask n "Nombre de la cuenta"
  valid_name "$n" || { err "Nombre inválido (3-31 caracteres: a-z 0-9 _ -)"; return 1; }
  if grep -q "^${n}|" "$V2DB"; then err "La cuenta ya existe"; return 1; fi
  ask d "Días de validez" 30; d=${d:-30}
  [[ $d =~ ^[0-9]+$ ]] || { err "Días inválidos"; return 1; }
  id=$(cat /proc/sys/kernel/random/uuid)
  exp=$(date -d "+$d days" +%F)
  v2_edit --arg id "$id" --arg em "$n" \
    '.inbounds[0].settings.clients += [{"id":$id,"alterId":0,"email":$em}]' || return 1
  echo "$n|$id|$exp" >> "$V2DB"
  systemctl restart v2ray
  echo
  box_top "CUENTA V2RAY CREADA"
  krow "Cuenta" "$n"
  krow "Expira" "$exp"
  krow "UUID" "$id"
  krow "Puerto" "$PORT_V2RAY"
  krow "Red / Path" "ws  $V2PATH"
  box_bot
  echo
  printf '%s%sEnlace VMess%s\n' "$ML" "$DIM" "$N"
  printf '%s%s\n' "$ML" "$(v2_link "$n" "$id")"
}

v2_delete() {
  v2_need || return 1
  local n
  ask n "Cuenta a eliminar"
  valid_name "$n" && grep -q "^${n}|" "$V2DB" || { err "Cuenta no encontrada"; return 1; }
  v2_edit --arg em "$n" '.inbounds[0].settings.clients |= map(select(.email != $em))' || return 1
  sed -i "/^${n}|/d" "$V2DB"
  systemctl restart v2ray
  ok "Cuenta $n eliminada"
}

v2_renew() {
  local n d exp t
  ask n "Cuenta a renovar"
  valid_name "$n" && grep -q "^${n}|" "$V2DB" || { err "Cuenta no encontrada"; return 1; }
  ask d "Días desde hoy" 30; d=${d:-30}
  [[ $d =~ ^[0-9]+$ ]] || { err "Días inválidos"; return 1; }
  exp=$(date -d "+$d days" +%F)
  t=$(mktemp)
  U="$n" V="$exp" awk -F'|' -v OFS='|' '$1==ENVIRON["U"]{$3=ENVIRON["V"]}1' "$V2DB" > "$t"
  cat "$t" > "$V2DB"; rm -f "$t"
  ok "$n vence el $exp"
}

v2_list() {
  local n id e c=0
  while IFS='|' read -r n id e; do
    [[ -n $n ]] || continue
    c=$(( c + 1 ))
    printf '%s%s%s%s  %sexpira %s%s\n' "$ML" "$A1$BD" "$n" "$N" "$DIM" "$e" "$N"
    printf '%s%s%s%s\n' "$ML" "$DIM" "$id" "$N"
    printf '%s%s\n\n' "$ML" "$(v2_link "$n" "$id")"
  done < "$V2DB"
  (( c )) || warn "No hay cuentas V2Ray creadas."
  return 0
}

menu_v2() {
  ensure_base
  while :; do
    draw_header
    section "CUENTAS V2RAY"
    echo
    MG_NUM=(01 02 03 04)
    MG_LAB=("Crear cuenta" "Eliminar cuenta" "Renovar cuenta" "Listar y enlaces")
    MG_ST=()
    box_top "ADMINISTRAR"
    menu_grid
    box_bot
    back_line
    prompt_opt
    case $O in
      1) run_screen "CREAR CUENTA V2RAY" v2_create ;;
      2) run_screen "ELIMINAR CUENTA V2RAY" v2_delete ;;
      3) run_screen "RENOVAR CUENTA V2RAY" v2_renew ;;
      4) run_screen "CUENTAS V2RAY" v2_list ;;
      0) return ;;
      *) flash_warn "Opción no válida." ;;
    esac
  done
}

# ------------------------------ Protocolos ----------------------------
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


# ------------------------------ Herramientas --------------------------
cfg_banner() {
  ensure_base
  note "Escribe el banner SSH (HTML permitido). Una línea vacía termina la escritura."
  local l txt=""
  while IFS= read -rp "$ML${A1}›${N} " l; do [[ -z $l ]] && break; txt+="$l"$'\n'; done
  [[ -n $txt ]] || { err "Banner vacío"; return 1; }
  printf '%s' "$txt" > "$BANNER"
  ok "Banner aplicado"
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
  ask s "Tamaño de swap en MB" 1024; s=${s:-1024}
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
  ask d1 "DNS primario" 1.1.1.1; d1=${d1:-1.1.1.1}
  ask d2 "DNS secundario" 8.8.8.8; d2=${d2:-8.8.8.8}
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
  ask d "Dominio" "vacío = certificado autofirmado con la IP"
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
    is_on "$k" && systemctl restart "${SVC[$k]}" && ok "Reiniciado: $k"
  done
  ok "Servicios reiniciados"
}

autostart_on() { grep -q 'vpspanel-autostart' /root/.bashrc 2>/dev/null; }

toggle_autostart() {
  if autostart_on; then
    sed -i '/vpspanel-autostart/d' /root/.bashrc
    ok "Auto-inicio desactivado"
  else
    echo '[[ $- == *i* && -z "${VPSPANEL_ACTIVE:-}" ]] && vpspanel # vpspanel-autostart' >> /root/.bashrc
    ok "Auto-inicio activado"
  fi
}


# ------------------------------ Desinstalar ---------------------------
uninstall_all() {
  local c s u p
  warn "Se eliminarán el panel, sus servicios y las cuentas SSH creadas."
  ask c "Escribe SI para confirmar"
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


# ------------------------------ Registro del VPS ----------------------
NEW_NAME=""; NEW_THEME=1

valid_vps_name() { local re='^[A-Za-z0-9][A-Za-z0-9 ._-]{1,13}$'; [[ $1 =~ $re ]]; }

reg_fmt() { # recalcula los textos derivados del registro
  VPS_NAME_UP=${VPS_NAME^^}
  if [[ $VPS_DATE =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    VPS_DATE_TXT="${VPS_DATE:8:2}/${VPS_DATE:5:2}/${VPS_DATE:0:4}"
  else
    VPS_DATE_TXT="-"
  fi
  BAN_KEY=''
}

reg_load() { # lee vps.conf (no se ejecuta como código)
  local k v n=''
  VPS_THEME=1; VPS_DATE=''
  [[ -r $CONF ]] || return 1
  while IFS='=' read -r k v; do
    case $k in
      NAME)  n=$v ;;
      THEME) [[ $v =~ ^[0-9]{1,3}$ ]] && VPS_THEME=$(( 10#$v )) ;;
      DATE)  VPS_DATE=$v ;;
      COLOR) case $v in 24|256|auto) COLOR_MODE=$v ;; esac ;;
    esac
  done < "$CONF"
  set_colormode
  valid_vps_name "$n" || return 1
  VPS_NAME=$n
  reg_fmt
  return 0
}

reg_save() {
  {
    printf 'NAME=%s\n' "$VPS_NAME"
    printf 'THEME=%s\n' "$VPS_THEME"
    printf 'DATE=%s\n' "$VPS_DATE"
    printf 'COLOR=%s\n' "$COLOR_MODE"
  } > "$CONF"
  chmod 600 "$CONF"
}

reg_sync_banner() { # nombre_anterior: si el banner SSH era el de fábrica, usa el nombre nuevo
  local old=$1 cur
  [[ -f $BANNER ]] || return 0
  cur=$(<"$BANNER")
  if [[ $cur == "$old" || $cur == "VPS PANEL" ]]; then printf '%s\n' "$VPS_NAME" > "$BANNER"; fi
  return 0
}

reg_head() { # paso nombre_para_el_banner
  VPS_NAME_UP=$2
  term_size; cls
  draw_logo 0
  section "REGISTRO DE VPS" "PASO $1 DE 3"
  echo
}

ask_vps_name() { # [nombre_actual] -> NEW_NAME ; con nombre actual, Enter lo conserva
  local cur=${1:-} n
  while :; do
    ask n "Nombre del VPS" "${cur:+Enter = $cur}"
    trim "$n"; n=$REPLY
    if [[ -z $n && -n $cur ]]; then NEW_NAME=$cur; return 0; fi
    if valid_vps_name "$n"; then NEW_NAME=$n; return 0; fi
    err "Nombre inválido: revisa las reglas de arriba."
  done
}

choose_theme() { # -> NEW_THEME ; Enter = tema actual
  local cur=$VPS_THEME n=${#THEMES[@]} i x sw name mark t
  for i in "${!THEMES[@]}"; do
    apply_theme $(( i + 1 )); mkgrad 24
    sw=''
    for (( x = 0; x < 24; x++ )); do sw+="${GRAD[x]}█"; done
    name=${THEMES[i]%%|*}
    mark=''
    (( i + 1 == cur )) && mark="  ${DIM}(actual)${N}"
    padr "$name" 10
    printf '%s%s%02d%s  %s%s%s  %s%s%s\n' "$ML" "$A1$BD" $(( i + 1 )) "$N" "$WHT" "$REPLY" "$N" "$sw" "$N" "$mark"
  done
  apply_theme "$cur"
  echo
  while :; do
    ask t "Número de tema" "1-$n, Enter = actual"
    if [[ -z $t ]]; then NEW_THEME=$cur; return 0; fi
    if [[ $t =~ ^[0-9]{1,3}$ ]]; then
      t=$(( 10#$t ))
      if (( t >= 1 && t <= n )); then NEW_THEME=$t; return 0; fi
    fi
    err "Elige un número entre 1 y $n."
  done
}

register_vps() { # new | edit
  local mode=${1:-new} old=$VPS_NAME ans
  [[ $mode == edit ]] || VPS_THEME=1
  apply_theme "$VPS_THEME"
  while :; do
    reg_head 1 "$VPS_NAME_UP"
    note "Antes de entrar al panel, registra este VPS."
    note "El nombre se dibuja como banner en cada pantalla."
    echo
    note "Reglas: de 2 a 14 caracteres. Se permiten letras, números, espacio, punto, guion (-) y guion bajo (_). Sin tildes ni eñes."
    echo
    ask_vps_name "$VPS_NAME"
    VPS_NAME=$NEW_NAME; reg_fmt
    reg_head 2 "$VPS_NAME_UP"
    note "Así se verá tu banner. Elige el tema de color."
    echo
    choose_theme
    apply_theme "$NEW_THEME"
    reg_head 3 "$VPS_NAME_UP"
    [[ -n $VPS_DATE ]] || VPS_DATE=$(date +%F)
    reg_fmt
    box_top "RESUMEN DEL REGISTRO"
    krow "Nombre" "$VPS_NAME"
    krow "Tema" "$TH_NAME"
    krow "IP" "${IP:0:30}"
    krow "Sistema" "$OS_NAME"
    krow "Fecha" "$VPS_DATE_TXT"
    box_bot
    echo
    ask ans "¿Guardar el registro?" "S/n"
    [[ $ans == [nN]* ]] || break
  done
  reg_save
  reg_sync_banner "$old"
  echo
  ok "VPS registrado como $VPS_NAME"
  pause
}

menu_register() {
  local old
  while :; do
    draw_header
    section "REGISTRO DEL VPS"
    echo
    box_top "DATOS REGISTRADOS"
    krow "Nombre" "$VPS_NAME"
    krow "Tema" "$TH_NAME"
    krow "Registrado" "$VPS_DATE_TXT"
    krow "IP" "${IP:0:30}"
    box_bot
    echo
    tstate_color
    MG_NUM=(01 02 03); MG_LAB=("Cambiar nombre" "Cambiar tema de color" "Colores de 24 bits")
    MG_ST=("" "" "$REPLY")
    box_top "ACCIONES"
    menu_grid
    box_bot
    echo
    note "Si el degradado se ve en bandas, activa los colores de 24 bits. Si los colores salen raros, desactívalos."
    back_line
    prompt_opt
    case $O in
      1) echo
         old=$VPS_NAME
         ask_vps_name "$VPS_NAME"
         if [[ $NEW_NAME != "$VPS_NAME" ]]; then
           VPS_NAME=$NEW_NAME; reg_fmt; reg_save; reg_sync_banner "$old"
           flash_ok "Nombre actualizado."
         fi ;;
      2) draw_header; section "TEMA DE COLOR"; echo
         choose_theme
         if (( NEW_THEME != VPS_THEME )); then
           apply_theme "$NEW_THEME"; reg_save
           flash_ok "Tema actualizado."
         fi ;;
      3) if (( TRUECOLOR )); then COLOR_MODE=256; else COLOR_MODE=24; fi
         set_colormode; apply_theme "$VPS_THEME"; reg_save
         if (( TRUECOLOR )); then flash_ok "Colores de 24 bits activados."; else flash_ok "Modo de 256 colores activado."; fi ;;
      0) return ;;
      *) flash_warn "Opción no válida." ;;
    esac
  done
}

tstate_color() { if (( TRUECOLOR )); then REPLY=on; else REPLY=off; fi; }

ui_start() {
  load_fonts
  term_size
  if reg_load; then apply_theme "$VPS_THEME"; else register_vps new; fi
  if (( FORCE_REG )); then register_vps edit; fi
}

# ------------------------------ Estado de servicios -------------------
declare -A ST=()

svc_state() { # clave -> REPLY: on | off (instalado, detenido) | none (no instalado)
  local k=$1
  if is_on "$k"; then REPLY=on; return 0; fi
  case $k in
    openvpn)   if [[ -f /etc/openvpn/server/server.conf || -f /etc/openvpn/server.conf ]]; then REPLY=off; else REPLY=none; fi ;;
    wireguard) if [[ -f /etc/wireguard/wg0.conf ]]; then REPLY=off; else REPLY=none; fi ;;
    ssh)       REPLY=off ;;
    *)         if systemctl cat "${SVC[$k]}" >/dev/null 2>&1; then REPLY=off; else REPLY=none; fi ;;
  esac
}

refresh_states() {
  local k
  for k in "${!SVC[@]}"; do svc_state "$k"; ST[$k]=$REPLY; done
}

# ------------------------------ Recursos del sistema ------------------
cpu_pct() { # -> REPLY (uso de CPU en %, medido en 0,15 s)
  local u n s i w q sq st t1 i1 t2 i2
  read -r _ u n s i w q sq st _ < /proc/stat
  t1=$(( u + n + s + i + w + q + sq + st )); i1=$(( i + w ))
  sleep 0.15
  read -r _ u n s i w q sq st _ < /proc/stat
  t2=$(( u + n + s + i + w + q + sq + st )); i2=$(( i + w ))
  if (( t2 > t1 )); then REPLY=$(( 100 * ((t2 - t1) - (i2 - i1)) / (t2 - t1) )); else REPLY=0; fi
}

fmt_mb() { local m=$1; if (( m >= 1024 )); then REPLY="$(( m / 1024 )).$(( m % 1024 * 10 / 1024 ))G"; else REPLY="${m}M"; fi; }

gather_sys() {
  local mt mu dt du up
  cpu_pct; CPU_PCT=$REPLY
  read -r mt mu < <(free -m | awk '/^Mem:/{print $2, $3}')
  mt=${mt:-0}; mu=${mu:-0}
  RAM_PCT=$(( mt > 0 ? mu * 100 / mt : 0 ))
  read -r dt du < <(df -P -m / | awk 'NR==2{print $2, $3}')
  dt=${dt:-0}; du=${du:-0}
  DSK_PCT=$(( dt > 0 ? du * 100 / dt : 0 ))
  read -r up _ < /proc/uptime; up=${up%.*}
  UP_TXT="$(( up / 86400 ))d $(( up % 86400 / 3600 ))h $(( up % 3600 / 60 ))m"
  read -r LOAD _ < /proc/loadavg
  N_SSH=$(grep -c . "$USERDB" 2>/dev/null); N_SSH=${N_SSH:-0}
  N_V2=$(grep -c . "$V2DB" 2>/dev/null); N_V2=${N_V2:-0}
}

sys_card() {
  local p l r
  gather_sys
  box_top "RECURSOS"
  bar "$CPU_PCT" 10; printf -v p '%3d%%' "$CPU_PCT"; kv "CPU" "$REPLY ${WHT}${p}${N}"; l=$REPLY
  bar "$RAM_PCT" 10; printf -v p '%3d%%' "$RAM_PCT"; kv "RAM" "$REPLY ${WHT}${p}${N}"; r=$REPLY
  pair_row "$l" "$r"
  bar "$DSK_PCT" 10; printf -v p '%3d%%' "$DSK_PCT"; kv "DISCO" "$REPLY ${WHT}${p}${N}"; l=$REPLY
  kv "UPTIME" "${WHT}${UP_TXT}${N}"; r=$REPLY
  pair_row "$l" "$r"
  kv "CUENTAS" "${WHT}SSH ${A1}${N_SSH}${N}${WHT}  V2RAY ${A1}${N_V2}${N}"; l=$REPLY
  kv "CARGA" "${WHT}${LOAD}${N}"; r=$REPLY
  pair_row "$l" "$r"
  box_bot
}

svc_card() {
  local -a items=("SSH:ssh:$SSH_PORT" "DROPBEAR:dropbear:$PORT_DROPBEAR" "SSL:ssl:$PORT_SSL"
                  "WS:ws:$PORT_WS" "SQUID:squid:$PORT_SQUID" "V2RAY:v2ray:$PORT_V2RAY"
                  "BADVPN:badvpn:$PORT_BADVPN" "UDPCUSTOM:udp:$PORT_UDP" "SLOWDNS:slowdns:53")
  local cols sw n i j lab k port dot lc cellstr row=''
  if (( IW >= 54 )); then cols=3; else cols=2; fi
  sw=$(( (IW - 2 * (cols - 1)) / cols ))
  n=${#items[@]}
  box_top "SERVICIOS"
  for (( i = 0; i < n; i++ )); do
    IFS=: read -r lab k port <<< "${items[i]}"
    case ${ST[$k]-none} in
      on)  dot="${GRN}●${N}"; lc=$WHT ;;
      off) dot="${RED}●${N}"; lc=$WHT ;;
      *)   dot="${BRD}○${N}"; lc=$DIM ;;
    esac
    padr "$lab" 9
    printf -v port '%5s' "$port"
    cellstr="$dot ${lc}${REPLY}${N} ${DIM}${port}${N}"
    padv "$cellstr" "$sw"; cellstr=$REPLY
    j=$(( i % cols ))
    if (( j > 0 )); then row+="  "; fi
    row+=$cellstr
    if (( j == cols - 1 || i == n - 1 )); then box_row "$row"; row=''; fi
  done
  box_bot
}

# ------------------------------ Protocolos ----------------------------
menu_protocols() {
  local i k nn
  while :; do
    refresh_states
    draw_header
    section "PROTOCOLOS"
    echo
    MG_NUM=(); MG_LAB=(); MG_ST=()
    for i in "${!PROTO_KEYS[@]}"; do
      k=${PROTO_KEYS[i]}
      printf -v nn '%02d' $(( i + 1 ))
      MG_NUM+=("$nn"); MG_LAB+=("${PROTO_LABELS[i]}"); MG_ST+=("${ST[$k]-none}")
    done
    box_top "INSTALAR / ACTIVAR / DETENER"
    menu_grid
    box_bot
    printf '\n%s%s●%s %sactivo%s   %s●%s %sdetenido%s   %s○%s %sno instalado%s\n' \
      "$ML" "$GRN" "$N" "$DIM" "$N" "$RED" "$N" "$DIM" "$N" "$BRD" "$N" "$DIM" "$N"
    note "Elige un número: instala si falta, activa o detiene."
    back_line
    prompt_opt
    if [[ $O == 0 ]]; then return; fi
    if [[ $O =~ ^[0-9]+$ ]] && (( O >= 1 && O <= ${#PROTO_KEYS[@]} )); then
      run_screen "${PROTO_LABELS[O-1]}" proto_action "${PROTO_KEYS[O-1]}"
    else
      flash_warn "Opción no válida."
    fi
  done
}

# ------------------------------ Herramientas --------------------------
bbr_on()  { [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]; }
swap_on() { [[ -n $(swapon --noheadings --show=NAME 2>/dev/null) ]]; }
root_on() { [[ -f /etc/ssh/sshd_config.d/01-vpspanel-root.conf ]]; }
dom_on()  { [[ -s $DOMAIN_F ]]; }
tstate()  { if "$@"; then REPLY=on; else REPLY=off; fi; }

menu_tools() {
  local s2 s3 s6 s7 s9
  while :; do
    tstate bbr_on; s2=$REPLY
    tstate swap_on; s3=$REPLY
    tstate dom_on; s6=$REPLY
    tstate root_on; s7=$REPLY
    tstate autostart_on; s9=$REPLY
    draw_header
    section "HERRAMIENTAS Y AJUSTES"
    echo
    MG_NUM=(01 02 03 04 05 06 07 08 09)
    MG_LAB=("Banner SSH" "TCP BBR" "Memoria swap" "Limpiar caché y logs" "Configurar DNS"
            "Dominio / SSL" "Acceso root" "Reiniciar servicios" "Auto-iniciar panel")
    MG_ST=("" "$s2" "$s3" "" "" "$s6" "$s7" "" "$s9")
    box_top "AJUSTES"
    menu_grid
    box_bot
    back_line
    prompt_opt
    case $O in
      1) run_screen "BANNER SSH" cfg_banner ;;
      2) run_screen "ACELERACIÓN TCP BBR" cfg_bbr ;;
      3) run_screen "MEMORIA SWAP" cfg_swap ;;
      4) run_screen "LIMPIAR CACHÉ Y LOGS" cfg_cache ;;
      5) run_screen "CONFIGURAR DNS" cfg_dns ;;
      6) run_screen "DOMINIO / CERTIFICADO SSL" cfg_domain ;;
      7) run_screen "CLAVE Y ACCESO ROOT" cfg_root ;;
      8) run_screen "REINICIAR SERVICIOS" restart_services ;;
      9) run_screen "AUTO-INICIO DEL PANEL" toggle_autostart ;;
      0) return ;;
      *) flash_warn "Opción no válida." ;;
    esac
  done
}

# ---------------------------------- Menú ------------------------------
mrow() { # num etiqueta descripción [danger]
  local nc=$A1 lc=$WHT lab desc='' lw=24 dw
  (( lw > IW - 4 )) && lw=$(( IW - 4 ))
  dw=$(( IW - 4 - lw ))
  if [[ ${4:-} == danger ]]; then nc=$RED; lc=$RED; fi
  padr "$2" "$lw"; lab=$REPLY
  (( dw >= 22 )) && desc="${DIM}${3:0:dw}${N}"
  box_row "${nc}${BD}$1${N}  ${lc}${lab}${N}${desc}"
}

main_box() {
  box_top "MENÚ PRINCIPAL"
  mrow 01 "Cuentas SSH / Dropbear" "Crear, renovar, borrar"
  mrow 02 "Cuentas V2Ray" "Cuentas VMess con enlace"
  mrow 03 "Protocolos" "Instalar, activar, parar"
  mrow 04 "Herramientas y ajustes" "BBR, swap, DNS, root"
  mrow 05 "Instalación completa" "Protocolos base y BBR"
  mrow 06 "Registro del VPS" "Nombre y tema del banner"
  mrow 07 "Reiniciar VPS" "Reinicio del servidor"
  mrow 08 "Desinstalar panel" "Borra panel y cuentas" danger
  box_bot
}

reboot_vps() {
  local c
  ask c "¿Reiniciar el VPS ahora?" "s/N"
  [[ $c == [sS]* ]] && reboot
  return 0
}

main_menu() {
  while :; do
    refresh_states
    draw_header
    echo
    if (( T_ROWS >= 28 )); then sys_card; echo; fi
    if (( T_ROWS >= 36 )); then svc_card; echo; fi
    main_box
    back_line "Salir"
    prompt_opt
    case $O in
      1) menu_ssh ;;
      2) menu_v2 ;;
      3) ensure_base; menu_protocols ;;
      4) menu_tools ;;
      5) run_screen "INSTALACIÓN COMPLETA" install_all ;;
      6) menu_register ;;
      7) run_screen "REINICIAR VPS" reboot_vps ;;
      8) run_screen "DESINSTALAR PANEL" uninstall_all ;;
      0) printf '\n%s%sHasta pronto.%s\n\n' "$ML" "$DIM" "$N"; exit 0 ;;
      *) flash_warn "Opción no válida." ;;
    esac
  done
}

self_install() {
  local me; me=$(readlink -f "$0" 2>/dev/null)
  if [[ -f $me && $me != /usr/local/bin/vpspanel ]]; then
    install -m755 "$me" /usr/local/bin/vpspanel
  fi
}

FORCE_REG=0

cleanup() { # al salir: detiene tareas en segundo plano y devuelve el cursor
  local j
  j=$(jobs -p 2>/dev/null)
  # shellcheck disable=SC2086
  [[ -n $j ]] && kill $j 2>/dev/null
  if (( UI_COLOR )); then printf '\e[?25h'; fi
  return 0
}
trap cleanup EXIT

self_install
reg_load >/dev/null 2>&1 || true
apply_theme "$VPS_THEME"
case "${1:-}" in
  --install-all) install_all; exit 0 ;;
  --register)    FORCE_REG=1 ;;
  "") ;;
  *) echo "Uso: $0 [--install-all|--register]"; exit 1 ;;
esac
ui_start
main_menu
