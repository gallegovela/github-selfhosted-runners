# Runner: claude

Carpeta: `claude/`. Servicio en `docker-compose.yml`: `claude-runner`
(profile `claude`, imagen `gallegovela-github-selfhosted-runners/claude-runner:latest`,
contenedor `gh-runner-claude`).

## Propósito

Atiende la pipeline de issues por labels definida en
`.github/workflows/issue-pipeline.yml` (ver "Pipeline de issues dirigida
por labels" en `CLAUDE.md`). Se registra contra la organización con el
label `ionosL1`, y los jobs de esa pipeline lo reclaman con
`runs-on: ionos-l1-claude`.

Es deliberadamente minimal: solo lleva lo que esa pipeline necesita
(`git`, `gh`, la CLI de `claude`), no el toolchain propio de
ningún proyecto consumidor (Python/Node/Docker...). Si una etapa futura
necesitara compilar o testear el código de un repo concreto, esas
herramientas se añadirían a este Dockerfile entonces, no de forma
preventiva.

## Imagen (`claude/Dockerfile`)

- Base: `ubuntu:24.04`.
- Paquetes base: `ca-certificates`, `curl`, `git`, `jq`, `openssl`.
- `gh` (GitHub CLI) instalado desde el repositorio APT oficial de
  `cli.github.com`, no el paquete empaquetado por Ubuntu -- el workflow
  depende de comportamiento reciente de `gh` que el paquete de Ubuntu no
  trae.
- El binario del runner de GitHub Actions (`actions-runner`) se descarga
  fijado por versión y verificado por `sha256sum` (`RUNNER_VERSION`,
  `RUNNER_SHA256`, `RUNNER_ARCH` como `ARG` en el Dockerfile).
- CLI de `claude` instalada de forma nativa vía
  `curl -fsSL https://claude.ai/install.sh | bash`, que la deja en
  `~/.local/bin` (añadido al `PATH`).
- Usuario no root: el runner de GitHub Actions rechaza configurarse/
  ejecutarse como root, y esto no se fuerza con
  `RUNNER_ALLOW_RUNASROOT`. Se crea el usuario `runner` con uid/gid
  **fijados a 1001:1001** (no el valor por defecto de `useradd`) para que
  el directorio de secretos del host pueda chown-earse a un id estable y
  conocido (ver `README.md`, sección "Estado y secretos").
- `actions-runner/_work` se pre-crea en la imagen, propiedad de
  `runner`, antes de que Docker lo monte como volumen -- si no existiera
  ya en la imagen, Docker lo crearía como root al montarlo, y el proceso
  `runner` no podría usarlo como caché de checkout/tools.
- `installdependencies.sh` del runner de Actions se ejecuta como root
  (necesita `apt-get`); todo lo demás corre como `runner`.

## Registro y baja como runner de organización (`claude/entrypoint.sh`)

No usa un token de registro estático (caduca en ~1h, inviable para un
contenedor que puede reiniciarse más tarde). En su lugar, se autentica
como GitHub App en cada arranque:

1. Genera un JWT firmado en RS256 con la clave privada de la App
   (`GITHUB_APP_PRIVATE_KEY_PATH`), usando `openssl dgst -sign` sobre un
   header/payload codificados en base64url a mano (sin dependencias
   extra tipo `jwt-cli`).
2. Cambia ese JWT por un installation access token
   (`POST /app/installations/{id}/access_tokens`).
3. Con ese token, pide un registration token de la organización
   (`POST /orgs/{org}/actions/runners/registration-token`).
4. Registra el runner con `config.sh --url https://github.com/<org>
   --token <reg_token> --name <RUNNER_NAME> --labels <RUNNER_LABELS>
   --unattended --replace` y lo arranca con `run.sh`.

Al recibir `SIGTERM`/`SIGINT` (p.ej. `docker stop`), un `trap`
ejecuta `deregister`: repite el paso JWT -> installation token, pide un
remove-token (`POST /orgs/{org}/actions/runners/remove-token`) y llama a
`config.sh remove`, para no dejar el runner listado como "offline" en la
organización. Es best-effort (`|| true` / `return 0` en cada paso) para
no bloquear el apagado del contenedor si la API de GitHub falla.

`docker-compose.yml` le da `stop_grace_period: 30s` (por encima de los
10s por defecto de Compose), porque esta cadena JWT -> installation
token -> remove-token necesita más tiempo del que da el grace period
estándar.

## Autenticación de la CLI `claude`

No usa login interactivo ni requiere que `~/.claude` sobreviva a la
recreación del contenedor. Se autentica vía `CLAUDE_CODE_OAUTH_TOKEN`
(token de larga duración generado con `claude setup-token`), guardado
como secreto de **organización** en GitHub y pasado como variable de
entorno a nivel de workflow (en `issue-pipeline.yml`, no en este repo) en
cada ejecución.

## Variables de entorno

Requeridas (sin default, `docker-compose.yml` falla si faltan):

- `GITHUB_ORG`
- `GITHUB_APP_ID`
- `GITHUB_APP_INSTALLATION_ID`

Con default en `docker-compose.yml`:

- `RUNNER_NAME` (default `claude-runner-1`)
- `RUNNER_LABELS` (default `ionosL1`)

Fijada por el propio `docker-compose.yml` (no configurable por `.env`):

- `GITHUB_APP_PRIVATE_KEY_PATH=/home/runner/secrets/github-app-private-key.pem`
  (ruta *dentro* del contenedor donde se monta el `.pem`).

## Secretos y volúmenes

Nada sensible se hornea en la imagen. `docker-compose.yml` monta en
tiempo de ejecución, desde `$SECRETS_DIR` (ruta del host, fuera del
repo, default `/etc/github-selfhosted-runners/secrets`):

- `github-app-private-key.pem` -> `/home/runner/secrets/github-app-private-key.pem` (`:ro`)

Debe ser propiedad de uid:gid `1001:1001` (el usuario `runner` fijado en
el Dockerfile) en el host, o el contenedor no podrá leerlo pese al
`:ro`.

Este runner no monta ninguna clave SSH: las etapas `preparation` e
`implementation` de la pipeline de issues (las únicas que hacen `git
push`) lo hacen por HTTPS con el `GITHUB_TOKEN` efímero del propio job
de `issue-pipeline.yml` (`permissions: contents: write`, scopeado a
esas dos etapas), no con una deploy key estática -- ver "Pipeline de
issues dirigida por labels" en `CLAUDE.md`.

Además, un volumen nombrado `runner-work` se monta en
`actions-runner/_work`, para que la caché de checkout/tools no se pierda
en cada recreación del contenedor.

## Referencia cruzada

- Workflow que consume este runner: `.github/workflows/issue-pipeline.yml`.
- Convenciones generales de runners y de la pipeline de issues:
  `CLAUDE.md`.
