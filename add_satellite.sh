#!/usr/bin/env bash
# Ubuntu Observabilidad & Seguridad Activa - Generador de Nodos Satélite
# Ejecuta en el Servidor Máster para registrar un nuevo Satélite y generar su comando de vinculación.
set -Eeuo pipefail
umask 027

WG_CONF="/etc/wireguard/wg0.conf"
WG_SERVER_PUB="/etc/wireguard/server_public.key"
SATELLITES_DIR="/etc/wireguard/satellites"

show_help() {
  cat <<'EOF'
Uso: sudo ./add_satellite.sh <NOMBRE_SATELITE> [OPCIONES]

Registra un nuevo nodo satélite en el servidor Máster, asigna IP privada en WireGuard
y genera el comando de instalación seguro para ejecutar en el satélite.

Argumentos:
  <NOMBRE_SATELITE>         Identificador único del satélite (ej. frontend, backend, worker-01).

Opciones:
  --pubkey <PUBKEY>         Clave pública generada por el satélite (si ya se ejecutó install.sh allí).
  --ip <IP_PRIVADA>         Asigna manualmente la IP en WireGuard (ej. 10.10.0.2).
  --endpoint <IP:PUERTO>    Sobrescribe el endpoint público del Máster (ej. 198.51.100.5:51820).
  -h, --help                Muestra esta ayuda y termina.

Ejemplos:
  sudo ./add_satellite.sh frontend
  sudo ./add_satellite.sh backend --pubkey "CLAVE_PUBLICA_GENERADA_EN_SATELITE"
  sudo ./add_satellite.sh worker-01 --ip 10.10.0.3
EOF
}

if [[ $# -lt 1 ]]; then
  show_help
  exit 1
fi

SAT_NAME=""
CUSTOM_IP=""
CUSTOM_ENDPOINT=""
CUSTOM_PUBKEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    --pubkey)
      CUSTOM_PUBKEY="$2"
      shift 2
      ;;
    --ip)
      CUSTOM_IP="$2"
      shift 2
      ;;
    --endpoint)
      CUSTOM_ENDPOINT="$2"
      shift 2
      ;;
    *)
      if [[ -z "$SAT_NAME" ]]; then
        SAT_NAME="$1"
        shift
      else
        echo "Error: Argumento inesperado: $1" >&2
        exit 1
      fi
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Error: Requiere privilegios de root. Ejecuta con: sudo $0" >&2
  exit 1
fi

# Sanitizar nombre del satélite
SAT_NAME="$(echo "$SAT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
if [[ -z "$SAT_NAME" ]]; then
  echo "Error: El nombre del satélite es inválido. Usa caracteres alfanuméricos, guiones o guiones bajos." >&2
  exit 1
fi

if [[ ! -f "$WG_CONF" ]]; then
  echo "Error: No se encontró '$WG_CONF'. Asegúrate de haber instalado el rol Master primero:" >&2
  echo "       sudo ./install.sh --role master" >&2
  exit 1
fi

# 1. Determinar IP del Satélite
if [[ -n "$CUSTOM_IP" ]]; then
  SAT_IP="$CUSTOM_IP"
else
  # Buscar última IP asignada en 10.10.0.X
  LAST_OCTET=1
  while read -r line; do
    if [[ "$line" =~ 10\.10\.0\.([0-9]+) ]]; then
      OCT="${BASH_REMATCH[1]}"
      if (( OCT > LAST_OCTET )); then
        LAST_OCTET="$OCT"
      fi
    fi
  done < "$WG_CONF"
  NEXT_OCTET=$((LAST_OCTET + 1))
  if (( NEXT_OCTET >= 254 )); then
    echo "Error: Se alcanzó el límite de IPs disponibles en la subred 10.10.0.0/24." >&2
    exit 1
  fi
  SAT_IP="10.10.0.${NEXT_OCTET}"
fi

# 2. Clave del satélite
if [[ -n "$CUSTOM_PUBKEY" ]]; then
  SAT_PUBKEY="$CUSTOM_PUBKEY"
  SAT_PRIVKEY=""
else
  if command -v wg >/dev/null 2>&1; then
    SAT_PRIVKEY="$(wg genkey)"
    SAT_PUBKEY="$(echo "$SAT_PRIVKEY" | wg pubkey)"
  else
    SAT_PRIVKEY="$(openssl rand -base64 32)"
    SAT_PUBKEY="$(openssl rand -base64 32)"
  fi
fi

# 3. Clave pública del Máster
if [[ -f "$WG_SERVER_PUB" ]]; then
  MASTER_PUBKEY="$(cat "$WG_SERVER_PUB")"
