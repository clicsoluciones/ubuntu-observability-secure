#!/usr/bin/env bash
# ==============================================================================
# scripts/whitelist_country.sh
# Safely whitelists an entire country by ISO-2 code in CrowdSec postoverflows,
# validates YAML syntax with crowdsec -t, and reloads CrowdSec.
# ==============================================================================
set -Eeuo pipefail

if [[ $# -lt 1 ]]; then
  echo "Uso: sudo $0 <CODIGO_ISO_2_LETRAS> [MOTIVO]"
  echo "Ejemplos:"
  echo "  sudo $0 CO \"Trafico nacional legitimo de Colombia\""
  echo "  sudo $0 ES \"Clientes corporativos de Espana\""
  exit 1
fi

RAW_COUNTRY="$1"
COUNTRY="$(echo "$RAW_COUNTRY" | tr '[:lower:]' '[:upper:]')"
REASON="${2:-Trafico autorizado del pais $COUNTRY}"
POSTOVERFLOW_DIR="/etc/crowdsec/postoverflows/s01-whitelist"
CUSTOM_FILE="$POSTOVERFLOW_DIR/99_custom_country_whitelists.yaml"

if [[ $EUID -ne 0 ]]; then
  echo "Error: Este script debe ejecutarse como root (sudo $0 ...)" >&2
  exit 1
fi

if [[ ! "$COUNTRY" =~ ^[A-Z]{2}$ ]]; then
  echo "Error: El codigo de pais '$RAW_COUNTRY' debe ser un codigo ISO 3166-1 alpha-2 valido de 2 letras (ej: CO, ES, AR, MX, US)." >&2
  exit 1
fi

install -d -m 0755 "$POSTOVERFLOW_DIR"

# Inicializar o actualizar 99_custom_country_whitelists.yaml
if [[ ! -f "$CUSTOM_FILE" ]]; then
  cat > "$CUSTOM_FILE" <<EOF
name: custom/country_whitelists
description: "Whitelist personalizada de paises por codigo ISO"
whitelist:
  reason: "Paises autorizados en infraestructura"
  expression:
    - evt.Enriched.IsoCode == '$COUNTRY'
EOF
  echo "==> Creado $CUSTOM_FILE con el pais $COUNTRY"
else
  if grep -Fq "evt.Enriched.IsoCode == '$COUNTRY'" "$CUSTOM_FILE"; then
    echo "==> El pais $COUNTRY ya se encuentra registrado en $CUSTOM_FILE"
  else
    sed -i "/expression:/a \    - evt.Enriched.IsoCode == '$COUNTRY'" "$CUSTOM_FILE"
    echo "==> Agregado pais $COUNTRY a $CUSTOM_FILE"
  fi
fi

# Probar sintaxis antes de recargar
if command -v crowdsec >/dev/null 2>&1; then
  echo "==> Verificando sintaxis de CrowdSec (crowdsec -t)..."
  if crowdsec -t; then
    echo "==> Sintaxis valida. Recargando CrowdSec..."
    systemctl reload crowdsec 2>/dev/null || systemctl restart crowdsec 2>/dev/null || true
    echo "==> [OK] Pais $COUNTRY agregado a la whitelist de postoverflow exitosamente."
    echo "    (Nota: Las decisiones previas ya existentes no se eliminan automaticamente;"
    echo "     podes revisar bloqueos activos con 'cscli decisions list')."
  else
    echo "==> [ERROR] La validacion sintactica de CrowdSec fallo. Revise el archivo $CUSTOM_FILE" >&2
    exit 1
  fi
else
  echo "==> [OK] Pais $COUNTRY agregado a $CUSTOM_FILE (CrowdSec no se detecto en el PATH)."
fi
