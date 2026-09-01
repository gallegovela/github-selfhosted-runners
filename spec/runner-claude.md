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
(`git`, `gh`, `ssh`, la CLI de `claude`), no el toolchain propio de
ningún proyecto consumidor (Python/Node/Docker...). Si una etapa futura
necesitara compilar o testear el código de un repo concreto, esas
herramientas se añadirían a este Dockerfile entonces, no de forma
preventiva.

## Imagen (`claude/Dockerfile`)

- Base: `ubuntu:24.04`.
- Paquetes base: `ca-certificates`, `curl`, `git`, `jq`, `openssl`,
  `openssh-client`.
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
- `~/.ssh` y `actions-runner/_work` se pre-crean en la imagen, propiedad
  de `runner`, antes de que Docker los monte como volumen/bind mount --
  si no existieran ya en la imagen, Docker los crearía como root al
  montarlos, y el proceso `runner` no podría escribir en ellos
  (`ssh-keyscan` fallaría con "Permission denied", y el runner no podría
  usar `_work` como caché de checkout/tools).
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

Antes de registrar, añade la clave de host de `github.com` a
`known_hosts` con `ssh-keyscan` en cada arranque (no se asume presente,
al ser una imagen nueva en cada rebuild, a diferencia de una máquina
bare-metal persistente).

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
- `id_ed25519` -> `/home/runner/.ssh/id_ed25519` (`:ro`)

Ambos ficheros deben ser propiedad de uid:gid `1001:1001` (el usuario
`runner` fijado en el Dockerfile) en el host, o el contenedor no podrá
leerlos pese al `:ro`. `id_ed25519` debe ser una clave dedicada a este
runner (deploy key), no una clave personal ni la de `root` del host.

Además, un volumen nombrado `runner-work` se monta en
`actions-runner/_work`, para que la caché de checkout/tools no se pierda
en cada recreación del contenedor.

## Referencia cruzada

- Workflow que consume este runner: `.github/workflows/issue-pipeline.yml`.
- Composite action usada por sus etapas `preparation`/`implementation`:
  `.github/actions/setup-ssh-and-git/action.yml`.
- Convenciones generales de runners y de la pipeline de issues:
  `CLAUDE.md`.