elif command -v wg >/dev/null 2>&1 && wg show wg0 public-key >/dev/null 2>&1; then
  MASTER_PUBKEY="$(wg show wg0 public-key)"
else
  echo "Error: No se pudo obtener la clave pública del servidor WireGuard en '$WG_SERVER_PUB'." >&2
  exit 1
fi

# 4. Endpoint público del Máster
if [[ -n "$CUSTOM_ENDPOINT" ]]; then
  MASTER_ENDPOINT="$CUSTOM_ENDPOINT"
else
  PUB_IP="$(curl -s4 --connect-timeout 3 https://ifconfig.me 2>/dev/null || curl -s4 --connect-timeout 3 https://api.ipify.org 2>/dev/null || ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -n1 || echo 'IP_PUBLICA_DEL_MASTER')"
  MASTER_ENDPOINT="${PUB_IP}:51820"
fi

# 5. Limpiar registro previo en CrowdSec LAPI si existiera
if command -v cscli >/dev/null 2>&1; then
  cscli machines delete "$SAT_NAME" >/dev/null 2>&1 || true
fi

# 6. Registrar Peer en wg0.conf si no existe ya
mkdir -p "$SATELLITES_DIR"
if grep -q "AllowedIPs = ${SAT_IP}/32" "$WG_CONF"; then
  echo "Advertencia: La IP ${SAT_IP} ya estaba registrada en $WG_CONF. Actualizando configuración..."
else
  cat >> "$WG_CONF" <<PEER

# Satélite: ${SAT_NAME}
[Peer]
PublicKey = ${SAT_PUBKEY}
AllowedIPs = ${SAT_IP}/32
PEER
fi

# 7. Sincronizar WireGuard en vivo si wg0 está activa
if command -v wg >/dev/null 2>&1 && ip link show wg0 >/dev/null 2>&1; then
  wg set wg0 peer "$SAT_PUBKEY" allowed-ips "${SAT_IP}/32" || true
fi

# 8. Guardar archivo de configuración local del satélite de respaldo (si se generó clave privada)
SAT_CONF="${SATELLITES_DIR}/${SAT_NAME}.conf"
if [[ -n "$SAT_PRIVKEY" ]]; then
  cat > "$SAT_CONF" <<EOF
[Interface]
Address = ${SAT_IP}/24
PrivateKey = ${SAT_PRIVKEY}

[Peer]
PublicKey = ${MASTER_PUBKEY}
Endpoint = ${MASTER_ENDPOINT}
AllowedIPs = 10.10.0.0/24
PersistentKeepalive = 25
EOF
  chmod 0600 "$SAT_CONF"
fi

# 9. Imprimir banner con el comando seguro para el satélite
CMD="sudo ./install.sh --role satellite --name \"${SAT_NAME}\" --master \"${MASTER_ENDPOINT}\" --master-key \"${MASTER_PUBKEY}\""
if [[ -n "$CUSTOM_IP" ]]; then
  CMD="${CMD} --satellite-ip \"${SAT_IP}\""
fi

cat <<BANNER

================================================================================
             NUEVO NODO SATÉLITE REGISTRADO: ${SAT_NAME}
================================================================================
  - Nombre:           ${SAT_NAME}
  - IP WireGuard:     ${SAT_IP}/24
  - Master Endpoint:  ${MASTER_ENDPOINT}
  - Master PubKey:    ${MASTER_PUBKEY}
BANNER

if [[ -n "$CUSTOM_PUBKEY" ]]; then
  echo "  - Satélite PubKey:  ${SAT_PUBKEY}"
elif [[ -f "$SAT_CONF" ]]; then
  echo "  - Config local:     ${SAT_CONF}"
fi

cat <<BANNER

  >>> COMANDO PARA EJECUTAR EN EL SATÉLITE (${SAT_NAME}): <<<

  $CMD

================================================================================
  NOTAS DE SEGURIDAD Y VINCULACIÓN:
  1. No se pasan contraseñas en flags CLI (evita filtraciones en bash history y ps aux).
  2. El satélite generará sus propias claves WireGuard y deducirá su IP local.
  3. Una vez finalizada la instalación en el satélite, autoriza su agente CrowdSec
     ejecutando en este servidor Máster:
         sudo cscli machines validate "${SAT_NAME}"
BANNER

if [[ -z "$CUSTOM_PUBKEY" ]]; then
  cat <<BANNER
  4. Si el satélite generó una clave pública WireGuard nueva, sincronízala aquí con:
         sudo wg set wg0 peer <SATELITE_PUBKEY> allowed-ips ${SAT_IP}/32
================================================================================
BANNER
else
  echo "================================================================================"
fi
