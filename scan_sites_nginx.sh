#!/usr/bin/env bash
# ==============================================================================
# scan_sites_nginx.sh
# Escanea los archivos de configuración de Nginx y lista cada sitio web
# (server_name), sus puertos de escucha (listen), estado SSL y el destino
# interno (proxy_pass, fastcgi_pass o ruta root).
# Compatible con cualquier instalación de Ubuntu/Debian (sin depender de column
# ni de extensiones específicas de gawk).
#
# Uso:
#   sudo ./scan_sites_nginx.sh                 # Escanea /etc/nginx (o nginx -T)
#   ./scan_sites_nginx.sh /ruta/a/nginx        # Escanea un directorio o archivo
#   sudo ./scan_sites_nginx.sh --csv           # Exporta en formato CSV
#   sudo ./scan_sites_nginx.sh --json          # Exporta en formato JSON
# ==============================================================================

set -euo pipefail

FORMAT="table"
CUSTOM_PATH=""

show_help() {
  cat <<EOF
Uso: $0 [RUTA_NGINX] [OPCIONES]

Escanea y lista los sitios virtuales de Nginx configurados o activos.

Opciones:
  --table       Muestra salida en formato tabla alineada (por defecto).
  --csv         Exporta en formato CSV estructurado.
  --json        Exporta en formato JSON válido.
  -h, --help    Muestra esta ayuda y termina.

Argumentos:
  RUTA_NGINX    Ruta opcional a un archivo de configuración o directorio (ej: /etc/nginx).
                Si se omite, usa la salida activa de 'nginx -T' (o /etc/nginx por defecto).
EOF
}

for arg in "$@"; do
  case "$arg" in
    --table) FORMAT="table" ;;
    --csv)   FORMAT="csv" ;;
    --json)  FORMAT="json" ;;
    --help|-h)
      show_help
      exit 0
      ;;
    *)
      if [[ -z "$CUSTOM_PATH" ]]; then
        CUSTOM_PATH="$arg"
      else
        echo "Error: Argumento desconocido o múltiple ruta: '$arg'" >&2
        echo "Consulta la ayuda con: $0 --help" >&2
        exit 1
      fi
      ;;
  esac
done

# Validar ruta si fue especificada manualmente
if [[ -n "$CUSTOM_PATH" && ! -e "$CUSTOM_PATH" ]]; then
  echo "Error: La ruta '$CUSTOM_PATH' no existe." >&2
  exit 1
fi

# Recolectar flujo de archivos de configuración de Nginx
collect_config_stream() {
  if [[ -n "$CUSTOM_PATH" ]]; then
    if [[ -f "$CUSTOM_PATH" ]]; then
      echo "# configuration file $CUSTOM_PATH:"
      cat "$CUSTOM_PATH"
      echo ""
    elif [[ -d "$CUSTOM_PATH" ]]; then
      while IFS= read -r -d '' f; do
        echo "# configuration file $f:"
        cat "$f"
        echo ""
      done < <(find -L "$CUSTOM_PATH" -type f ! -name "*.bak" ! -name "*~" ! -name "*.dpkg-*" -print0 2>/dev/null | sort -z)
    fi
  else
    # Si nginx -T está disponible y tenemos permisos, devuelve toda la configuración activa
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
      nginx -T 2>/dev/null
    else
      # Fallback: lectura directa de archivos en /etc/nginx
      local base_dir="/etc/nginx"
      if [[ ! -d "$base_dir" ]]; then
        echo "Error: No se encontró $base_dir. Especifica la ruta manualmente: $0 /ruta/nginx" >&2
        exit 1
      fi
      local search_paths=()
      [[ -f "$base_dir/nginx.conf" ]] && search_paths+=("$base_dir/nginx.conf")
      [[ -d "$base_dir/sites-enabled" ]] && search_paths+=("$base_dir/sites-enabled")
      [[ -d "$base_dir/conf.d" ]] && search_paths+=("$base_dir/conf.d")

      for sp in "${search_paths[@]}"; do
        if [[ -f "$sp" ]]; then
          echo "# configuration file $sp:"
          cat "$sp"
          echo ""
        elif [[ -d "$sp" ]]; then
          while IFS= read -r -d '' f; do
            echo "# configuration file $f:"
            cat "$f"
            echo ""
          done < <(find -L "$sp" -maxdepth 2 -type f ! -name "*.bak" ! -name "*~" ! -name "*.dpkg-*" -print0 2>/dev/null | sort -z)
        fi
      done
    fi
  fi
}

