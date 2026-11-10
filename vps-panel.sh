#!/usr/bin/env bash
# ======================================================================
#  VPS PANEL v2.3 - instalador y administrador de protocolos para tuneles
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
#  Cuentas SSH nuevas: contrasena xxxx, 30 dias y 1 conexion. En los campos con valor por
#  defecto ([30], [1]...) ENTER escribe ese valor en el campo para que quede a la vista.
#  Atajo "1.1" en el menu principal: crea al instante user1, user2, user3... (contrasena xxxx,
#  30 dias, 1 conexion) sin preguntar nada. La secuencia se guarda en /etc/vpspanel/quick.seq.
#  Usuarios SSH: la opcion 2 elimina varios a la vez (1,5,6,9) y la 8 elimina todos. En la 2,
#  hasta 3 usuarios (DEL_NOWARN) se borran directo, sin advertencia; con mas de 3 sale la
#  advertencia y se esperan 3 segundos (DEL_WAIT_SEL). En la 8 la espera es de 7 (DEL_WAIT).
#  Los puertos se cambian en Preparacion del sistema y se guardan en /etc/vpspanel/ports.conf
#    UDPCUSTOM_URL=<url> vpspanel      (opcional) usar otro binario de udp-custom
#
#  Interfaz: replica el panel de referencia (colores RGB exactos, lineas de 53
#  columnas). Todo el aspecto visual esta en el bloque "Interfaz".
#    VPSPANEL_COLOR=256 vpspanel       terminal sin colores de 24 bits (aproximado)
#    VPSPANEL_COLOR=16  vpspanel       colores del tema de la terminal
# ======================================================================

set -u
shopt -s extglob
export DEBIAN_FRONTEND=noninteractive
export VPSPANEL_ACTIVE=1

# ------------------------------ Configuracion -------------------------
VERSION=2.3
NAME_MAX=24        # largo maximo del nombre del VPS (se muestra en el titulo)
DEF_PASS=xxxx      # contrasena por defecto de las cuentas SSH (ENTER en el campo la escribe sola)
BASE=${VPSPANEL_BASE:-/etc/vpspanel}
USERDB=$BASE/users.db
V2DB=$BASE/v2ray.db
BANNER=$BASE/banner
CERT=$BASE/cert.pem
DOMAIN_F=$BASE/domain
NAME_F=$BASE/vps.name
REG_F=$BASE/vps.reg
HIDE_F=$BASE/hide.conf     # partes del panel ocultas (una por linea: name, server, services)

# Atajo "1.1" del menu principal: cuentas user1, user2, user3... creadas sin preguntar nada
QUICK_PREFIX=user          # nombre base; el numero lo pone la secuencia
QUICK_PASS=xxxx            # contrasena fija
QUICK_DAYS=30              # dias de validez
QUICK_LIMIT=1              # conexiones simultaneas (igual que el valor por defecto de NUEVO USUARIO SSH)
SEQ_F=$BASE/quick.seq      # ultimo numero usado: la secuencia sigue despues de cerrar o reiniciar
QUICK_LOCK=$BASE/quick.lock  # candado: dos sesiones del panel no pueden tomar el mismo numero

DEL_WAIT=7                 # segundos de espera con la advertencia antes de eliminar TODAS las cuentas (opcion 8)
DEL_WAIT_SEL=3             # segundos de espera con la advertencia al eliminar varias cuentas (opcion 2)
DEL_NOWARN=3               # opcion 2: hasta este numero de cuentas se borran directo, sin advertencia
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
# Todo el aspecto visual esta en este bloque. Replica el panel de referencia:
#   - lineas "=" y "-" rojas de 53 columnas; titulos en blanco (secciones en naranja)
#   - menus con el formato "[1] > TEXTO" y estados [ON] verde / [OFF] rojo
#   - botones con fondo de color (gris, rojo y azul) y titulo con degradado
# Colores: por defecto RGB de 24 bits (los mismos de la referencia). Si tu terminal no
# los admite (PuTTY viejo, JuiceSSH, ConnectBot, Terminal de macOS):
#     VPSPANEL_COLOR=256 vpspanel     colores aproximados de 256
#     VPSPANEL_COLOR=16  vpspanel     colores del tema de la terminal
#   o dejalo fijo:  echo 256 > /etc/vpspanel/color.conf
# El simbolo de grado de las tablas y los circulos de estado se escriben como bytes UTF-8
# (\x..): el archivo sigue siendo ASCII. No hay emojis en ningun menu.

ANCHO=53       # ancho de las lineas (igual que la referencia)
FW=12          # ancho de las etiquetas de field() (algunas pantallas lo cambian)
VL=0           # largo visible del ultimo texto medido con vlen()
CMODE=24       # modo de color: 24 (RGB), 256 o 16
GRADMAP=0000000011111111112222222223444   # degradado del titulo: 31 posiciones -> color 0..4
MON=(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

c256() {   # r g b -> indice de la paleta xterm de 256 colores mas cercano
  local r=$1 g=$2 b=$3 mx mn a rq gq bq
  mx=$r; (( g > mx )) && mx=$g; (( b > mx )) && mx=$b
  mn=$r; (( g < mn )) && mn=$g; (( b < mn )) && mn=$b
  if (( mx - mn < 10 )); then                       # gris: rampa de grises
    a=$(( (r + g + b) / 3 ))
    if (( a < 8 )); then echo 16
    elif (( a > 246 )); then echo 231
    else echo $(( 232 + (a - 8) / 10 )); fi
    return
  fi
  rq=$(( r < 48 ? 0 : r < 115 ? 1 : (r - 35) / 40 ))
  gq=$(( g < 48 ? 0 : g < 115 ? 1 : (g - 35) / 40 ))
  bq=$(( b < 48 ? 0 : b < 115 ? 1 : (b - 35) / 40 ))
  echo $(( 16 + 36 * rq + 6 * gq + bq ))
}

c_fg() {   # r g b ansi16  -> color de texto (negrita) segun el modo
  case $CMODE in
    24)  printf '\e[1;38;2;%d;%d;%dm' "$1" "$2" "$3" ;;
    256) printf '\e[1;38;5;%dm' "$(c256 "$1" "$2" "$3")" ;;
    *)   printf '\e[%sm' "$4" ;;
  esac
}

