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
(`git`, `gh`, la CLI de `claude` y el plugin de Codex con lo que este
requiere: Node y la CLI `codex`), no el toolchain propio de ningún
proyecto consumidor (Python/Docker...). Si una etapa futura
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
- Node.js (`NODE_MAJOR`, 22 por defecto) desde el repositorio APT
  oficial de NodeSource, y la CLI de Codex (`npm install -g
  @openai/codex@${CODEX_VERSION}`, fijada por versión) instalados para
  todo el sistema. Los workflows que usan `actions/setup-node` siguen
  teniendo su propio Node primero en el `PATH`.
- Plugin de Codex para Claude Code (`openai/codex-plugin-cc`), ver
  "Codex" más abajo.
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

## Codex

La imagen incluye el plugin de Codex para Claude Code
([openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc)):
comandos `/codex:review`, `/codex:adversarial-review`, `/codex:rescue`,
etc., y el subagente `codex:codex-rescue`, para que los agentes de la
pipeline puedan pedir una revisión o delegar una tarea en Codex.

Equivalencias con la instalación interactiva:

| Interactivo | En la imagen |
| --- | --- |
| `/plugin marketplace add openai/codex-plugin-cc` | `claude plugin marketplace add openai/codex-plugin-cc` (al construir) |
| `/plugin install codex@openai-codex` | `claude plugin install codex@openai-codex` (al construir, ámbito de usuario en `~/.claude`) |
| `/reload-plugins` | No hace falta: cada `claude -p` es un proceso nuevo |
| `/codex:setup` (instalar Codex) | `npm install -g @openai/codex` (al construir) |
| `/codex:setup` (login) | Una vez, a mano, con `docker exec` (abajo) |

El login de Codex es un secreto y no se hornea en la imagen. Se guarda en
`~/.codex`, que es un volumen propio (`codex-home` en `claude-runner`,
`codex-home-claude-test` en `claude-test-runner`), así que sobrevive a
las recreaciones del contenedor y Codex puede renovar sus tokens. Se hace
una vez por runner, con el contenedor arrancado:

```bash
# Suscripción de ChatGPT (sin navegador en el servidor: código de dispositivo)
docker exec -it gh-runner-claude codex login --device-auth
# o con una API key de OpenAI (se lee de stdin, no queda en el historial)
docker exec -i gh-runner-claude codex login --with-api-key < fichero-con-la-key

# Comprobar (equivale a /codex:setup)
docker exec gh-runner-claude codex login status
```

Lo mismo con `gh-runner-claude-test`. Si se borra el volumen, hay que
repetir el login.

El "review gate" del plugin (hook `Stop` que hace que Codex revise cada
respuesta de Claude antes de terminar) queda **desactivado**, que es su
valor por defecto: en CI puede encadenar Claude y Codex en bucle y gastar
el uso de las dos suscripciones. No se activa con
`/codex:setup --enable-review-gate` en estos runners.

Para actualizar Codex o el plugin se reconstruye la imagen: el plugin se
descarga en su última versión al construir y Codex en la de
`CODEX_VERSION`.

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

Este runner no monta ninguna clave SSH: toda la pipeline de issues
definida en `issue-pipeline.yml` (comprobación de permisos, `git push`
en `preparation`/`implementation`, comentarios de resultado en cada
etapa, `gh pr create` en `merge`) se autentica frente a GitHub con el
secreto de repo `GH_TOKEN` (un PAT) -- no con el `GITHUB_TOKEN`
efímero de cada job ni con una deploy key estática -- ver "Pipeline de
issues dirigida por labels" en `CLAUDE.md`.

Además, un volumen nombrado `runner-work` se monta en
`actions-runner/_work`, para que la caché de checkout/tools no se pierda
en cada recreación del contenedor, y `codex-home` en `~/.codex`, con el
login de Codex (ver "Codex").

## Referencia cruzada

- Workflow que consume este runner: `.github/workflows/issue-pipeline.yml`.
- Convenciones generales de runners y de la pipeline de issues:
  `CLAUDE.md`.
