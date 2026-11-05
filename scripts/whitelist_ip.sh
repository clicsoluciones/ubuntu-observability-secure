#!/usr/bin/env bash
# ==============================================================================
# scripts/whitelist_ip.sh
# Safely whitelists an IP address or CIDR in CrowdSec, removes any active bans,
# validates YAML syntax with crowdsec -t, and reloads CrowdSec.
# ==============================================================================
set -Eeuo pipefail

if [[ $# -lt 1 ]]; then
  echo "Uso: sudo $0 <IP_O_CIDR> [MOTIVO]"
  echo "Ejemplo: sudo $0 144.126.213.42 \"Frontend de aplicacion\""
  exit 1
fi

TARGET="$1"
REASON="${2:-Servidor de infraestructura propia}"
CUSTOM_WHITELIST_FILE="/etc/crowdsec/parsers/s02-enrich/99_custom_whitelists.yaml"

if [[ $EUID -ne 0 ]]; then
  echo "Error: Este script debe ejecutarse como root (sudo $0 ...)" >&2
  exit 1
fi

echo "==> Desbloqueando activamente $TARGET si tiene decisiones de ban..."
if command -v cscli >/dev/null 2>&1; then
  cscli decisions delete --ip "$TARGET" 2>/dev/null || cscli decisions delete --range "$TARGET" 2>/dev/null || true
fi

install -d -m 0755 /etc/crowdsec/parsers/s02-enrich

# Limpiar archivo malformado previo si existe
if [[ -f /etc/crowdsec/parsers/s02-enrich/my_whitelists.yaml ]]; then
  if ! crowdsec -t >/dev/null 2>&1; then
    echo "==> Detectado archivo previo con error de sintaxis /etc/crowdsec/parsers/s02-enrich/my_whitelists.yaml. Respaldando..."
    mv /etc/crowdsec/parsers/s02-enrich/my_whitelists.yaml /etc/crowdsec/parsers/s02-enrich/my_whitelists.yaml.bak
  fi
fi

# Inicializar o actualizar 99_custom_whitelists.yaml
if [[ ! -f "$CUSTOM_WHITELIST_FILE" ]]; then
  cat > "$CUSTOM_WHITELIST_FILE" <<EOF
name: custom/infra_whitelists
description: "Whitelist personalizada de infraestructura administrada"
whitelist:
  reason: "Infraestructura autorizada"
  ip:
    - "$TARGET"
  cidr: []
EOF
else
  # Verificar si ya está listada
  if grep -Fq "\"$TARGET\"" "$CUSTOM_WHITELIST_FILE"; then
    echo "==> La IP/CIDR $TARGET ya se encuentra registrada en $CUSTOM_WHITELIST_FILE"
  else
    if [[ "$TARGET" =~ / ]]; then
      # Es un rango CIDR
      sed -i "/cidr:/a \    - \"$TARGET\"" "$CUSTOM_WHITELIST_FILE"
    else
      # Es una IP fija
      sed -i "/ip:/a \    - \"$TARGET\"" "$CUSTOM_WHITELIST_FILE"
    fi
    echo "==> Agregada $TARGET a $CUSTOM_WHITELIST_FILE"
  fi
fi

# Probar sintaxis antes de recargar
if command -v crowdsec >/dev/null 2>&1; then
  echo "==> Verificando sintaxis de CrowdSec (crowdsec -t)..."
  if crowdsec -t; then
    echo "==> Sintaxis valida. Recargando CrowdSec..."
    systemctl reload crowdsec 2>/dev/null || systemctl restart crowdsec 2>/dev/null || true
    echo "==> [OK] IP $TARGET agregada a whitelist y desbloqueada exitosamente."
  else
    echo "==> [ERROR] La validacion sintactica de CrowdSec fallo. Revise la configuracion." >&2
    exit 1
  fi
else
  echo "==> [OK] IP agregada a $CUSTOM_WHITELIST_FILE (CrowdSec no se detecto en el PATH)."
fi