c_bt() {   # r g b  r g b  ansi16  -> texto + fondo (botones y resaltados)
  case $CMODE in
    24)  printf '\e[1;38;2;%d;%d;%d;48;2;%d;%d;%dm' "$1" "$2" "$3" "$4" "$5" "$6" ;;
    256) printf '\e[1;38;5;%d;48;5;%dm' "$(c256 "$1" "$2" "$3")" "$(c256 "$4" "$5" "$6")" ;;
    *)   printf '\e[%sm' "$7" ;;
  esac
}

init_ui() {   # colores: solo si la salida es una terminal (VPSPANEL_COLOR=... los fuerza)
  local mode=${VPSPANEL_COLOR:-}
  [[ -z $mode && -s $BASE/color.conf ]] && mode=$(head -c 16 "$BASE/color.conf" | tr -dc '0-9A-Za-z')
  # los iconos y el simbolo de grado son UTF-8: si la sesion no lo es, se fuerza C.UTF-8
  [[ $(locale charmap 2>/dev/null) == UTF-8 ]] || { export LC_ALL=C.UTF-8; } 2>/dev/null
  if [[ ( -t 1 || -n ${VPSPANEL_COLOR:-} ) && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    case ${mode,,} in
      16|ansi)                 CMODE=16 ;;
      256)                     CMODE=256 ;;
      24|true|truecolor|24bit) CMODE=24 ;;
      *) case ${TERM:-} in linux|vt*|ansi|cons*|screen|screen.*) CMODE=16 ;; *) CMODE=24 ;; esac ;;
    esac
    RST=$'\e[0m'
    #            R   G   B  ansi16
    RED=$(c_fg 242  78  80 '1;31')     # lineas, flechas, etiquetas de puertos, [OFF], peligro
    GRN=$(c_fg   0 132  99 '1;32')     # numeros [1], [ON], valores
    BLU=$(c_fg  32 145 246 '1;94')     # etiquetas (S.O:, RAM:, CPU:...)
    DBL=$(c_fg   8  99 159 '0;34')     # azul oscuro
    WHT=$(c_fg 255 255 255 '1;37')     # texto de los menus
    YEL=$(c_fg 236 168  85 '1;33')     # secciones, avisos y pregunta del menu principal
    LYE=$(c_fg 253 196 125 '1;93')     # amarillo claro (cabeceras de tabla, opciones destacadas)
    PNK=$(c_fg 210  84 154 '1;35')     # IP
    GRY=$(c_fg 141 145 165 '0;37')     # gris
    MAG=$PNK
    G0=$(c_fg 255  95  95 '1;31'); G1=$(c_fg 255   0 135 '1;31'); G2=$(c_fg 255   0 175 '1;35')
    G3=$(c_fg 215   0 175 '1;35'); G4=$(c_fg 215   0 215 '1;35')   # degradado del titulo
    #                  texto (R G B)   fondo (R G B)   ansi16
    BTN_GRAY=$(c_bt 226 227 232  141 145 165 '30;47')     # boton gris   (SALIR DEL VPS)
    BTN_RED=$(c_bt  226 227 232  242  78  80 '1;37;41')   # boton rojo   (VOLVER, SALIR DEL SCRIPT)
    BTN_REDW=$(c_bt 255 255 255  242  78  80 '1;37;41')   # boton rojo con texto blanco (menus SSH)
    BTN_BLUE=$(c_bt 226 227 232    8  99 159 '1;37;44')   # boton azul   (REBOOT VPS)
    HL_GRY=$(c_bt   255 255 255  141 145 165 '1;30;47')   # resaltado gris (PREPARACION DEL SISTEMA)
  else
    RST=''; RED=''; GRN=''; BLU=''; DBL=''; WHT=''; YEL=''; LYE=''; PNK=''; GRY=''; MAG=''
    G0=''; G1=''; G2=''; G3=''; G4=''
    BTN_GRAY=''; BTN_RED=''; BTN_REDW=''; BTN_BLUE=''; HL_GRY=''
  fi
  MK_ON=$'\xe2\x97\x89'; MK_OFF=$'\xe2\x97\x8b'   # marcas de estado: activo / inactivo
  EQ=$(rep = "$ANCHO"); DASH=$(rep - "$ANCHO")
}

