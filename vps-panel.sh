#!/usr/bin/env bash
# ======================================================================
#  VPS PANEL v3.3 - instalador y administrador de protocolos para tuneles
#  Compatible con HTTP Custom y apps similares.
#  SSH, Dropbear, SSL, WebSocket, SOCKS Python, WS-ePro, Squid, V2Ray,
#  BadVPN-UDPGW, UDP Custom, SlowDNS, OpenVPN, WireGuard y Psiphon
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
#  Atajo "1.2": cuentas de prueba prueba1, prueba2, prueba3... (contrasena xxx, 3 conexiones) que
#  duran 24 horas exactas desde que se crean (no hasta medianoche). La hora exacta de cada una
#  queda en /etc/vpspanel/users.exp y la secuencia en /etc/vpspanel/test.seq.
#  Usuarios SSH: la opcion 2 elimina varios a la vez (1,5,6,9) y la 8 elimina todos. En la 2,
#  hasta 3 usuarios (DEL_NOWARN) se borran directo, sin advertencia; con mas de 3 sale la
#  advertencia y se esperan 3 segundos (DEL_WAIT_SEL). En la 8 la espera es de 7 (DEL_WAIT).
#  Los puertos se cambian en Preparacion del sistema y se guardan en /etc/vpspanel/ports.conf
#    UDPCUSTOM_URL=<url> vpspanel      (opcional) usar otro binario de udp-custom
#    SLOWDNS_NS=<ns> vpspanel --install-all   (opcional) incluir SlowDNS sin preguntar
#
#  Instalacion desde cero (VPS nuevo): el panel espera a que terminen las actualizaciones
#  automaticas del sistema, actualiza la lista de paquetes, abre cada puerto en el firewall
#  (ufw, firewalld e iptables; servicio vps-firewall para que sigan abiertos al reiniciar) y
#  comprueba cada protocolo con una conexion real antes de darlo por activo.
#  Registro de errores: todo lo que hacen los comandos queda en /var/log/vpspanel/<protocolo>.log
#  y, si algo falla, el error real (salida del comando o journal del servicio) sale en pantalla.
#
#  Copias de seguridad (opcion 9): /var/backups/vpspanel, fuera de /etc/vpspanel. Actualizar,
#  reinstalar o cambiar el script no las toca y desinstalar las conserva salvo que pidas borrarlas.
#  Se crea una copia sola cada vez que cambian usuarios o configuracion (y una diaria), y otra antes
#  de actualizar, restaurar o desinstalar. Si el panel se instala de nuevo sin datos, recupera solo
#  los usuarios (con su contrasena, vencimiento y limite), los puertos, llaves y clientes.
#  Actualizar (opcion 8): con el enlace RAW del instalador nuevo (https). Antes se guardan los
#  datos y la version actual; si algo sale mal, "vps-rollback" vuelve a la version anterior.
#    vpspanel --backup               crear una copia ahora
#    vpspanel --restore ARCHIVO      restaurar una copia (tambien una traida de otro VPS)
#    vpspanel --update [ENLACE]      actualizar el panel
#    vps-rollback                    volver a la version anterior del panel
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
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}

# ------------------------------ Configuracion -------------------------
VERSION=3.3
PREP_V=3          # version de la preparacion del sistema (se repite si cambia)
NAME_MAX=24        # largo maximo del nombre del VPS (se muestra en el titulo)
DEF_PASS=xxxx      # contrasena por defecto de las cuentas SSH (ENTER en el campo la escribe sola)
BASE=${VPSPANEL_BASE:-/etc/vpspanel}
LOG_DIR=${VPSPANEL_LOGDIR:-/var/log/vpspanel}   # registros de instalacion y errores
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

# Atajo "1.2" del menu principal: cuentas de prueba prueba1, prueba2, prueba3... sin preguntar nada
TEST_PREFIX=prueba         # nombre base; el numero lo pone su propia secuencia
TEST_PASS=xxx              # contrasena fija
TEST_HOURS=24              # duracion exacta en horas (24 = 1 dia): vence a esa hora, no a medianoche
TEST_LIMIT=3               # conexiones simultaneas
TEST_SEQ_F=$BASE/test.seq  # ultimo numero usado de prueba1, prueba2... (no se reutilizan)
PX_DB=$BASE/users.exp      # vencimiento exacto de las cuentas de prueba: usuario|segundos desde 1970
DB_LOCK=$BASE/cleanup.lock # candado de las bases de cuentas (el mismo de vps-cleanup: nunca escriben a la vez)

# Copias de seguridad y actualizaciones: fuera de $BASE, sobreviven a actualizar y reinstalar
BK_DIR=${VPSPANEL_BKDIR:-/var/backups/vpspanel}
BK_KEEP=30                 # copias automaticas que se conservan
BK_KEEP_EV=15              # copias manuales y de antes de actualizar, restaurar o desinstalar
BK_FORMAT=1                # formato de las copias (MANIFEST: format=1)
SCRIPT_BK=$BK_DIR/scripts  # versiones anteriores del panel (vps-rollback)
PANEL_BIN=${VPSPANEL_BIN:-/usr/local/bin/vpspanel}
HELPERS_V=2                # version de vps-cleanup, vps-rollback y el cron: si cambia, se reinstalan solos
UPDATE_URL=''              # enlace fijo del instalador para ACTUALIZAR PANEL (vacio: se pregunta y se recuerda)

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
PORT_SOCKS=${PORT_SOCKS:-8880}       # SOCKS Python (proxy HTTP/SOCKS5 -> SSH)
PORT_WSEPRO=${PORT_WSEPRO:-2082}     # WS-ePro (WebSocket -> Dropbear o SSH)
PORT_OVPN=${PORT_OVPN:-1194}         # OpenVPN (TCP)
PORT_WG=${PORT_WG:-51820}            # WireGuard (UDP)
PORT_PSIPHON=${PORT_PSIPHON:-3001}   # Psiphon: OSSH en este puerto y MEEK en el siguiente
UDPCUSTOM_URL=${UDPCUSTOM_URL:-}

# Puertos personalizables (Protocolos > Cambiar puerto). PVAR: variable de cada protocolo.
declare -A PVAR=([dropbear]=PORT_DROPBEAR [ssl]=PORT_SSL [badvpn]=PORT_BADVPN [ws]=PORT_WS
                 [squid]=PORT_SQUID [v2ray]=PORT_V2RAY [udp]=PORT_UDP [slowdns]=PORT_SLOWDNS
                 [socks]=PORT_SOCKS [wsepro]=PORT_WSEPRO [openvpn]=PORT_OVPN [wireguard]=PORT_WG
                 [psiphon]=PORT_PSIPHON)
declare -A PDEF=([dropbear]=110 [ssl]=443 [badvpn]=7300 [ws]=80
                 [squid]=3128 [v2ray]=8080 [udp]=36712 [slowdns]=5300
                 [socks]=8880 [wsepro]=2082 [openvpn]=1194 [wireguard]=51820 [psiphon]=3001)
PORT_KEYS=(dropbear ssl ws squid v2ray badvpn udp slowdns socks wsepro openvpn wireguard psiphon)

# UDP Custom: binario x86_64 descargado automaticamente. La URL apunta a un commit
# exacto del repositorio (no a "main") y el archivo se verifica con SHA256 antes de
# instalarlo, asi no puede cambiar sin que el panel se entere.
UDP_BIN_URL=https://raw.githubusercontent.com/Rerechan02/UDP/d0ebcc4b65a4ac3dffc3739df402a36d7297ef08/bin/udp-custom-linux-amd64
UDP_BIN_SHA256=2a1b5584c7947feb5a02e847e09795751024f63ce7137a353c2b9c2a4282d636

# Psiphon (psiphond oficial de Psiphon-Labs, x86_64): commit fijo y SHA256 verificado.
PSIPHON_URL=https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/0f968b4dd6981b75aad9c72b51e39edfefec52ff/psiphond/psiphond
PSIPHON_SHA256=073769485c5b5817e042f7f0e9a51a1b09cd1050ccb61d667f62038874d7db43

SSH_PORT=$( { sshd -T 2>/dev/null || cat /etc/ssh/sshd_config; } 2>/dev/null | awk 'tolower($1)=="port"{print $2; exit}')
SSH_PORT=${SSH_PORT:-22}

# V2Ray: se descarga el ultimo release oficial sin usar la API de GitHub (que limita a 60
# consultas por hora por IP y hace fallar la instalacion) y se verifica con su .dgst (SHA256).
V2_RELEASE=https://github.com/v2fly/v2ray-core/releases/latest/download
BADVPN_REPO=https://github.com/ambrop72/badvpn.git
DNSTT_REPO=https://www.bamsoftware.com/git/dnstt.git
DNSTT_COMMIT=0c5c52a57d899c05428c116898941761a2ed83c2
GO_VERSION=1.23.12                  # Go oficial (para compilar dnstt y wireguard-go), verificado con SHA256
declare -A GO_SHA256=([amd64]=d3847fef834e9db11bf64e3fb34db9c04db14e068eeb064f49af747010454f90
                      [arm64]=52ce172f96e21da53b1ae9079808560d49b02ac86cecfa457217597f9bc28ab3)
WGGO_REPO=https://git.zx2c4.com/wireguard-go   # WireGuard en espacio de usuario (kernels sin WireGuard)
WGGO_TAG=0.0.20250522

OVPN_DIR=/etc/openvpn/server        # OpenVPN propio del panel (usuario/contrasena = cuentas SSH)
OVPN_NET=10.8.0.0/24
WG_CONF=/etc/wireguard/wg0.conf
WG_NET=10.66.66                     # red de WireGuard: servidor .1, clientes .2 a .254
PSI_DIR=$BASE/psiphon
SSL_SOCK=/run/vps-sslws/ssl.sock    # proxy interno de SSL (SSH directo o payload dentro de TLS)

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
  [socks]=vps-socks
  [wsepro]=vps-wsepro
  [psiphon]=vps-psiphon
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
  [openvpn]=inst_openvpn
  [wireguard]=inst_wireguard
  [socks]=inst_socks
  [psiphon]=inst_psiphon
  [wsepro]=inst_wsepro
)
PROTO_KEYS=(dropbear ssl badvpn ws squid v2ray udp slowdns openvpn wireguard socks psiphon wsepro)
PROTO_NAMES=("DROPBEAR" "SSL" "BADVPN" "WEBSOCKET" "SQUID"
             "V2RAY" "UDP CUSTOM" "SLOWDNS" "OPENVPN" "WIREGUARD"
             "SOCKS PYTHON" "PSIPHON" "WS-EPRO")

# ------------------------------ Interfaz ------------------------------
# Todo el aspecto visual esta en este bloque. Replica el panel de referencia:
#   - lineas "=" y "-" rojas de 53 columnas; titulos en blanco (secciones en naranja)
#   - menus con el formato "[1] > TEXTO" y estados [ON] verde / [OFF] rojo
#   - botones con fondo de color (gris, rojo y azul)
#   - titulo del panel (nombre del VPS) en blanco entre las lineas rojas, como cada pantalla
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
    #                texto (R G B)   fondo (R G B)   ansi16
    BTN_GRAY=$(c_bt 226 227 232  141 145 165 '30;47')     # boton gris   (SALIR DEL VPS)
    BTN_RED=$(c_bt  226 227 232  242  78  80 '1;37;41')   # boton rojo   (VOLVER, SALIR DEL SCRIPT)
    BTN_REDW=$(c_bt 255 255 255  242  78  80 '1;37;41')   # boton rojo con texto blanco (menus SSH)
    BTN_BLUE=$(c_bt 226 227 232    8  99 159 '1;37;44')   # boton azul   (REBOOT VPS)
    HL_GRY=$(c_bt   255 255 255  141 145 165 '1;30;47')   # resaltado gris (PREPARACION DEL SISTEMA)
  else
    RST=''; RED=''; GRN=''; BLU=''; DBL=''; WHT=''; YEL=''; LYE=''; PNK=''; GRY=''; MAG=''
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

title()      { line_eq; center "$1" "${2:-$WHT}"; line_eq; }   # barra, titulo, barra
brand()      { title "${1^^}" "$WHT"; }                       # titulo del panel: nombre del VPS en blanco
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

rd() { local p=$1; shift; read -rp " ${WHT}${p}${RST}" "$@"; }   # pregunta: rd "TEXTO: " variable (nunca "p")

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
  if [[ ! -t 1 ]]; then info "$text..."; "$@" >>"${SPIN_LOG:-/dev/null}" 2>&1 </dev/null; return $?; fi
  "$@" >>"${SPIN_LOG:-/dev/null}" 2>&1 </dev/null &
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
  mkdir -p "$BASE" "$LOG_DIR"
  chmod 700 "$LOG_DIR" 2>/dev/null
  touch "$USERDB" "$V2DB" "$PX_DB"
  chmod 600 "$USERDB" "$V2DB" "$PX_DB"
  # restos de escrituras cortadas (un corte nunca deja la base a medias: se escribe en .tmp-*)
  find "$BASE" -maxdepth 2 -name '.tmp-*' -mmin +10 -delete 2>/dev/null
  return 0
}

init_env() {
  local ip=${VPSPANEL_IP:-}
  if [[ -z $ip ]]; then
    ip=$(curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
    [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] || ip=$(curl -4fsS --max-time 4 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]')
    [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  IP=$ip
  OS_NAME=$(grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2)
  OS_NAME=${OS_NAME:-Linux}
  OS_NAME=${OS_NAME% \(*}; OS_NAME=${OS_NAME/GNU\/Linux /}   # "Debian GNU/Linux 12 (bookworm)" -> "Debian 12"
  OS_NAME=${OS_NAME% LTS}                                  # "Ubuntu 20.04.6 LTS" -> "Ubuntu 20.04.6"
}

preflight() {
  [[ $EUID -eq 0 ]] || { echo "Ejecuta como root."; exit 1; }
  command -v systemctl >/dev/null 2>&1 || { echo "Se requiere systemd."; exit 1; }
}

vps_name() { cat "$NAME_F" 2>/dev/null; }

# Vista del panel: el nombre, los datos del servidor y la lista de servicios se pueden ocultar.
is_hidden()   { grep -qx "$1" "$HIDE_F" 2>/dev/null; }            # name | server | services
toggle_hide() { if is_hidden "$1"; then sed -i "/^$1\$/d" "$HIDE_F"; else echo "$1" >> "$HIDE_F"; fi; }
is_shown()    { ! is_hidden "$1"; }                                # lo contrario de is_hidden

# ------------------------------ Registro de errores --------------------
# Cada operacion (instalar, reparar, aplicar) escribe en $LOG_DIR/<clave>.log todo lo que
# hacen sus comandos. Si algo falla se muestra en pantalla el final de esa salida o el
# journal del servicio: el error real, no un mensaje generico.
LOG=$LOG_DIR/panel.log

log_use() {   # clave [titulo]  ->  lo que sigue se registra en $LOG_DIR/<clave>.log
  mkdir -p "$LOG_DIR" 2>/dev/null
  LOG=$LOG_DIR/$1.log
  if [[ -f $LOG ]] && (( $(stat -c %s "$LOG" 2>/dev/null || echo 0) > 524288 )); then
    mv -f "$LOG" "$LOG.1"                                      # rota a partir de 512 KB
  fi
  printf '\n===== %s  %s =====\n' "$(date '+%F %T')" "${2:-$1}" >> "$LOG"
}

logln() { printf '%s\n' "$*" >> "$LOG" 2>/dev/null; return 0; }

gray_lines() {   # [max]  ->  muestra lo que llega por la entrada, sin colores ni retornos de carro
  local n=${1:-18} l
  sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/.*\r//' | grep -v '^[[:space:]]*$' | tail -n "$n" |
    while IFS= read -r l; do printf '   %s%s%s\n' "$GRY" "${l:0:180}" "$RST"; done
}

show_tail() {   # archivo [desde_linea] [lineas]  ->  final de un registro en pantalla
  local f=$1 from=${2:-1} n=${3:-18}
  [[ -s $f ]] || return 0
  line_dash
  tail -n +"$from" "$f" | gray_lines "$n"
  printf ' %sRegistro completo: %s%s\n' "$GRY" "$f" "$RST"
  line_dash
}

run() {   # mensaje comando [args...]  ->  ejecuta con la animacion; la salida va al registro.
          # Si falla, muestra las ultimas lineas de esa salida (el error real).
  local text=$1 rc from; shift
  from=$(( $(wc -l < "$LOG" 2>/dev/null || echo 0) + 1 ))
  printf '$ %s\n' "$*" >> "$LOG"
  SPIN_LOG=$LOG spin "$text" "$@"
  rc=$?
  if (( rc != 0 )); then
    printf '[codigo de salida %d]\n' "$rc" >> "$LOG"
    if [[ ${RUN_QUIET:-0} != 1 ]]; then
      err "$text: fallo (codigo $rc). Salida del comando:"
      show_tail "$LOG" "$from"
    fi
  fi
  return $rc
}

# ------------------------------ apt -----------------------------------
# En un VPS recien creado, cloud-init y las actualizaciones automaticas ocupan apt varios
# minutos: sin esperar, todas las instalaciones fallan y la lista de paquetes queda vacia.
apt_busy() {   # 0 si apt/dpkg estan ocupados por otro proceso
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PYEOF' 2>/dev/null
import fcntl, os, sys
for p in ("/var/lib/dpkg/lock-frontend", "/var/lib/dpkg/lock",
          "/var/lib/apt/lists/lock", "/var/cache/apt/archives/lock"):
    try:
        fd = os.open(p, os.O_RDWR)
    except OSError:
        continue
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.lockf(fd, fcntl.LOCK_UN)
    except OSError:
        sys.exit(0)
    finally:
        os.close(fd)
sys.exit(1)
PYEOF
    return
  fi
  pgrep -x 'apt|apt-get|aptitude|dpkg' >/dev/null 2>&1 || pgrep -f '/usr/bin/unattended-upgrade( |$)' >/dev/null 2>&1
}

apt_who() { ps -eo pid=,args= 2>/dev/null | grep -E '[a]pt-get|[a]pt |[d]pkg|[u]nattended-upgrade |[c]loud-init' | head -3 | cut -c1-70 | paste -sd';' -; }

apt_wait_loop() { local t=0; while apt_busy; do sleep 2; t=$(( t + 2 )); (( t >= ${APT_WAIT:-1200} )) && return 1; done; return 0; }

apt_wait() {   # espera a que apt quede libre (hasta APT_WAIT segundos, 20 minutos por defecto)
  apt_busy || return 0
  warn "apt esta ocupado (actualizaciones automaticas; normal en un VPS nuevo)."
  logln "apt ocupado por: $(apt_who)"
  if ! spin "Esperando a que termine (puede tardar varios minutos)" apt_wait_loop; then
    err "apt sigue ocupado despues de $(( ${APT_WAIT:-1200} / 60 )) minutos: $(apt_who)"
    return 1
  fi
  ok "apt quedo libre"
}

apt_update() {   # actualiza la lista de paquetes (3 intentos); una vez por sesion del panel
  local i from bad
  for i in 1 2 3; do
    apt_wait || return 1
    from=$(( $(wc -l < "$LOG" 2>/dev/null || echo 0) + 1 ))
    if RUN_QUIET=$(( i < 3 )) run "Actualizando lista de paquetes" \
         apt-get update -o Acquire::Retries=3 -o DPkg::Lock::Timeout=300; then
      APT_FRESH=1
      # apt termina bien aunque fallen algunos repositorios: se avisa cuales (si falta un
      # paquete despues, la causa suele estar aqui)
      bad=$(tail -n +"$from" "$LOG" | grep -E '^(Err:|W: Failed to fetch|W: Some index files)' | head -4)
      if [[ -n $bad ]]; then
        warn "Algunos repositorios de apt fallaron (se continua con los demas):"
        printf '%s\n' "$bad" | gray_lines 4
      fi
      return 0
    fi
    (( i < 3 )) && { warn "No se pudo actualizar la lista de paquetes. Reintento $(( i + 1 ))/3..."; sleep 5; }
  done
  err "No se pudo actualizar la lista de paquetes: revisa la conexion y /etc/apt/sources.list."
  return 1
}

apt_i() {   # paquetes...  ->  instala esperando a apt, con reintento y el error real en pantalla
  local -a o=(-y -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef
              -o Dpkg::Options::=--force-confold --no-install-recommends)
  [[ -n ${FORCE:-} ]] && o+=(--reinstall)
  apt_wait || return 1
  [[ -n ${APT_FRESH:-} ]] || apt_update || return 1
  RUN_QUIET=1 run "Instalando $*" apt-get install "${o[@]}" "$@" && return 0
  warn "La instalacion de $* fallo; se repara dpkg y se reintenta..."
  RUN_QUIET=1 run "Reparando dpkg" dpkg --configure -a
  apt_update || return 1
  run "Reintentando: $*" apt-get install "${o[@]}" "$@"
}

# ----------------------- Funciones base -------------------------------
svc_unit() {   # clave -> unidad de systemd real
  case $1 in
    openvpn) if [[ -f $OVPN_DIR/server.conf || ! -f /etc/openvpn/server.conf ]]; then
               echo openvpn-server@server; else echo openvpn@server; fi ;;     # @server: instalacion antigua
    *) echo "${SVC[$1]}" ;;
  esac
}

is_on() { systemctl is-active --quiet "$(svc_unit "$1")"; }

get_host() { local d; d=$(cat "$DOMAIN_F" 2>/dev/null); echo "${d:-$IP}"; }

valid_name() { [[ $1 =~ ^[a-z_][a-z0-9_-]{2,30}$ ]]; }

port_busy() { ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .; }

listening() {   # puerto [tcp|udp] -> 0 si algo escucha en ese puerto
  if [[ ${2:-tcp} == udp ]]; then ss -H -lun "sport = :$1" 2>/dev/null | grep -q .
  else ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .; fi
}

port_owner() {   # puerto [tcp|udp] -> programa que lo usa
  local f=-ltnp; [[ ${2:-tcp} == udp ]] && f=-lunp
  ss -H "$f" "sport = :$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1
}

need_port() { # clave puerto [tcp|udp]
  local p=$2 pr=${3:-tcp} who
  is_on "$1" && return 0
  if listening "$p" "$pr"; then
    who=$(port_owner "$p" "$pr")
    err "El puerto $p/$pr ya esta en uso por: ${who:-otro programa}"
    info "Cambia el puerto de ${1^^} (CAMBIAR PUERTO) o deten ese programa."
    return 1
  fi
}

ovpn_conf_file() { if [[ -f $OVPN_DIR/server.conf ]]; then echo "$OVPN_DIR/server.conf"
                   elif [[ -f /etc/openvpn/server.conf ]]; then echo /etc/openvpn/server.conf; fi; }
ovpn_port()  { local f p=''; f=$(ovpn_conf_file); [[ -n $f ]] && p=$(awk '$1=="port"{print $2; exit}' "$f"); echo "${p:-$PORT_OVPN}"; }
ovpn_proto() { local f p=''; f=$(ovpn_conf_file); [[ -n $f ]] && p=$(awk '$1=="proto"{print $2; exit}' "$f")
               case ${p:-tcp} in udp*) echo udp ;; *) echo tcp ;; esac; }
wg_port()    { local p; p=$(awk -F' *= *' '$1=="ListenPort"{print $2; exit}' "$WG_CONF" 2>/dev/null); echo "${p:-$PORT_WG}"; }

# ------------------------------ Firewall ------------------------------
# El panel abre en el firewall del sistema los puertos de todo lo instalado: ufw y firewalld
# (si estan activos) y siempre iptables/ip6tables (reglas marcadas "vpspanel" al principio de
# INPUT). Muchos VPS nuevos (Oracle Cloud, etc.) rechazan todo menos el 22 con iptables: sin
# esto los servicios quedan "activos" pero nadie puede conectarse. El servicio vps-firewall
# vuelve a aplicar las reglas en cada arranque.
fw_ports_of() {   # clave -> lineas puerto/proto que deben quedar abiertas
  case $1 in
    dropbear) echo "$PORT_DROPBEAR/tcp" ;;
    ssl)      echo "$PORT_SSL/tcp" ;;
    ws)       echo "$PORT_WS/tcp" ;;
    socks)    echo "$PORT_SOCKS/tcp" ;;
    wsepro)   echo "$PORT_WSEPRO/tcp" ;;
    squid)    echo "$PORT_SQUID/tcp" ;;
    v2ray)    echo "$PORT_V2RAY/tcp" ;;
    udp)      echo "$PORT_UDP/udp" ;;
    slowdns)  printf '53/udp\n%s/udp\n' "$PORT_SLOWDNS" ;;
    openvpn)  echo "$(ovpn_port)/$(ovpn_proto)" ;;
    wireguard) echo "$(wg_port)/udp" ;;
    psiphon)  printf '%s/tcp\n%s/tcp\n' "$PORT_PSIPHON" "$(( PORT_PSIPHON + 1 ))" ;;
  esac
}

fw_sync() {   # recalcula los puertos abiertos segun lo instalado y los aplica
  local k
  [[ -x /usr/local/bin/vps-fw ]] || return 0
  {
    echo "$SSH_PORT/tcp"
    for k in "${PROTO_KEYS[@]}"; do proto_installed "$k" && fw_ports_of "$k"; done
  } | awk 'NF && !s[$0]++' > "$BASE/fw.ports"
  {
    proto_installed openvpn && echo "$OVPN_NET"
    proto_installed wireguard && echo "$WG_NET.0/24"
  } > "$BASE/fw.nat"
  /usr/local/bin/vps-fw apply >> "$LOG" 2>&1
  systemctl enable vps-firewall >/dev/null 2>&1
  return 0
}