# Procesar bloques server { ... } con AWK estándar (compatible con mawk/gawk)
PARSED_DATA="$(collect_config_stream | awk '
  BEGIN {
    current_file = "desconocido"
    in_server = 0
    brace_depth = 0
    server_depth = 0
    token = ""
  }

  # Detectar marcador de archivo emitido por nginx -T o por collect_config_stream
  /^# configuration file / {
    line = $0
    sub(/^# configuration file /, "", line)
    sub(/:[[:space:]]*$/, "", line)
    current_file = line
    next
  }

  {
    # Eliminar comentarios manteniendo directivas en la misma línea
    sub(/#.*/, "")
    if ($0 ~ /^[[:space:]]*$/) next

    len = length($0)
    for (i = 1; i <= len; i++) {
      c = substr($0, i, 1)
      if (c == "{") {
        trimmed = token
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", trimmed)
        brace_depth++
        if (!in_server && trimmed == "server") {
          in_server = 1
          server_depth = brace_depth
          srv_file = current_file
          srv_names = ""
          srv_ports = ""
          srv_backends = ""
          srv_root = ""
        }
        token = ""
      } else if (c == "}") {
        if (in_server && brace_depth == server_depth) {
          if (srv_names == "") srv_names = "_ (default)"
          if (srv_ports == "") srv_ports = "80"
          target = (srv_backends != "") ? srv_backends : ((srv_root != "") ? "root:" srv_root : "-")
          short_file = srv_file
          sub(/^\/etc\/nginx\//, "", short_file)
          printf "%s\t%s\t%s\t%s\n", srv_names, srv_ports, target, short_file
          in_server = 0
        }
        brace_depth--
        token = ""
      } else if (c == ";") {
        if (in_server) {
          stmt = token
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", stmt)
          gsub(/[[:space:]]+/, " ", stmt)

          if (stmt ~ /^listen /) {
            val = stmt
            sub(/^listen /, "", val)
            m = split(val, parts, " ")
            addr_port = parts[1]
            is_ssl = (val ~ /(^| )ssl( |$)/) ? " (SSL)" : ""
            entry = addr_port is_ssl
            if (index("," srv_ports ",", "," entry ",") == 0) {
              srv_ports = (srv_ports == "") ? entry : srv_ports ", " entry
            }
          } else if (stmt ~ /^server_name /) {
            val = stmt
            sub(/^server_name /, "", val)
            if (srv_names == "") srv_names = val
            else srv_names = srv_names " " val
          } else if (stmt ~ /^proxy_pass / || stmt ~ /^fastcgi_pass /) {
            val = stmt
            sub(/^(proxy_pass|fastcgi_pass) /, "", val)
            if (index("," srv_backends ",", "," val ",") == 0) {
              srv_backends = (srv_backends == "") ? val : srv_backends ", " val
            }
          } else if (stmt ~ /^root / && srv_root == "") {
            val = stmt
            sub(/^root /, "", val)
            srv_root = val
          }
        }
        token = ""
      } else {
        token = token c
      }
    }
    token = token " "
  }
')"

if [[ -z "$PARSED_DATA" ]]; then
  if [[ "$FORMAT" == "json" ]]; then
    echo "[]"
  else
    echo "No se encontraron bloques 'server' en la configuración de Nginx."
  fi
  exit 0
fi

case "$FORMAT" in
  csv)
    echo "sitio_web,puertos_listen,destino_proxy_o_root,archivo_config"
    while IFS=$'\t' read -r names ports target file; do
      # Escapar comillas dobles internas para formato RFC 4180
      names_esc="${names//\"/\"\"}"
      ports_esc="${ports//\"/\"\"}"
      target_esc="${target//\"/\"\"}"
      file_esc="${file//\"/\"\"}"
      echo "\"$names_esc\",\"$ports_esc\",\"$target_esc\",\"$file_esc\""
    done <<< "$PARSED_DATA"
    ;;
  json)
    echo "["
    first=1
    while IFS=$'\t' read -r names ports target file; do
      [[ $first -eq 0 ]] && echo ","
      first=0
      # Escapar caracteres de control JSON
      clean_names=$(printf '%s' "$names" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
      clean_ports=$(printf '%s' "$ports" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
      clean_target=$(printf '%s' "$target" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
      clean_file=$(printf '%s' "$file" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
      printf '  {"server_name": "%s", "listen": "%s", "target": "%s", "config_file": "%s"}' \
        "$clean_names" "$clean_ports" "$clean_target" "$clean_file"
    done <<< "$PARSED_DATA"
    echo ""
    echo "]"
    ;;
  *)
    # Formateador de tabla auto-ajustable en AWK puro (no requiere el binario column)
    awk -F'\t' '
      BEGIN {
        h1 = "SITIO WEB (SERVER_NAME)"
        h2 = "PUERTOS (LISTEN)"
        h3 = "DESTINO (PROXY / ROOT)"
        h4 = "ARCHIVO CONFIG"
        w1 = length(h1); w2 = length(h2); w3 = length(h3); w4 = length(h4)
        rows = 0
      }
      {
        rows++
        c1[rows] = $1; c2[rows] = $2; c3[rows] = $3; c4[rows] = $4
        if (length($1) > w1) w1 = length($1)
        if (length($2) > w2) w2 = length($2)
        if (length($3) > w3) w3 = length($3)
        if (length($4) > w4) w4 = length($4)
      }
      function repeat_char(ch, cnt,    s, k) {
        s = ""
        for (k = 1; k <= cnt; k++) s = s ch
        return s
      }
      END {
        fmt = "%-" w1 "s   %-" w2 "s   %-" w3 "s   %-" w4 "s\n"
        printf fmt, h1, h2, h3, h4
        printf fmt, repeat_char("-", w1), repeat_char("-", w2), repeat_char("-", w3), repeat_char("-", w4)
        for (r = 1; r <= rows; r++) {
          printf fmt, c1[r], c2[r], c3[r], c4[r]
        }
      }
    ' <<< "$PARSED_DATA"
    ;;
esac
