# CLAUDE.md

Guía para trabajar en este repositorio. Léela entera antes de tocar nada,
incluida la sección de convenciones de la pipeline de issues, que es como se
suele llegar a este repo.

## Qué es este proyecto

Conjunto de runners de GitHub Actions autoalojados (self-hosted) para la
organización `gallegovela`, pensados para desplegarse todos juntos en una
única máquina mediante Docker. Cada runner es un contenedor Docker
independiente; un único `docker-compose.yml` en la raíz del repo levanta
todos los servicios, configurando cada uno a partir de los ficheros que
tiene en su propia carpeta (`Dockerfile`, `entrypoint.sh`).

Los runners se registran contra la organización (no contra un repo
concreto), así que pueden atender workflows de cualquier repo de
`gallegovela` que los reclame por label (`runs-on: <label>`).

Detalles completos de arranque, `.env`, `COMPOSE_PROFILES` y gestión de
secretos: ver `README.md`. Este fichero (`CLAUDE.md`) documenta
convenciones de trabajo en el repo, no el "cómo arrancarlo".

## Estructura del repositorio

```
docker-compose.yml     # un servicio por runner, cada uno con su `profiles: [...]`
.env / .env.example    # config de todo el proyecto (COMPOSE_PROFILES, SECRETS_DIR, vars por runner)
<runner>/              # una carpeta por runner (p.ej. claude/)
  Dockerfile
  entrypoint.sh
spec/                  # un fichero `runner-<nombre>.md` por cada runner, ver más abajo
.github/
  workflows/            # workflows de este propio repo (p.ej. issue-pipeline.yml)
  actions/              # composite actions reutilizadas por esos workflows
```

## Convención: un runner = una carpeta + un servicio + un spec

Cada runner autoalojado que exista en este repo tiene tres partes, y las
tres deben mantenerse en sincronía:

1. Una carpeta en la raíz (`<runner>/`) con su propio `Dockerfile` y
   `entrypoint.sh`, minimal para lo que ese runner concreto necesita. No se
   comparte una imagen "todo incluido" entre runners: si un runner nuevo
   necesita Python/Node/Docker/etc., se añade en su propio Dockerfile, no
   en uno común.
2. Un servicio en `docker-compose.yml`, con `build: ./<runner>`,
   `profiles: ["<runner>"]` y las variables de entorno propias de ese
   runner (documentadas también en `.env.example`).
3. Un fichero `spec/runner-<runner>.md` que documenta ese runner en
   detalle: qué workflow(s) atiende, qué lleva instalado y por qué, cómo
   se autentica/registra, qué secretos y volúmenes espera, y cualquier
   decisión de diseño específica suya.

Al añadir un runner nuevo, créalas las tres. Al modificar el
comportamiento de un runner existente (paquetes que instala, forma de
autenticarse, variables que requiere...), actualiza su
`spec/runner-<runner>.md` en el mismo cambio -- no dejes que el spec se
quede desactualizado respecto al `Dockerfile`/`entrypoint.sh` real.

Qué va en `CLAUDE.md` (este fichero) frente a qué va en cada
`spec/runner-*.md`:

- **`CLAUDE.md`**: todo lo que aplica al proyecto en su conjunto o a más
  de un runner -- estructura del repo, convenciones para añadir/modificar
  runners, cómo funciona la pipeline de issues, filosofía general de
  secretos/estado.
- **`spec/runner-<runner>.md`**: todo lo específico de ese runner --
  imagen base, paquetes instalados, flujo de registro/autenticación
  concreto, variables de entorno que requiere, volúmenes/secretos que
  monta, y el porqué de sus decisiones particulares.

## Pipeline de issues dirigida por labels

Este repo se gestiona (o está preparado para gestionarse) a sí mismo con
una pipeline de issues por labels, definida en
`.github/workflows/issue-pipeline.yml` y que corre sobre el runner
`claude` de este mismo proyecto (label `ionosL1` / `runs-on:
ionos-l1-claude`) -- es decir, el propio repo se apoya en la
infraestructura que define, no en runners alojados por GitHub.

Cada etapa se dispara al añadir un label al issue, o al comentar en un
issue que ya lo tiene (esto último para poder responder a una pregunta
aclaratoria de Claude sin tener que quitar y volver a poner el label).
Antes de ejecutar nada, cada etapa comprueba que quien disparó el evento
tiene permiso `write`/`admin` sobre el repo (job `check-permission`).

Labels y responsabilidad de cada etapa:

- **`documentation`**: analiza el issue y su hilo completo, y propone un
  plan de acción para los cambios en `spec/` necesarios para resolverlo.
  No modifica ningún fichero -- solo comenta el plan en el issue.
- **`preparation`**: crea o reutiliza la rama `issue-<n>`, aplica en ella
  los cambios de `spec/` acordados en la etapa anterior, y hace commit +
  push. No toca código fuera de `spec/` en esta etapa.
- **`implementation`**: sobre la rama `issue-<n>` (que ya tiene el spec
  actualizado), implementa el cambio real, y hace commit + push.
- **`merge`**: abre un Pull Request desde `issue-<n>` contra la rama por
  defecto, resumiendo en título y descripción los cambios hechos para ese
  issue.

Cada etapa arranca su prompt con "Review CLAUDE.md in full before
anything else" -- por eso este fichero, junto con `spec/`, es la fuente
de verdad que Claude usa en cada ejecución para saber cómo está
organizado el repo y qué convenciones seguir; ambos deben mantenerse
completos y al día. La autenticación de `claude` en la pipeline usa
`CLAUDE_CODE_OAUTH_TOKEN` (secreto de organización, token de larga
duración generado con `claude setup-token`), inyectado a nivel de
workflow -- no hace falta login interactivo en el runner.

Las etapas que necesitan `git push` (`preparation`, `implementation`)
lo hacen por HTTPS con el `GITHUB_TOKEN` efímero del propio job
(`permissions: contents: write`, scopeado a esas dos etapas) -- no con
una clave SSH estática.

## Filosofía de secretos y estado

Nada sensible se hornea en ninguna imagen. Todo secreto (claves privadas
de GitHub App, claves SSH) se monta como volumen en tiempo de ejecución
desde `SECRETS_DIR`, una ruta del sistema fuera del repo. Ver la sección
"Estado y secretos" del `README.md` para el detalle operativo (permisos,
uid/gid, por qué no usar un símlink a una clave personal).