fw_rule() {   # puerto proto -> 0 si iptables tiene la regla del panel que lo abre
  iptables -w -S INPUT 2>/dev/null | grep -q -- "-p $2 -m $2 --dport $1 .*--comment vpspanel"
}

# ------------------------------ Verificacion --------------------------
probe() { python3 /usr/local/bin/vps-probe "$@" 2>&1; }

check_proto() {   # clave -> prueba real del protocolo; imprime el detalle o el motivo del fallo
  local k=$1 p pr=tcp out rc
  p=$(svc_port "$k")
  case $k in udp|slowdns|wireguard) pr=udp ;; openvpn) pr=$(ovpn_proto) ;; esac
  if ! listening "$p" "$pr"; then echo "nada escucha en el puerto $p/$pr"; return 1; fi
  case $k in
    dropbear)  out=$(probe banner "$p") ;;
    ws|wsepro) out=$(probe ws "$p") ;;
    socks)     out=$(probe ws "$p") && out=$(probe socks5 "$p" "127.0.0.1:$SSH_PORT") ;;
    ssl)       out=$(probe tls "$p") ;;
    squid)     out=$(probe connect "$p" "127.0.0.1:$SSH_PORT") ;;
    v2ray)     out=$(probe v2ws "$p" "$V2PATH") ;;
    badvpn)    out=$(probe udpgw "$p") ;;
    slowdns)   out=$(probe dns "$p" "$(cat "$BASE/slowdns/ns" 2>/dev/null)") ;;
    openvpn)   out=$(probe ovpn "$p" "$pr") ;;
    wireguard) out=$(wg show wg0 listen-port 2>&1) && out="interfaz wg0 activa" ;;
    psiphon)   out=$(probe tcp "$p") && out=$(probe http $(( p + 1 ))) && out="OSSH $p y MEEK $(( p + 1 )) responden" ;;
    *)         out="escuchando" ;;
  esac
  rc=$?
  if (( rc == 0 )) && [[ $k == slowdns ]] && ! iptables -w -t nat -S PREROUTING 2>/dev/null | grep -q -- "--dport 53 .*--to-ports $p"; then
    out="falta la redireccion del puerto 53/udp al $p"; rc=1
  fi
  if (( rc == 0 )); then echo "puerto $p/$pr, $out"; else echo "$out"; fi
  return $rc
}

svc_report() {   # clave -> estado real del servicio, quien ocupa su puerto y su journal
  local k=$1 u pp o n
  local -a units=("$(svc_unit "$k")")
  [[ $k == ssl ]] && units+=(vps-sslws)
  line_dash
  for u in "${units[@]}"; do
    n=14; [[ $u == vps-sslws ]] && n=4
    printf ' %sSERVICIO:%s %s%s%s (%s, reinicios: %s)\n' "$BLU" "$RST" "$WHT" "$u" "$RST" \
      "$(systemctl show -p ActiveState,SubState --value "$u" 2>/dev/null | paste -sd/ -)" \
      "$(systemctl show -p NRestarts --value "$u" 2>/dev/null)"
    printf ' %sULTIMOS MENSAJES (journalctl -u %s):%s\n' "$BLU" "$u" "$RST"
    if journalctl -u "$u" -n 1 --no-pager -o cat 2>/dev/null | grep -q .; then
      journalctl -u "$u" -n "$n" --no-pager -o cat 2>/dev/null | gray_lines "$n"
    else
      printf '   %s(sin mensajes)%s\n' "$GRY" "$RST"
    fi
    { echo "--- systemctl status $u"; systemctl status "$u" --no-pager -l -n 40 2>&1; } >> "$LOG"
  done
  while IFS= read -r pp; do
    [[ -n $pp ]] || continue
    o=$(port_owner "${pp%/*}" "${pp#*/}")
    [[ -n $o ]] && printf ' %sPUERTO %s:%s en uso por %s\n' "$BLU" "$pp" "$RST" "$o"
  done < <(fw_ports_of "$k")
  printf ' %sRegistro completo: %s%s\n' "$GRY" "$LOG" "$RST"
  line_dash
}

verify() { # clave nombre  ->  espera a que quede activo, escuchando y respondiendo de verdad
  local k=$1 nm=${2:-$1} unit st why='' i max=${VERIFY_WAIT:-20} r0 r1
  if [[ -n ${NOSTART:-} ]]; then info "$nm: configuracion actualizada (servicio detenido)"; return 0; fi
  unit=$(svc_unit "$k")
  r0=$(systemctl show -p NRestarts --value "$unit" 2>/dev/null)
  for (( i = 0; i < max; i++ )); do
    sleep 1
    st=$(systemctl show -p ActiveState --value "$unit" 2>/dev/null)
    case $st in
      active)
        if why=$(check_proto "$k"); then
          ok "$nm activo y respondiendo ($why)"
          logln "verificado: $nm -> $why"
          return 0
        fi ;;
      failed) why="el servicio fallo al iniciar"; break ;;
      *) why="el servicio no termina de iniciar (estado: ${st:-desconocido})" ;;
    esac
  done
  r1=$(systemctl show -p NRestarts --value "$unit" 2>/dev/null)
  if [[ ${r0:-0} =~ ^[0-9]+$ && ${r1:-0} =~ ^[0-9]+$ ]] && (( ${r1:-0} > ${r0:-0} )); then
    why="el servicio se cierra solo al iniciar (systemd lo reinicio $(( r1 - r0 )) veces)"
  fi
  logln "FALLO: $nm -> $why"
  err "$nm no funciona: $why"
  svc_report "$k"
  return 1
}

# ------------------------------ systemd -------------------------------
svc_restart() {   # unidad -> la habilita y la reinicia (no hace nada con NOSTART)
  [[ -n ${NOSTART:-} ]] && return 0
  systemctl reset-failed "$1" >/dev/null 2>&1
  systemctl enable "$1" >> "$LOG" 2>&1
  systemctl restart "$1" >> "$LOG" 2>&1
  return 0
}

mkunit() { # nombre descripcion exec [directivas extra de [Service]] [directivas extra de [Unit]]
  local name=$1 desc=$2 exec=$3 extra=${4:-} uextra=${5:-}
  {
    echo "[Unit]"
    echo "Description=$desc"
    echo "After=network-online.target"
    echo "Wants=network-online.target"
    echo "StartLimitIntervalSec=0"
    [[ -n $uextra ]] && echo "$uextra"
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
  svc_restart "$name"
}

# ---- Bases de cuentas (users.db, v2ray.db, users.exp): escritura segura --------------
# Siempre con el candado de vps-cleanup (el panel y el cron nunca escriben a la vez) y en un
# archivo temporal que reemplaza al original de una sola vez: un corte (SSH caido, reinicio,
# disco lleno) nunca deja la base vacia ni a medias.
db_locked() {   # comando [args]  ->  lo ejecuta con el candado de las bases (en un subshell)
  ( flock -w 30 8 || { err "Cuentas ocupadas por otra operacion. Reintenta."; exit 1; }
    "$@" ) 8>"$DB_LOCK"
}

_db_filter() {   # archivo comando [args]  ->  el archivo pasa a ser la salida del comando (que lo lee)
  local f=$1 t; shift
  [[ -e $f ]] || install -m 600 /dev/null "$f" || return 1
  t=$(mktemp "${f%/*}/.tmp-XXXXXX") || return 1
  if "$@" < "$f" > "$t"; then
    chmod 600 "$t"
    sync "$t" 2>/dev/null
    mv -f "$t" "$f" && return 0
  fi
  rm -f "$t"
  return 1
}
db_filter() { db_locked _db_filter "$@"; }

_db_append() { printf '%s\n' "$2" >> "$1"; }
db_add() { db_locked _db_append "$1" "$2"; }   # archivo linea

db_set() { # usuario campo valor  (users.db)
  db_filter "$USERDB" env U="$1" F="$2" V="$3" awk -F'|' -v OFS='|' '$1==ENVIRON["U"]{$(ENVIRON["F"]+0)=ENVIRON["V"]}1'
}

px_out() {   # usuario [segundos]  ->  filtro de users.exp: quita al usuario y, con segundos, lo vuelve a poner
  awk -F'|' -v u="$1" '$1 != u'
  [[ -n ${2:-} ]] && printf '%s|%s\n' "$1" "$2"
  return 0
}
px_set() { db_filter "$PX_DB" px_out "$1" "$2"; }                                   # usuario segundos
px_del() { grep -q "^$1|" "$PX_DB" 2>/dev/null || return 0; db_filter "$PX_DB" px_out "$1"; }   # usuario

# Cuentas que el panel puede borrar o modificar: UID normal (1000-59999). Nunca root, nobody ni
# cuentas del sistema, aunque aparezcan en users.db (por ejemplo en una copia ajena).
panel_uid() { local i; i=$(id -u "$1" 2>/dev/null) || return 1; (( i >= 1000 && i < 60000 )); }
panel_acct() {   # usuario -> 0 si existe y es del estilo del panel (UID normal y sin shell)
  panel_uid "$1" || return 1
  [[ $(getent passwd "$1" | cut -d: -f7) =~ ^(/bin/false|/usr/bin/false|/usr/sbin/nologin|/sbin/nologin|/bin/nologin)$ ]]
}

acct_make() {   # usuario clave fecha [hash]  ->  crea la cuenta del sistema (o ajusta la existente)
  local u=$1 p=$2 e=$3 h=${4:-}
  if id "$u" >/dev/null 2>&1; then
    panel_acct "$u" || return 2                                   # existe y no es del panel: no se toca
    usermod -e "$e" "$u" >/dev/null 2>&1
  else
    useradd -M -s /bin/false -e "$e" "$u" 2>/dev/null || return 1
  fi
  # con el hash guardado la contrasena queda identica (aunque se haya cambiado fuera del panel)
  if [[ -n $h ]] && printf '%s:%s\n' "$u" "$h" | chpasswd -e 2>/dev/null; then return 0; fi
  printf '%s:%s\n' "$u" "$p" | chpasswd 2>/dev/null
}

# ------------------------------ Herramientas internas -----------------
install_tools() {   # motor de proxy (WebSocket/SOCKS/SSL) y pruebas de conexion
  cat > /usr/local/bin/vps-proxy.py <<'PYEOF'
#!/usr/bin/env python3
"""vps-proxy: proxy de VPS PANEL para apps de tunel (HTTP Custom y similares).

Acepta en el mismo puerto:
  - SSH directo (el cliente habla primero o espera el banner del servidor)
  - payload HTTP / WebSocket ("GET / HTTP/1.1 ... Upgrade: websocket"), incluso varios
    seguidos ([split]) o con el banner SSH en el mismo envio
  - CONNECT host:puerto (responde 200)
  - SOCKS5 sin autenticacion (con --socks)
y reenvia todo a un puerto local (SSH o Dropbear). Solo se llega a puertos de este VPS que
esten permitidos: no es un proxy abierto.

Uso: vps-proxy.py -l ESCUCHA -t DESTINO [-a PUERTOS] [-s 101|200] [--self IPS] [--socks]
  -l   puerto (todas las interfaces, IPv4 e IPv6), IP:puerto o unix:/ruta/socket
  -t   puerto local por defecto (127.0.0.1)
  -a   otros puertos locales permitidos, separados por comas (CONNECT, X-Real-Host, SOCKS5)
  -s   respuesta a payloads sin Upgrade ni CONNECT: 101 (WebSocket) o 200
  --self  IPs propias del VPS separadas por comas (CONNECT a la IP publica = local)
"""
import argparse
import asyncio
import base64
import hashlib
import os
import socket
import struct
import sys

BUF = 65536
FIRST_WAIT = 3.0      # cliente SSH que espera el banner del servidor
NEXT_WAIT = 1.0       # despues de responder un payload, espera mas datos
HEAD_WAIT = 10.0      # tiempo maximo para completar una cabecera HTTP
MAX_ROUNDS = 8        # payloads seguidos que se aceptan en una conexion
MAX_HEAD = 65536
GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
METHODS = (b"GET", b"POST", b"PUT", b"HEAD", b"CONNECT", b"OPTIONS", b"PATCH", b"DELETE",
           b"TRACE", b"PROPFIND", b"MOVE", b"COPY", b"LOCK", b"UNLOCK", b"MKCOL", b"ACL")

DEFAULT = 22
ALLOWED = set()
STATUS = 101
SOCKS = False
SELF = {"127.0.0.1", "localhost", "::1", "0.0.0.0", "::", "ip6-localhost"}


def log(msg):
    sys.stderr.write("vps-proxy: %s\n" % msg)
    sys.stderr.flush()


def local_target(host, port):
    """(127.0.0.1, puerto) si host es este VPS y el puerto esta permitido; si no, None."""
    host = host.strip().strip("[]").lower()
    if host in SELF and (port == DEFAULT or port in ALLOWED):
        return ("127.0.0.1", port)
    return None


def split_hostport(value):
    value = value.strip()
    if value.startswith("["):                         # [IPv6]:puerto
        h, _, rest = value[1:].partition("]")
        p = rest[1:] if rest.startswith(":") else ""
    else:
        h, sep, p = value.rpartition(":")
        if not sep or ":" in h:                       # sin puerto o IPv6 sin corchetes
            h, p = value, ""
    try:
        return h, int(p) if p else None
    except ValueError:
        return h, None


def is_http(data):
    head = data.lstrip(b"\r\n")[:16]
    return any(head.startswith(m + b" ") for m in METHODS)


def pick_target(head, current):
    """Destino segun CONNECT o la cabecera X-Real-Host (solo puertos locales permitidos)."""
    lines = head.split(b"\r\n")
    first = lines[0].split()
    if len(first) >= 2 and first[0].upper() == b"CONNECT":
        h, p = split_hostport(first[1].decode("latin1"))
        if p is not None:
            t = local_target(h, p)
            if t:
                return t
    for line in lines[1:]:
        if line.lower().startswith(b"x-real-host:"):
            h, p = split_hostport(line.split(b":", 1)[1].decode("latin1"))
            if p is not None:
                t = local_target(h, p)
                if t:
                    return t
            break
    return current


def make_response(head):
    lines = head.split(b"\r\n")
    first = lines[0].split()
    if first and first[0].upper() == b"CONNECT":
        return b"HTTP/1.1 200 Connection established\r\n\r\n"
    hdr = {}
    for line in lines[1:]:
        k, sep, v = line.partition(b":")
        if sep:
            hdr[k.strip().lower()] = v.strip()
    if b"upgrade" in hdr or STATUS == 101:
        r = (b"HTTP/1.1 101 Switching Protocols\r\n"
             b"Upgrade: websocket\r\n"
             b"Connection: Upgrade\r\n")
        key = hdr.get(b"sec-websocket-key")
        if key:
            acc = base64.b64encode(hashlib.sha1(key + GUID).digest())
            r += b"Sec-WebSocket-Accept: " + acc + b"\r\n"
        return r + b"\r\n"
    return b"HTTP/1.1 200 Connection established\r\n\r\n"


def tune(writer):
    sock = writer.get_extra_info("socket")
    if sock is None or sock.family == getattr(socket, "AF_UNIX", -1):
        return
    for lvl, opt in ((socket.IPPROTO_TCP, socket.TCP_NODELAY), (socket.SOL_SOCKET, socket.SO_KEEPALIVE)):
        try:
            sock.setsockopt(lvl, opt, 1)
        except OSError:
            pass


async def read_some(reader, timeout):
    """Lee lo que llegue; None si se agota el tiempo, b'' si el cliente cerro."""
    try:
        return await asyncio.wait_for(reader.read(BUF), timeout)
    except asyncio.TimeoutError:
        return None


async def read_exact(reader, buf, n):
    while len(buf) < n:
        more = await read_some(reader, HEAD_WAIT)
        if not more:
            raise ConnectionError("cerrado")
        buf += more
    return buf


async def socks5(reader, writer, buf):
    """Negocia SOCKS5 (sin autenticacion). Devuelve (destino, sobrante) o None."""
    buf = await read_exact(reader, buf, 2)
    buf = await read_exact(reader, buf, 2 + buf[1])
    methods, buf = buf[2:2 + buf[1]], buf[2 + buf[1]:]
    if 0 not in methods:
        writer.write(b"\x05\xff")
        await writer.drain()
        return None
    writer.write(b"\x05\x00")
    await writer.drain()
    buf = await read_exact(reader, buf, 4)
    cmd, atyp = buf[1], buf[3]
    if atyp == 1:
        buf = await read_exact(reader, buf, 10)
        host, rest = socket.inet_ntoa(buf[4:8]), buf[8:]
    elif atyp == 3:
        buf = await read_exact(reader, buf, 5)
        n = buf[4]
        buf = await read_exact(reader, buf, 5 + n + 2)
        host, rest = buf[5:5 + n].decode("latin1"), buf[5 + n:]
    elif atyp == 4:
        buf = await read_exact(reader, buf, 22)
        host, rest = socket.inet_ntop(socket.AF_INET6, buf[4:20]), buf[20:]
    else:
        writer.write(b"\x05\x08\x00\x01\x00\x00\x00\x00\x00\x00")
        await writer.drain()
        return None
    port = struct.unpack(">H", rest[:2])[0]
    rest = rest[2:]
    target = local_target(host, port) if cmd == 1 else None
    if target is None:
        code = 0x07 if cmd != 1 else 0x02            # comando no soportado / no permitido
        writer.write(bytes([5, code, 0, 1, 0, 0, 0, 0, 0, 0]))
        await writer.drain()
        return None
    writer.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
    await writer.drain()
    return target, rest


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(BUF)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(reader, writer):
    tune(writer)
    remote = None
    target = ("127.0.0.1", DEFAULT)
    try:
        buf = await read_some(reader, FIRST_WAIT)
        if buf == b"":
            return
        buf = buf or b""                              # None: SSH directo, el servidor habla primero

        if buf[:1] == b"\x05" and SOCKS:
            res = await socks5(reader, writer, buf)
            if res is None:
                return
            target, buf = res
        else:
            rounds = 0
            while buf and is_http(buf) and rounds < MAX_ROUNDS:
                buf = buf.lstrip(b"\r\n")
                while b"\r\n\r\n" not in buf:         # cabecera incompleta ([split])
                    more = await read_some(reader, HEAD_WAIT)
                    if not more or len(buf) > MAX_HEAD:
                        return
                    buf += more
                head, _, buf = buf.partition(b"\r\n\r\n")
                target = pick_target(head, target)
                writer.write(make_response(head))
                await writer.drain()
                rounds += 1
                buf = buf.lstrip(b"\r\n")
                if not buf:                           # espera el siguiente payload o el banner SSH
                    more = await read_some(reader, NEXT_WAIT)
                    if more == b"":
                        return
                    buf = more or b""
            if buf and not buf.startswith(b"SSH-") and is_http(buf):
                return                                # demasiados payloads

        r_reader, remote = await asyncio.open_connection(*target)
        tune(remote)
        if buf:
            remote.write(buf)
            await remote.drain()
        await asyncio.gather(pipe(reader, remote), pipe(r_reader, writer))
    except Exception:
        pass
    finally:
        for w in (writer, remote):
            if w is not None:
                try:
                    w.close()
                except Exception:
                    pass


async def serve(listen):
    servers = []
    if listen.startswith("unix:"):
        path = listen[5:]
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        servers.append(await asyncio.start_unix_server(handle, path=path))
        os.chmod(path, 0o660)
    else:
        host, port = split_hostport(listen) if ":" in listen else ("", int(listen))
        if host:
            fam = socket.AF_INET6 if ":" in host else socket.AF_INET
            addrs = [(fam, host)]
        else:
            addrs = [(socket.AF_INET, "0.0.0.0"), (socket.AF_INET6, "::")]
        for fam, h in addrs:
            try:
                s = socket.socket(fam, socket.SOCK_STREAM)
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                if fam == socket.AF_INET6:
                    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                s.bind((h, port))
                s.listen(1024)
                s.setblocking(False)
            except OSError as e:
                if fam == socket.AF_INET6 and not host:
                    continue                          # sin IPv6: solo IPv4
                log("no se pudo escuchar en %s:%s: %s" % (h, port, e))
                sys.exit(1)
            servers.append(await asyncio.start_server(handle, sock=s))
    log("escuchando en %s -> 127.0.0.1:%d (permitidos: %s)"
        % (listen, DEFAULT, ",".join(str(p) for p in sorted(ALLOWED)) or "-"))
    await asyncio.gather(*(srv.serve_forever() for srv in servers))


def main():
    global DEFAULT, ALLOWED, STATUS, SOCKS
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("-l", "--listen", required=True)
    ap.add_argument("-t", "--target", type=int, required=True)
    ap.add_argument("-a", "--allow", default="")
    ap.add_argument("-s", "--status", type=int, choices=(101, 200), default=101)
    ap.add_argument("--self", dest="selfips", default="")
    ap.add_argument("--socks", action="store_true")
    a = ap.parse_args()
    DEFAULT = a.target
    ALLOWED = {int(p) for p in a.allow.split(",") if p.strip().isdigit()}
    STATUS = a.status
    SOCKS = a.socks
    SELF.update(x.strip().lower() for x in a.selfips.split(",") if x.strip())
    SELF.add(socket.gethostname().lower())
    try:
        asyncio.run(serve(a.listen))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
PYEOF
  cat > /usr/local/bin/vps-probe <<'PYEOF'
#!/usr/bin/env python3
"""vps-probe: pruebas de conexion reales de los protocolos de VPS PANEL (uso interno).

  vps-probe banner  PUERTO            SSH directo (Dropbear/OpenSSH): banner SSH
  vps-probe ws      PUERTO            payload WebSocket -> 101/200 -> banner SSH
  vps-probe tls     PUERTO            TLS -> banner SSH, y TLS + payload -> 101 -> banner SSH
  vps-probe connect PUERTO DESTINO    CONNECT DESTINO -> 200 -> banner SSH
  vps-probe socks5  PUERTO DESTINO    SOCKS5 -> banner SSH
  vps-probe v2ws    PUERTO PATH       handshake WebSocket de V2Ray -> 101
  vps-probe udpgw   PUERTO            BadVPN: datagrama de ida y vuelta por udpgw
  vps-probe dns     PUERTO DOMINIO    SlowDNS: consulta DNS -> respuesta
  vps-probe ovpn    PUERTO tcp|udp    OpenVPN: reinicio de control -> respuesta del servidor
  vps-probe http    PUERTO            responde HTTP
  vps-probe tcp     PUERTO            acepta conexiones TCP
Opcion: --host IP (por defecto 127.0.0.1). Sale con 0 si pasa; si no, imprime el motivo.
"""
import base64
import os
import random
import socket
import ssl
import struct
import sys

TIMEOUT = 8
HOST = "127.0.0.1"
IDENT = b"SSH-2.0-vpspanel_probe\r\n"


class Fail(Exception):
    pass


def connect(port):
    try:
        return socket.create_connection((HOST, port), timeout=TIMEOUT)
    except ConnectionRefusedError:
        raise Fail("conexion rechazada en el puerto %d (nada escucha ahi)" % port)
    except socket.timeout:
        raise Fail("sin respuesta al conectar al puerto %d" % port)
    except OSError as e:
        raise Fail("no se pudo conectar al puerto %d: %s" % (port, e.strerror or e))


def recv_line(s, limit=512):
    buf = b""
    try:
        while not buf.endswith(b"\n") and len(buf) < limit:
            c = s.recv(1)
            if not c:
                break
            buf += c
    except socket.timeout:
        pass
    return buf


def recv_head(s):
    buf = b""
    try:
        while b"\r\n\r\n" not in buf and len(buf) < 16384:
            c = s.recv(1)
            if not c:
                break
            buf += c
    except socket.timeout:
        pass
    if not buf:
        raise Fail("el servidor cerro la conexion sin responder al payload")
    if b"\r\n\r\n" not in buf:
        raise Fail("respuesta incompleta al payload: %r" % buf[:80])
    return buf.split(b"\r\n", 1)[0].decode("latin1", "replace")


def ssh_banner(s, where):
    s.sendall(IDENT)
    line = recv_line(s)
    if not line:
        raise Fail("%s: no llego el banner SSH (el destino no responde)" % where)
    if not line.startswith(b"SSH-"):
        raise Fail("%s: respuesta que no es SSH: %r" % (where, line[:60]))
    return line.strip().decode("latin1", "replace")


def status_ok(line, codes=("101", "200")):
    parts = line.split()
    return len(parts) >= 2 and parts[1] in codes


PAYLOAD = (b"GET / HTTP/1.1\r\nHost: vpspanel.probe\r\nUpgrade: websocket\r\n"
           b"Connection: Upgrade\r\n\r\n")


def p_banner(port):
    s = connect(port)
    return ssh_banner(s, "puerto %d" % port)


def p_ws(port):
    s = connect(port)
    s.sendall(PAYLOAD)
    st = recv_head(s)
    if not status_ok(st):
        raise Fail("respuesta inesperada al payload: %s" % st)
    b = ssh_banner(s, "despues de %s" % st)
    return "%s -> %s" % (st, b)


def tls_wrap(s):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        return ctx.wrap_socket(s, server_hostname="vpspanel.probe")
    except ssl.SSLError as e:
        raise Fail("fallo el saludo TLS: %s" % e)
    except OSError as e:
        raise Fail("el servidor cerro la conexion durante el saludo TLS: %s" % e)


def tls_close(s):
    """cierre TLS ordenado (close_notify): evita errores "unexpected eof" en el log de stunnel"""
    try:
        s.settimeout(2)
        s.unwrap().close()
    except Exception:
        try:
            s.close()
        except Exception:
            pass


def p_tls(port):
    s = tls_wrap(connect(port))
    b = ssh_banner(s, "TLS directo")
    tls_close(s)
    s = tls_wrap(connect(port))
    s.sendall(PAYLOAD)
    st = recv_head(s)
    if not status_ok(st):
        raise Fail("TLS + payload: respuesta inesperada: %s" % st)
    ssh_banner(s, "TLS + payload")
    tls_close(s)
    return "%s, TLS + payload OK" % b


def p_connect(port, target):
    s = connect(port)
    s.sendall(("CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n" % (target, target)).encode())
    st = recv_head(s)
    if not status_ok(st, ("200",)):
        raise Fail("CONNECT %s rechazado: %s" % (target, st))
    b = ssh_banner(s, "CONNECT %s" % target)
    return "CONNECT %s -> %s" % (target, b)


def p_socks5(port, target):
    h, p = target.rsplit(":", 1)
    s = connect(port)
    s.sendall(b"\x05\x01\x00")
    r = s.recv(2)
    if r != b"\x05\x00":
        raise Fail("SOCKS5: metodo rechazado (%r)" % r)
    hb = h.encode()
    s.sendall(b"\x05\x01\x00\x03" + bytes([len(hb)]) + hb + struct.pack(">H", int(p)))
    r = s.recv(10)
    if len(r) < 2 or r[1] != 0:
        raise Fail("SOCKS5: CONNECT a %s rechazado (%r)" % (target, r[:2]))
    b = ssh_banner(s, "SOCKS5 %s" % target)
    return "SOCKS5 %s -> %s" % (target, b)


def p_v2ws(port, path):
    s = connect(port)
    key = base64.b64encode(os.urandom(16))
    s.sendall(b"GET " + path.encode() + b" HTTP/1.1\r\nHost: vpspanel.probe\r\nUpgrade: websocket\r\n"
              b"Connection: Upgrade\r\nSec-WebSocket-Key: " + key + b"\r\nSec-WebSocket-Version: 13\r\n\r\n")
    st = recv_head(s)
    if not status_ok(st, ("101",)):
        raise Fail("el path %s no acepta WebSocket: %s" % (path, st))
    return "WebSocket %s -> %s" % (path, st)


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise Fail("udpgw cerro la conexion")
        buf += c
    return buf


def p_udpgw(port):
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.bind(("127.0.0.1", 0))
    u.settimeout(TIMEOUT)
    uport = u.getsockname()[1]
    t = connect(port)
    data = b"vpspanel-udpgw-%d" % random.randint(1000, 9999)
    body = struct.pack("<BH", 0, 7) + socket.inet_aton("127.0.0.1") + struct.pack(">H", uport) + data
    t.sendall(struct.pack("<H", len(body)) + body)
    try:
        got, addr = u.recvfrom(2048)
    except socket.timeout:
        raise Fail("udpgw no reenvio el datagrama UDP")
    if got != data:
        raise Fail("udpgw reenvio datos distintos")
    u.sendto(b"eco:" + got, addr)
    try:
        n = struct.unpack("<H", recv_exact(t, 2))[0]
        pkt = recv_exact(t, n)
    except socket.timeout:
        raise Fail("udpgw no devolvio la respuesta UDP por TCP")
    if pkt[9:] != b"eco:" + data:
        raise Fail("respuesta udpgw inesperada")
    return "datagrama UDP de ida y vuelta OK"


def p_dns(port, domain):
    qid = random.randint(1, 65535)
    name = "p%d.%s" % (random.randint(10000, 99999), domain.strip("."))
    q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    for label in name.split("."):
        q += bytes([len(label)]) + label.encode()
    q += b"\x00" + struct.pack(">HH", 16, 1)
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.settimeout(TIMEOUT)
    u.sendto(q, (HOST, port))
    try:
        r, _ = u.recvfrom(4096)
    except socket.timeout:
        raise Fail("el servidor DNS del puerto %d no responde" % port)
    except ConnectionRefusedError:
        raise Fail("nada escucha en el puerto UDP %d" % port)
    if len(r) < 12 or struct.unpack(">H", r[:2])[0] != qid or not r[2] & 0x80:
        raise Fail("respuesta DNS invalida")
    return "responde consultas DNS"


def p_ovpn(port, proto="tcp"):
    pkt = bytes([7 << 3]) + os.urandom(8) + b"\x00" + b"\x00\x00\x00\x00"
    if proto == "udp":
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.settimeout(TIMEOUT)
        u.sendto(pkt, (HOST, port))
        try:
            r, _ = u.recvfrom(4096)
        except (socket.timeout, ConnectionRefusedError):
            raise Fail("OpenVPN UDP no responde en el puerto %d" % port)
    else:
        s = connect(port)
        s.sendall(struct.pack(">H", len(pkt)) + pkt)
        try:
            n = struct.unpack(">H", recv_exact(s, 2))[0]
            r = recv_exact(s, n)
        except socket.timeout:
            raise Fail("OpenVPN no respondio al inicio de sesion")
    if not r or (r[0] >> 3) not in (8, 10):
        raise Fail("respuesta que no es de OpenVPN")
    return "OpenVPN responde (%s)" % proto


def p_http(port):
    s = connect(port)
    s.sendall(b"GET / HTTP/1.1\r\nHost: vpspanel.probe\r\nConnection: close\r\n\r\n")
    line = recv_line(s)
    if not line.startswith(b"HTTP/1."):
        raise Fail("no responde HTTP: %r" % line[:60])
    return line.strip().decode("latin1", "replace")


def p_tcp(port):
    connect(port).close()
    return "acepta conexiones"


MODES = {"banner": p_banner, "ws": p_ws, "tls": p_tls, "connect": p_connect, "socks5": p_socks5,
         "v2ws": p_v2ws, "udpgw": p_udpgw, "dns": p_dns, "ovpn": p_ovpn, "http": p_http, "tcp": p_tcp}


def main():
    global HOST
    args = sys.argv[1:]
    if "--host" in args:
        i = args.index("--host")
        HOST = args[i + 1]
        del args[i:i + 2]
    if not args or args[0] not in MODES or len(args) < 2:
        print(__doc__)
        return 2
    try:
        msg = MODES[args[0]](int(args[1]), *args[2:])
    except Fail as e:
        print(e)
        return 1
    except Exception as e:                            # error inesperado: se muestra tal cual
        print("%s: %s" % (type(e).__name__, e))
        return 1
    print(msg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
  chmod 755 /usr/local/bin/vps-proxy.py /usr/local/bin/vps-probe
}

install_firewall() {   # vps-fw y el servicio que reaplica las reglas al arrancar
  cat > /usr/local/bin/vps-fw <<'EOF'
#!/bin/bash
# vps-fw: reglas de firewall de VPS PANEL
#   vps-fw apply            abre los puertos de /etc/vpspanel/fw.ports y el NAT de fw.nat
#   vps-fw clear            quita todas las reglas del panel
#   vps-fw udpclean PUERTO  quita las reglas que deja UDP Custom (no las borra al detenerse)
BASE=/etc/vpspanel
TAG=vpspanel

del_tagged() {   # iptables|ip6tables tabla cadena
  local r
  "$1" -w -t "$2" -S "$3" 2>/dev/null | grep -- "--comment $TAG" | sed 's/^-A /-D /' |
    while read -r r; do "$1" -w -t "$2" $r 2>/dev/null; done
}

clear_rules() {
  local ipt
  for ipt in iptables ip6tables; do
    command -v $ipt >/dev/null 2>&1 || continue
    del_tagged $ipt filter INPUT
    del_tagged $ipt filter FORWARD
    del_tagged $ipt nat POSTROUTING
  done
}

apply() {
  local ipt p pr sub dev
  clear_rules
  for ipt in iptables ip6tables; do
    command -v $ipt >/dev/null 2>&1 || continue
    $ipt -w -S INPUT >/dev/null 2>&1 || continue
    [[ -s $BASE/fw.ports ]] || continue
    while IFS=/ read -r p pr; do
      [[ $p =~ ^[0-9]+$ && $pr =~ ^(tcp|udp)$ ]] || continue
      $ipt -w -I INPUT -p "$pr" -m "$pr" --dport "$p" -m comment --comment $TAG -j ACCEPT 2>/dev/null \
        || $ipt -w -I INPUT -p "$pr" -m "$pr" --dport "$p" -j ACCEPT
    done < "$BASE/fw.ports"
  done
  if [[ -s $BASE/fw.nat ]] && command -v iptables >/dev/null 2>&1; then
    sysctl -qw net.ipv4.ip_forward=1
    dev=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
    while read -r sub; do
      [[ $sub =~ ^[0-9./]+$ ]] || continue
      iptables -w -t nat -A POSTROUTING -s "$sub" ${dev:+-o "$dev"} -m comment --comment $TAG -j MASQUERADE
      iptables -w -I FORWARD -s "$sub" -m comment --comment $TAG -j ACCEPT
      iptables -w -I FORWARD -d "$sub" -m state --state RELATED,ESTABLISHED -m comment --comment $TAG -j ACCEPT
    done < "$BASE/fw.nat"
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    while IFS=/ read -r p pr; do ufw allow "$p/$pr" >/dev/null 2>&1; done < "$BASE/fw.ports"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    while IFS=/ read -r p pr; do
      firewall-cmd -q --add-port="$p/$pr" 2>/dev/null; firewall-cmd -q --permanent --add-port="$p/$pr" 2>/dev/null
    done < "$BASE/fw.ports"
    if [[ -s $BASE/fw.nat ]]; then firewall-cmd -q --add-masquerade; firewall-cmd -q --permanent --add-masquerade; fi
  fi
  return 0
}

udpclean() {   # puerto
  local ipt r p=$1
  [[ $p =~ ^[0-9]+$ ]] || return 0
  for ipt in iptables ip6tables; do
    command -v $ipt >/dev/null 2>&1 || continue
    $ipt -w -t nat -S PREROUTING 2>/dev/null | grep -E -- "-p udp .*-j DNAT --to-destination :$p\$" |
      sed 's/^-A /-D /' | while read -r r; do $ipt -w -t nat $r 2>/dev/null; done
    $ipt -w -S INPUT 2>/dev/null | grep -E -- "^-A INPUT -p udp -m udp --dport $p -j ACCEPT\$" |
      sed 's/^-A /-D /' | while read -r r; do $ipt -w $r 2>/dev/null; done
  done
  return 0
}

case ${1:-} in
  apply)    apply ;;
  clear)    clear_rules ;;
  udpclean) udpclean "${2:-}" ;;
  *) echo "uso: vps-fw apply|clear|udpclean PUERTO"; exit 1 ;;
