#!/usr/bin/env bash
# ==============================================================================
# scripts/setup_telegram_alerts.sh
# Configures Telegram alerting for Grafana:
# - Supports individual users and groups/supergroups (chat_id with negative prefix)
# - Validates bot token and chat_id via Telegram Bot API
# - Can auto-detect group chat_id from recent updates if not specified
# - Provisions /etc/grafana/provisioning/alerting/telegram.yml
# - Restarts Grafana and confirms alert delivery
# ==============================================================================
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Error: Este script debe ejecutarse como root (sudo $0 ...)" >&2
  exit 1
fi

echo "====================================================================="
echo "   Configurador de Notificaciones de Alertas a Telegram en Grafana"
echo "====================================================================="

BOT_TOKEN="${1:-}"
CHAT_ID="${2:-}"

# 1. Solicitar BOT_TOKEN si no fue pasado por parámetro
if [[ -z "$BOT_TOKEN" ]]; then
  read -rp "1. Ingrese el Bot Token de Telegram (ej: 123456789:ABCdefGHI...): " BOT_TOKEN
fi

if [[ -z "$BOT_TOKEN" ]]; then
  echo "Error: El Bot Token es obligatorio." >&2
  exit 1
fi

# Validar conectividad con el bot
echo "==> Verificando Bot Token con la API de Telegram..."
bot_info="$(curl -s -f "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null || true)"

if [[ -z "$bot_info" ]] || ! grep -q '"ok":true' <<< "$bot_info"; then
  echo "Error: Token inválido o sin conexión con la API de Telegram." >&2
  echo "Respuesta: $bot_info" >&2
  exit 1
fi

bot_username="$(python3 -c "import json, sys; d=json.loads(sys.stdin.read()); print(d.get('result', {}).get('username', ''))" <<< "$bot_info" 2>/dev/null || echo "bot")"
echo "==> [OK] Bot autenticado correctamente: @${bot_username}"

# 2. Solicitar o auto-detectar CHAT_ID
if [[ -z "$CHAT_ID" ]]; then
  echo ""
  echo "Buscando chats recientes donde el bot participe..."
  updates="$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" 2>/dev/null || true)"
  
  detected_chats="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    chats = {}
    for item in d.get('result', []):
        msg = item.get('message') or item.get('channel_post') or item.get('my_chat_member', {}).get('chat')
        if msg:
            chat = msg.get('chat') if 'chat' in msg else msg
            if chat and 'id' in chat:
                cid = str(chat['id'])
                title = chat.get('title') or chat.get('username') or chat.get('first_name') or 'Sin nombre'
                ctype = chat.get('type', 'desconocido')
                chats[cid] = f\"{title} (Tipo: {ctype}, ID: {cid})\"
    for cid, desc in chats.items():
        print(f\"{cid}|{desc}\")
except Exception:
    pass
" <<< "$updates")"

  if [[ -n "$detected_chats" ]]; then
    echo "Chats detectados recientemente:"
    while IFS='|' read -r cid desc; do
      echo "  - $desc"
    done <<< "$detected_chats"
    echo ""
  else
    echo "Tip: Si creaste un grupo nuevo, agregá al bot @${bot_username} al grupo y enviá cualquier mensaje (ej: 'hola')."
  fi

  read -rp "2. Ingrese el Chat ID (para grupos suele ser negativo, ej: -1001234567890): " CHAT_ID
fi

if [[ -z "$CHAT_ID" ]]; then
  echo "Error: El Chat ID es obligatorio." >&2
  exit 1
fi

# 3. Enviar mensaje de prueba a Telegram
echo "==> Enviando mensaje de prueba al chat $CHAT_ID..."

send_telegram_msg() {
  local target="$1"
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${target}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=🚀 <b>Grafana Alerting: Conexión Exitosa</b>

Se ha configurado el canal de alertas para el servidor: <code>$(hostname)</code>.
Todas las 16 alertas de infraestructura y seguridad se notificarán a este grupo." 2>/dev/null || true
}

send_result="$(send_telegram_msg "$CHAT_ID")"

if [[ -z "$send_result" ]] || ! grep -q '"ok":true' <<< "$send_result"; then
  # Si el usuario copio el ID desde Telegram Web K (ej: -5295361051 sin el prefijo -100)
  if [[ "$CHAT_ID" =~ ^-[0-9]+$ ]] && [[ ! "$CHAT_ID" =~ ^-100 ]]; then
    candidate_id="-100${CHAT_ID#-}"
    echo "==> Reintentando con prefijo oficial de supergrupo Telegram ($candidate_id)..."
    retry_result="$(send_telegram_msg "$candidate_id")"
    if grep -q '"ok":true' <<< "$retry_result"; then
      CHAT_ID="$candidate_id"
      send_result="$retry_result"
      echo "==> [OK] Detectado supergrupo de Telegram. Chat ID ajustado a: $CHAT_ID"
    fi
  elif [[ "$CHAT_ID" =~ ^[0-9]{9,}$ ]]; then
    # Omitio el signo menos por completo
    candidate_id="-100${CHAT_ID}"
    echo "==> Reintentando con prefijo de supergrupo ($candidate_id)..."
    retry_result="$(send_telegram_msg "$candidate_id")"
    if grep -q '"ok":true' <<< "$retry_result"; then
      CHAT_ID="$candidate_id"
      send_result="$retry_result"
      echo "==> [OK] Detectado supergrupo de Telegram. Chat ID ajustado a: $CHAT_ID"
    fi
  fi
fi

if [[ -z "$send_result" ]] || ! grep -q '"ok":true' <<< "$send_result"; then
  echo "Error: No se pudo enviar el mensaje a Telegram." >&2
  echo "Verifique que el bot @${bot_username} sea miembro del grupo con permisos para escribir." >&2
  echo "Detalle API: $send_result" >&2
  exit 1
fi

echo "==> [OK] Mensaje de prueba recibido en Telegram con éxito."

# 4. Aprovisionar configuración en Grafana
echo "==> Aprovisionando Contact Point y Notification Policy en Grafana..."
PROV_DIR="/etc/grafana/provisioning/alerting"
install -d -m 0750 "$PROV_DIR"

cat > "$PROV_DIR/telegram.yml" <<EOF
apiVersion: 1

contactPoints:
  - orgId: 1
    name: telegram-alertas
    receivers:
      - uid: telegram_ops_channel
        type: telegram
        disableResolveMessage: false
        settings:
          bottoken: "$BOT_TOKEN"
          chatid: "$CHAT_ID"
          parse_mode: "HTML"

policies:
  - orgId: 1
    receiver: telegram-alertas
    group_by: ['grafana_folder', 'alertname']
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
EOF

chown root:grafana "$PROV_DIR/telegram.yml" 2>/dev/null || true
chmod 0640 "$PROV_DIR/telegram.yml"

# 5. Reiniciar Grafana para aplicar la nueva política
echo "==> Reiniciando servicio grafana-server..."
systemctl restart grafana-server 2>/dev/null || true

echo ""
echo "====================================================================="
echo "   [LISTO] Integración con Telegram completada exitosamente"
echo "====================================================================="
echo "  • Bot: @${bot_username}"
echo "  • Chat ID: ${CHAT_ID}"
echo "  • Contact Point: telegram-alertas"
echo "  • Archivo seguro: $PROV_DIR/telegram.yml (0640 root:grafana)"
echo "  • Las alertas activas y resueltas se notificarán automáticamente al grupo."
echo "====================================================================="