rep()  { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }   # repite un caracter n veces
vlen() { local s=${1//$'\e['*([0-9;])m/}; VL=${#s}; }                      # largo visible (sin colores)
cls()  { [[ -t 1 ]] && printf '\e[H\e[2J\e[3J'; return 0; }                # limpia la pantalla

# ---- Lineas y titulos ------------------------------------------------
line_eq()   { printf '%s%s%s\n' "$RED" "$EQ" "$RST"; }     # ====================
line_dash() { printf '%s%s%s\n' "$RED" "$DASH" "$RST"; }   # --------------------

center() {   # texto [color]  ->  texto centrado en la linea
  local pad=$(( (ANCHO - ${#1}) / 2 ))
  (( pad < 0 )) && pad=0
  printf '%*s%s%s%s\n' "$pad" '' "${2:-$WHT}" "$1" "$RST"
}

center_grad() {   # texto  ->  centrado, con el degradado de color por caracter del titulo
  local t=$1 n=${#1} i j out='' pad
  local -a G=("$G0" "$G1" "$G2" "$G3" "$G4")
  pad=$(( (ANCHO - n) / 2 )); (( pad < 0 )) && pad=0
  for (( i = 0; i < n; i++ )); do
    j=$(( i * 31 / n ))
    out+="${G[${GRADMAP:j:1}]}${t:i:1}"
  done
  printf '%*s%s%s\n' "$pad" '' "$out" "$RST"
}

title()      { line_eq; center "$1" "${2:-$WHT}"; line_eq; }   # barra, titulo, barra
sub_header() { cls; title "$1" "${2:-}"; }                     # pantalla nueva con titulo

section() {   # texto  ->  ============ TEXTO ============
  local n=$(( ANCHO - ${#1} - 2 )) l r
  (( n < 2 )) && n=2
  l=$(( n / 2 )); r=$(( n - l ))
  printf '%s%s%s %s %s%s%s\n' "$RED" "$(rep = "$l")" "$YEL" "$1" "$RED" "$(rep = "$r")" "$RST"
}

# ---- Menus -----------------------------------------------------------
item_m() {   # numero texto [color]  ->  " [1] > TEXTO"   (menu principal)
  printf ' %s[%s]%s %s>%s %s%s%s\n' "$GRN" "$1" "$RST" "$RED" "$RST" "${3:-$WHT}" "$2" "$RST"
}

item() {   # numero texto [color]  ->  "  [1] > TEXTO"   (submenus: numero alineado a la derecha)
  printf ' %s%4s%s %s>%s %s%s%s\n' "$GRN" "[$1]" "$RST" "$RED" "$RST" "${3:-$WHT}" "$2" "$RST"
}

onoff() {   # comando [args]  ->  [ON] verde si el comando tiene exito, [OFF] rojo si no
  if "$@"; then printf '%s[ON]%s' "$GRN" "$RST"; else printf '%s[OFF]%s' "$RED" "$RST"; fi
}

ON_W=0   # ancho del texto de item_on (para alinear los estados de un mismo menu)
item_on() {   # numero texto comando [args]  ->  opcion con su estado al final
  local n=$1 t=$2; shift 2
  item "$n" "$(printf '%-*s' "$ON_W" "$t") $(onoff "$@")"
}

menu_end() {   # [texto] [estilo]  ->  pie de los submenus: "[0] > VOLVER" (boton rojo)
  line_eq
  item 0 "${1:-VOLVER}" "${2:-$BTN_RED}"
  line_eq
}

# ---- Datos en columnas -----------------------------------------------
pcell() { printf '%s%s:%s %s%s%s' "$RED" "$1" "$RST" "$GRN" "$2" "$RST"; }                  # ETIQUETA: puerto
field() { printf ' %s%-*s%s %s%s%s\n' "$BLU" "$FW" "$1" "$RST" "${3:-$WHT}" "$2" "$RST"; }  # ETIQUETA valor [color]

cols() {   # "col:celda" ...  ->  celdas colocadas en columnas fijas (col = posicion del primer caracter)
  local out='' cur=0 spec c cell n sp
  for spec in "$@"; do
    c=${spec%%:*}; cell=${spec#*:}
    n=$(( c - cur )); (( n < 0 )) && n=0
    printf -v sp '%*s' "$n" ''
    out+=$sp$cell
    vlen "$cell"; cur=$(( cur + n + VL ))
  done
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

rd() { local p=$1; shift; read -rp " ${WHT}${p}${RST}" "$@"; }   # pregunta: rd "TEXTO: " variable

rd_def() {   # texto variable defecto  ->  pregunta; ENTER en el campo vacio escribe el valor por defecto
  local t=$1 v
  printf ' %s%s%s ' "$WHT" "$t" "$RST"
  read -r v || return 1
  if [[ -z $v ]]; then
    v=$3
    # sube a la linea de la pregunta y escribe el valor en el campo, a continuacion del texto
    [[ -t 1 ]] && printf '\e[1A\r\e[%dC%s\n' "$(( ${#t} + 2 ))" "$v"
  fi
  printf -v "$2" '%s' "$v"
}
rd_pass() { rd_def "$1" "$2" "$DEF_PASS"; }   # contrasena: ENTER escribe xxxx

ask() {   # variable [estilo]  ->  pide la opcion del menu (los numeros se normalizan: 01 pasa a 1)
  local r txt='Seleccione una Opcion:' col=$WHT
  case ${2:-} in
    m) col=$YEL ;;                            # menu principal: naranja
    u) txt='SELECCIONE UNA OPCION:' ;;        # menus de cuentas: mayusculas
  esac
  printf ' %s%s%s ' "$col" "$txt" "$RST"
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
  OS_NAME=${OS_NAME% LTS}                                  # "Ubuntu 20.04.6 LTS" -> "Ubuntu 20.04.6"
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
  sub_header "CREAR USUARIOS"
  acct_table "$USERDB"
  menu_end VOLVER "$BTN_REDW"
  rd "NUEVO USUARIO: " u || return 3
  [[ -n $u && $u != 0 ]] || return 3
  valid_name "$u" || { err "Usuario invalido (3-31 caracteres: a-z 0-9 _ -)"; return 1; }
  if id "$u" >/dev/null 2>&1; then err "El usuario ya existe"; return 1; fi
  rd_pass "CONTRASENA:" p || return 1
  [[ $p != *"|"* && -n $p ]] || { err "La contrasena no puede contener '|'"; return 1; }
  rd_def "DIAS DE VALIDEZ [30]:" d 30 || return 3
  [[ $d =~ ^[0-9]+$ ]] || { err "Dias invalidos"; return 1; }
  rd_def "LIMITE DE CONEXIONES [1]:" l 1 || return 3
  [[ $l =~ ^[0-9]+$ ]] || { err "Limite invalido"; return 1; }
  exp=$(date -d "+$d days" +%F)
  useradd -M -s /bin/false -e "$exp" "$u" || { err "No se pudo crear el usuario"; return 1; }
  echo "$u:$p" | chpasswd
  echo "$u|$p|$exp|$l" >> "$USERDB"
  show_ssh_info "$u" "$p" "$exp" "$l"
}

# Atajo "1.1": crea al instante la siguiente cuenta de la secuencia user1, user2, user3...
# El ultimo numero usado queda en $SEQ_F, asi la secuencia sigue igual despues de cerrar el
# panel o reiniciar el VPS, y un numero no se reutiliza aunque su cuenta se borre o venza
# (vps-cleanup borra las vencidas, por eso el numero no se calcula mirando users.db).
# Si el nombre ya existe (por ejemplo un user5 creado a mano) se salta al siguiente libre:
# nunca se duplica una cuenta. Solo se avanza el contador cuando la cuenta quedo creada.
quick_make() {   # se llama con el candado tomado; imprime "usuario|fecha_de_vencimiento"
  local last=0 n u exp
  [[ -s $SEQ_F ]] && read -r last < "$SEQ_F"
  [[ $last =~ ^[0-9]+$ ]] || last=0
  n=$(( 10#$last + 1 ))
  while :; do
    u=$QUICK_PREFIX$n
    grep -q "^${u}|" "$USERDB" || id "$u" >/dev/null 2>&1 || break
    n=$(( n + 1 ))
  done
  exp=$(date -d "+$QUICK_DAYS days" +%F)
  useradd -M -s /bin/false -e "$exp" "$u" || { err "No se pudo crear el usuario $u"; return 1; }
  if ! echo "$u:$QUICK_PASS" | chpasswd; then
    userdel -f "$u" 2>/dev/null
    err "No se pudo asignar la contrasena de $u"; return 1
  fi
  echo "$u|$QUICK_PASS|$exp|$QUICK_LIMIT" >> "$USERDB"
  if printf '%s\n' "$n" > "$SEQ_F.tmp"; then    # escritura atomica: el contador nunca queda a medias
    sync "$SEQ_F.tmp" 2>/dev/null
    mv -f "$SEQ_F.tmp" "$SEQ_F"
  fi
  printf '%s|%s\n' "$u" "$exp"
}

quick_user() {
  local out rc u exp
  ensure_base
  out=$( { flock -w 10 9 || { err "Otra sesion del panel esta creando un usuario. Intenta de nuevo"; exit 2; }
           quick_make; } 9>"$QUICK_LOCK" )
  rc=$?
  out=${out##*$'\n'}
  (( rc == 0 )) && [[ $out == *"|"* ]] || return 1
  IFS='|' read -r u exp <<< "$out"
  show_ssh_info "$u" "$QUICK_PASS" "$exp" "$QUICK_LIMIT"
}

# Dias que faltan para una fecha AAAA-MM-DD: desde ahora hasta las 00:00 UTC de esa fecha
# (cuando la cuenta vence), redondeado hacia abajo. Negativo si ya vencio.
days_left() {   # fecha ahora_en_segundos
  local s r
  s=$(date -u -d "$1" +%s 2>/dev/null) || { echo 0; return; }
  r=$(( s - $2 ))
  if (( r < 0 && r % 86400 != 0 )); then echo $(( r / 86400 - 1 )); else echo $(( r / 86400 )); fi
}

fdate() {   # AAAA-MM-DD -> FD="May10/27" (mes en ingles, como la referencia)
  if [[ $1 =~ ^[0-9]{4}-(0[1-9]|1[0-2])-[0-9]{2}$ ]]; then
    FD="${MON[10#${BASH_REMATCH[1]} - 1]}${1:8:2}/${1:2:2}"
  else
    FD='--------'
  fi
}

# Tabla de cuentas: N, nombre, clave, fecha, dias que faltan, limite y estado (ULK = sin
# bloquear, LOK = bloqueada). Deja los nombres en ACCT[].
# El archivo puede ser users.db (SSH: con clave y limite) o v2ray.db (V2Ray).
acct_table() {   # archivo
  local db=$1 kind=v2 n p e l d c now sta num
  local -A LK=()
  [[ $db == "$USERDB" ]] && kind=ssh
  ACCT=()
  now=$(date +%s)
  num=$'N\xc2\xb0'
  if [[ $kind == ssh ]]; then
    if [[ -r /etc/shadow ]]; then
      while IFS=: read -r n p _; do [[ $p == '!'* ]] && LK[$n]=1; done < /etc/shadow
    fi
    printf '%s  %s %-14s%-14s%-9s%-4s%-4s%s%s\n' "$LYE" "$num" Usuario Contrasena Fecha Dia Lim Sta "$RST"
  else
    printf '%s  %s %-28s%-9s%s%s\n' "$LYE" "$num" Cuenta Fecha Dia "$RST"
  fi
  line_dash
  while IFS='|' read -r n p e l; do
    [[ -n $n ]] || continue
    ACCT+=("$n")
    d=$(days_left "$e" "$now"); fdate "$e"
    if (( d < 0 )); then c=$RED; else c=$GRN; fi
    if [[ $kind == ssh ]]; then
      if [[ -n ${LK[$n]:-} ]]; then sta="${RED}LOK"; else sta="${GRN}ULK"; fi
      printf '%s%3d)%s-%s%-14.14s%-14.14s%s%-9s%s%-4s%s%-4s%s%s\n' \
        "$GRN" "${#ACCT[@]}" "$RED" "$WHT" "$n" "$p" "$RED" "$FD" "$c" "$d" "$LYE" "${l:--}" "$sta" "$RST"
    else
      printf '%s%3d)%s-%s%-28.28s%s%-9s%s%-4s%s\n' \
        "$GRN" "${#ACCT[@]}" "$RED" "$WHT" "$n" "$RED" "$FD" "$c" "$d" "$RST"
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
  menu_end VOLVER "$BTN_REDW"
  rd "NUMERO O NOMBRE: " sel || return 3
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

# ---- Eliminar cuentas SSH: advertencia con espera obligatoria antes de borrar -----------
# Cuenta regresiva que no se puede saltar: da tiempo a leer la advertencia. Lo que se teclee
# mientras tanto se descarta, para que un ENTER suelto no llegue a confirmar nada.
warn_wait() {   # segundos
  local s=$1 w
  if [[ -t 1 ]]; then
    printf '\e[?25l'
    while (( s > 0 )); do
      w=segundos; (( s == 1 )) && w=segundo
      printf '\r\e[K %sPodras continuar en %d %s...%s' "$YEL" "$s" "$w" "$RST"
      sleep 1; s=$(( s - 1 ))
    done
    printf '\r\e[K\e[?25h'
  else
    info "Espera $s segundos para continuar..."; sleep "$s"
  fi
  if [[ -t 0 ]]; then while read -r -s -n 1 -t 0.05 _; do :; done; fi
}

# Nombres en 3 columnas (hasta $1); si son mas, resume el resto para que la pantalla no se desborde
names_grid() {   # max nombre...
  local max=$1 total n=0 u row=''
  shift; total=$#
  for u in "$@"; do
    (( n < max )) || break
    row+=$(printf '%s%-17.17s%s' "$WHT" "$u" "$RST")
    n=$(( n + 1 ))
    if (( n % 3 == 0 )); then printf ' %s\n' "$row"; row=''; fi
  done
  [[ -z $row ]] || printf ' %s\n' "$row"
  (( total <= max )) || printf ' %s... y %d mas%s\n' "$GRY" $(( total - max )) "$RST"
}

# Advertencia + espera (DEL_WAIT_SEL segundos en la opcion 2, DEL_WAIT en la 8) + confirmacion.
# Devuelve 3 si se cancela.
ssh_confirm_delete() {   # all|sel  nombres...
  local mode=$1 c n head secs=$DEL_WAIT_SEL
  shift; n=$#
  [[ $mode == all ]] && secs=$DEL_WAIT
  cls
  title "ADVERTENCIA" "$YEL"
  if [[ $mode == all ]]; then
    printf ' %sSe van a ELIMINAR TODAS las cuentas SSH (%d).%s\n\n' "$RED" "$n" "$RST"
  else
    if (( n == 1 )); then head="Se va a ELIMINAR 1 cuenta SSH:"; else head="Se van a ELIMINAR $n cuentas SSH:"; fi
    printf ' %s%s%s\n\n' "$RED" "$head" "$RST"
    names_grid 15 "$@"
    echo
  fi
  warn "Se borran del servidor y del panel."
  warn "Se cierran sus conexiones activas."
  warn "Esta accion NO se puede deshacer."
  echo
  warn_wait "$secs"
  if [[ $mode == all ]]; then
    rd "ESCRIBE SI PARA ELIMINAR TODAS LAS CUENTAS: " c || return 3
    [[ $c == SI ]] || return 3
  else
    rd "CONFIRMAR LA ELIMINACION? (s/N): " c || return 3
    [[ $c == [sS]* ]] || return 3
  fi
}

# Borra las cuentas indicadas: cierra sus conexiones, las quita del sistema y de users.db.
# Una cuenta solo sale de users.db si de verdad dejo de existir en el sistema; si no se pudo
# borrar, queda en la lista para poder reintentarlo.
ssh_remove() {   # nombres...
  local u t list
  local -a gone=() failed=()
  (( $# > 20 )) && info "Eliminando $# cuentas..."
  for u in "$@"; do
    valid_name "$u" || { failed+=("$u"); continue; }
    pkill -KILL -u "$u" 2>/dev/null
    userdel -f "$u" 2>/dev/null
    if id "$u" >/dev/null 2>&1; then failed+=("$u"); else gone+=("$u"); fi
  done
  if (( ${#gone[@]} )); then
    t=$(mktemp)
    list=$(IFS='|'; printf '%s' "${gone[*]}")
    awk -F'|' -v list="|$list|" 'index(list, "|" $1 "|") == 0' "$USERDB" > "$t" && cat "$t" > "$USERDB"
    rm -f "$t"
  fi
  if (( ${#gone[@]} == 1 )); then ok "Usuario ${gone[0]} eliminado"
  elif (( ${#gone[@]} > 1 )); then ok "${#gone[@]} usuarios eliminados"; fi
  if (( ${#failed[@]} )); then err "No se pudo eliminar: ${failed[*]}"; return 1; fi
  return 0
}

# Opcion 2: una o varias cuentas, por numero o por nombre, separadas por comas (1,5,6,9).
# Si algun dato no esta en la lista no se elimina nada. Hasta 3 cuentas (DEL_NOWARN) se borran
# directo, sin advertencia; con mas de 3 sale la advertencia con espera de DEL_WAIT_SEL segundos.
ssh_delete() {
  local sel tok idx u n
  local -a toks=() del=() bad=()
  local -A seen=()
  grep -q '^[^|]' "$USERDB" 2>/dev/null || { warn "No hay cuentas creadas"; return 1; }
  acct_table "$USERDB"
  menu_end VOLVER "$BTN_REDW"
  rd "NUMEROS O NOMBRES (EJ: 1,5,6,9): " sel || return 3
  read -ra toks <<< "${sel//,/ }"
  (( ${#toks[@]} )) || return 3
  [[ ${toks[*]} == 0 ]] && return 3
  for tok in "${toks[@]}"; do
    u=
    if [[ $tok =~ ^[0-9]{1,6}$ ]]; then
      idx=$(( 10#$tok ))
      (( idx >= 1 && idx <= ${#ACCT[@]} )) && u=${ACCT[idx-1]}
    else
      for n in "${ACCT[@]}"; do [[ $n == "$tok" ]] && { u=$n; break; }; done
    fi
    if [[ -z $u ]]; then bad+=("$tok"); continue; fi
    [[ -n ${seen[$u]:-} ]] && continue
    seen[$u]=1; del+=("$u")
  done
  if (( ${#bad[@]} )); then
    err "No esta en la lista: ${bad[*]}"
    info "Usa numeros separados por comas: 1,5,6,9"
    return 1
  fi
  if (( ${#del[@]} > DEL_NOWARN )); then
    ssh_confirm_delete sel "${del[@]}" || return $?
  fi
  ssh_remove "${del[@]}"
}

# Opcion 8: todas las cuentas SSH. Pide escribir SI despues de la advertencia.
ssh_delete_all() {
  local u
  local -a all=()
  while IFS='|' read -r u _; do [[ -n $u ]] && all+=("$u"); done < "$USERDB"
  (( ${#all[@]} )) || { warn "No hay cuentas creadas"; return 1; }
  ssh_confirm_delete all "${all[@]}" || return $?
  ssh_remove "${all[@]}"
}

ssh_renew() {
  local u d exp
  pick_account "$USERDB" || return $?
  u=$PICK
  valid_name "$u" && grep -q "^${u}|" "$USERDB" || { err "Usuario no encontrado"; return 1; }
  rd_def "DIAS DESDE HOY PARA $u [30]:" d 30 || return 3
  [[ $d =~ ^[0-9]+$ ]] || { err "Dias invalidos"; return 1; }
  exp=$(date -d "+$d days" +%F)
  usermod -e "$exp" "$u" && db_set "$u" 3 "$exp" && ok "$u vence el $exp"
}

ssh_passwd() {
  local u p
  rd "USUARIO: " u
  valid_name "$u" && grep -q "^${u}|" "$USERDB" || { err "Usuario no encontrado"; return 1; }
  rd_pass "NUEVA CONTRASENA:" p || return 1
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
  rd "ELIMINAR LA CUENTA $n? (s/N): " c
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
  rd_def "DIAS DESDE HOY PARA $n [30]:" d 30 || return 1
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
  rd_def "Tamano de swap en MB [1024]:" s 1024 || return 1
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
  rd_def "DNS primario [1.1.1.1]:" d1 1.1.1.1 || return 1
  rd_def "DNS secundario [8.8.8.8]:" d2 8.8.8.8 || return 1
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
  rd "ESCRIBE SI PARA CONTINUAR: " c
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
    rd "NOMBRE DEL VPS: " name || { err "No hay entrada disponible"; return 1; }
    read -ra w <<< "$name"; name="${w[*]:-}"            # quita espacios sobrantes
    if [[ -z $name && -n $cur ]]; then return 0; fi
    if ! name_check "$name"; then
      warn "$MSG"; sleep 2; continue
    fi
    sub_header "REGISTRO DE VPS"
    center_grad "=====>>>> ${name^^} <<<<====="
    echo
    rd "CONFIRMAR ESTE NOMBRE? [S/n]: " ans || return 1
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
  cols "1:$(pcell DROPBEAR "$PORT_DROPBEAR")"  "21:$(pcell SSL "$PORT_SSL")"
  cols "1:$(pcell WEBSOCKET "$PORT_WS")"       "21:$(pcell SQUID "$PORT_SQUID")"
  cols "1:$(pcell V2RAY "$PORT_V2RAY")"        "21:$(pcell BADVPN "$PORT_BADVPN")"
  cols "1:$(pcell UDPCUSTOM "$PORT_UDP")"
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
  field "IP:" "$IP" "$PNK"
  [[ -s $DOMAIN_F ]] && field "DOMINIO:" "$(get_host)"
  field "NOMBRE DE USUARIO:" "$1"
  field "CONTRASENA DE USUARIO:" "$2"
  field "CONEXIONES:" "$4"
  field "EXPIRA EN:" "${3:8:2}/${3:5:2}/${3:0:4}"
  section "PUERTOS"
  cols "1:$(pcell SSH "$SSH_PORT")"     "21:$(pcell DROPBEAR "$PORT_DROPBEAR")"
  cols "1:$(pcell SSL "$PORT_SSL")"     "21:$(pcell WEBSOCKET "$PORT_WS")"
  cols "1:$(pcell SQUID "$PORT_SQUID")" "21:$(pcell UDPCUSTOM "$PORT_UDP")"
  line_eq
  field "UDPGW:" "127.0.0.1:$PORT_BADVPN" "$GRN"
  printf ' %sPAYLOAD WS:%s\n' "$BLU" "$RST"
  printf ' %sGET / HTTP/1.1[crlf]Host: %s[crlf]Upgrade: websocket[crlf][crlf]%s\n' "$GRN" "$(get_host)" "$RST"
}

ssh_list() {
  grep -q '^[^|]' "$USERDB" 2>/dev/null || { warn "No hay usuarios creados"; return 0; }
  acct_table "$USERDB"
  printf '\n %sTOTAL: %d%s\n' "$BLU" "${#ACCT[@]}" "$RST"
}

ssh_online() {
  local u p e l n tot=0
  printf '%s %-20s %s%s\n' "$LYE" USUARIO CONEXIONES "$RST"
  line_dash
  while IFS='|' read -r u p e l; do
    [[ -n $u ]] || continue
    n=$(ps -u "$u" -o comm= 2>/dev/null | grep -cE '^(sshd|dropbear)$')
    if (( n > 0 )); then printf ' %s%-20s%s %s%s%s\n' "$WHT" "$u" "$RST" "$GRN" "$n" "$RST"; tot=$(( tot + n )); fi
  done < "$USERDB"
  printf '\n %sTOTAL DE CONEXIONES: %d%s\n' "$BLU" "$tot" "$RST"
}

menu_ssh() {
  ensure_base
  local o
  while :; do
    sub_header "ADMINISTRACION DE USUARIOS SSH V16"
    item 1 "NUEVO USUARIO SSH"
    item 2 "REMOVER USUARIO" "$RED"
    item 3 "RENOVAR USUARIO" "$GRN"
    item 4 "CAMBIAR CONTRASENA"
    line_dash
    item 5 "DETALLES DE TODOS USUARIOS" "$GRN"
    item 6 "MONITOR DE USUARIOS CONECTADOS"
    line_dash
    item 7 "ELIMINAR USUARIOS VENCIDOS"
    item 8 "ELIMINAR TODOS LOS USUARIOS" "$RED"
    menu_end VOLVER "$BTN_REDW"
    ask o u || return
    case $o in
      1) ssh_create;                                  [[ $? == 3 ]] && continue ;;
      2) sub_header "REMOVER USUARIO";                ssh_delete; [[ $? == 3 ]] && continue ;;
      3) sub_header "RENOVAR USUARIO";                ssh_renew;  [[ $? == 3 ]] && continue ;;
      4) sub_header "CAMBIAR CONTRASENA";             ssh_passwd ;;
      5) sub_header "DETALLES DE TODOS USUARIOS";     ssh_list ;;
      6) sub_header "MONITOR DE USUARIOS CONECTADOS"; ssh_online ;;
      7) sub_header "ELIMINAR USUARIOS VENCIDOS";     /usr/local/bin/vps-cleanup && ok "Usuarios vencidos eliminados" ;;
      8) sub_header "ELIMINAR TODOS LOS USUARIOS";    ssh_delete_all; [[ $? == 3 ]] && continue ;;
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
  rd "NOMBRE DE LA CUENTA: " n
  valid_name "$n" || { err "Nombre invalido (3-31 caracteres: a-z 0-9 _ -)"; return 1; }
  if grep -q "^${n}|" "$V2DB"; then err "La cuenta ya existe"; return 1; fi
  rd_def "DIAS DE VALIDEZ [30]:" d 30 || return 1
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
  now=$(date +%s)
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
  local o
  while :; do
    sub_header "ADMINISTRACION DE CUENTAS V2RAY"
    item 1 "NUEVA CUENTA V2RAY"
    item 2 "REMOVER CUENTA" "$RED"
    item 3 "RENOVAR CUENTA" "$GRN"
    line_dash
    item 4 "DETALLES Y ENLACES DE LAS CUENTAS" "$GRN"
    menu_end VOLVER "$BTN_REDW"
    ask o u || return
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

proto_menu() {   # clave nombre   (administrador de un protocolo)
  local k=$1 nm=$2 o st sub
  case $k in openvpn|wireguard) sub_header "$nm"; proto_action "$k"; pause; return ;; esac
  while :; do
    if is_on "$k" || proto_installed "$k"; then st=installed; else st=none; fi
    sub="PUERTO: $(pget "$k")"
    [[ $k == ws ]]       && sub+=" >> $SSH_PORT"
    [[ $k == v2ray ]]    && sub+="   PATH: $V2PATH"
    [[ $k == slowdns ]]  && sub+="   NS: $(cat "$BASE/slowdns/ns" 2>/dev/null || echo -)"
    cls
    title "$nm MANAGER"
    center "$sub" "$LYE"
    line_eq
    if [[ $st == installed ]]; then
      item_on 1 "INICIAR/PARAR SERVICIO" is_on "$k"
    else
      item 1 "INSTALAR $nm" "$GRN"
    fi
    line_dash
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

# ------------------------------ Herramientas --------------------------
menu_view() {   # mostrar u ocultar partes de la pantalla principal
  local o ON_W=26
  while :; do
    sub_header "VISTA DEL PANEL"
    item_on 1 "MOSTRAR NOMBRE DEL VPS"        is_shown name
    item_on 2 "MOSTRAR DATOS DEL SERVIDOR"    is_shown server
    item_on 3 "MOSTRAR PUERTOS ACTIVOS"       is_shown services
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

# Celdas de la pantalla de preparacion del sistema (dos columnas, como la referencia)
scell() {   # numero texto [clave de protocolo]  ->  " [1]> TEXTO         [ON]"
  local st=''
  [[ -n ${3:-} ]] && st=$(onoff is_on "$3")
  printf ' %s%4s%s%s>%s %s%-14s%s%s' "$GRN" "[$1]" "$RST" "$RED" "$RST" "$WHT" "$2" "$RST" "$st"
}

qcell() {   # numero texto [marca]  ->  " [11]> TEXTO  o"  (la marca va en la columna del estado)
  local pad
  printf ' %s%4s%s%s>%s %s%s%s' "$GRN" "[$1]" "$RST" "$RED" "$RST" "$WHT" "$2" "$RST"
  if [[ -n ${3:-} ]]; then
    pad=$(( 14 - ${#2} )); (( pad < 1 )) && pad=1
    printf '%*s%s' "$pad" '' "$3"
  fi
}

swap_on() { swapon --show --noheadings 2>/dev/null | grep -q .; }

mark() {   # comando [args]  ->  marca verde (activo) o roja (inactivo)
  if "$@"; then printf '%s%s%s' "$GRN" "$MK_ON" "$RST"; else printf '%s%s%s' "$RED" "$MK_OFF" "$RST"; fi
}

menu_system() {   # PREPARACION DEL SISTEMA: puertos activos, protocolos y configuraciones rapidas
  local o i h n
  while :; do
    cls
    title "INFORMACION DEL SISTEMA Y PUERTOS ACTIVOS" "$YEL"
    ports_block
    section "MENU DE PROTOCOLOS"
    n=${#PROTO_KEYS[@]}; h=$(( (n + 1) / 2 ))        # izquierda 1..h, derecha h+1..n
    for (( i = 0; i < h; i++ )); do
      if (( i + h < n )); then
        cols "0:$(scell $(( i + 1 )) "${PROTO_NAMES[i]}" "${PROTO_KEYS[i]}")" \
             "26:$(scell $(( i + h + 1 )) "${PROTO_NAMES[i + h]}" "${PROTO_KEYS[i + h]}")"
      else
        cols "0:$(scell $(( i + 1 )) "${PROTO_NAMES[i]}" "${PROTO_KEYS[i]}")"
      fi
    done
    section "CONFIGURACIONES RAPIDAS"
    cols "0:$(qcell 11 'CAMBIAR PUERTOS')"      "26:$(qcell 16 'LIMPIAR CACHE/LOGS')"
    cols "0:$(qcell 12 'RESTAURAR PUERTOS')"    "26:$(qcell 17 'CONFIGURAR IP DNS')"
    cols "0:$(qcell 13 'BANNER SSH')"           "26:$(qcell 18 'GEN DOMI/CERT-SSL' "$(mark test -s "$DOMAIN_F")")"
    cols "0:$(qcell 14 'ACELERACION TCPBBR')"   "26:$(qcell 19 'CLAVE Y ACCESO ROOT')"
    cols "0:$(qcell 15 'MEMORIA SWAP' "$(mark swap_on)")" "26:$(qcell 20 'REINICIAR SERVICIOS')"
    line_eq
    item 21 "NOMBRE DEL VPS"  "$DBL"
    item 22 "VISTA DEL PANEL" "$BLU"
    line_eq
    printf ' %s%4s%s %s>%s    %s VOLVER %s        %s%4s%s %s>%s %sAUTO-INICIAR%s %s\n' \
      "$GRN" "[0]" "$RST" "$RED" "$RST" "$BTN_RED" "$RST" \
      "$GRN" "[23]" "$RST" "$RED" "$RST" "$WHT" "$RST" "$(onoff autostart_on)"
    line_eq
    ask o || return
    case $o in
      0)  return ;;
      11) sub_header "CAMBIAR PUERTOS";        ports_wizard ;;
      12) sub_header "RESTAURAR PUERTOS";      ports_reset ;;
      13) sub_header "BANNER SSH";             cfg_banner; [[ $? == 3 ]] && continue ;;
      14) sub_header "ACELERACION TCP BBR";    cfg_bbr ;;
      15) sub_header "MEMORIA SWAP";           cfg_swap ;;
      16) sub_header "LIMPIAR CACHE Y LOGS";   cfg_cache ;;
      17) sub_header "CONFIGURAR DNS";         cfg_dns ;;
      18) sub_header "DOMINIO Y CERTIFICADO";  cfg_domain ;;
      19) sub_header "CLAVE Y ACCESO ROOT";    cfg_root ;;
      20) sub_header "REINICIAR SERVICIOS";    restart_services ;;
      21) cfg_vpsname; continue ;;
      22) menu_view; continue ;;
      23) toggle_autostart ;;
      *)  if [[ $o =~ ^[0-9]+$ ]] && (( o >= 1 && o <= ${#PROTO_KEYS[@]} )); then
            proto_menu "${PROTO_KEYS[o-1]}" "${PROTO_NAMES[o-1]}"
          fi
          continue ;;
    esac
    pause
  done
}

# ---------------------------------- Menu ------------------------------
fmt_mb() {   # MB -> 1.9Gi / 186Mi (redondeado como "free -h")
  local m=$1 t
  if (( m >= 1024 )); then t=$(( (m * 10 + 512) / 1024 )); printf '%d.%dGi' $(( t / 10 )) $(( t % 10 ))
  else printf '%dMi' "$m"; fi
}

sys_stats() {   # llena las variables de CPU y RAM que muestra header()
  local l1 mt mu mf
  read -r l1 _ < /proc/loadavg
  CPU_N=$(nproc 2>/dev/null || echo 1)
  CPU_P=$(awk -v l="$l1" -v n="$CPU_N" 'BEGIN{p=l/n*100; if(p>100)p=100; printf "%d", p}')
  read -r mt mu mf < <(free -m | awk '/^Mem:/{print $2, $3, $4}')
  mt=${mt:-0}; mu=${mu:-0}; mf=${mf:-0}
  RAM_T=$(fmt_mb "$mt"); RAM_U=$(fmt_mb "$mu"); RAM_F=$(fmt_mb "$mf")
  RAM_P=$(awk -v u="$mu" -v t="$mt" 'BEGIN{printf "%.2f", (t > 0 ? u / t * 100 : 0)}')
}

# Servicios del bloque de puertos (en este orden) y como se llaman ahi
SHOW_KEYS=(badvpn dropbear ssh ssl v2ray ws udp squid slowdns openvpn wireguard)
declare -A SHOW_LABEL=([badvpn]=BADVPN [dropbear]=DROPBEAR [ssh]=SSH [ssl]=SSL [v2ray]=V2RAY [ws]=WEBSOCKET
                       [udp]=UDPCUSTOM [squid]=SQUID [slowdns]=SLOWDNS [openvpn]=OPENVPN [wireguard]=WIREGUARD)

svc_port() {   # clave -> puerto que se muestra (openvpn y wireguard lo leen de su configuracion)
  case $1 in
    ssh)       echo "$SSH_PORT" ;;
    openvpn)   awk '$1=="port"{print $2; exit}' /etc/openvpn/server/server.conf /etc/openvpn/server.conf 2>/dev/null ;;
    wireguard) awk -F' *= *' '$1=="ListenPort"{print $2; exit}' /etc/wireguard/wg0.conf 2>/dev/null ;;
    *)         pget "$1" ;;
  esac
}

ports_block() {   # puertos de los servicios activos: ETIQUETA: puerto, en dos columnas
  local k p n=0 left=''
  for k in "${SHOW_KEYS[@]}"; do
    is_on "$k" || continue
    p=$(svc_port "$k"); p=${p:--}
    if (( n % 2 == 0 )); then
      left=$(pcell "${SHOW_LABEL[$k]}" "$p")
    else
      cols "1:$left" "21:$(pcell "${SHOW_LABEL[$k]}" "$p")"
    fi
    n=$(( n + 1 ))
  done
  (( n % 2 )) && cols "1:$left"
  (( n > 0 ))   # devuelve 0 solo si hay algo que mostrar
}

header() {
  local name
  name=$(vps_name)
  if is_hidden name || [[ -z $name ]]; then name='VPS PANEL'; fi
  is_hidden server || sys_stats

  cls
  # Titulo
  line_eq
  center_grad "=====>>>> ${name^^} <<<<====="
  line_eq

  # Datos del servidor: SISTEMA / MEMORIA / PROCESADOR
  if ! is_hidden server; then
    cols "1:${GRN}SISTEMA${RST}" "24:${GRN}MEMORIA${RST}" "40:${GRN}PROCESADOR${RST}"
    cols "1:${BLU}S.O:${RST} ${WHT}${OS_NAME:0:17}${RST}" \
         "24:${BLU}RAM:${RST}    ${GRN}${RAM_T}${RST}" \
         "40:${BLU}CPU:${RST} ${GRN}${CPU_N}${RST}"
    cols "1:${BLU}IP:${RST} ${PNK}${IP:0:18}${RST}" \
         "24:${BLU}USADA:${RST}  ${GRN}${RAM_U}${RST}" \
         "40:${BLU}EN USO:${RST}${GRN}${CPU_P}%${RST}"
    cols "1:${BLU}FECHA:${RST} ${WHT}$(date +%D)${RST}" \
         "24:${BLU}LIBRE:${RST}  ${GRN}${RAM_F}${RST}"
    cols "1:${BLU}HORA:${RST}  ${WHT}$(date +%T)${RST}" \
         "24:${BLU}EN USO:${RST} ${GRN}${RAM_P}%${RST}"
    line_eq
  fi

  # Puertos de los servicios activos
  if ! is_hidden services; then
    ports_block && line_eq
  fi

  # Menu
  item_m 1 "ADMINISTRAR CUENTAS (SSH/DROPBEAR)"
  item_m 1.1 "CREAR USUARIO RAPIDO"
  item_m 2 "ADMINISTRAR CUENTAS (V2ray)"
  line_dash
  item_m 3 "PREPARACION DEL SISTEMA" "$HL_GRY"
  line_dash
  printf ' %s[4]%s %s>%s %s[!]%s %sDESINSTALAR PANEL%s\n' "$GRN" "$RST" "$RED" "$RST" "$YEL" "$RST" "$RED" "$RST"
  line_dash
  item_m 5 "INSTALAR TODOS LOS PROTOCOLOS"
  line_eq
  printf ' %s0)%s %sSALIR DEL VPS%s  %s6)%s %sSALIR DEL SCRIPT%s  %s7)%s %sREBOOT VPS%s\n' \
    "$GRN" "$RST" "$BTN_GRAY" "$RST" "$GRN" "$RST" "$BTN_RED" "$RST" "$GRN" "$RST" "$BTN_BLUE" "$RST"
  line_eq
}

exit_vps() {   # cierra el panel y la sesion SSH que lo abrio
  local p
  cls
  p=$(ps -o comm= -p "$PPID" 2>/dev/null)
  case $p in bash|-bash|sh|dash|ash|zsh) kill -HUP "$PPID" 2>/dev/null ;; esac
  exit 0
}

main_menu() {
  local o c=''
  while :; do
    header
    ask o m || exit 0
    case $o in
      1) menu_ssh ;;
      1.1) sub_header "CREAR USUARIO RAPIDO"; quick_user; pause ;;
      2) menu_v2 ;;
      3) ensure_base; menu_system ;;
      4) sub_header "DESINSTALAR PANEL"; uninstall_all; pause ;;
      5) sub_header "INSTALACION COMPLETA"; install_all; pause ;;
      6) cls; exit 0 ;;
      7) rd "REINICIAR EL VPS AHORA? (s/N): " c; [[ $c == [sS] ]] && reboot ;;
      0) exit_vps ;;
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
