#!/usr/bin/env bash
# ==============================================================================
# scripts/whitelist_country.sh
# Safely whitelists an entire country by ISO-2 code in CrowdSec:
# 1. Adds parser whitelist (s02-enrich) using evt.Enriched.IsoCode
# 2. Adds postoverflow whitelist (s01-whitelist) using evt.Overflow.Alert.Source.Cn
# 3. Flushes any active bans for IPs from that country
# 4. Validates syntax with crowdsec -t and reloads service
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

PARSER_DIR="/etc/crowdsec/parsers/s02-enrich"
POSTOVERFLOW_DIR="/etc/crowdsec/postoverflows/s01-whitelist"
PARSER_FILE="$PARSER_DIR/99_custom_country_whitelists.yaml"
POSTOVERFLOW_FILE="$POSTOVERFLOW_DIR/99_custom_country_whitelists.yaml"

if [[ $EUID -ne 0 ]]; then
  echo "Error: Este script debe ejecutarse como root (sudo $0 ...)" >&2
  exit 1
fi

if [[ ! "$COUNTRY" =~ ^[A-Z]{2}$ ]]; then
  echo "Error: El codigo de pais '$RAW_COUNTRY' debe ser un codigo ISO 3166-1 alpha-2 valido de 2 letras (ej: CO, ES, AR, MX, US)." >&2
  exit 1
fi

install -d -m 0755 "$PARSER_DIR" "$POSTOVERFLOW_DIR"

# 1. Configurar whitelist en postoverflows (clave: evt.Overflow.Alert.Source.Cn)
if [[ ! -f "$POSTOVERFLOW_FILE" ]]; then
  cat > "$POSTOVERFLOW_FILE" <<EOF
name: custom/country_postoverflow_whitelists
description: "Whitelist personalizada de paises por codigo ISO en postoverflow"
whitelist:
  reason: "Paises autorizados en infraestructura"
  expression:
    - evt.Overflow.Alert.Source.Cn == '$COUNTRY'
EOF
  echo "==> Creado $POSTOVERFLOW_FILE (postoverflow) con el pais $COUNTRY"
else
  if grep -Fq "evt.Overflow.Alert.Source.Cn == '$COUNTRY'" "$POSTOVERFLOW_FILE"; then
    echo "==> El pais $COUNTRY ya se encuentra registrado en postoverflows ($POSTOVERFLOW_FILE)"
  else
    # Si tenia sintaxis previa incorrecta con evt.Enriched.IsoCode en postoverflow, actualizarla
    sed -i "s/evt\.Enriched\.IsoCode == '$COUNTRY'/evt.Overflow.Alert.Source.Cn == '$COUNTRY'/g" "$POSTOVERFLOW_FILE"
    if ! grep -Fq "evt.Overflow.Alert.Source.Cn == '$COUNTRY'" "$POSTOVERFLOW_FILE"; then
      sed -i "/expression:/a \    - evt.Overflow.Alert.Source.Cn == '$COUNTRY'" "$POSTOVERFLOW_FILE"
    fi
    echo "==> Agregado pais $COUNTRY a postoverflows ($POSTOVERFLOW_FILE)"
  fi
fi

# 2. Configurar whitelist en parsers s02-enrich (clave: evt.Enriched.IsoCode)
if [[ ! -f "$PARSER_FILE" ]]; then
  cat > "$PARSER_FILE" <<EOF
name: custom/country_parser_whitelists
description: "Whitelist personalizada de paises por codigo ISO en parser s02-enrich"
whitelist:
  reason: "Paises autorizados en infraestructura"
  expression:
    - evt.Enriched.IsoCode == '$COUNTRY'
EOF
  echo "==> Creado $PARSER_FILE (parser) con el pais $COUNTRY"
else
  if grep -Fq "evt.Enriched.IsoCode == '$COUNTRY'" "$PARSER_FILE"; then
    echo "==> El pais $COUNTRY ya se encuentra registrado en parsers ($PARSER_FILE)"
  else
    sed -i "/expression:/a \    - evt.Enriched.IsoCode == '$COUNTRY'" "$PARSER_FILE"
    echo "==> Agregado pais $COUNTRY a parsers ($PARSER_FILE)"
  fi
fi

# 3. Eliminar bloqueos activos previos para IPs provenientes de este pais
if command -v cscli >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  echo "==> Buscando decisiones de ban activas pertenecientes al pais $COUNTRY..."
  raw_decisions="$(cscli decisions list -o json 2>/dev/null || true)"
  active_ips="$(python3 -c "
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)
target = sys.argv[1].upper()
for d in data:
    source = d.get('source', {})
    cn = (source.get('cn') or '').upper()
    if cn == target:
        for dec in d.get('decisions', []):
            val = dec.get('value')
            if val:
                print(val)
" "$COUNTRY" <<< "$raw_decisions")"

  if [[ -n "$active_ips" ]]; then
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      echo "  -> Desbloqueando IP activa de $COUNTRY: $ip"
      cscli decisions delete --ip "$ip" 2>/dev/null || true
    done <<< "$active_ips"
  else
    echo "==> No se encontraron bloqueos activos previos para el pais $COUNTRY."
  fi
fi

# 4. Probar sintaxis antes de recargar
if command -v crowdsec >/dev/null 2>&1; then
  echo "==> Verificando sintaxis de CrowdSec (crowdsec -t)..."
  if crowdsec -t; then
    echo "==> Sintaxis valida. Recargando CrowdSec..."
    systemctl reload crowdsec 2>/dev/null || systemctl restart crowdsec 2>/dev/null || true
    echo "==> [OK] Pais $COUNTRY agregado a listas blancas (parser + postoverflow) y recargado con exito."
  else
    echo "==> [ERROR] La validacion sintactica de CrowdSec fallo. Revise la configuracion." >&2
    exit 1
  fi
else
  echo "==> [OK] Archivos de whitelist creados (CrowdSec no se detecto en el PATH)."
fi
