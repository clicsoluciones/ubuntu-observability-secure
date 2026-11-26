# Feature: Arquitectura Multi-Host Master / Satélite con WireGuard

## Specs
- S1: "si, ya un servido tien la foma anterior, como se conviente en master , seri el mismo comoando y el shel verifica y actualiza ?". La conversión a Master desde una instalación standalone existente debe ser 100% idempotente: no borra bases de datos de Grafana, logs de Loki, métricas de Prometheus ni reglas de CrowdSec; únicamente instala y configura WireGuard, ajusta listeners en la interfaz `wg0` y actualiza dashboards.
- S2: El script `install.sh` debe soportar el parámetro `--role [standalone|master|satellite]` (por defecto `standalone`).
- S3: El rol Master configura WireGuard (`wg0` en `10.10.0.1/24`), ajusta Prometheus (`--web.enable-remote-write-receiver` y escucha en `wg0`), Loki (escucha en `wg0`) y CrowdSec LAPI (`10.10.0.1:8080`), y permite registrar satélites de antemano vía `--satellites "sat1,sat2"` o dinámicamente vía `--add-satellite <nombre>`.
- S4: El rol Satellite omite la instalación de Grafana, Prometheus y Loki. Configura WireGuard (`wg0` con su IP asignada), Grafana Alloy (enviando métricas a `http://10.10.0.1:9090/api/v1/write` y logs a `http://10.10.0.1:3100/loki/api/v1/push`), y CrowdSec Agent + Bouncer conectado al LAPI del Máster.
- S5: El dashboard de Grafana (`ubuntu-security-overview.json`) debe incluir la variable `$host` para filtrar por servidor y un panel resumen de flota para ver el estado de todos los nodos.
- S6: La herramienta de diagnóstico `doctor.sh` debe detectar el rol del nodo y verificar el estado del túnel WireGuard y los servicios correspondientes sin fallar por servicios omitidos en satélites.
- S7: Actualizar la documentación en `README.md` con ejemplos claros de instalación de Máster, Satélite y migración desde standalone.

## Tasks
- T1 (S5): Actualizar dashboard de Grafana para multi-host con variable $host y resumen de flota. Route: inline. Commit: completed.
- T2 (S4): Adaptar plantilla de Grafana Alloy para soportar endpoints remotos en satélites. Route: inline. Commit: completed.
- T3 (S1, S2, S3, S4): Modificar `install.sh` con soporte de roles (standalone/master/satellite), WireGuard y actualización idempotente. Route: inline. Commit: completed.
- T4 (S6): Actualizar `doctor.sh` para diagnóstico según rol y validación de WireGuard. Route: inline. Commit: completed.
- T5 (S7): Actualizar `README.md` con guía de despliegue multi-host y migración. Route: inline. Commit: completed.

## Log
- L1: El usuario solicita viabilidad y diseño para separar servicios (frontend/backend) en diferentes servidores, administrando todo desde un servidor padre (Master) con dashboard centralizado mientras los otros actúan como satélites protegiendo localmente pero enviando telemetría al padre.
- L2: El usuario confirma que los servidores están separados en Internet público sin red privada previa; se acuerda interconexión segura mediante WireGuard integrado en el instalador.
- L3: El usuario aprueba el diseño y consulta cómo migrar un servidor existente a Master manteniendo la idempotencia mediante `install.sh`.
- L4: Implementada arquitectura multi-host completa: soporte de roles en `install.sh`, generador `add_satellite.sh`, dashboard Grafana con vista de flota y filtro dinámico `$host`, adaptación en `alloy/config.alloy`, diagnóstico en `doctor.sh` y documentación en `README.md`.
