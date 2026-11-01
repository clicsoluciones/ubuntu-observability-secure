# Reglas LogQL del documento

Estas consultas se ejecutan sobre el datasource Loki (`uid: loki`) en Grafana > Alerting > Alert rules. Configura el intervalo de evaluación indicado y un umbral numérico. Las expresiones conservan los umbrales del documento original; ajústalos a la línea base del servidor.

| Alerta | Consulta LogQL | Umbral / duración |
|---|---|---|
| Fuerza bruta SSH | `sum(count_over_time({job="ssh_auth"} |= "Failed password"[5m]))` | > 15 en 5m |
| Login SSH exitoso | `sum(count_over_time({job="ssh_auth"} |= "Accepted "[5m]))` | > 0 inmediato |
| Fallo de sudo / escalada | `sum(count_over_time({job="ssh_auth"} |= "sudo:" |= "authentication failure"[5m]))` | > 2 en 5m |
| Inundación HTTP | `sum(rate({job="nginx_access"}[1m]))` | > 400 req/s durante 2m |
| Ráfaga 403/404 | `sum(rate({job="nginx_access"} | json | status =~ "403|404"[2m])) * 60` | > 100 por minuto durante 2m |
| Sondeo de rutas críticas | `sum(count_over_time({job="nginx_access"} |~ "(?i)(\\.env|\\.git|wp-admin|phpmyadmin|actuator)"[5m]))` | > 10 en 5m |
| Herramientas de escaneo | `sum(count_over_time({job="nginx_access"} |~ "(?i)(sqlmap|nikto|nuclei|nmap|masscan|zgrab)"[5m]))` | > 0 inmediato |

## Notas de interpretación

- La consulta HTTP flood original del PDF usa `sum(rate({job="nginx_access"}[1m]))`; la tasa depende de la unidad de tiempo de Loki y debe validarse con tráfico real. No adoptes 400 req/s como umbral universal.
- Para `status` en JSON, el formato de log Nginx debe incluir el campo numérico `status`.
- Las alertas de login SSH exitoso notifican cada acceso; restringe destinatarios y define una política de notificación para evitar ruido.
- Las consultas LogQL son métricas de rango; en Grafana crea una regla basada en consulta Loki y añade la condición/umbral indicado.