esac
EOF
  chmod 755 /usr/local/bin/vps-fw
  cat > /etc/systemd/system/vps-firewall.service <<'EOF'
[Unit]
Description=VPS Panel - puertos de los protocolos en el firewall
After=network-pre.target netfilter-persistent.service ufw.service firewalld.service nftables.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/vps-fw apply
ExecReload=/usr/local/bin/vps-fw apply

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable vps-firewall >/dev/null 2>&1
}

install_helpers() {
  cat > /usr/local/bin/vps-sessions <<'EOF'
#!/bin/bash
# Sesiones SSH y Dropbear activas, una por linea: "usuario pid segundos"
# OpenSSH: el proceso de cada sesion corre como el usuario.
ps -eo user=,pid=,etimes=,comm= 2>/dev/null |
  awk '($4=="sshd" || $4=="sshd-session") && $1!="root" && $1!="sshd" {print $1, $2, $3}'
# Dropbear: las sesiones de solo tunel siguen como root; el usuario sale del journal
# ("[PID] ... auth succeeded for 'usuario'"). Se toma la ultima linea de cada PID vivo.
journalctl -u vps-dropbear --since "-3 days" -o cat 2>/dev/null |
  sed -n "s/^\[\([0-9][0-9]*\)\] .*auth succeeded for '\([^']*\)'.*/\1 \2/p" |
  awk '{u[$1] = $2} END {for (p in u) print p, u[p]}' |
  while read -r pid u; do
    [[ $(cat "/proc/$pid/comm" 2>/dev/null) == dropbear ]] || continue
    echo "$u $pid $(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
  done
EOF
  cat > /usr/local/bin/vps-limiter <<'EOF'
#!/bin/bash
# Limita conexiones simultaneas por usuario (SSH/Dropbear): se quedan las mas antiguas
DB=/etc/vpspanel/users.db
[[ -s $DB ]] || exit 0
S=$(/usr/local/bin/vps-sessions)
while IFS='|' read -r u p e l; do
  [[ -n $u && ${l:-0} -gt 0 ]] || continue
  mapfile -t pids < <(awk -v u="$u" '$1==u {print $3" "$2}' <<< "$S" | sort -rn | awk '{print $2}')
  if (( ${#pids[@]} > l )); then
    kill -9 "${pids[@]:l}" 2>/dev/null
  fi
done < "$DB"
EOF

  cat > /usr/local/bin/vps-cleanup <<'EOF'
#!/bin/bash
# Elimina cuentas SSH y V2Ray vencidas. Una cuenta vence a las 00:00 UTC de su fecha (igual que
# en la tabla de cuentas del panel, donde ya sale en rojo). Las cuentas de prueba vencen a la hora
# exacta de users.exp (usuario|segundos): en ese momento pasan a ser cuentas vencidas normales.
#   vps-cleanup          a mano (ELIMINAR USUARIOS VENCIDOS)
#   vps-cleanup --auto   cada minuto desde cron. Con la eliminacion automatica desactivada
#                        (/etc/vpspanel/autodel.off) las vencidas quedan bloqueadas, sin borrarse.
# Nunca toca root ni cuentas del sistema (UID fuera de 1000-59999), aunque esten en users.db.
BASE=/etc/vpspanel
DB=$BASE/users.db
PX=$BASE/users.exp
V2DB=$BASE/v2ray.db
V2CFG=/usr/local/etc/v2ray/config.json
exec 9>"$BASE/cleanup.lock"
if [[ ${1:-} == --auto ]]; then flock -n 9 || exit 0; else flock -w 30 9; fi
today=$(date -u +%F)
now=$(date +%s)
vencida() { [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && ! $1 > $today ]]; }   # fecha <= hoy (UTC)
normal() { local i; i=$(id -u "$1" 2>/dev/null) || return 0; (( i >= 1000 && i < 60000 )); }   # no existe o UID normal
rewrite() {   # archivo comando [args]  ->  reemplazo atomico: la base nunca queda a medias
  local f=$1 t; shift
  t=$(mktemp "$BASE/.tmp-XXXXXX") || return 1
  if "$@" < "$f" > "$t"; then chmod 600 "$t"; mv -f "$t" "$f" && return 0; fi
  rm -f "$t"; return 1
}
# Cuentas de prueba que llegaron a su hora: fecha = hoy (vencida) y el sistema las bloquea
if [[ -s $PX ]]; then
  while IFS='|' read -r u t; do
    [[ $u =~ ^[a-z_][a-z0-9_-]*$ && $t =~ ^[0-9]+$ ]] && (( t <= now )) || continue
    if grep -q "^${u}|" "$DB" 2>/dev/null; then
      rewrite "$DB" awk -F'|' -v OFS='|' -v u="$u" -v d="$today" '$1 == u {$3 = d} 1'
      normal "$u" && usermod -e "$today" "$u" >/dev/null 2>&1
      logger -t vpspanel "cuenta de prueba vencida: $u"
    fi
    rewrite "$PX" awk -F'|' -v u="$u" '$1 != u'
  done < "$PX"
fi
[[ ${1:-} == --auto && -f $BASE/autodel.off ]] && exit 0
if [[ -s $DB ]]; then
  S=''
  while IFS='|' read -r u p e l; do
    [[ $u =~ ^[a-z_][a-z0-9_-]*$ ]] && vencida "$e" || continue
    if ! normal "$u"; then logger -t vpspanel "no se elimina $u: es una cuenta del sistema"; continue; fi
    usermod -L "$u" >/dev/null 2>&1                           # nadie mas entra con esa cuenta
    [[ -n $S ]] || S=$(/usr/local/bin/vps-sessions 2>/dev/null)
    pids=$(awk -v u="$u" '$1==u {print $2}' <<< "$S")        # SSH y Dropbear (Dropbear corre como root)
    [[ -n $pids ]] && kill -9 $pids 2>/dev/null
    pkill -KILL -u "$u" 2>/dev/null
    userdel -f "$u" 2>/dev/null
    if ! id "$u" >/dev/null 2>&1; then                       # si no se pudo, se reintenta al minuto
      rewrite "$DB" awk -F'|' -v u="$u" '$1 != u'
      [[ -s $PX ]] && rewrite "$PX" awk -F'|' -v u="$u" '$1 != u'
      logger -t vpspanel "cuenta SSH vencida eliminada: $u (vencia $e)"
    fi
  done < "$DB"
fi
if [[ -s $V2DB && -f $V2CFG ]]; then
  changed=0
  while IFS='|' read -r n id e; do
    [[ $n =~ ^[a-z_][a-z0-9_-]*$ ]] && vencida "$e" || continue
    t=$(mktemp)
    if jq --arg em "$n" '.inbounds[0].settings.clients |= map(select(.email != $em))' "$V2CFG" > "$t"; then
      cat "$t" > "$V2CFG"                                    # cat: conserva permisos (V2Ray corre como nobody)
      rewrite "$V2DB" awk -F'|' -v n="$n" '$1 != n'
      logger -t vpspanel "cuenta V2Ray vencida eliminada: $n (vencia $e)"
      changed=1
    fi
    rm -f "$t"
  done < "$V2DB"
  (( changed )) && systemctl restart v2ray
fi
exit 0
EOF
  chmod 755 /usr/local/bin/vps-sessions /usr/local/bin/vps-limiter /usr/local/bin/vps-cleanup

  cat > /etc/cron.d/vpspanel <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root /usr/local/bin/vps-limiter >/dev/null 2>&1
* * * * * root /usr/local/bin/vps-cleanup --auto >/dev/null 2>&1
41 3 * * * root [ -x /usr/local/bin/vpspanel ] && /usr/local/bin/vpspanel --backup auto >/dev/null 2>&1
EOF
  chmod 644 /etc/cron.d/vpspanel
  systemctl enable --now cron >/dev/null 2>&1
  install_tools
  install_firewall
  install_rollback
  echo "$HELPERS_V" > "$BASE/.helpers"
}

install_rollback() {   # vps-rollback: vuelve a la version anterior del panel (sirve aunque la nueva falle)
  cat > /usr/local/bin/vps-rollback <<'EOF'
#!/bin/bash
# vps-rollback: vuelve a una version anterior de VPS PANEL. Antes de cada actualizacion el panel
# guarda la version instalada en /var/backups/vpspanel/scripts. Usuarios y configuracion no cambian.
#   vps-rollback          instala la version guardada mas reciente que sea distinta de la actual
#   vps-rollback --list   muestra las versiones guardadas
D=/var/backups/vpspanel/scripts
T=/usr/local/bin/vpspanel
[[ $EUID -eq 0 ]] || { echo " Ejecuta como root."; exit 1; }
ver() { sed -n 's/^VERSION=\([0-9][0-9.]*\).*/\1/p' "$1" 2>/dev/null | head -1; }
mapfile -t L < <(ls -1t "$D"/vpspanel-*.sh 2>/dev/null)
if [[ ${1:-} == --list ]]; then
  (( ${#L[@]} )) || { echo " No hay versiones anteriores guardadas."; exit 0; }
  for f in "${L[@]}"; do
    m=''; cmp -s "$f" "$T" && m='  (la instalada)'
    printf ' %s  version %-6s %s%s\n' "$(date -r "$f" '+%d/%m/%Y %H:%M')" "$(ver "$f")" "${f##*/}" "$m"
  done
  exit 0
fi
for f in "${L[@]}"; do
  cmp -s "$f" "$T" && continue
  bash -n "$f" 2>/dev/null || continue                      # una copia danada no se instala
  if [[ -s $T ]]; then                                       # la actual tambien se guarda (para volver a ella)
    v=$(ver "$T"); c=$D/vpspanel-${v:-x}-$(sha256sum "$T" | cut -c1-12).sh
    if [[ -f $c ]]; then touch "$c"; else cp "$T" "$c.tmp" && chmod 600 "$c.tmp" && mv -f "$c.tmp" "$c"; fi
  fi
  if install -m 755 "$f" "$T.rollback" && mv -f "$T.rollback" "$T"; then
    touch "$f"
    echo " Panel restaurado a la version $(ver "$f") (${f##*/})."
    echo " Usuarios y configuracion no cambian. Abre el panel con: vpspanel"
    exit 0
  fi
  rm -f "$T.rollback"; echo " No se pudo instalar ${f##*/}"; exit 1
done
echo " No hay una version anterior guardada."
exit 1
EOF
  chmod 755 /usr/local/bin/vps-rollback
}

# Eliminacion automatica de cuentas vencidas: activada por defecto (se apaga con autodel.off)
autodel_on() { [[ ! -f $BASE/autodel.off ]]; }

toggle_autodel() {
  if autodel_on; then
    touch "$BASE/autodel.off"
    ok "Eliminacion automatica de usuarios vencidos DESACTIVADA"
    info "Las cuentas vencidas quedan bloqueadas pero no se borran (ELIMINAR USUARIOS VENCIDOS)."
  else
    rm -f "$BASE/autodel.off"
    ok "Eliminacion automatica de usuarios vencidos ACTIVADA"
    /usr/local/bin/vps-cleanup --auto 2>/dev/null && info "Se revisaron las cuentas: las vencidas ya se eliminaron."
  fi
}

helpers_update() {   # instalaciones anteriores o actualizadas: vps-cleanup, vps-rollback y el cron al dia
  [[ -f $BASE/.prep ]] || return 0
  [[ $(cat "$BASE/.helpers" 2>/dev/null) == "$HELPERS_V" ]] && return 0
  install_helpers >/dev/null 2>&1
  return 0
}

ssh_restart() { systemctl restart ssh >> "$LOG" 2>&1 || systemctl restart sshd >> "$LOG" 2>&1; }

# Compatibilidad con las apps de tunel: muchas usan librerias SSH antiguas (familia Ganymed/Trilead)
# que no conocen rsa-sha2-256/512. OpenSSH 8.8+ (Ubuntu 22.04, Debian 12...) ya no ofrece ssh-rsa:
# si el VPS solo tiene llave RSA (pasa en varias imagenes) la app falla con "Cannot negotiate,
# proposals do not match". Se crean las llaves que falten (ECDSA, ED25519) y se agregan con "+"
# ssh-rsa y el intercambio de claves SHA-1: las apps modernas siguen usando los algoritmos nuevos.
ssh_conf_others() {   # archivos de configuracion de sshd que no son del panel
  local c
  echo /etc/ssh/sshd_config
  for c in /etc/ssh/sshd_config.d/*.conf; do
    [[ -f $c && $c != */00-vpspanel.conf ]] && echo "$c"
  done
  return 0
}

ssh_hostkeys() {   # crea las llaves del servidor que falten; imprime HostKey si sshd no las cargaria solo
  local t f
  local -a cf
  mapfile -t cf < <(ssh_conf_others)
  for t in rsa ecdsa ed25519; do
    f=/etc/ssh/ssh_host_${t}_key
    if [[ ! -s $f ]]; then
      rm -f "$f" "$f.pub"
      ssh-keygen -q -t "$t" -N '' -f "$f" >> "$LOG" 2>&1 && logln "llave del servidor creada: $t"
    fi
  done
  # Con lineas HostKey en la configuracion no se usan las llaves por defecto: se agregan las que falten
  grep -qsE '^[[:space:]]*HostKey[[:space:]]' "${cf[@]}" || return 0
  for t in rsa ecdsa ed25519; do
    f=/etc/ssh/ssh_host_${t}_key
    [[ -s $f ]] || continue
    grep -qsE "^[[:space:]]*HostKey[[:space:]]+${f}[[:space:]]*\$" "${cf[@]}" || echo "HostKey $f"
  done
  return 0
}

ssh_legacy() {   # algoritmos extra con "+" (solo los que esta version de OpenSSH soporta)
  local q a
  local -a kex=()
  q=$(ssh -Q kex 2>/dev/null)
  for a in diffie-hellman-group14-sha1 diffie-hellman-group-exchange-sha1; do
    grep -qx "$a" <<< "$q" && kex+=("$a")
  done
  (( ${#kex[@]} )) && echo "KexAlgorithms +$(IFS=,; echo "${kex[*]}")"
  ssh -Q key 2>/dev/null | grep -qx ssh-rsa && echo "HostKeyAlgorithms +ssh-rsa"
  return 0
}

cfg_ssh() {
  local f=/etc/ssh/sshd_config.d/00-vpspanel.conf out hk lg
  mkdir -p /etc/ssh/sshd_config.d
  [[ -d /run/sshd ]] || install -d -m 0755 -o root -g root /run/sshd   # sshd -t la exige (root, 0755)
  grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d' /etc/ssh/sshd_config \
    || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  hk=$(ssh_hostkeys)
  lg=$(ssh_legacy)
  {
    echo "PasswordAuthentication yes"
    echo "AllowTcpForwarding yes"
    echo "PermitTunnel yes"
    echo "UseDNS no"
    echo "TCPKeepAlive yes"
    echo "ClientAliveInterval 30"
    echo "ClientAliveCountMax 3"
    echo "MaxSessions 100"
    echo "MaxStartups 100:30:200"
    echo "Banner $(banner_path)"
    echo "# Compatibilidad con apps de tunel (librerias SSH antiguas)"
    [[ -n $hk ]] && echo "$hk"
    [[ -n $lg ]] && echo "$lg"
  } > "$f"
  if ! out=$(sshd -t 2>&1); then
    printf '%s\n' "$out" >> "$LOG"
    if [[ -n $lg ]]; then                                   # se reintenta sin los algoritmos extra
      sed -i '/^KexAlgorithms +/d; /^HostKeyAlgorithms +/d' "$f"
      sshd -t >/dev/null 2>&1 && warn "sshd no acepto los algoritmos de compatibilidad; se omiten."
    fi
  fi
  if ! out=$(sshd -t 2>&1); then
    printf '%s\n' "$out" >> "$LOG"
    err "Configuracion SSH invalida; se revierte. Detalle:"
    printf '%s\n' "$out" | gray_lines 6
    rm -f "$f"
    return 1
  fi
  # Lo que sshd usa de verdad: una linea "PasswordAuthentication no" antes del Include ganaria
  if [[ $(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2; exit}') == no ]]; then
    sed -i -E 's/^[[:space:]]*(PasswordAuthentication[[:space:]]+no)/# \1   # desactivado por VPS PANEL/I' /etc/ssh/sshd_config
    logln "sshd_config: se comento PasswordAuthentication no"
  fi
  ssh_restart
  return 0
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
  log_use dropbear "Instalar Dropbear"
  ensure_base || return 1
  need_port dropbear "$PORT_DROPBEAR" || return 1
  info "Instalando Dropbear..."
  # dropbear-bin: solo el programa (el paquete "dropbear" agrega dropbear-initramfs en algunas versiones)
  apt_i dropbear-bin || { warn "Se prueba con el paquete dropbear..."; apt_i dropbear; } || return 1
  systemctl disable --now dropbear >> "$LOG" 2>&1
  dropbear_keys || return 1
  grep -qx /bin/false /etc/shells || echo /bin/false >> /etc/shells
  unit_dropbear
}

dropbear_keys() {   # llaves del servidor (Dropbear no las crea solo con dropbear-bin)
  local t f kg
  kg=$(command -v dropbearkey) || { err "No se encontro dropbearkey (paquete dropbear-bin incompleto)"; return 1; }
  mkdir -p /etc/dropbear
  for t in rsa ecdsa ed25519; do
    f=/etc/dropbear/dropbear_${t}_host_key
    [[ -s $f ]] && continue
    if [[ $t == rsa ]]; then "$kg" -t rsa -s 2048 -f "$f" >> "$LOG" 2>&1
    else "$kg" -t "$t" -f "$f" >> "$LOG" 2>&1 || rm -f "$f"; fi       # ed25519 no existe en 2019.78
  done
  [[ -s /etc/dropbear/dropbear_rsa_host_key || -s /etc/dropbear/dropbear_ecdsa_host_key ]] \
    || { err "No se pudieron crear las llaves de Dropbear"; show_tail "$LOG"; return 1; }
}

unit_dropbear() {   # servicio con el puerto y el banner actuales
  # KillMode=process: reiniciar Dropbear (puerto, banner) no corta a los usuarios conectados
  mkunit vps-dropbear "Dropbear SSH" \
    "$(command -v dropbear || echo /usr/sbin/dropbear) -F -E -R -p $PORT_DROPBEAR -W 65536 -K 30 $(banner_opt)" \
    "KillMode=process"
  fw_sync
  verify dropbear Dropbear
}

inst_ssl() {
  log_use ssl "Instalar SSL"
  ensure_base || return 1
  need_port ssl "$PORT_SSL" || return 1
  info "Instalando SSL (stunnel)..."
  apt_i stunnel4 || return 1
  systemctl disable --now stunnel4 >> "$LOG" 2>&1
  install_tools
  [[ -s $CERT ]] || mk_selfsigned "$(get_host)"
  conf_ssl
}

conf_ssl() {   # stunnel + proxy interno: SSH directo, payload o WebSocket dentro de TLS
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
connect = $SSL_SOCK
EOF
  cat > /etc/systemd/system/vps-sslws.service <<EOF
[Unit]
Description=Proxy interno de SSL (SSH directo o payload/WebSocket dentro de TLS)
PartOf=vps-stunnel.service
StartLimitIntervalSec=0

[Service]
Type=simple
RuntimeDirectory=vps-sslws
ExecStart=$(proxy_exec "unix:$SSL_SOCK" "$SSH_PORT" 101)
Restart=always
RestartSec=2
LimitNOFILE=65535
EOF
  mkunit vps-stunnel "Stunnel SSL a SSH" "/usr/bin/stunnel4 $BASE/stunnel.conf" "" \
    "Requires=vps-sslws.service
After=vps-sslws.service"
  fw_sync
  verify ssl "SSL (stunnel)"
}

inst_badvpn() {
  log_use badvpn "Instalar BadVPN-UDPGW"
  ensure_base || return 1
  need_port badvpn "$PORT_BADVPN" || return 1
  if [[ -n ${FORCE:-} ]] || ! /usr/local/bin/badvpn-udpgw --help >/dev/null 2>&1; then
    info "Compilando BadVPN-UDPGW..."
    apt_i gcc make cmake git libc6-dev || return 1
    run "Compilando badvpn-udpgw (1-2 minutos)" build_badvpn || return 1
  fi
  unit_badvpn
}

build_badvpn() (   # subshell: la salida va al registro
  set -e
  t=$(mktemp -d)
  trap 'rm -rf "$t"' EXIT
  git clone --depth 1 "$BADVPN_REPO" "$t/src"
  mkdir "$t/build"
  cd "$t/build"
  cmake ../src -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  make -j"$(nproc)"
  install -m755 udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw
)

unit_badvpn() {
  mkunit vps-badvpn "BadVPN UDPGW" \
    "/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:$PORT_BADVPN --max-clients 1000 --max-connections-for-client 20"
  verify badvpn BadVPN-UDPGW
}

# ---- Proxys en Python (WebSocket, SOCKS Python, WS-ePro y el interno de SSL) ----
# Un solo motor (vps-proxy.py) para todos: responde payloads y WebSocket, CONNECT y SOCKS5,
# acepta SSH directo y solo reenvia a puertos locales de tunel (SSH, Dropbear, OpenVPN).
proxy_allow() { printf '%s,%s,%s' "$SSH_PORT" "$PORT_DROPBEAR" "$(ovpn_port)"; }
# shellcheck disable=SC2046   # hostname -I: una IP por palabra, a proposito
proxy_self()  { local a; a=$(printf '%s\n' "$IP" $(hostname -I 2>/dev/null) | awk 'NF && !s[$0]++' | paste -sd, -); printf '%s' "${a:-127.0.0.1}"; }
proxy_exec() { # escucha destino respuesta(101|200) [--socks]
  printf '%s /usr/local/bin/vps-proxy.py -l %s -t %s -a %s -s %s --self %s%s' \
    "$(command -v python3 || echo /usr/bin/python3)" "$1" "$2" "$(proxy_allow)" "$3" "$(proxy_self)" "${4:+ $4}"
}

inst_ws() {
  log_use ws "Instalar WebSocket"
  ensure_base || return 1
  need_port ws "$PORT_WS" || return 1
  info "Instalando proxy WebSocket..."
  install_tools
  unit_ws
}

unit_ws() {
  mkunit vps-ws "Proxy WebSocket a SSH" "$(proxy_exec "$PORT_WS" "$SSH_PORT" 101)"
  fw_sync
  verify ws "WebSocket"
}

inst_socks() {
  log_use socks "Instalar SOCKS Python"
  ensure_base || return 1
  need_port socks "$PORT_SOCKS" || return 1
  info "Instalando SOCKS Python..."
  install_tools
  unit_socks
}

unit_socks() {   # proxy HTTP (payload/CONNECT, responde 200) y SOCKS5 hacia SSH
  mkunit vps-socks "SOCKS Python (proxy HTTP y SOCKS5 a SSH)" "$(proxy_exec "$PORT_SOCKS" "$SSH_PORT" 200 --socks)"
  fw_sync
  verify socks "SOCKS Python"
}

wsepro_target() { if proto_installed dropbear; then echo "$PORT_DROPBEAR"; else echo "$SSH_PORT"; fi; }

inst_wsepro() {
  log_use wsepro "Instalar WS-ePro"
  ensure_base || return 1
  need_port wsepro "$PORT_WSEPRO" || return 1
  info "Instalando WS-ePro..."
  install_tools
  unit_wsepro
}

unit_wsepro() {   # WebSocket hacia Dropbear (o SSH si Dropbear no esta instalado)
  mkunit vps-wsepro "WS-ePro (WebSocket a Dropbear/SSH)" "$(proxy_exec "$PORT_WSEPRO" "$(wsepro_target)" 101)"
  fw_sync
  verify wsepro "WS-ePro"
}

inst_squid() {
  log_use squid "Instalar Squid"
  ensure_base || return 1
  need_port squid "$PORT_SQUID" || return 1
  info "Instalando Squid..."
  apt_i squid || return 1
  conf_squid
}

conf_squid() {
  local ips out
  # shellcheck disable=SC2046
  ips=$(printf '%s\n' 127.0.0.1 ::1 "$IP" $(hostname -I 2>/dev/null) | awk 'NF && !s[$0]++' | paste -sd' ' -)
  cat > /etc/squid/squid.conf <<EOF
# VPS PANEL: solo se permite llegar a los puertos de tunel de este VPS (no es un proxy abierto)
http_port $PORT_SQUID
visible_hostname vps-panel
via off
forwarded_for delete
cache deny all
access_log none
shutdown_lifetime 1 seconds
acl self_dst dst $ips
acl tunnel_ports port $SSH_PORT $PORT_DROPBEAR $PORT_WS $PORT_SOCKS $PORT_WSEPRO $(ovpn_port)
http_access allow self_dst tunnel_ports
http_access deny all
EOF
  if ! out=$(squid -k parse -f /etc/squid/squid.conf 2>&1); then
    printf '%s\n' "$out" >> "$LOG"
    err "squid.conf no es valido:"
    printf '%s\n' "$out" | grep -iE 'error|fatal|warn|bungled' | gray_lines 8
    return 1
  fi
  svc_restart squid
  fw_sync
  VERIFY_WAIT=40 verify squid Squid
}

# ------------------------------ V2Ray ---------------------------------
v2_cmd() {   # subcomando de V2Ray segun la version (v5: "run -config"; v4: "-config")
  if /usr/local/bin/v2ray version 2>/dev/null | grep -q '^V2Ray 4\.'; then echo "-config"; else echo "run -config"; fi
}

v2_download() (   # ultimo release oficial, verificado con SHA256
  set -e
  case $(uname -m) in
    x86_64|amd64)  a=64 ;;
    aarch64|arm64) a=arm64-v8a ;;
    *) echo "Arquitectura no soportada: $(uname -m)"; exit 1 ;;
  esac
  t=$(mktemp -d)
  trap 'rm -rf "$t"' EXIT
  curl -fsSL --retry 3 --connect-timeout 15 -o "$t/v2.zip" "$V2_RELEASE/v2ray-linux-$a.zip"
  curl -fsSL --retry 3 --connect-timeout 15 -o "$t/v2.dgst" "$V2_RELEASE/v2ray-linux-$a.zip.dgst"
  want=$(awk -F'= *' 'toupper($1) ~ /SHA2-256|SHA256/ {print $2; exit}' "$t/v2.dgst" | tr -d '[:space:]')
  got=$(sha256sum "$t/v2.zip" | awk '{print $1}')
  echo "SHA256 esperado: $want"
  echo "SHA256 obtenido: $got"
  [ -n "$want" ] && [ "$want" = "$got" ] || { echo "La verificacion SHA256 de V2Ray fallo"; exit 1; }
  unzip -oq "$t/v2.zip" -d "$t/x"
  install -m755 "$t/x/v2ray" /usr/local/bin/v2ray
  mkdir -p /usr/local/share/v2ray
  for f in geoip.dat geosite.dat; do [ -f "$t/x/$f" ] && install -m644 "$t/x/$f" /usr/local/share/v2ray/; done
  /usr/local/bin/v2ray version | head -1
)

v2_write_config() {   # config con las cuentas de v2ray.db (asi una reinstalacion no las pierde)
  local clients
  clients=$(awk -F'|' 'NF >= 2 && $1 != "" && $2 != "" {
              printf "%s{\"id\":\"%s\",\"alterId\":0,\"email\":\"%s\"}", (n++ ? "," : ""), $2, $1 }' "$V2DB")
  mkdir -p "$(dirname "$V2CFG")"
  cat > "$V2CFG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT_V2RAY,
      "listen": "0.0.0.0",
      "protocol": "vmess",
      "settings": { "clients": [$clients] },
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
}

v2_unit() {
  cat > /etc/systemd/system/v2ray.service <<EOF
[Unit]
Description=V2Ray Service
Documentation=https://www.v2fly.org/
After=network.target nss-lookup.target
StartLimitIntervalSec=0

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Environment=V2RAY_LOCATION_ASSET=/usr/local/share/v2ray
ExecStart=/usr/local/bin/v2ray $(v2_cmd) $V2CFG
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  rm -f /etc/systemd/system/v2ray.service.d/10-donot_touch_single_conf.conf
  systemctl daemon-reload
}

v2_test() {   # valida la configuracion antes de reiniciar; muestra el error de V2Ray si lo hay
  local -a args=(test -config "$V2CFG")
  local out
  /usr/local/bin/v2ray version 2>/dev/null | grep -q '^V2Ray 4\.' && args=(-test -config "$V2CFG")
  if ! out=$(/usr/local/bin/v2ray "${args[@]}" 2>&1); then
    printf '%s\n' "$out" >> "$LOG"
    err "La configuracion de V2Ray no es valida:"
    printf '%s\n' "$out" | gray_lines 8
    return 1
  fi
}

inst_v2ray() {
  log_use v2ray "Instalar V2Ray"
  ensure_base || return 1
  need_port v2ray "$PORT_V2RAY" || return 1
  info "Instalando V2Ray..."
  if [[ -n ${FORCE:-} || ! -x /usr/local/bin/v2ray ]]; then
    run "Descargando V2Ray (release oficial)" v2_download || return 1
  fi
  v2_write_config
  v2_unit
  v2_test || return 1
  svc_restart v2ray
  fw_sync
  verify v2ray V2Ray
}

# ------------------------------ SlowDNS -------------------------------
mem_check() {   # compilar con Go necesita ~1 GB entre RAM libre y swap
  local m
  m=$(awk '/^(MemAvailable|SwapFree):/ {s += $2} END {print int(s / 1024)}' /proc/meminfo 2>/dev/null)
  if [[ ${m:-0} =~ ^[0-9]+$ ]] && (( m > 0 && m < 900 )); then
    warn "Memoria libre (RAM + swap): ${m} MB. Si la compilacion falla con 'killed',"
    warn "activa MEMORIA SWAP (opcion 18 de PREPARACION DEL SISTEMA) y repite."
  fi
  return 0
}

go_install() (   # Go oficial, verificado con SHA256
  set -e
  case $(uname -m) in x86_64|amd64) ga=amd64 ;; aarch64|arm64) ga=arm64 ;; *) echo "Arquitectura no soportada"; exit 1 ;; esac
  if [ -x /usr/local/go/bin/go ] && /usr/local/go/bin/go version | grep -q "go$GO_VERSION "; then exit 0; fi
  curl -fsSL --retry 3 --connect-timeout 15 -o /tmp/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-${ga}.tar.gz"
  echo "${GO_SHA256[$ga]}  /tmp/go.tgz" | sha256sum -c -
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tgz
  rm -f /tmp/go.tgz
  /usr/local/go/bin/go version
)

build_dnstt() (
  set -e
  t=$(mktemp -d)
  trap 'rm -rf "$t"' EXIT
  git clone "$DNSTT_REPO" "$t/dnstt"
  cd "$t/dnstt"
  git checkout -q "$DNSTT_COMMIT" || echo "aviso: no existe el commit $DNSTT_COMMIT, se usa el ultimo"
  cd dnstt-server
  export GOPATH=$t/gopath GOCACHE=$t/gocache GOFLAGS=-mod=mod CGO_ENABLED=0 GOTOOLCHAIN=local
  /usr/local/go/bin/go build -o /usr/local/bin/dnstt-server .
  /usr/local/bin/dnstt-server -h 2>&1 | head -2 || true
)

inst_slowdns() {
  log_use slowdns "Instalar SlowDNS"
  ensure_base || return 1
  local ns cur
  cur=$(cat "$BASE/slowdns/ns" 2>/dev/null)
  if [[ -n ${SLOWDNS_NS:-} ]]; then ns=$SLOWDNS_NS
  else
    rd "NameServer (NS) del dominio, ej. ns.midominio.com${cur:+ [$cur]}: " ns
    ns=${ns:-$cur}
  fi
  [[ $ns =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { err "NameServer invalido"; return 1; }
  need_port slowdns "$PORT_SLOWDNS" udp || return 1
  if [[ -n ${FORCE:-} || ! -x /usr/local/bin/dnstt-server ]]; then
    info "Compilando dnstt-server (Go $GO_VERSION)..."
    apt_i git ca-certificates || return 1
    mem_check
    run "Descargando Go $GO_VERSION" go_install || return 1
    run "Compilando dnstt-server (1-3 minutos)" build_dnstt || return 1
  fi
  mkdir -p "$BASE/slowdns"
  if [[ ! -s $BASE/slowdns/server.key ]]; then
    run "Generando llaves de SlowDNS" /usr/local/bin/dnstt-server -gen-key \
      -privkey-file "$BASE/slowdns/server.key" -pubkey-file "$BASE/slowdns/server.pub" || return 1
  fi
  echo "$ns" > "$BASE/slowdns/ns"
  unit_slowdns
}

unit_slowdns() {   # usa el NameServer guardado
  local ns ipt
  ns=$(<"$BASE/slowdns/ns")
  ipt=$(command -v iptables || echo /usr/sbin/iptables)
  mkunit vps-slowdns "SlowDNS (dnstt)" \
    "/usr/local/bin/dnstt-server -udp :$PORT_SLOWDNS -privkey-file $BASE/slowdns/server.key $ns 127.0.0.1:$SSH_PORT" \
    "ExecStartPre=-$ipt -w -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports $PORT_SLOWDNS
ExecStartPre=$ipt -w -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports $PORT_SLOWDNS
ExecStopPost=-$ipt -w -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports $PORT_SLOWDNS"
  fw_sync
  verify slowdns SlowDNS || return 1
  [[ -n ${NOSTART:-} ]] && return 0
  info "NameServer: $ns"
  info "Llave publica: $(cat "$BASE/slowdns/server.pub")"
  info "Registros DNS: A ns1.<dominio> -> $IP  |  NS $ns -> ns1.<dominio>"
}

# ------------------------------ OpenVPN -------------------------------
# OpenVPN propio del panel: TCP (funciona por Squid, SOCKS Python o payload), sin certificado
# de cliente: usuario y contrasena son los de las cuentas SSH (vencimiento incluido).
ovpn_mkpki() (   # CA y certificado del servidor con openssl
  set -e
  umask 077
  cd "$OVPN_DIR"
  cat > pki.cnf <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = VPS-PANEL-CA
[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[v3_srv]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
  openssl req -x509 -config pki.cnf -extensions v3_ca -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -keyout ca.key -out ca.crt
  openssl req -new -config pki.cnf -newkey rsa:2048 -nodes -sha256 -subj /CN=vps-panel-server \
    -keyout server.key -out server.csr
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 3650 -sha256 \
    -extfile pki.cnf -extensions v3_srv -out server.crt
  rm -f server.csr pki.cnf
  chmod 644 ca.crt server.crt
)

inst_openvpn() {
  log_use openvpn "Instalar OpenVPN"
  ensure_base || return 1
  [[ -c /dev/net/tun ]] || { err "Este VPS no tiene /dev/net/tun (TUN desactivado; en OpenVZ/LXC se activa en el panel del proveedor)."; return 1; }
  if [[ -f /etc/openvpn/server.conf && ! -f $OVPN_DIR/server.conf ]]; then   # instalacion anterior (script externo)
    warn "Se reemplaza la instalacion anterior de OpenVPN (copia en /etc/openvpn/server.conf.bak)."
    systemctl disable --now openvpn@server >> "$LOG" 2>&1
    mv -f /etc/openvpn/server.conf /etc/openvpn/server.conf.bak
  fi
  need_port openvpn "$PORT_OVPN" || return 1
  info "Instalando OpenVPN..."
  apt_i openvpn || return 1
  mkdir -p "$OVPN_DIR"; chmod 700 "$OVPN_DIR"
  if [[ ! -s $OVPN_DIR/ca.crt || ! -s $OVPN_DIR/server.crt || ! -s $OVPN_DIR/server.key ]]; then
    run "Generando certificados de OpenVPN" ovpn_mkpki || return 1
  fi
  ovpn_conf
}

ovpn_conf() {
  local plugin ver ciph proto
  plugin=$(find /usr/lib -name openvpn-plugin-auth-pam.so 2>/dev/null | head -1)
  [[ -n $plugin ]] || { err "No se encontro openvpn-plugin-auth-pam.so (paquete openvpn incompleto)"; return 1; }
  printf 'auth     required pam_unix.so\naccount  required pam_unix.so\n' > /etc/pam.d/openvpn-vpspanel
  ver=$(openvpn --version 2>/dev/null | awk 'NR==1{print $2}')
  if dpkg --compare-versions "${ver:-2.4}" ge 2.5; then
    ciph=$'data-ciphers AES-128-GCM:AES-256-GCM:CHACHA20-POLY1305:AES-128-CBC\ndata-ciphers-fallback AES-128-CBC'
  else
    ciph=$'cipher AES-128-CBC\nncp-ciphers AES-128-GCM:AES-256-GCM'
  fi
  proto=tcp; [[ -e /proc/net/if_inet6 ]] || proto=tcp4
  cat > "$OVPN_DIR/server.conf" <<EOF
# VPS PANEL: OpenVPN TCP; usuario y contrasena = cuentas SSH del panel
port $PORT_OVPN
proto $proto
dev tun
ca ca.crt
cert server.crt
key server.key
dh none
ecdh-curve prime256v1
topology subnet
server ${OVPN_NET%/*} 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
$ciph
auth SHA256
tls-version-min 1.2
persist-key
persist-tun
verify-client-cert none
username-as-common-name
duplicate-cn
plugin $plugin openvpn-vpspanel
max-clients 250
verb 3
EOF
  ovpn_client
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-vpspanel-forward.conf
  sysctl -qw net.ipv4.ip_forward=1
  svc_restart openvpn-server@server
  fw_sync
  verify openvpn OpenVPN || return 1
  [[ -n ${NOSTART:-} ]] && return 0
  info "Archivo para el cliente: $BASE/openvpn/cliente.ovpn (usuario y contrasena = cuenta SSH)"
}

ovpn_client() {   # archivo .ovpn unico: cada usuario entra con su cuenta SSH
  mkdir -p "$BASE/openvpn"
  {
    echo "# VPS PANEL - OpenVPN. Usuario y contrasena: los de tu cuenta SSH."
    echo "client"
    echo "dev tun"
    echo "proto tcp"
    echo "remote $(get_host) $PORT_OVPN"
    echo "resolv-retry infinite"
    echo "nobind"
    echo "persist-key"
    echo "persist-tun"
    echo "remote-cert-tls server"
    echo "auth-user-pass"
    echo "auth SHA256"
    echo "cipher AES-128-CBC"
    echo "ignore-unknown-option data-ciphers"
    echo "data-ciphers AES-128-GCM:AES-256-GCM:CHACHA20-POLY1305:AES-128-CBC"
    echo "verb 3"
    echo "# Por el proxy del panel (descomenta una): Squid o SOCKS Python"
    echo "# http-proxy $(get_host) $PORT_SQUID"
    echo "# http-proxy $(get_host) $PORT_SOCKS"
    echo "<ca>"
    cat "$OVPN_DIR/ca.crt"
    echo "</ca>"
  } > "$BASE/openvpn/cliente.ovpn"
}

ovpn_show() {
  [[ -s $BASE/openvpn/cliente.ovpn ]] || { err "OpenVPN no esta instalado."; return 1; }
  ovpn_client
  info "Copia este contenido en un archivo .ovpn (usuario y contrasena = cuenta SSH):"
  line_dash
  cat "$BASE/openvpn/cliente.ovpn"
  line_dash
  info "Tambien esta en: $BASE/openvpn/cliente.ovpn"
}

# ------------------------------ WireGuard -----------------------------
inst_wireguard() {
  log_use wireguard "Instalar WireGuard"
  ensure_base || return 1
  if [[ ! -f $WG_CONF && -s $BASE/wireguard/wg0.conf.bak ]]; then   # reinstalacion: recupera los clientes
    mkdir -p /etc/wireguard; cp "$BASE/wireguard/wg0.conf.bak" "$WG_CONF"; chmod 600 "$WG_CONF"
  fi
  [[ -f $WG_CONF ]] || need_port wireguard "$PORT_WG" udp || return 1
  info "Instalando WireGuard..."
  apt_i wireguard-tools iproute2 || return 1
  apt_i qrencode >/dev/null 2>&1 || warn "No se pudo instalar qrencode: los clientes se mostraran sin codigo QR."
  if ip link add vpswgtest type wireguard >> "$LOG" 2>&1; then
    ip link del vpswgtest >/dev/null 2>&1
  else
    # Kernel sin WireGuard (comun en OpenVZ/LXC): wireguard-go, la version oficial en espacio de
    # usuario. wg-quick la usa sola cuando el kernel no tiene el modulo.
    [[ -c /dev/net/tun ]] || { err "El kernel no soporta WireGuard y no hay /dev/net/tun (activa TUN en el panel del proveedor)."; return 1; }
    warn "El kernel de este VPS no trae WireGuard: se usara wireguard-go (espacio de usuario)."
    if [[ -n ${FORCE:-} ]] || ! /usr/local/bin/wireguard-go --version >/dev/null 2>&1; then
      apt_i git ca-certificates || return 1
      mem_check
      run "Descargando Go $GO_VERSION" go_install || return 1
      run "Compilando wireguard-go (1-2 minutos)" build_wggo || return 1
    fi
  fi
  mkdir -p /etc/wireguard "$BASE/wireguard"; chmod 700 /etc/wireguard "$BASE/wireguard"
  if [[ ! -s $WG_CONF ]]; then
    ( umask 077; printf '[Interface]\nAddress = %s.1/24\nListenPort = %s\nPrivateKey = %s\n' \
        "$WG_NET" "$PORT_WG" "$(wg genkey)" > "$WG_CONF" )
  fi
  wg_apply
  [[ -n ${NOSTART:-} ]] || info "Crea los clientes en WIREGUARD > AGREGAR CLIENTE."
}

build_wggo() (
  set -e
  t=$(mktemp -d)
  trap 'rm -rf "$t"' EXIT
  git clone "$WGGO_REPO" "$t/wg" || git clone https://github.com/WireGuard/wireguard-go "$t/wg"
  cd "$t/wg"
  git checkout -q "$WGGO_TAG"
  export GOPATH=$t/gopath GOCACHE=$t/gocache GOFLAGS=-mod=mod CGO_ENABLED=0 GOTOOLCHAIN=local
  /usr/local/go/bin/go build -o /usr/local/bin/wireguard-go .
  /usr/local/bin/wireguard-go --version
)

wg_apply() {   # puerto actual en wg0.conf y en los archivos de los clientes
  local f
  sed -i -E "s/^ListenPort *=.*/ListenPort = $PORT_WG/" "$WG_CONF"
  for f in "$BASE"/wireguard/*.conf; do
    [[ -f $f ]] && sed -i -E "s/^Endpoint *=.*/Endpoint = $(get_host):$PORT_WG/" "$f"
  done
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-vpspanel-forward.conf
  sysctl -qw net.ipv4.ip_forward=1
  svc_restart wg-quick@wg0
  fw_sync
  VERIFY_WAIT=10 verify wireguard WireGuard
}

wg_clients() { awk '/^### Client /{print $3}' "$WG_CONF" 2>/dev/null; }

wg_add() {
  local n ip i used spub cpriv psk f
  [[ -f $WG_CONF ]] || { err "WireGuard no esta instalado."; return 1; }
  rd "NOMBRE DEL CLIENTE: " n
  [[ $n =~ ^[A-Za-z0-9_-]{1,15}$ ]] || { err "Nombre invalido (1-15 caracteres: letras, numeros, _ -)"; return 1; }
  wg_clients | grep -qx "$n" && { err "El cliente ya existe"; return 1; }
  used=$(grep -oE "AllowedIPs *= *${WG_NET//./\\.}\.[0-9]+" "$WG_CONF" | awk -F. '{print $NF}')
  ip=''
  for (( i = 2; i <= 254; i++ )); do grep -qx "$i" <<< "$used" || { ip=$i; break; }; done
  [[ -n $ip ]] || { err "No quedan direcciones libres"; return 1; }
  spub=$(sed -n 's/^PrivateKey *= *//p' "$WG_CONF" | head -1 | wg pubkey) || { err "No se pudo leer la llave del servidor en $WG_CONF"; return 1; }
  cpriv=$(wg genkey); psk=$(wg genpsk)
  printf '\n### Client %s\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s.%s/32\n' \
    "$n" "$(wg pubkey <<< "$cpriv")" "$psk" "$WG_NET" "$ip" >> "$WG_CONF"
  f=$BASE/wireguard/$n.conf
  ( umask 077; cat > "$f" <<EOF
[Interface]
PrivateKey = $cpriv
Address = $WG_NET.$ip/32
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $spub
PresharedKey = $psk
Endpoint = $(get_host):$(wg_port)
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  )
  wg syncconf wg0 <(wg-quick strip wg0) >> "$LOG" 2>&1 || systemctl restart wg-quick@wg0
  ok "Cliente $n creado ($WG_NET.$ip)"
  wg_print "$n"
}

wg_print() {   # nombre -> configuracion del cliente y codigo QR
  local f=$BASE/wireguard/$1.conf
  [[ -s $f ]] || { err "No esta guardada la configuracion de $1"; return 1; }
  line_dash
  cat "$f"
  line_dash
  command -v qrencode >/dev/null 2>&1 && qrencode -t ansiutf8 < "$f"
  info "Archivo: $f"
}

wg_del() {
  local n t
  [[ -f $WG_CONF ]] || { err "WireGuard no esta instalado."; return 1; }
  wg_clients | grep -q . || { warn "No hay clientes"; return 1; }
  printf ' %s%s%s\n' "$LYE" "$(wg_clients | paste -sd' ' -)" "$RST"
  rd "CLIENTE A ELIMINAR: " n
  [[ -n $n ]] && wg_clients | grep -qx "$n" || { err "Cliente no encontrado"; return 1; }
  t=$(mktemp)
  awk -v n="$n" '/^### Client /{skip = ($3 == n)} !skip' "$WG_CONF" > "$t" && cat "$t" > "$WG_CONF"
  rm -f "$t" "$BASE/wireguard/$n.conf"
  wg syncconf wg0 <(wg-quick strip wg0) >> "$LOG" 2>&1 || systemctl restart wg-quick@wg0
  ok "Cliente $n eliminado"
}

wg_list() {
  local n sel
  [[ -f $WG_CONF ]] || { err "WireGuard no esta instalado."; return 1; }
  wg_clients | grep -q . || { warn "No hay clientes"; return 0; }
  while read -r n; do
    printf ' %s%-16s%s %s\n' "$WHT" "$n" "$RST" \
      "$(awk -v n="$n" '/^### Client /{c = ($3 == n)} c && /^AllowedIPs/{print $3; exit}' "$WG_CONF")"
  done < <(wg_clients)
  rd "VER LA CONFIGURACION DE (ENTER = ninguno): " sel
  [[ -n $sel ]] && wg_print "$sel"
  return 0
}

# ------------------------------ Psiphon -------------------------------
psi_download() (
  set -e
  t=$(mktemp)
  trap 'rm -f "$t"' EXIT
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 600 -o "$t" "$PSIPHON_URL"
  got=$(sha256sum "$t" | awk '{print $1}')
  echo "SHA256 esperado: $PSIPHON_SHA256"
  echo "SHA256 obtenido: $got"
  [ "$got" = "$PSIPHON_SHA256" ] || { echo "La verificacion SHA256 de psiphond fallo"; exit 1; }
  install -m755 "$t" /usr/local/bin/psiphond
)

psi_generate() (   # configuracion y server entry nuevos para la IP y los puertos actuales
  set -e
  mkdir -p "$PSI_DIR"
  cd "$PSI_DIR"
  rm -f psiphond.config psiphond-traffic-rules.config psiphond-osl.config psiphond-tactics.config server-entry.dat
  /usr/local/bin/psiphond -ipaddress "$IP" -web 0 \
    -protocol "OSSH:$PORT_PSIPHON" -protocol "UNFRONTED-MEEK-OSSH:$(( PORT_PSIPHON + 1 ))" generate
  # escucha en todas las interfaces: en VPS con NAT (Oracle, AWS, GCP) la IP publica no esta en la interfaz
  jq --arg u "127.0.0.1:$PORT_BADVPN" '.ServerIPAddress = "0.0.0.0" | .UDPInterceptUdpgwServerAddress = $u' \
    psiphond.config > psiphond.config.tmp
  mv psiphond.config.tmp psiphond.config
  chmod 600 psiphond.config
  echo "$IP $PORT_PSIPHON" > generated.for
)

inst_psiphon() {
  log_use psiphon "Instalar Psiphon"
  ensure_base || return 1
  case $(uname -m) in x86_64|amd64) ;; *) err "Psiphon solo tiene binario para x86_64 (este servidor es $(uname -m))"; return 1 ;; esac
  need_port psiphon "$PORT_PSIPHON" || return 1
  need_port psiphon "$(( PORT_PSIPHON + 1 ))" || return 1
  info "Instalando Psiphon..."
  if [[ -n ${FORCE:-} || ! -x /usr/local/bin/psiphond ]]; then
    run "Descargando psiphond (40 MB)" psi_download || return 1
  fi
  psi_apply
}

psi_apply() {   # regenera la configuracion si cambiaron la IP o el puerto (nuevo server entry)
  if [[ ! -s $PSI_DIR/psiphond.config || $(cat "$PSI_DIR/generated.for" 2>/dev/null) != "$IP $PORT_PSIPHON" ]]; then
    run "Generando la configuracion de Psiphon" psi_generate || return 1
    warn "Server entry nuevo: vuelve a copiarlo en las apps (PSIPHON > VER SERVER ENTRY)."
  fi
  mkunit vps-psiphon "Psiphon (psiphond)" "/usr/local/bin/psiphond -config $PSI_DIR/psiphond.config run" \
    "WorkingDirectory=$PSI_DIR"
  fw_sync
  VERIFY_WAIT=30 verify psiphon Psiphon
}

psi_show() {
  [[ -s $PSI_DIR/server-entry.dat ]] || { err "Psiphon no esta instalado."; return 1; }
  info "Server entry (copialo completo en la app):"
  line_dash
  cat "$PSI_DIR/server-entry.dat"; echo
  line_dash
  info "Tambien esta en: $PSI_DIR/server-entry.dat"
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
  px_del "$u"                                     # una cuenta normal no tiene hora exacta de vencimiento
  if ! db_add "$USERDB" "$u|$p|$exp|$l"; then
    userdel -f "$u" 2>/dev/null
    err "No se pudo guardar $u en la base del panel; no se creo."; return 1
  fi
  show_ssh_info "$u" "$p" "$exp" "$l"
}

# Atajos "1.1" (user1, user2...) y "1.2" (prueba1, prueba2...): crean al instante la siguiente
# cuenta de su secuencia. El ultimo numero usado queda en su archivo .seq, asi la secuencia sigue
# igual despues de cerrar el panel o reiniciar el VPS, y un numero no se reutiliza aunque su cuenta
# se borre o venza (vps-cleanup borra las vencidas, por eso el numero no se calcula mirando
# users.db): nadie entra con una cuenta de prueba vieja que se volvio a crear con su mismo nombre.
# Si el nombre ya existe (por ejemplo un user5 creado a mano) se salta al siguiente libre:
# nunca se duplica una cuenta. Solo se avanza el contador cuando la cuenta quedo creada.
seq_make() {   # prefijo clave limite archivo.seq fecha [hasta]  (con el candado tomado; imprime el usuario)
  local pre=$1 pass=$2 lim=$3 sf=$4 exp=$5 until=${6:-} last=0 n u
  [[ -s $sf ]] && read -r last < "$sf"
  [[ $last =~ ^[0-9]+$ ]] || last=0
  n=$(( 10#$last + 1 ))
  while :; do
    u=$pre$n
    grep -q "^${u}|" "$USERDB" || id "$u" >/dev/null 2>&1 || break
    n=$(( n + 1 ))
  done
  useradd -M -s /bin/false -e "$exp" "$u" || { err "No se pudo crear el usuario $u"; return 1; }
  if ! echo "$u:$pass" | chpasswd; then
    userdel -f "$u" 2>/dev/null
    err "No se pudo asignar la contrasena de $u"; return 1
  fi
  # la hora exacta va antes que la cuenta: vps-cleanup nunca ve una cuenta de prueba sin ella
  if [[ -n $until ]]; then px_set "$u" "$until"; else px_del "$u"; fi ||
    { userdel -f "$u" 2>/dev/null; err "No se pudo guardar el vencimiento de $u; no se creo."; return 1; }
  if ! db_add "$USERDB" "$u|$pass|$exp|$lim"; then
    userdel -f "$u" 2>/dev/null; px_del "$u"
    err "No se pudo guardar $u en la base del panel; no se creo."; return 1
  fi
  if printf '%s\n' "$n" > "$sf.tmp"; then       # escritura atomica: el contador nunca queda a medias
    sync "$sf.tmp" 2>/dev/null
    mv -f "$sf.tmp" "$sf"
  fi
  printf '%s\n' "$u"
}

seq_user() {   # prefijo clave limite archivo.seq fecha [hasta]  ->  crea la cuenta; deja el nombre en SEQ_U
  local out rc
  SEQ_U=''
  ensure_base
  out=$( { flock -w 10 9 || { err "Otra sesion del panel esta creando un usuario. Intenta de nuevo"; exit 2; }
           seq_make "$@"; } 9>"$QUICK_LOCK" )
  rc=$?
  out=${out##*$'\n'}
  (( rc == 0 )) && [[ $out =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
  SEQ_U=$out
}

quick_user() {   # 1.1: user1, user2... (QUICK_PASS, QUICK_DAYS dias, QUICK_LIMIT conexiones)
  local exp
  exp=$(date -d "+$QUICK_DAYS days" +%F)
  seq_user "$QUICK_PREFIX" "$QUICK_PASS" "$QUICK_LIMIT" "$SEQ_F" "$exp" || return 1
  show_ssh_info "$SEQ_U" "$QUICK_PASS" "$exp" "$QUICK_LIMIT"
}

dur_txt() {   # horas -> "1 dia", "2 dias", "12 horas"
  local h=$1
  if (( h % 24 == 0 )); then (( h == 24 )) && echo "1 dia" || echo "$(( h / 24 )) dias"
  else echo "$h horas"; fi
}

# 1.2: prueba1, prueba2... (TEST_PASS, TEST_LIMIT conexiones) que vencen TEST_HOURS horas despues de
# crearlas, a la hora exacta. users.db lleva como fecha el dia siguiente a esa hora (asi ni la fecha
# ni el sistema la cortan antes) y vps-cleanup la vence a la hora exacta guardada en users.exp.
test_user() {
  local until exp
  until=$(( $(date +%s) + TEST_HOURS * 3600 ))
  exp=$(date -u -d "@$(( until + 86400 ))" +%F)
  seq_user "$TEST_PREFIX" "$TEST_PASS" "$TEST_LIMIT" "$TEST_SEQ_F" "$exp" "$until" || return 1
  show_ssh_info "$SEQ_U" "$TEST_PASS" "$exp" "$TEST_LIMIT" \
    "$(date -d "@$until" '+%d/%m/%Y %H:%M') ($(dur_txt "$TEST_HOURS"))" "USUARIO DE PRUEBA CREADO!"
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
  local db=$1 kind=v2 n p e l d c now sta num t r
  local -A LK=() PXT=()
  [[ $db == "$USERDB" ]] && kind=ssh
  ACCT=()
  now=$(date +%s)
  num=$'N\xc2\xb0'
  if [[ $kind == ssh ]]; then
    if [[ -r /etc/shadow ]]; then
      while IFS=: read -r n p _; do [[ $p == '!'* ]] && LK[$n]=1; done < /etc/shadow
    fi
    if [[ -s $PX_DB ]]; then        # cuentas de prueba: vencen a una hora exacta (columna Dia en horas)
      while IFS='|' read -r n t; do [[ -n $n && $t =~ ^[0-9]+$ ]] && PXT[$n]=$t; done < "$PX_DB"
    fi
    printf '%s  %s %-14s%-14s%-9s%-4s%-4s%s%s\n' "$LYE" "$num" Usuario Contrasena Fecha Dia Lim Sta "$RST"
  else
    printf '%s  %s %-28s%-9s%s%s\n' "$LYE" "$num" Cuenta Fecha Dia "$RST"
  fi
  line_dash
  while IFS='|' read -r n p e l; do
    [[ -n $n ]] || continue
    ACCT+=("$n")
    if [[ -n ${PXT[$n]:-} ]]; then   # prueba: fecha de su hora de vencimiento y horas que faltan (24h, 5h...)
      r=$(( PXT[$n] - now ))
      fdate "$(date -d "@${PXT[$n]}" +%F)"
      if (( r > 0 )); then d="$(( (r + 3599) / 3600 ))h"; c=$GRN; else d=0; c=$RED; fi
    else
      d=$(days_left "$e" "$now"); fdate "$e"
      if (( d < 0 )); then c=$RED; else c=$GRN; fi
    fi
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
  local u list
  local -a gone=() failed=()
  (( $# > 20 )) && info "Eliminando $# cuentas..."
  for u in "$@"; do
    valid_name "$u" || { failed+=("$u"); continue; }
    if id "$u" >/dev/null 2>&1 && ! panel_uid "$u"; then      # root o cuenta del sistema: nunca se borra
      warn "$u es del sistema: solo se quita de la lista."
      gone+=("$u"); continue
    fi
    pkill -KILL -u "$u" 2>/dev/null
    userdel -f "$u" 2>/dev/null
    if id "$u" >/dev/null 2>&1; then failed+=("$u"); else gone+=("$u"); fi
  done
  if (( ${#gone[@]} )); then
    list=$(IFS='|'; printf '%s' "${gone[*]}")
    db_filter "$USERDB" awk -F'|' -v list="|$list|" 'index(list, "|" $1 "|") == 0' \
      || err "No se pudo actualizar la lista del panel."
    [[ -s $PX_DB ]] && db_filter "$PX_DB" awk -F'|' -v list="|$list|" 'index(list, "|" $1 "|") == 0'
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
  # al renovar, una cuenta de prueba pasa a ser normal (vence por fecha, ya no a una hora exacta)
  usermod -e "$exp" "$u" && db_set "$u" 3 "$exp" && px_del "$u" && ok "$u vence el $exp"
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
  db_filter "$V2DB" awk -F'|' -v n="$n" '$1 != n' || { err "No se pudo actualizar v2ray.db"; return 1; }
  systemctl restart v2ray
  ok "Cuenta $n eliminada"
}

v2_renew() {
  local n d exp
  pick_account "$V2DB" || return $?
  n=$PICK
  valid_name "$n" && grep -q "^${n}|" "$V2DB" || { err "Cuenta no encontrada"; return 1; }
  rd_def "DIAS DESDE HOY PARA $n [30]:" d 30 || return 1
  [[ $d =~ ^[0-9]+$ ]] || { err "Dias invalidos"; return 1; }
  exp=$(date -d "+$d days" +%F)
  db_filter "$V2DB" env U="$n" V="$exp" awk -F'|' -v OFS='|' '$1==ENVIRON["U"]{$3=ENVIRON["V"]}1' \
    || { err "No se pudo actualizar v2ray.db"; return 1; }
  ok "$n vence el $exp"
}

# ------------------------- Protocolos / Herramientas ------------------
proto_label() {   # clave -> nombre que se muestra
  local i
  for i in "${!PROTO_KEYS[@]}"; do [[ ${PROTO_KEYS[i]} == "$1" ]] && { echo "${PROTO_NAMES[i]}"; return; }; done
  echo "${1^^}"
}

proto_action() {   # no instalado: lo instala; instalado: lo inicia o lo detiene
  local k=$1 u nm
  nm=$(proto_label "$k")
  if ! proto_installed "$k"; then
    "${INST[$k]}"
    return
  fi
  u=$(svc_unit "$k")
  if is_on "$k"; then
    systemctl disable --now "$u" >/dev/null 2>&1
    ok "${k^^} detenido"
  else
    log_use "$k" "Iniciar $nm"
    systemctl reset-failed "$u" >/dev/null 2>&1
    systemctl enable --now "$u" >> "$LOG" 2>&1
    fw_sync
    verify "$k" "$nm"
  fi
}

proto_repair() {   # clave -> reinstala y reconfigura (conserva cuentas, llaves y clientes)
  local k=$1 nm
  nm=$(proto_label "$k")
  info "Reinstalando $nm desde cero (se conservan cuentas, llaves y clientes)..."
  FORCE=1 "${INST[$k]}"
}

proto_uninstall() {   # clave -> quita el servicio, el programa y su puerto del firewall
  local k=$1 nm c u
  nm=$(proto_label "$k")
  rd "DESINSTALAR $nm? (s/N): " c
  [[ $c == [sS]* ]] || return 3
  log_use "$k" "Desinstalar $nm"
  u=$(svc_unit "$k")
  systemctl disable --now "$u" >> "$LOG" 2>&1
  case $k in
    ssl)       systemctl stop vps-sslws >/dev/null 2>&1
               rm -f /etc/systemd/system/vps-sslws.service "$BASE/stunnel.conf" ;;
    badvpn)    rm -f /usr/local/bin/badvpn-udpgw ;;
    squid)     run "Quitando squid" apt-get purge -y squid ;;
    v2ray)     rm -f /usr/local/bin/v2ray "$V2CFG" /etc/systemd/system/v2ray.service       # las cuentas quedan en v2ray.db
               rm -rf /usr/local/share/v2ray /etc/systemd/system/v2ray.service.d ;;
    udp)       /usr/local/bin/vps-fw udpclean "$PORT_UDP"; rm -rf /etc/udp-custom ;;
    slowdns)   rm -f /usr/local/bin/dnstt-server ;;                                        # las llaves quedan en $BASE/slowdns
    openvpn)   rm -f "$OVPN_DIR/server.conf" /etc/pam.d/openvpn-vpspanel ;;               # la CA queda: el .ovpn sigue valido
    wireguard) mkdir -p "$BASE/wireguard"; mv -f "$WG_CONF" "$BASE/wireguard/wg0.conf.bak" 2>/dev/null ;;
    psiphon)   rm -f /usr/local/bin/psiphond ;;                                            # las llaves quedan en $PSI_DIR
  esac
  [[ $u == vps-* || $u == udp-custom ]] && rm -f "/etc/systemd/system/$u.service"
  systemctl daemon-reload
  case $k in
    dropbear)          apply_proto wsepro ;;          # WS-ePro vuelve a apuntar a SSH
    openvpn|wireguard) apply_proto udp ;;
  esac
  fw_sync
  ok "$nm desinstalado"
}

proto_diag() {   # clave -> estado, puerto, firewall, prueba real y registros
  local k=$1 nm u st p pr why l
  nm=$(proto_label "$k")
  log_use diagnostico "Diagnostico $nm"
  u=$(svc_unit "$k")
  p=$(svc_port "$k"); pr=tcp
  case $k in udp|slowdns|wireguard) pr=udp ;; openvpn) pr=$(ovpn_proto) ;; esac
  st=$(systemctl show -p ActiveState,SubState --value "$u" 2>/dev/null | paste -sd/ -)
  field "SERVICIO:" "$u ($st)" "$( [[ $st == active/* ]] && echo "$GRN" || echo "$RED")"
  if listening "$p" "$pr"; then field "PUERTO:" "$p/$pr escuchando ($(port_owner "$p" "$pr"))" "$GRN"
  else field "PUERTO:" "$p/$pr sin escuchar" "$RED"; fi
  if [[ $k == badvpn ]]; then field "FIREWALL:" "no hace falta (solo 127.0.0.1)" "$GRN"
  elif fw_rule "$p" "$pr"; then field "FIREWALL:" "abierto en iptables (regla del panel)" "$GRN"
  else field "FIREWALL:" "sin regla del panel (REPARAR la crea)" "$YEL"; fi
  if why=$(check_proto "$k"); then field "PRUEBA:" "OK: $why" "$GRN"
  else field "PRUEBA:" "FALLA: $why" "$RED"; fi
  if [[ $pr == tcp && $k != badvpn && -n $IP ]]; then
    if timeout 4 bash -c "exec 3<>/dev/tcp/$IP/$p" 2>/dev/null; then
      field "IP PUBLICA:" "$IP:$p responde" "$GRN"
    else
      field "IP PUBLICA:" "$IP:$p sin respuesta" "$YEL"
      echo " Si la prueba local pasa pero la IP publica no responde, abre el puerto en el"
      echo " firewall del proveedor (Security List / Security Group / Firewall de la nube)."
    fi
  fi
  svc_report "$k"
  l=$LOG_DIR/$k.log
  if [[ -s $l ]]; then
    printf ' %sULTIMAS LINEAS DEL REGISTRO DE INSTALACION:%s\n' "$BLU" "$RST"
    grep -v '^$' "$l" | tail -n 12 | gray_lines 12
  fi
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
  ensure_base || return 1
  log_use dominio "Dominio y certificado"
  local d rc
  rd "Dominio (vacio = certificado autofirmado con la IP): " d
  if [[ -z $d ]]; then
    rm -f "$DOMAIN_F"
    mk_selfsigned "$IP"
    ok "Certificado autofirmado generado"
    return 0
  fi
  [[ $d =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { err "Dominio invalido"; return 1; }
  apt_i certbot || return 1

  # certbot --standalone necesita el puerto 80: se detiene lo del panel que lo use y se
  # vuelve a iniciar al terminar (tambien en cada renovacion automatica)
  mkdir -p /etc/letsencrypt/renewal-hooks/{pre,post,deploy}
  cat > /etc/letsencrypt/renewal-hooks/pre/vpspanel.sh <<'EOF'
#!/bin/sh
: > /run/vpspanel-80.stopped
for u in vps-ws vps-socks vps-wsepro v2ray squid vps-psiphon; do
  pid=$(systemctl show -p MainPID --value "$u" 2>/dev/null)
  [ -n "$pid" ] && [ "$pid" != 0 ] || continue
  if ss -Hltnp 'sport = :80' 2>/dev/null | grep -q "pid=$pid,"; then
    systemctl stop "$u" && echo "$u" >> /run/vpspanel-80.stopped
  fi
done
iptables -w -I INPUT -p tcp --dport 80 -m comment --comment vpspanel-certbot -j ACCEPT 2>/dev/null
exit 0
EOF
  cat > /etc/letsencrypt/renewal-hooks/post/vpspanel.sh <<'EOF'
#!/bin/sh
iptables -w -D INPUT -p tcp --dport 80 -m comment --comment vpspanel-certbot -j ACCEPT 2>/dev/null
if [ -f /run/vpspanel-80.stopped ]; then
  while read -r u; do systemctl start "$u"; done < /run/vpspanel-80.stopped
  rm -f /run/vpspanel-80.stopped
fi
exit 0
EOF
  cat > /etc/letsencrypt/renewal-hooks/deploy/vpspanel.sh <<EOF
#!/bin/sh
cat /etc/letsencrypt/live/$d/fullchain.pem /etc/letsencrypt/live/$d/privkey.pem > $CERT
chmod 600 $CERT
systemctl restart vps-stunnel 2>/dev/null
exit 0
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/{pre,post,deploy}/vpspanel.sh

  /etc/letsencrypt/renewal-hooks/pre/vpspanel.sh
  certbot certonly --standalone -d "$d" --non-interactive --agree-tos --register-unsafely-without-email 2>&1 | tee -a "$LOG"
  rc=${PIPESTATUS[0]}
  /etc/letsencrypt/renewal-hooks/post/vpspanel.sh
  (( rc == 0 )) || { err "certbot fallo: verifica que $d apunte a $IP y que el puerto 80 este abierto en el proveedor."; return 1; }

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

restart_services() {   # reinicia lo que esta activo y comprueba que de verdad responda
  local k
  log_use servicios "Reiniciar servicios"
  is_on ssh && ssh_restart && echo "  reiniciado: ssh"
  for k in "${PROTO_KEYS[@]}"; do
    is_on "$k" || continue
    systemctl restart "$(svc_unit "$k")" >> "$LOG" 2>&1
    VERIFY_WAIT=30 verify "$k" "$(proto_label "$k")"
  done
  fw_sync
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
  local c='' s u p keep=''
  warn "Se eliminaran el panel y sus servicios."
  warn "Tambien se borraran las cuentas SSH."
  rd "ESCRIBE SI PARA CONTINUAR: " c
  [[ $c == SI ]] || return 0
  # copia final: si se conservan las copias, al instalar el panel otra vez los usuarios vuelven solos
  if bk_snap antes-de-desinstalar; then [[ -n $BK_LAST ]] && ok "Copia de seguridad final: $BK_LAST"
  else warn "No se pudo crear la copia final (quedan las anteriores)."; fi
  echo
  info "Con las copias, al instalar de nuevo el panel"
  info "vuelven solos los usuarios y la configuracion."
  rd "CONSERVAR LAS COPIAS DE SEGURIDAD? (S/n): " keep
  NO_AUTOBK=1                                    # desde aqui no se crean mas copias automaticas
  while IFS='|' read -r u p _; do
    [[ -n $u ]] || continue
    if id "$u" >/dev/null 2>&1 && ! panel_uid "$u"; then continue; fi   # nunca root ni cuentas del sistema
    pkill -KILL -u "$u" 2>/dev/null; userdel -f "$u" 2>/dev/null
  done < "$USERDB"
  for s in vps-dropbear vps-stunnel vps-sslws vps-badvpn vps-ws vps-socks vps-wsepro vps-slowdns \
           udp-custom vps-psiphon vps-firewall; do
    systemctl disable --now "$s" >/dev/null 2>&1
    rm -f "/etc/systemd/system/$s.service"
  done
  systemctl disable --now squid v2ray >/dev/null 2>&1
  if [[ -f $OVPN_DIR/server.conf ]]; then          # OpenVPN del panel
    systemctl disable --now openvpn-server@server >/dev/null 2>&1
    rm -f "$OVPN_DIR"/{server.conf,ca.crt,ca.key,ca.srl,server.crt,server.key} /etc/pam.d/openvpn-vpspanel
  fi
  if [[ -f $WG_CONF ]] && ! grep -q '^PostUp' "$WG_CONF"; then   # WireGuard del panel (sin PostUp)
    systemctl disable --now wg-quick@wg0 >/dev/null 2>&1
    rm -f "$WG_CONF"
  fi
  [[ -x /usr/local/bin/vps-fw ]] && { /usr/local/bin/vps-fw udpclean "$PORT_UDP"; /usr/local/bin/vps-fw clear; }
  systemctl daemon-reload
  rm -rf /etc/udp-custom
  rm -f /usr/local/bin/{vps-ws.py,vps-proxy.py,vps-probe,vps-fw,vps-sessions,vps-limiter,vps-cleanup,vps-rollback,badvpn-udpgw,dnstt-server,psiphond,wireguard-go}
  rm -f /etc/cron.d/vpspanel /etc/sysctl.d/99-vpspanel.conf /etc/sysctl.d/99-vpspanel-forward.conf
  rm -f /etc/ssh/sshd_config.d/00-vpspanel.conf /etc/ssh/sshd_config.d/01-vpspanel-root.conf
  rm -f /etc/letsencrypt/renewal-hooks/{pre,post,deploy}/vpspanel.sh
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
  autostart_on && sed -i '/vpspanel-autostart/d' /root/.bashrc
  rm -rf "$BASE" "$LOG_DIR"
  rm -f "$PANEL_BIN"
  if [[ $keep == [nN]* ]]; then
    rm -rf "$BK_DIR"
    ok "Copias de seguridad borradas."
  else
    ok "Copias de seguridad conservadas en $BK_DIR"
    info "Al instalar el panel otra vez, todo se recupera solo."
  fi
  ok "Panel desinstalado (squid y v2ray quedan instalados pero detenidos)."
  exit 0
}


# Instala este archivo como "vpspanel". Si habia otra version instalada (actualizacion a mano con
# el instalador nuevo), antes guarda esa version (vps-rollback) y una copia de los datos.
self_install() {
  local me; me=$(readlink -f "$0" 2>/dev/null)
  [[ -f $me && $me != "$PANEL_BIN" ]] || return 0
  cmp -s "$me" "$PANEL_BIN" 2>/dev/null && return 0
  if [[ -s $PANEL_BIN ]]; then
    script_save "$PANEL_BIN" && install_rollback 2>/dev/null
    bk_snap antes-de-actualizar >/dev/null 2>&1
  fi
  install -m 755 "$me" "$PANEL_BIN.new" && mv -f "$PANEL_BIN.new" "$PANEL_BIN"
}


# ------------------------------ Copias de seguridad -------------------
# Todo lo necesario para recuperar el panel se guarda en $BK_DIR, fuera de $BASE: usuarios con su
# contrasena (texto y hash del sistema), vencimiento y limite; cuentas V2Ray y de prueba; puertos,
# nombre, banner, dominio y certificado; llaves de SlowDNS y Psiphon; CA y llaves de OpenVPN;
# WireGuard con sus clientes. Cada copia es un .tar.gz autocontenido con un MANIFEST (formato,
# version, fecha, cuentas y protocolos): sirve tambien en otro VPS.
#   automatica: al volver al menu principal y al salir, solo si algo cambio; y una diaria (cron)
#   por evento: antes de actualizar, restaurar o desinstalar, y a mano (COPIAS DE SEGURIDAD)
# Restaurar UNE las cuentas (las de la copia + las actuales que no estan en ella): no borra ninguna.
# Lo que nunca se copia ni se restaura (temporales, candados y marcas propias de este servidor):
BK_SKIP='^(\.prep|\.helpers|[^/]*\.lock|fw\.(ports|nat)|.*\.tmp|(.*/)?\.tmp-.*)$'
BK_DBS='^(users\.db|v2ray\.db|users\.exp|quick\.seq|test\.seq)$'   # se unen aparte al restaurar

bk_files() { ls -1 "$BK_DIR"/vpspanel-*.tar.gz 2>/dev/null | LC_ALL=C sort -r; }   # la mas reciente primero

mf_get() {   # clave MANIFEST  ->  valor (solo caracteres seguros: la copia puede venir de otro VPS)
  sed -n "s/^$1=//p" "$2" 2>/dev/null | head -1 | tr -cd 'A-Za-z0-9 ._:/@+,-' | cut -c1-60
}

bk_fingerprint() {   # huella rapida (nombres, tamanos, fechas): si no cambio, no hace falta copiar
  {                    # sin candados ni temporales (el cron abre cleanup.lock cada minuto)
    find "$BASE" -type f ! -name '*.lock' ! -name '*.tmp' ! -name '.tmp-*' ! -name 'fw.ports' ! -name 'fw.nat' \
      ! -name '.prep' ! -name '.helpers' -printf '%P %s %T@\n' 2>/dev/null
    stat -c '%n %s %Y' "$OVPN_DIR/ca.crt" "$OVPN_DIR/server.key" "$WG_CONF" /etc/shadow 2>/dev/null
  } | LC_ALL=C sort | sha256sum | cut -d' ' -f1
}

bk_collect() {   # carpeta  ->  arma ahi vpspanel-backup/ con los datos actuales del panel
  local d=$1/vpspanel-backup f list=$1/.list
  mkdir -p "$d/base" "$d/extra" || return 1
  ( cd "$BASE" && find . -type f -size -5M -print0 2>/dev/null ) |
    while IFS= read -r -d '' f; do f=${f#./}; [[ $f =~ $BK_SKIP ]] || printf '%s\0' "$f"; done > "$list"
  tar -C "$BASE" --null -T "$list" -cf - 2>/dev/null | tar -C "$d/base" -xpf - || return 1
  for f in ca.crt ca.key ca.srl server.crt server.key; do
    [[ -f $OVPN_DIR/$f ]] || continue
    mkdir -p "$d/extra/openvpn" && cp -p -- "$OVPN_DIR/$f" "$d/extra/openvpn/$f" || return 1
  done
  if [[ -f $WG_CONF ]]; then
    mkdir -p "$d/extra/wireguard" && cp -p -- "$WG_CONF" "$d/extra/wireguard/wg0.conf" || return 1
  fi
  # contrasena de cada cuenta tal como la tiene el sistema (hash): al restaurar queda identica
  awk -F'|' 'FILENAME == ARGV[1] { if ($1 != "") u[$1]; next }
             { split($0, a, ":"); if (a[1] in u) print a[1] ":" a[2] }' "$USERDB" /etc/shadow > "$d/extra/shadow" 2>/dev/null
  touch "$d/base/users.db" "$d/base/v2ray.db" "$d/base/users.exp"
  rm -f "$list"
  chmod -R go-rwx "$d"
  return 0
}

bk_datahash() {   # carpeta  ->  hash del contenido (sin MANIFEST): dos copias con los mismos datos coinciden
  ( cd "$1/vpspanel-backup" && find . -type f ! -name MANIFEST -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum ) |
    sha256sum | cut -d' ' -f1
}

bk_manifest() {   # carpeta motivo hash
  local d=$1/vpspanel-backup k pl='' ns nv
  for k in "${PROTO_KEYS[@]}"; do proto_installed "$k" && pl+="$k "; done
  ns=$(grep -c '^[^|]' "$d/base/users.db" 2>/dev/null); nv=$(grep -c '^[^|]' "$d/base/v2ray.db" 2>/dev/null)
  {
    echo "format=$BK_FORMAT"
    echo "panel_version=$VERSION"
    echo "created=$(date +%s)"
    echo "reason=$2"
    echo "host=$(hostname 2>/dev/null)"
    echo "ip=${IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    echo "name=$(vps_name)"
    echo "ssh_users=${ns:-0}"
    echo "v2_users=${nv:-0}"
    echo "protocols=${pl% }"
    echo "data_hash=$3"
  } > "$d/MANIFEST"
  chmod 600 "$d/MANIFEST"
}

_bk_snap() {   # motivo  ->  (con el candado de las copias) imprime la ruta de la copia; 3 = sin cambios
  local why=$1 fp h tmp name='' free i
  fp=$(bk_fingerprint)
  [[ $why == auto && $fp == "$(cat "$BK_DIR/.fp" 2>/dev/null)" ]] && return 3
  free=$(df -Pk "$BK_DIR" 2>/dev/null | awk 'NR == 2 {print $4}')
  if [[ $free =~ ^[0-9]+$ ]] && (( free < 10240 )); then
    err "Disco casi lleno (menos de 10 MB): no se crea la copia."; return 1
  fi
  tmp=$(mktemp -d "$BK_DIR/.stage-XXXXXX") || return 1
  if ! bk_collect "$tmp"; then rm -rf "$tmp"; err "No se pudieron reunir los datos para la copia."; return 1; fi
  h=$(bk_datahash "$tmp")
  if [[ $why == auto && $h == "$(cat "$BK_DIR/.hash" 2>/dev/null)" ]]; then   # solo cambiaron fechas
    echo "$fp" > "$BK_DIR/.fp"; rm -rf "$tmp"; return 3
  fi
  bk_manifest "$tmp" "$why" "$h"
  for i in 1 2 3; do
    name=$BK_DIR/vpspanel-$(date +%Y%m%d-%H%M%S)-$why.tar.gz
    [[ -e $name ]] || break
    sleep 1
  done
  # se escribe aparte, se comprueba que se pueda leer y recien ahi toma su nombre definitivo
  if tar -czf "$name.part" -C "$tmp" vpspanel-backup 2>/dev/null && tar -tzf "$name.part" >/dev/null 2>&1; then
    chmod 600 "$name.part"
    sync "$name.part" 2>/dev/null
    mv -f "$name.part" "$name"
  else
    rm -f "$name.part"; rm -rf "$tmp"; err "No se pudo escribir la copia (disco lleno?)."; return 1
  fi
  rm -rf "$tmp"
  echo "$h" > "$BK_DIR/.hash"; echo "$fp" > "$BK_DIR/.fp"
  bk_prune
  printf '%s\n' "$name"
}

bk_snap() {   # [motivo]  ->  crea una copia ("auto": solo si algo cambio). Deja la ruta en BK_LAST
  local why=${1:-manual} out rc
  BK_LAST=''
  [[ $why =~ ^[a-z-]{1,24}$ ]] || why=manual
  [[ -s $NAME_F || -s $USERDB || -s $V2DB ]] || return 0       # panel sin datos: nada que guardar
  mkdir -p "$BK_DIR" && chmod 700 "$BK_DIR" || { err "No se pudo crear $BK_DIR"; return 1; }
  out=$( ( flock -w 30 7 || exit 1; _bk_snap "$why" ) 7>"$BK_DIR/.lock" )
  rc=$?
  (( rc == 3 )) && return 0
  (( rc == 0 )) || return 1
  BK_LAST=${out##*$'\n'}
  logln "copia de seguridad ($why): $BK_LAST"
  return 0
}

bk_prune() {   # quedan las BK_KEEP automaticas y las BK_KEEP_EV de otros motivos mas recientes
  local f na=0 ne=0
  while IFS= read -r f; do
    if [[ $f == *-auto.tar.gz ]]; then na=$(( na + 1 )); (( na > BK_KEEP )) && rm -f -- "$f"
    else ne=$(( ne + 1 )); (( ne > BK_KEEP_EV )) && rm -f -- "$f"; fi
  done < <(bk_files)
  find "$BK_DIR" -maxdepth 1 \( -name '*.part' -o -name '.stage-*' -o -name '.restore-*' \) -mmin +60 \
    -exec rm -rf {} + 2>/dev/null
  return 0
}

bk_auto() {   # copia automatica silenciosa (solo si algo cambio)
  [[ -z ${NO_AUTOBK:-} && $EUID -eq 0 && -d $BASE ]] || return 0
  bk_snap auto >/dev/null 2>&1
  return 0
}

bk_valid() {   # archivo  ->  0 si es una copia valida (formato conocido, rutas seguras); el motivo en MSG
  local f=$1 n sz list re='^vpspanel-backup(/[A-Za-z0-9._@+=,-]+)*/?$'
  MSG=''
  [[ -f $f && -r $f ]] || { MSG="No existe el archivo: $f"; return 1; }
  sz=$(stat -c %s "$f" 2>/dev/null)
  [[ $sz =~ ^[0-9]+$ ]] && (( sz > 0 && sz < 52428800 )) || { MSG="El archivo esta vacio o es demasiado grande."; return 1; }
  list=$(tar -tzf "$f" 2>/dev/null) || { MSG="No es una copia del panel (.tar.gz danado o de otro tipo)."; return 1; }
  while IFS= read -r n; do
    [[ $n =~ $re && $n != *..* ]] || { MSG="La copia tiene rutas no permitidas."; return 1; }
  done <<< "$list"
  # solo archivos normales y carpetas (sin enlaces ni dispositivos) y hasta 100 MB descomprimida
  tar -tvzf "$f" 2>/dev/null | awk '{ t = substr($1, 1, 1); if (t != "-" && t != "d") bad = 1; s += $3 }
                                    END { exit (bad || s > 104857600) }' \
    || { MSG="La copia tiene enlaces, archivos especiales o es demasiado grande."; return 1; }
  grep -qx 'vpspanel-backup/MANIFEST' <<< "$list" || { MSG="La copia no tiene MANIFEST."; return 1; }
  tar -xzOf "$f" vpspanel-backup/MANIFEST 2>/dev/null | grep -qx "format=$BK_FORMAT" \
    || { MSG="El formato de la copia no es compatible con esta version del panel."; return 1; }
  return 0
}

bk_extract() {   # archivo (ya validado)  ->  lo extrae en una carpeta temporal privada: BK_TMP
  local d
  BK_TMP=''
  mkdir -p "$BK_DIR" && chmod 700 "$BK_DIR" || return 1
  BK_TMP=$(mktemp -d "$BK_DIR/.restore-XXXXXX") || return 1
  if tar -xzf "$1" -C "$BK_TMP" --no-same-owner 2>/dev/null && [[ -f $BK_TMP/vpspanel-backup/MANIFEST ]]; then
    d=$BK_TMP/vpspanel-backup/base
    mkdir -p "$d" && touch "$d/users.db" "$d/v2ray.db" "$d/users.exp"
    return 0
  fi
  rm -rf "$BK_TMP"; BK_TMP=''; MSG="No se pudo extraer la copia."
  return 1
}

bk_show() {   # MANIFEST  ->  resumen de la copia
  local m=$1 t k pl='' first=1 l
  t=$(mf_get created "$m"); [[ $t =~ ^[0-9]+$ ]] || t=0
  field "FECHA:" "$(date -d "@$t" '+%d/%m/%Y %H:%M')"
  field "MOTIVO:" "$(mf_get reason "$m")"
  field "VPS:" "$(mf_get name "$m")  $(mf_get ip "$m")"
  field "VERSION:" "$(mf_get panel_version "$m")"
  field "CUENTAS:" "SSH $(mf_get ssh_users "$m")   V2RAY $(mf_get v2_users "$m")"
  for k in $(sed -n 's/^protocols=//p' "$m" | head -1 | tr -cd 'a-z '); do
    [[ -n ${INST[$k]:-} ]] && pl+="$(proto_label "$k") "
  done
  [[ -n $pl ]] || pl='ninguno'
  while IFS= read -r l; do
    if (( first )); then field "PROTOCOLOS:" "$l"; first=0; else printf ' %*s %s%s%s\n' "$FW" '' "$WHT" "$l" "$RST"; fi
  done < <(fold -s -w 38 <<< "$pl")
}

bk_cfg_fp() {   # huella de la configuracion (sin las bases de cuentas): si cambia al restaurar, se aplica
  local f
  {
    while IFS= read -r -d '' f; do
      f=${f#./}
      [[ $f =~ $BK_SKIP || $f =~ $BK_DBS ]] && continue
      printf '%s %s\n' "$f" "$(cat "$BASE/$f" 2>/dev/null | sha256sum | cut -c1-16)"
    done < <(cd "$BASE" && find . -type f -print0 2>/dev/null | LC_ALL=C sort -z)
    cat "$OVPN_DIR/ca.crt" "$OVPN_DIR/server.key" "$WG_CONF" 2>/dev/null | sha256sum
  } | sha256sum | cut -d' ' -f1
}

# Aplica una copia extraida. Configuracion: la de la copia. Cuentas: las de la copia (se crean las
# que faltan, con su contrasena, vencimiento y limite) + las actuales que no estan en ella. Nunca
# toca cuentas del sistema ni root. Luego aplica puertos, llaves y cuentas a lo que este instalado.
bk_apply() {   # carpeta_extraida  ->  RST_N (cuentas SSH restauradas) y RST_BAD (no restauradas)
  local w=$1 s=$1/vpspanel-backup f u p e l h a b k fp0 fp1 ban0 ban1
  local -A BH=()
  RST_N=0; RST_BAD=0
  fp0=$(bk_cfg_fp); ban0=$(cat "$BANNER" 2>/dev/null | sha256sum)
  # 1) configuracion de $BASE (las bases de cuentas y las secuencias se unen despues)
  while IFS= read -r -d '' f; do
    f=${f#./}
    [[ $f =~ $BK_SKIP || $f =~ $BK_DBS ]] && continue
    [[ $f == */* ]] && mkdir -p "$BASE/${f%/*}"
    cp -p -- "$s/base/$f" "$BASE/$f.tmp" && mv -f -- "$BASE/$f.tmp" "$BASE/$f"
  done < <(cd "$s/base" && find . -type f -print0 2>/dev/null)
  [[ -d $BASE/wireguard ]] && chmod 700 "$BASE/wireguard"
  # 2) cuentas SSH de la copia
  if [[ -s $s/extra/shadow ]]; then
    while IFS=: read -r u h; do [[ $u =~ ^[a-z_][a-z0-9_-]*$ && -n $h ]] && BH[$u]=$h; done < "$s/extra/shadow"
  fi
  : > "$w/acc.ssh"
  while IFS='|' read -r u p e l; do
    [[ -n $u ]] || continue
    if ! [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ && $e =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && ${l:-1} =~ ^[0-9]+$ ]]; then
      RST_BAD=$(( RST_BAD + 1 )); continue
    fi
    acct_make "$u" "$p" "$e" "${BH[$u]:-}"
    case $? in
      0) printf '%s|%s|%s|%s\n' "$u" "$p" "$e" "${l:-1}" >> "$w/acc.ssh"; RST_N=$(( RST_N + 1 )) ;;
      2) warn "$u existe y no es una cuenta del panel: no se toca."; RST_BAD=$(( RST_BAD + 1 )) ;;
      *) warn "No se pudo crear la cuenta $u."; RST_BAD=$(( RST_BAD + 1 )) ;;
    esac
  done < "$s/base/users.db"
  # 3) bases de cuentas: las de la copia + las actuales que no estan en ella
  db_filter "$USERDB" awk -F'|' 'FILENAME == ARGV[1] { a[$1]; print; next } !($1 in a)' "$w/acc.ssh" - \
    || { err "No se pudo escribir users.db"; return 1; }
  awk -F'|' 'FILENAME == ARGV[1] { a[$1]; next } ($1 in a) && $2 ~ /^[0-9]+$/' "$w/acc.ssh" "$s/base/users.exp" > "$w/acc.px"
  db_filter "$PX_DB" awk -F'|' 'FILENAME == ARGV[1] { a[$1]; next } FILENAME == ARGV[2] { print; next } !($1 in a)' \
    "$w/acc.ssh" "$w/acc.px" -
  awk -F'|' 'NF >= 3 && $1 ~ /^[a-z_][a-z0-9_-]*$/ && $2 ~ /^[0-9a-fA-F-]+$/ && $3 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/' \
    "$s/base/v2ray.db" > "$w/acc.v2"
  db_filter "$V2DB" awk -F'|' 'FILENAME == ARGV[1] { a[$1]; print; next } !($1 in a)' "$w/acc.v2" - \
    || { err "No se pudo escribir v2ray.db"; return 1; }
  for f in quick.seq test.seq; do               # las secuencias nunca retroceden (no se repiten nombres)
    a=$(cat "$BASE/$f" 2>/dev/null); b=$(cat "$s/base/$f" 2>/dev/null)
    [[ $a =~ ^[0-9]+$ ]] || a=0; [[ $b =~ ^[0-9]+$ ]] || b=0
    (( 10#$b > 10#$a )) && printf '%s\n' "$(( 10#$b ))" > "$BASE/$f"
  done
  # 4) llaves de OpenVPN y WireGuard: los archivos que ya tienen los clientes siguen sirviendo
  if [[ -s $s/extra/openvpn/ca.crt && -s $s/extra/openvpn/server.key ]]; then
    mkdir -p "$OVPN_DIR" && chmod 700 "$OVPN_DIR"
    for f in ca.crt ca.key ca.srl server.crt server.key; do
      [[ -f $s/extra/openvpn/$f ]] && install -m 600 "$s/extra/openvpn/$f" "$OVPN_DIR/$f"
    done
    chmod 644 "$OVPN_DIR/ca.crt" "$OVPN_DIR/server.crt" 2>/dev/null
  fi
  if [[ -s $s/extra/wireguard/wg0.conf ]]; then
    if [[ -f $WG_CONF ]]; then
      install -m 600 "$s/extra/wireguard/wg0.conf" "$WG_CONF.tmp" && mv -f "$WG_CONF.tmp" "$WG_CONF"
    else                                        # WireGuard sin instalar: lo recupera al instalarlo
      mkdir -p "$BASE/wireguard" && chmod 700 "$BASE/wireguard"
      install -m 600 "$s/extra/wireguard/wg0.conf" "$BASE/wireguard/wg0.conf.bak"
    fi
  fi
  # 5) lo instalado toma los puertos, banner, llaves y cuentas restaurados (sin arrancar lo detenido)
  load_ports
  fp1=$(bk_cfg_fp); ban1=$(cat "$BANNER" 2>/dev/null | sha256sum)
  if [[ -f $BASE/.prep ]]; then
    [[ -f $V2CFG ]] && v2_write_config
    if [[ $fp0 != "$fp1" ]]; then
      info "Aplicando la configuracion a los servicios..."
      [[ $ban0 != "$ban1" ]] && cfg_ssh
      for k in dropbear ws socks wsepro squid ssl v2ray badvpn openvpn wireguard slowdns udp psiphon; do apply_proto "$k"; done
    elif [[ -f $V2CFG ]] && v2_test; then
      systemctl try-restart v2ray >/dev/null 2>&1
    fi
    fw_sync
  fi
  return 0
}

bk_restore() {   # archivo [si]  ->  restaura una copia (pide confirmacion salvo "si"); 3 = cancelado
  local f=$1 yes=${2:-} c='' rc
  bk_valid "$f" || { err "$MSG"; return 1; }
  bk_extract "$f" || { err "$MSG"; return 1; }
  bk_show "$BK_TMP/vpspanel-backup/MANIFEST"
  line_dash
  info "Vuelven las cuentas de la copia (clave, vencimiento"
  info "y limite); las actuales que no esten se conservan."
  info "Antes se guarda el estado actual para deshacerlo."
  if [[ $yes != si ]]; then
    rd "ESCRIBE SI PARA RESTAURAR: " c
    [[ $c == SI ]] || { rm -rf "$BK_TMP"; return 3; }
  fi
  log_use copias "Restaurar ${f##*/}"
  if ! bk_snap antes-de-restaurar; then
    rm -rf "$BK_TMP"; err "No se pudo guardar el estado actual: no se restauro nada."; return 1
  fi
  [[ -n $BK_LAST ]] && ok "Estado actual guardado en ${BK_LAST##*/}"
  bk_apply "$BK_TMP"; rc=$?
  rm -rf "$BK_TMP"
  if (( rc != 0 )); then err "La restauracion no termino."; info "Estado anterior: ${BK_LAST:-$BK_DIR}"; return 1; fi
  ok "Copia restaurada: $RST_N cuentas SSH recuperadas."
  info "Total en el panel: $(grep -c '^[^|]' "$USERDB") SSH y $(grep -c '^[^|]' "$V2DB") V2Ray."
  (( RST_BAD )) && warn "$RST_BAD cuentas no se restauraron (detalle arriba)."
  bk_auto
  return 0
}

bk_pick() {   # lista las copias guardadas y deja la elegida en PICK; 3 = volver
  local f t i=0 sel m num=$'N\xc2\xb0'
  local -a L=()
  PICK=''
  mapfile -t L < <(bk_files | head -n 20)
  (( ${#L[@]} )) || { warn "Todavia no hay copias guardadas."; return 1; }
  m=$(mktemp)
  printf '%s  %s %-17s%-21s%5s%5s%s\n' "$LYE" "$num" FECHA MOTIVO SSH V2R "$RST"
  line_dash
  for f in "${L[@]}"; do
    i=$(( i + 1 ))
    tar -xzOf "$f" vpspanel-backup/MANIFEST > "$m" 2>/dev/null
    t=$(mf_get created "$m"); [[ $t =~ ^[0-9]+$ ]] || t=0
    printf '%s%3d)%s %s%-17s%s%-21s%s%5s%5s%s\n' "$GRN" "$i" "$RST" "$WHT" "$(date -d "@$t" '+%d/%m/%Y %H:%M')" \
      "$GRY" "$(mf_get reason "$m" | cut -c1-20)" "$GRN" "$(mf_get ssh_users "$m")" "$(mf_get v2_users "$m")" "$RST"
  done
  rm -f "$m"
  menu_end
  rd "NUMERO DE LA COPIA: " sel || return 3
  sel=${sel//[[:space:]]/}
  [[ $sel =~ ^[0-9]+$ ]] || return 3
  sel=$(( 10#$sel ))
  (( sel >= 1 && sel <= ${#L[@]} )) || return 3
  PICK=${L[sel-1]}
}

bk_summary() {   # cabecera de COPIAS DE SEGURIDAD
  local f n m t
  n=$(bk_files | wc -l)
  field "CARPETA:" "$BK_DIR"
  field "COPIAS:" "$n guardadas (se crean solas cuando algo cambia)"
  f=$(bk_files | head -1)
  if [[ -n $f ]]; then
    m=$(mktemp); tar -xzOf "$f" vpspanel-backup/MANIFEST > "$m" 2>/dev/null
    t=$(mf_get created "$m"); [[ $t =~ ^[0-9]+$ ]] || t=0
    field "ULTIMA:" "$(date -d "@$t" '+%d/%m/%Y %H:%M')  SSH $(mf_get ssh_users "$m")  V2RAY $(mf_get v2_users "$m")"
    rm -f "$m"
  fi
}

menu_backup() {
  local o path='' rc
  while :; do
    sub_header "COPIAS DE SEGURIDAD"
    bk_summary
    line_eq
    item 1 "CREAR UNA COPIA AHORA"
    item 2 "RESTAURAR UNA COPIA GUARDADA" "$GRN"
    item 3 "RESTAURAR DESDE UN ARCHIVO (OTRO VPS)"
    line_dash
    item 4 "VOLVER A LA VERSION ANTERIOR DEL PANEL"
    menu_end
    ask o || return
    case $o in
      1) sub_header "CREAR UNA COPIA"
         if bk_snap manual && [[ -n $BK_LAST ]]; then
           ok "Copia creada: $BK_LAST"
           info "Descargala por SFTP para guardarla fuera del VPS."
         else
           err "No se pudo crear la copia."
         fi ;;
      2) sub_header "RESTAURAR UNA COPIA"
         bk_pick || { rc=$?; (( rc == 3 )) && continue; pause; continue; }
         sub_header "RESTAURAR UNA COPIA"
         bk_restore "$PICK"; [[ $? == 3 ]] && continue ;;
      3) sub_header "RESTAURAR DESDE UN ARCHIVO"
         echo " Sube el archivo .tar.gz al VPS (SFTP) y escribe su ruta,"
         echo " por ejemplo: /root/vpspanel-20261114-031500-manual.tar.gz"
         echo
         rd "RUTA DEL ARCHIVO: " path || continue
         [[ -n $path && $path != 0 ]] || continue
         sub_header "RESTAURAR DESDE UN ARCHIVO"
         bk_restore "$path"; [[ $? == 3 ]] && continue ;;
      4) sub_header "VERSION ANTERIOR DEL PANEL"
         panel_rollback; rc=$?
         (( rc == 3 )) && continue
         if (( rc == 0 )); then pause; exec "$PANEL_BIN"; fi ;;
      0) return ;;
      *) continue ;;
    esac
    pause
  done
}

# ---- Al abrir el panel: recuperacion tras reinstalar y revision de la base de cuentas ------
data_recover() {   # panel sin datos (instalado de nuevo) y con copias: recupera la ultima valida
  local f=''
  REC_MAN=''
  [[ -s $NAME_F || -s $USERDB || -s $V2DB ]] && return 1          # el panel ya tiene datos
  [[ -d $BK_DIR ]] || return 1
  while IFS= read -r f; do bk_valid "$f" && break; f=''; done < <(bk_files)
  [[ -n $f ]] || return 1
  bk_extract "$f" || return 1
  log_use copias "Recuperacion automatica desde ${f##*/}"
  info "Copia de seguridad encontrada: recuperando datos..."
  if ! bk_apply "$BK_TMP"; then
    rm -rf "$BK_TMP"; err "No se pudo recuperar ${f##*/}"; return 1
  fi
  REC_MAN=$(mktemp)
  cp "$BK_TMP/vpspanel-backup/MANIFEST" "$REC_MAN"
  rm -rf "$BK_TMP"
  ok "Recuperadas $RST_N cuentas SSH y $(grep -c '^[^|]' "$V2DB") V2Ray."
  info "Copia: ${f##*/}"
  logln "recuperacion automatica: ${f##*/} ($RST_N cuentas SSH)"
  return 0
}

reinstall_protos() {   # claves...  ->  instala esos protocolos con los puertos y llaves recuperados
  local k n=0
  local -a bad=()
  ensure_base || return 1
  [[ -s $BASE/slowdns/ns ]] && SLOWDNS_NS=$(head -n1 "$BASE/slowdns/ns")   # sin volver a preguntar el NS
  for k in dropbear ssl badvpn ws socks wsepro squid v2ray udp slowdns openvpn wireguard psiphon; do
    [[ " $* " == *" $k "* ]] || continue
    n=$(( n + 1 ))
    printf '\n %s[%d/%d]%s %s%s%s\n' "$YEL" "$n" "$#" "$RST" "$WHT" "$(proto_label "$k")" "$RST"
    "${INST[$k]}" || bad+=("$(proto_label "$k")")
  done
  fw_sync
  echo
  if (( ${#bad[@]} )); then warn "Con fallos: ${bad[*]}"; info "Reparalos en PREPARACION DEL SISTEMA."
  else ok "Protocolos instalados con la configuracion recuperada"; fi
}

data_check() {   # base de cuentas y cuentas del sistema en orden; si no, ofrece repararlo
  local f='' u p e l t c='' now today tmp
  local -a lost=() gone=() glines=()
  local -A SYS=() PXT=() BH=()
  now=$(date +%s); today=$(date -u +%F)
  while IFS=: read -r u _; do SYS[$u]=1; done < <(getent passwd)
  f=$(bk_files | head -1)
  [[ -n $f ]] && ! bk_valid "$f" && f=''
  # a) users.db quedo vacia, pero siguen en el servidor cuentas del panel que estan en la ultima copia
  if [[ -n $f ]] && ! grep -q '^[^|]' "$USERDB" 2>/dev/null; then
    while IFS='|' read -r u p e l; do
      [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ && -n ${SYS[$u]:-} ]] && panel_acct "$u" && lost+=("$u")
    done < <(tar -xzOf "$f" vpspanel-backup/base/users.db 2>/dev/null)
  fi
  # b) cuentas vigentes de users.db que no existen en el sistema (sistema reinstalado o borradas a mano)
  if [[ -s $PX_DB ]]; then while IFS='|' read -r u t; do PXT[$u]=$t; done < "$PX_DB"; fi
  while IFS='|' read -r u p e l; do
    [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ && $e =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && -z ${SYS[$u]:-} ]] || continue
    [[ $e > $today ]] || continue                                  # vencida: vps-cleanup la quita sola
    t=${PXT[$u]:-}; [[ $t =~ ^[0-9]+$ ]] && (( t <= now )) && continue   # prueba ya vencida
    gone+=("$u"); glines+=("$u|$p|$e")
  done < "$USERDB"
  (( ${#lost[@]} + ${#gone[@]} )) || return 0
  cls
  title "REVISION DE CUENTAS" "$YEL"
  if (( ${#lost[@]} )); then
    warn "La lista de cuentas del panel esta vacia, pero"
    warn "${#lost[@]} cuentas siguen en el servidor. Se pueden"
    warn "recuperar desde la ultima copia:"
    names_grid 9 "${lost[@]}"
    rd "RECUPERAR LA LISTA DESDE LA COPIA? (S/n): " c
    if [[ $c != [nN]* ]]; then
      tmp=$(mktemp)
      tar -xzOf "$f" vpspanel-backup/base/users.db 2>/dev/null |
        awk -F'|' -v list="|$(IFS='|'; printf '%s' "${lost[*]}")|" 'index(list, "|" $1 "|") > 0' > "$tmp"
      db_filter "$USERDB" awk -F'|' 'FILENAME == ARGV[1] { a[$1]; print; next } !($1 in a)' "$tmp" -
      tar -xzOf "$f" vpspanel-backup/base/users.exp 2>/dev/null |
        awk -F'|' 'FILENAME == ARGV[1] { a[$1]; next } ($1 in a)' "$tmp" - > "$tmp.px"
      db_filter "$PX_DB" awk -F'|' 'FILENAME == ARGV[1] { a[$1]; print; next } !($1 in a)' "$tmp.px" -
      rm -f "$tmp" "$tmp.px"
      ok "Lista recuperada: $(grep -c '^[^|]' "$USERDB") cuentas"
    fi
    echo
  fi
  if (( ${#gone[@]} )); then
    warn "${#gone[@]} cuentas del panel no existen en el servidor"
    warn "(sistema reinstalado o borradas fuera del panel):"
    names_grid 9 "${gone[@]}"
    echo " S = volver a crearlas (misma contrasena, vencimiento y limite)"
    echo " N = quitarlas de la lista del panel"
    rd "VOLVER A CREARLAS? (S/n): " c
    if [[ $c == [nN]* ]]; then
      t=$(IFS='|'; printf '%s' "${gone[*]}")
      db_filter "$USERDB" awk -F'|' -v list="|$t|" 'index(list, "|" $1 "|") == 0'
      [[ -s $PX_DB ]] && db_filter "$PX_DB" awk -F'|' -v list="|$t|" 'index(list, "|" $1 "|") == 0'
      ok "${#gone[@]} cuentas quitadas de la lista"
    else
      if [[ -n $f ]]; then   # hash de la ultima copia: la contrasena queda identica a la original
        while IFS=: read -r u t; do [[ -n $u && -n $t ]] && BH[$u]=$t; done < <(tar -xzOf "$f" vpspanel-backup/extra/shadow 2>/dev/null)
      fi
      c=0
      for t in "${glines[@]}"; do
        IFS='|' read -r u p e <<< "$t"
        if acct_make "$u" "$p" "$e" "${BH[$u]:-}"; then c=$(( c + 1 )); else warn "No se pudo crear $u"; fi
      done
      ok "$c cuentas creadas de nuevo"
    fi
  fi
  pause
}

data_startup() {   # al abrir el panel: recuperacion tras reinstalar o revision de la base de cuentas
  local o='' k pl=''
  if data_recover; then
    if [[ -t 0 && -t 1 ]]; then
      cls
      title "RECUPERACION AUTOMATICA" "$GRN"
      echo " El panel estaba sin datos y habia una copia de seguridad: se"
      echo " recuperaron los usuarios (con su contrasena, vencimiento y"
      echo " limite), los puertos, el nombre, las llaves y los clientes."
      echo
      bk_show "$REC_MAN"
      for k in $(sed -n 's/^protocols=//p' "$REC_MAN" | head -1 | tr -cd 'a-z '); do
        [[ -n ${INST[$k]:-} ]] && ! proto_installed "$k" && pl+="$k "
      done
      line_eq
      if [[ -n $pl ]]; then
        echo " Los protocolos que tenia el panel no estan instalados ahora."
        item 1 "INSTALARLOS CON LA MISMA CONFIGURACION" "$GRN"
        item 0 "CONTINUAR SIN INSTALAR"
        line_eq
        ask o && [[ $o == 1 ]] && { reinstall_protos $pl; pause; }
      else
        pause
      fi
    fi
    rm -f "$REC_MAN"
    return 0
  fi
  [[ -t 0 && -t 1 ]] && data_check
  return 0
}

# ------------------------------ Actualizar el panel -------------------
# Descarga el instalador nuevo (solo https) o lo toma de un archivo del VPS, comprueba que sea un
# script valido (no una pagina web, sintaxis correcta, carga sin errores), guarda una copia de los
# datos y la version actual (vps-rollback), lo instala de una sola vez y abre la version nueva, que
# reinstala sus herramientas sola. Usuarios, cuentas y configuracion no se tocan.
ver_of() { sed -n 's/^VERSION=\([0-9][0-9.]*\).*/\1/p' "$1" 2>/dev/null | head -1; }
ver_lt() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1) == "$1" ]]; }   # a < b

script_save() {   # [archivo]  ->  guarda esa version del panel para poder volver a ella (vps-rollback)
  local src=${1:-$PANEL_BIN} v dst
  [[ -s $src ]] || return 0
  mkdir -p "$SCRIPT_BK" && chmod 700 "$BK_DIR" "$SCRIPT_BK" || return 1
  v=$(ver_of "$src")
  dst=$SCRIPT_BK/vpspanel-${v:-x}-$(sha256sum "$src" | cut -c1-12).sh
  if [[ -f $dst ]]; then touch "$dst"
  else cp -- "$src" "$dst.tmp" && chmod 600 "$dst.tmp" && mv -f "$dst.tmp" "$dst" || return 1; fi
  ls -1t "$SCRIPT_BK"/vpspanel-*.sh 2>/dev/null | tail -n +6 | xargs -r rm -f --   # se guardan las 5 ultimas
  return 0
}

upd_fetch() {   # enlace|ruta destino
  local src=$1 dst=$2
  case $src in
    https://*)
      run "Descargando el instalador" curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 2 --connect-timeout 15 --max-time 180 --max-filesize 10485760 -o "$dst" "$src" ;;
    http://*)
      err "El enlace debe ser https://"; info "Una descarga http sin cifrar se puede alterar."; return 1 ;;
    *)
      [[ -f $src ]] || { err "No es un enlace https:// ni un archivo de este VPS: $src"; return 1; }
      cp -- "$src" "$dst" ;;
  esac
}

upd_check() {   # archivo  ->  0 si es un instalador valido; version en NEWV, motivo en MSG
  local f=$1 out
  NEWV=''; MSG=''
  [[ -s $f ]] || { MSG="El archivo descargado esta vacio."; return 1; }
  if head -c 4096 "$f" | grep -qiE '<!doctype html|<html|<head>'; then
    MSG="El enlace abre una pagina web, no el script. Usa el enlace directo (RAW) del archivo."; return 1
  fi
  head -n1 "$f" | grep -qE '^#!.*(bash|sh)' || { MSG="El archivo no es un script de bash (no empieza con #!)."; return 1; }
  if ! out=$(bash -n "$f" 2>&1); then MSG="El script tiene errores de sintaxis: $(head -n2 <<< "$out")"; return 1; fi
  NEWV=$(ver_of "$f")
  if grep -q 'VPSPANEL_SOURCE_ONLY' "$f"; then   # carga de prueba: define todo sin abrir el menu
    if ! out=$(cd / && VPSPANEL_SOURCE_ONLY=1 timeout 30 bash -c 'source "$1"' _ "$f" 2>&1 </dev/null); then
      MSG="El script nuevo falla al cargar: $(tail -n2 <<< "$out")"; return 1
    fi
  fi
  return 0
}

panel_update() {   # [enlace|archivo]  ->  0 = actualizado (falta abrir la version nueva); 3 = cancelado
  local src=${1:-} def tmp c='' sum need='' cur
  cur=$(ver_of "$PANEL_BIN"); cur=${cur:-$VERSION}    # la instalada (otra sesion pudo actualizar ya)
  def=${UPDATE_URL:-$(head -n1 "$BASE/update.url" 2>/dev/null)}
  if [[ -z $src ]]; then
    field "VERSION:" "$cur (instalada)"
    [[ -n $def ]] && field "ENLACE:" "${def:0:38}$( (( ${#def} > 38 )) && echo ...)"
    echo
    echo " Pega el enlace RAW del instalador nuevo (https://...) o la"
    echo " ruta de un archivo del VPS. Usuarios y configuracion se"
    echo " conservan; antes se guarda una copia de todo."
    [[ -n $def ]] && echo " ENTER = usar el mismo enlace de la ultima vez."
    echo
    rd "ENLACE: " src || return 3
    src=${src//[[:space:]]/}
    [[ -z $src ]] && src=$def
    [[ -n $src && $src != 0 ]] || return 3
  fi
  log_use actualizacion "Actualizar desde $src"
  tmp=$(mktemp) || return 1
  if ! upd_fetch "$src" "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! upd_check "$tmp"; then err "$MSG"; logln "rechazado: $MSG"; rm -f "$tmp"; return 1; fi
  sum=$(sha256sum "$tmp" | cut -d' ' -f1)
  field "NUEVA:" "version ${NEWV:-desconocida}"
  printf ' %sSHA256:%s\n %s%s%s\n' "$BLU" "$RST" "$GRY" "$sum" "$RST"   # para compararlo con el publicado
  if cmp -s "$tmp" "$PANEL_BIN"; then
    rm -f "$tmp"; ok "Ya tienes instalada esta misma version."; return 2
  fi
  if ! grep -q 'VPSPANEL_ACTIVE' "$tmp"; then warn "El archivo no parece ser VPS PANEL."; need=1
  elif [[ -z $NEWV ]]; then warn "No se pudo leer la version del archivo nuevo."; need=1
  elif ver_lt "$NEWV" "$cur"; then warn "Es una version ANTERIOR a la instalada ($cur)."; need=1
  elif [[ $NEWV == "$cur" ]]; then info "Misma version ($cur) con cambios: se reinstala."
  fi
  if [[ -n $need ]]; then
    if [[ ! -t 0 ]]; then rm -f "$tmp"; err "Sin confirmacion no se instala (usa el menu)."; return 1; fi
    rd "ESCRIBE SI PARA INSTALARLA DE TODOS MODOS: " c
    [[ $c == SI ]] || { rm -f "$tmp"; return 3; }
  elif [[ -t 0 ]]; then
    rd "ACTUALIZAR AHORA? (S/n): " c
    [[ $c == [nN]* ]] && { rm -f "$tmp"; return 3; }
  fi
  # 1) copia de los datos y de la version actual: sin ellas no se actualiza
  if ! bk_snap antes-de-actualizar; then rm -f "$tmp"; err "No se pudo crear la copia de seguridad: no se actualiza."; return 1; fi
  [[ -n $BK_LAST ]] && ok "Copia de seguridad: ${BK_LAST##*/}"
  if ! script_save "$PANEL_BIN"; then rm -f "$tmp"; err "No se pudo guardar la version actual: no se actualiza."; return 1; fi
  install_rollback 2>/dev/null
  # 2) se instala de una sola vez (esta sesion sigue con la version anterior hasta reabrir)
  if ! { install -m 755 "$tmp" "$PANEL_BIN.new" && mv -f "$PANEL_BIN.new" "$PANEL_BIN"; }; then
    rm -f "$PANEL_BIN.new" "$tmp"; err "No se pudo instalar la version nueva (sigue la anterior)."; return 1
  fi
  rm -f "$tmp"
  [[ $src == https://* ]] && printf '%s\n' "$src" > "$BASE/update.url"
  logln "actualizado: $cur -> ${NEWV:-?} (sha256 $sum) desde $src"
  ok "Panel actualizado: $cur -> ${NEWV:-?}"
  info "Si algo falla: vps-rollback vuelve a la anterior."
  return 0
}

panel_rollback() {   # vuelve a la version anterior del panel (vps-rollback); 3 = cancelado
  local c=''
  [[ -x /usr/local/bin/vps-rollback ]] || install_rollback
  /usr/local/bin/vps-rollback --list
  echo
  info "Usuarios y configuracion no cambian."
  rd "VOLVER A LA VERSION ANTERIOR? (s/N): " c
  [[ $c == [sS]* ]] || return 3
  /usr/local/bin/vps-rollback
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
    echo " Asi se vera el titulo del panel:"
    echo
    brand "$name"
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
# Se marca como hecha solo si todo salio bien: si falla (sin internet, apt ocupado...),
# se vuelve a intentar en la siguiente instalacion en lugar de dejar el sistema a medias.
ssh_ok() {   # sshd acepta contrasenas, reenvio TCP y negocia con las librerias SSH de las apps
  local t k
  t=$(sshd -T 2>/dev/null)
  [[ -n $t ]] || return 0                                   # no se puede comprobar
  grep -qx 'passwordauthentication yes' <<< "$t" || return 1
  grep -qx 'allowtcpforwarding no' <<< "$t" && return 1
  for k in rsa ecdsa ed25519; do
    [[ -s /etc/ssh/ssh_host_${k}_key ]] && grep -qx "hostkey /etc/ssh/ssh_host_${k}_key" <<< "$t" || return 1
  done
  if ssh -Q key 2>/dev/null | grep -qx ssh-rsa; then
    grep '^hostkeyalgorithms ' <<< "$t" | grep -qE '[ ,]ssh-rsa(,|$)' || return 1
  fi
  if ssh -Q kex 2>/dev/null | grep -qx diffie-hellman-group14-sha1; then
    grep '^kexalgorithms ' <<< "$t" | grep -qE '[ ,]diffie-hellman-group14-sha1(,|$)' || return 1
  fi
  return 0
}

ensure_base() {
  if [[ $(cat "$BASE/.prep" 2>/dev/null) == "$PREP_V" ]]; then
    ssh_ok || { log_use sistema "Configurar SSH"; cfg_ssh; }        # algo la cambio despues: se repara
    return 0
  fi
  local keep=$LOG rc=0
  log_use sistema "Preparacion del sistema"
  info "Preparando el sistema..."
  if apt_update && apt_i curl wget jq git unzip tar openssl iptables ca-certificates cron procps iproute2 python3 psmisc; then
    grep -qx /bin/false /etc/shells || echo /bin/false >> /etc/shells
    install_helpers
    cfg_ssh || warn "SSH: se mantiene la configuracion anterior."
    fw_sync
    echo "$PREP_V" > "$BASE/.prep"
  else
    err "No se pudo preparar el sistema. Se reintentara en la proxima instalacion."
    rc=1
  fi
  LOG=$keep
  return $rc
}

# ------------------------------ UDP Custom ----------------------------
# Instalacion 100% automatica: descarga el binario, lo verifica, crea la
# configuracion y el servicio. No hay que copiar ni pegar ningun enlace.
inst_udp() {
  log_use udp "Instalar UDP Custom"
  ensure_base || return 1
  need_port udp "$PORT_UDP" udp || return 1
  case $(uname -m) in
    x86_64|amd64) ;;
    *) err "UDP Custom solo tiene binario para x86_64 (este servidor es $(uname -m))"; return 1 ;;
  esac

  local dir=/etc/udp-custom tmp url=${UDPCUSTOM_URL:-$UDP_BIN_URL} sum
  if [[ -n ${FORCE:-} || ! -x $dir/udp-custom ]]; then
    tmp=$(mktemp)
    if ! run "Descargando UDP Custom" \
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
  fi
  conf_udp || return 1
  [[ -n ${NOSTART:-} ]] || info "En HTTP Custom: modo UDP Custom, host $(get_host), puerto $PORT_UDP"
}

udp_excl() {   # puertos UDP que udp-custom NO debe capturar (DNS, SlowDNS, OpenVPN, WireGuard)
  local -a e=(53 "$PORT_SLOWDNS" 1194 51820)
  proto_installed openvpn && [[ $(ovpn_proto) == udp ]] && e+=("$(ovpn_port)")
  proto_installed wireguard && e+=("$(wg_port)")
  printf '%s\n' "${e[@]}" | sort -un | paste -sd, -
}

conf_udp() {   # configuracion y servicio de UDP Custom con el puerto actual
  local dir=/etc/udp-custom
  cat > "$dir/config.json" <<EOF
{
  "listen": ":$PORT_UDP",
  "stream_buffer": 33554432,
  "receive_buffer": 83886080,
  "auth": { "mode": "passwords" }
}
EOF
  # udp-custom crea reglas DNAT para casi todos los puertos UDP y no las borra al detenerse:
  # se limpian antes de cada inicio y al detenerlo, asi no capturan puertos de otros servicios.
  mkunit udp-custom "UDP Custom" "$dir/udp-custom server -exclude $(udp_excl)" \
    "WorkingDirectory=$dir
ExecStartPre=-/usr/local/bin/vps-fw udpclean $PORT_UDP
ExecStopPost=-/usr/local/bin/vps-fw udpclean $PORT_UDP"
  fw_sync
  verify udp "UDP Custom"
}

show_ports_plan() {
  section "PUERTOS A USAR"
  cols "1:$(pcell DROPBEAR "$PORT_DROPBEAR")"  "21:$(pcell SSL "$PORT_SSL")"
  cols "1:$(pcell WEBSOCKET "$PORT_WS")"       "21:$(pcell SQUID "$PORT_SQUID")"
  cols "1:$(pcell V2RAY "$PORT_V2RAY")"        "21:$(pcell BADVPN "$PORT_BADVPN")"
  cols "1:$(pcell UDPCUSTOM "$PORT_UDP")"      "21:$(pcell "SOCKS PY" "$PORT_SOCKS")"
  cols "1:$(pcell WS-EPRO "$PORT_WSEPRO")"
}

install_all() {
  ensure_base || { err "Sin la preparacion del sistema no se puede instalar. Revisa el error de arriba."; return 1; }
  local step n=0 total a
  local -a steps=("inst_dropbear:Dropbear" "inst_ssl:SSL (stunnel)" "inst_badvpn:BadVPN UDPGW"
                  "inst_ws:WebSocket" "inst_socks:SOCKS Python" "inst_wsepro:WS-ePro" "inst_squid:Squid"
                  "inst_v2ray:V2Ray" "inst_udp:UDP Custom") okl=() bad=()
  [[ -n ${SLOWDNS_NS:-} ]] && steps+=("inst_slowdns:SlowDNS")
  total=${#steps[@]}
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
  for step in "${steps[@]}"; do
    n=$(( n + 1 ))
    printf '\n %s[%d/%d]%s %s%s%s\n' "$YEL" "$n" "$total" "$RST" "$WHT" "${step#*:}" "$RST"
    if "${step%%:*}"; then okl+=("${step#*:}")
    else bad+=("${step#*:}"); warn "Fallo ${step#*:}. Se continua con el resto."; fi
  done
  echo
  cfg_bbr
  echo
  if (( ${#bad[@]} == 0 )); then
    ok "Instalacion completa: $total de $total protocolos funcionando. Abre el panel con: $(panel_cmd)"
  else
    warn "Funcionando ${#okl[@]} de $total. Con fallos: $(IFS=,; echo "${bad[*]}" | sed 's/,/, /g')"
    info "El error de cada uno esta arriba y en $LOG_DIR/. Puedes repararlos desde"
    info "PREPARACION DEL SISTEMA > (protocolo) > REPARAR / REINSTALAR."
  fi
}

# --------------------------- Cuentas SSH / Dropbear -------------------
show_ssh_info() { # usuario clave expira limite [texto del vencimiento] [titulo]
  local FW=24   # etiquetas mas anchas en esta pantalla
  cls
  title "${6:-USUARIO CREADO CON EXITO!}" "$GRN"
  field "IP:" "$IP" "$PNK"
  [[ -s $DOMAIN_F ]] && field "DOMINIO:" "$(get_host)"
  field "NOMBRE DE USUARIO:" "$1"
  field "CONTRASENA DE USUARIO:" "$2"
  field "CONEXIONES:" "$4"
  field "EXPIRA EN:" "${5:-${3:8:2}/${3:5:2}/${3:0:4}}"
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
  local u p e l n tot=0 sess
  sess=$(/usr/local/bin/vps-sessions 2>/dev/null)
  printf '%s %-20s %s%s\n' "$LYE" USUARIO CONEXIONES "$RST"
  line_dash
  while IFS='|' read -r u p e l; do
    [[ -n $u ]] || continue
    n=$(awk -v u="$u" '$1==u' <<< "$sess" | wc -l)
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
    item 4 "ELIMINAR USUARIOS VENCIDOS"
    line_dash
    item 5 "DETALLES DE TODOS USUARIOS" "$GRN"
    item 6 "MONITOR DE USUARIOS CONECTADOS"
    line_dash
    item 7 "CAMBIAR CONTRASENA"
    item 8 "ELIMINAR TODOS LOS USUARIOS" "$RED"
    menu_end VOLVER "$BTN_REDW"
    ask o u || return
    case $o in
      1) ssh_create;                                  [[ $? == 3 ]] && continue ;;
      2) sub_header "REMOVER USUARIO";                ssh_delete; [[ $? == 3 ]] && continue ;;
      3) sub_header "RENOVAR USUARIO";                ssh_renew;  [[ $? == 3 ]] && continue ;;
      4) sub_header "ELIMINAR USUARIOS VENCIDOS";     /usr/local/bin/vps-cleanup && ok "Usuarios vencidos eliminados" ;;
      5) sub_header "DETALLES DE TODOS USUARIOS";     ssh_list ;;
      6) sub_header "MONITOR DE USUARIOS CONECTADOS"; ssh_online ;;
      7) sub_header "CAMBIAR CONTRASENA";             ssh_passwd ;;
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
  db_add "$V2DB" "$n|$id|$exp" || { err "No se pudo guardar la cuenta en v2ray.db"; return 1; }
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

proto_installed() {
  case $1 in
    openvpn)   [[ -n $(ovpn_conf_file) ]] ;;
    wireguard) [[ -f $WG_CONF ]] ;;
    *)         systemctl cat "${SVC[$1]}" >/dev/null 2>&1 ;;
  esac
}

save_ports() {
  local k
  {
    for k in "${PORT_KEYS[@]}"; do echo "${PVAR[$k]}=$(pget "$k")"; done
    echo "V2PATH=$V2PATH"
  } > "$BASE/ports.conf"
}

load_ports() {   # lee /etc/vpspanel/ports.conf validando cada linea
  local l k v
  if [[ -f $BASE/ports.conf ]]; then
    while IFS= read -r l; do
      k=${l%%=*}; v=${l#*=}
      case $k in
        PORT_DROPBEAR|PORT_SSL|PORT_BADVPN|PORT_WS|PORT_SQUID|PORT_V2RAY|PORT_UDP|PORT_SLOWDNS|\
        PORT_SOCKS|PORT_WSEPRO|PORT_OVPN|PORT_WG|PORT_PSIPHON)
          if [[ $v =~ ^[0-9]{1,5}$ ]] && (( 10#$v >= 1 && 10#$v <= 65535 )); then
            printf -v "$k" '%s' "$(( 10#$v ))"
          fi ;;
        V2PATH) [[ $v =~ ^/[A-Za-z0-9._~/-]{1,40}$ ]] && V2PATH=$v ;;
      esac
    done < "$BASE/ports.conf"
  fi
  # OpenVPN y WireGuard: manda el puerto que tiene su configuracion real
  [[ -n $(ovpn_conf_file) ]] && PORT_OVPN=$(ovpn_port)
  [[ -f $WG_CONF ]] && PORT_WG=$(wg_port)
  return 0
}

is_udp_key() { [[ $1 == udp || $1 == slowdns || $1 == wireguard ]]; }

key_ports() {   # clave -> puertos que ocupa (Psiphon usa dos)
  local p; p=$(pget "$1")
  if [[ $1 == psiphon ]]; then echo "$p $(( p + 1 ))"; else echo "$p"; fi
}

port_check() {   # clave puerto -> 0 si sirve (deja el numero en PCHK); si no, el motivo en MSG
  local k=$1 p=$2 o q x
  if ! [[ $p =~ ^[0-9]{1,5}$ ]] || (( 10#$p < 1 || 10#$p > 65535 )); then MSG="Puerto invalido (1-65535)."; return 1; fi
  p=$(( 10#$p ))
  [[ $k == psiphon ]] && (( p == 65535 )) && { MSG="Psiphon usa este puerto y el siguiente."; return 1; }
  for o in "${PORT_KEYS[@]}"; do
    [[ $o == "$k" ]] && continue
    if { is_udp_key "$o" && is_udp_key "$k"; } || { ! is_udp_key "$o" && ! is_udp_key "$k"; }; then
      for x in $(key_ports "$o"); do
        for q in $p $( [[ $k == psiphon ]] && echo $(( p + 1 )) ); do
          if (( x == q )); then MSG="Ya lo usa ${o^^} en este panel."; return 1; fi
        done
      done
    fi
  done
  if ! is_udp_key "$k" && { (( p == SSH_PORT )) || { [[ $k == psiphon ]] && (( p + 1 == SSH_PORT )); }; }; then
    MSG="Es el puerto SSH del servidor."; return 1
  fi
  if is_udp_key "$k" && (( p == 53 )); then MSG="El 53/udp lo usa SlowDNS para recibir las consultas."; return 1; fi
  PCHK=$p
  (( p == $(pget "$k") )) && return 0                       # sin cambios
  for q in $p $( [[ $k == psiphon ]] && echo $(( p + 1 )) ); do
    if is_udp_key "$k"; then
      if listening "$q" udp; then MSG="El puerto UDP $q ya esta en uso por $(port_owner "$q" udp)."; return 1; fi
    elif port_busy "$q"; then
      MSG="El puerto $q ya esta en uso por $(port_owner "$q" tcp)."; return 1
    fi
  done
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
  v2_test || return 1
  svc_restart v2ray
  fw_sync
  verify v2ray V2Ray
}

apply_proto() {   # clave -> reescribe su configuracion con los puertos actuales (solo si esta instalado)
  local k=$1 was=1 keep=$LOG
  proto_installed "$k" || return 0
  is_on "$k" || was=0
  log_use "$k" "Aplicar configuracion"
  if (( was )); then apply_one "$k"; else NOSTART=1 apply_one "$k"; fi
  LOG=$keep
  return 0
}

apply_one() {
  case $1 in
    dropbear)  unit_dropbear ;;
    ssl)       conf_ssl ;;
    badvpn)    unit_badvpn ;;
    ws)        unit_ws ;;
    socks)     unit_socks ;;
    wsepro)    unit_wsepro ;;
    squid)     conf_squid ;;
    v2ray)     v2_apply ;;
    udp)       conf_udp ;;
    slowdns)   [[ -s $BASE/slowdns/ns ]] && unit_slowdns ;;
    openvpn)   [[ -f $OVPN_DIR/server.conf ]] && ovpn_conf ;;
    wireguard) wg_apply ;;
    psiphon)   psi_apply ;;
  esac
}

apply_chain() {   # clave -> la aplica y tambien a los que dependen de su puerto
  local d
  apply_proto "$1"
  case $1 in
    dropbear)        for d in ws socks wsepro ssl squid; do apply_proto "$d"; done ;;
    ws|socks|wsepro) apply_proto squid ;;
    openvpn)         for d in ws socks wsepro ssl squid udp; do apply_proto "$d"; done ;;
    slowdns|wireguard) apply_proto udp ;;
    badvpn)          apply_proto psiphon ;;
  esac
  fw_sync
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
  for k in dropbear ws socks wsepro squid ssl v2ray badvpn openvpn wireguard slowdns udp psiphon; do apply_proto "$k"; done
  fw_sync
}

v2_path_set() {
  local np=''   # no puede llamarse "p": rd usa una variable local con ese nombre y la respuesta se perdia
  proto_installed v2ray || { err "V2Ray no esta instalado."; return 1; }
  rd "Nuevo path de V2Ray [$V2PATH]: " np
  [[ -z $np ]] && { info "Sin cambios"; return 0; }
  [[ $np == /* ]] || np="/$np"
  [[ $np =~ ^/[A-Za-z0-9._~/-]{1,40}$ ]] || { err "Path invalido (letras, numeros y . _ ~ - /)"; return 1; }
  V2PATH=$np; save_ports
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
  log_use slowdns "Cambiar NameServer"
  unit_slowdns
}

pm_add() { act+=("$2"); item "${#act[@]}" "$1" "${3:-}"; }   # opcion numerada del administrador

proto_menu() {   # clave nombre   (administrador de un protocolo)
  local k=$1 nm=$2 o sub inst
  local -a act=()
  while :; do
    act=()
    if proto_installed "$k"; then inst=1; else inst=0; fi
    sub="PUERTO: $(svc_port "$k")"
    [[ $k == ws ]]       && sub+=" >> $SSH_PORT"
    [[ $k == wsepro ]]   && sub+=" >> $(wsepro_target)"
    [[ $k == v2ray ]]    && sub+="   PATH: $V2PATH"
    [[ $k == slowdns ]]  && sub+="   NS: $(cat "$BASE/slowdns/ns" 2>/dev/null || echo -)"
    [[ $k == psiphon ]]  && sub+=" (OSSH)  $(( PORT_PSIPHON + 1 )) (MEEK)"
    [[ $k == openvpn ]]  && sub+="/$(ovpn_proto)"
    cls
    title "$nm MANAGER"
    center "$sub" "$LYE"
    line_eq
    if (( inst )); then
      act+=(toggle); item_on 1 "INICIAR/PARAR SERVICIO" is_on "$k"
    else
      pm_add "INSTALAR $nm" install "$GRN"
    fi
    line_dash
    pm_add "CAMBIAR PUERTO" port
    [[ $k == v2ray ]]   && pm_add "CAMBIAR PATH" path
    [[ $k == slowdns ]] && pm_add "CAMBIAR NAMESERVER" ns
    if (( inst )); then
      case $k in
        openvpn)   pm_add "VER ARCHIVO .OVPN" ovpnfile ;;
        wireguard) pm_add "AGREGAR CLIENTE" wgadd; pm_add "ELIMINAR CLIENTE" wgdel; pm_add "VER CLIENTES / QR" wglist ;;
        psiphon)   pm_add "VER SERVER ENTRY" psientry ;;
      esac
      line_dash
      pm_add "REPARAR / REINSTALAR" repair "$GRN"
      pm_add "VER REGISTRO Y DIAGNOSTICO" diag
      pm_add "DESINSTALAR" uninstall "$RED"
    fi
    menu_end
    ask o || return
    [[ $o == 0 ]] && return
    [[ $o =~ ^[0-9]+$ ]] && (( o >= 1 && o <= ${#act[@]} )) || continue
    case ${act[o-1]} in
      toggle|install) proto_action "$k" ;;
      port)      proto_port "$k" ;;
      path)      v2_path_set ;;
      ns)        slowdns_ns ;;
      ovpnfile)  ovpn_show ;;
      wgadd)     wg_add ;;
      wgdel)     wg_del ;;
      wglist)    wg_list ;;
      psientry)  psi_show ;;
      repair)    proto_repair "$k" ;;
      diag)      sub_header "DIAGNOSTICO: $nm"; proto_diag "$k" ;;
      uninstall) proto_uninstall "$k"; [[ $? == 3 ]] && continue ;;
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
    cols "0:$(qcell 14 'CAMBIAR PUERTOS')"      "26:$(qcell 19 'LIMPIAR CACHE/LOGS')"
    cols "0:$(qcell 15 'RESTAURAR PUERTOS')"    "26:$(qcell 20 'CONFIGURAR IP DNS')"
    cols "0:$(qcell 16 'BANNER SSH')"           "26:$(qcell 21 'GEN DOMI/CERT-SSL' "$(mark test -s "$DOMAIN_F")")"
    cols "0:$(qcell 17 'ACELERACION TCPBBR')"   "26:$(qcell 22 'CLAVE Y ACCESO ROOT')"
    cols "0:$(qcell 18 'MEMORIA SWAP' "$(mark swap_on)")" "26:$(qcell 23 'REINICIAR SERVICIOS')"
    line_eq
    item 24 "NOMBRE DEL VPS"  "$DBL"
    item 25 "VISTA DEL PANEL" "$BLU"
    line_eq
    printf ' %s%4s%s %s>%s    %s VOLVER %s        %s%4s%s %s>%s %sAUTO-INICIAR%s %s\n' \
      "$GRN" "[0]" "$RST" "$RED" "$RST" "$BTN_RED" "$RST" \
      "$GRN" "[26]" "$RST" "$RED" "$RST" "$WHT" "$RST" "$(onoff autostart_on)"
    printf ' %26s%s%4s%s %s>%s %sAUTO-ELIMINAR%s %s\n' '' \
      "$GRN" "[27]" "$RST" "$RED" "$RST" "$WHT" "$RST" "$(onoff autodel_on)"
    line_eq
    ask o || return
    case $o in
      0)  return ;;
      14) sub_header "CAMBIAR PUERTOS";        ports_wizard ;;
      15) sub_header "RESTAURAR PUERTOS";      ports_reset ;;
      16) sub_header "BANNER SSH";             cfg_banner; [[ $? == 3 ]] && continue ;;
      17) sub_header "ACELERACION TCP BBR";    cfg_bbr ;;
      18) sub_header "MEMORIA SWAP";           cfg_swap ;;
      19) sub_header "LIMPIAR CACHE Y LOGS";   cfg_cache ;;
      20) sub_header "CONFIGURAR DNS";         cfg_dns ;;
      21) sub_header "DOMINIO Y CERTIFICADO";  cfg_domain ;;
      22) sub_header "CLAVE Y ACCESO ROOT";    cfg_root ;;
      23) sub_header "REINICIAR SERVICIOS";    restart_services ;;
      24) cfg_vpsname; continue ;;
      25) menu_view; continue ;;
      26) toggle_autostart ;;
      27) toggle_autodel ;;
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
SHOW_KEYS=(badvpn dropbear ssh ssl v2ray ws socks wsepro udp squid slowdns openvpn wireguard psiphon)
declare -A SHOW_LABEL=([badvpn]=BADVPN [dropbear]=DROPBEAR [ssh]=SSH [ssl]=SSL [v2ray]=V2RAY [ws]=WEBSOCKET
                       [socks]="SOCKS PY" [wsepro]=WS-EPRO [udp]=UDPCUSTOM [squid]=SQUID [slowdns]=SLOWDNS
                       [openvpn]=OPENVPN [wireguard]=WIREGUARD [psiphon]=PSIPHON)

svc_port() {   # clave -> puerto que se muestra (openvpn y wireguard lo leen de su configuracion)
  case $1 in
    ssh)       echo "$SSH_PORT" ;;
    openvpn)   ovpn_port ;;
    wireguard) wg_port ;;
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
  # Titulo: el nombre del VPS en blanco, entre las mismas lineas que el resto del panel
  brand "$name"

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
  item_m 1.2 "CREAR USUARIO DE PRUEBA"
  item_m 2 "ADMINISTRAR CUENTAS (V2ray)"
  line_dash
  item_m 3 "PREPARACION DEL SISTEMA" "$HL_GRY"
  line_dash
  printf ' %s[4]%s %s>%s %s[!]%s %sDESINSTALAR PANEL%s\n' "$GRN" "$RST" "$RED" "$RST" "$YEL" "$RST" "$RED" "$RST"
  line_dash
  item_m 5 "INSTALAR TODOS LOS PROTOCOLOS"
  printf ' %s[8]%s %s>%s %sACTUALIZAR PANEL%s %sv%s%s\n' "$GRN" "$RST" "$RED" "$RST" "$WHT" "$RST" "$GRY" "$VERSION" "$RST"
  item_m 9 "COPIAS DE SEGURIDAD"
  line_eq
  printf ' %s0)%s %sSALIR DEL VPS%s  %s6)%s %sSALIR DEL SCRIPT%s  %s7)%s %sREBOOT VPS%s\n' \
    "$GRN" "$RST" "$BTN_GRAY" "$RST" "$GRN" "$RST" "$BTN_RED" "$RST" "$GRN" "$RST" "$BTN_BLUE" "$RST"
  line_eq
}

exit_vps() {   # cierra el panel y la sesion SSH que lo abrio
  local p
  bk_auto                                         # antes de cortar la sesion
  cls
  p=$(ps -o comm= -p "$PPID" 2>/dev/null)
  case $p in bash|-bash|sh|dash|ash|zsh) kill -HUP "$PPID" 2>/dev/null ;; esac
  exit 0
}

main_menu() {
  local o c='' rc
  while :; do
    bk_auto                                       # copia automatica si algo cambio
    header
    ask o m || exit 0
    case $o in
      1) menu_ssh ;;
      1.1) sub_header "CREAR USUARIO RAPIDO"; quick_user; pause ;;
      1.2) sub_header "CREAR USUARIO DE PRUEBA"; test_user; pause ;;
      2) menu_v2 ;;
      3) ensure_base; menu_system ;;
      4) sub_header "DESINSTALAR PANEL"; uninstall_all; pause ;;
      5) sub_header "INSTALACION COMPLETA"; install_all; pause ;;
      6) cls; exit 0 ;;
      7) rd "REINICIAR EL VPS AHORA? (s/N): " c; [[ $c == [sS] ]] && { bk_auto; reboot; } ;;
      8) sub_header "ACTUALIZAR PANEL"; panel_update; rc=$?
         (( rc == 3 )) && continue
         if (( rc == 0 )); then                   # se abre la version nueva (integra sus herramientas)
           pause; cls; exec "$PANEL_BIN"
         fi
         pause ;;
      9) menu_backup ;;
      0) exit_vps ;;
    esac
  done
}

on_exit() {   # al salir: cursor visible, colores normales y copia automatica si algo cambio
  [[ -t 1 ]] && printf '\e[?25h\e[0m'
  bk_auto
  return 0
}

usage() {
  cat <<EOF
Uso: $0 [opcion]
  (sin opcion)          abre el panel
  --install-all         instala todos los protocolos sin preguntar
  --backup [motivo]     crea una copia de seguridad (el cron diario usa: --backup auto)
  --restore ARCHIVO     restaura una copia de seguridad (.tar.gz, tambien de otro VPS)
  --update [ENLACE]     actualiza el panel desde el enlace RAW del instalador nuevo
  --rollback            vuelve a la version anterior del panel
EOF
}

main() {
  local rc
  preflight
  if [[ ${1:-} == --backup ]]; then              # cron diario o a mano: sin red ni menus
    init_fs; load_ports; init_ui; helpers_update
    if bk_snap "${2:-manual}"; then
      if [[ -n $BK_LAST ]]; then echo "Copia creada: $BK_LAST"; else echo "Sin cambios desde la ultima copia."; fi
      exit 0
    fi
    echo "No se pudo crear la copia de seguridad." >&2; exit 1
  fi
  init_fs
  load_ports
  init_ui
  trap on_exit EXIT
  init_env
  self_install
  autostart_default
  banner_migrate
  helpers_update
  case "${1:-}" in
    --install-all) data_recover; default_name; INSTALL_AUTO=1; install_all; exit 0 ;;
    --restore)     [[ -n ${2:-} ]] || { usage; exit 1; }
                   if [[ -t 0 ]]; then bk_restore "$2"; else bk_restore "$2" si; fi
                   exit $? ;;
    --update)      panel_update "${2:-$(head -n1 "$BASE/update.url" 2>/dev/null)}"; rc=$?
                   (( rc == 0 )) && [[ -t 0 && -t 1 ]] && { pause; exec "$PANEL_BIN"; }
                   (( rc == 2 )) && rc=0
                   exit $rc ;;
    --rollback)    [[ -x /usr/local/bin/vps-rollback ]] || install_rollback
                   NO_AUTOBK=1; exec /usr/local/bin/vps-rollback ;;
    -h|--help)     usage; exit 0 ;;
    "") ;;
    *) usage; exit 1 ;;
  esac
  data_startup
  if [[ ! -s $NAME_F ]]; then
    if [[ -t 0 && -t 1 ]]; then register_vps || exit 1; else default_name; fi
  fi
  main_menu
}

if [[ -z ${VPSPANEL_SOURCE_ONLY:-} ]]; then main "$@"; fi
