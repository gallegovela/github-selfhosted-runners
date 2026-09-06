# gallegovela-github-selfhosted-runners

Runners de GitHub Actions **autoalojados** (self-hosted) para la
organización [`gallegovela`](https://github.com/gallegovela), pensados
para desplegarse todos juntos en una única máquina mediante Docker.

Cada runner es un contenedor Docker independiente, se registra contra la
**organización** (no contra un repo concreto) usando una GitHub App, y
puede atender workflows de cualquier repo de la organización que lo
reclame por label (`runs-on: <label>`).

## Por qué existe este repo

En vez de depender de runners alojados por GitHub (limitados en minutos,
sin estado entre ejecuciones, sin control sobre lo que llevan instalado),
este repo levanta runners propios en una VM controlada por la
organización: arrancan siempre con las mismas herramientas, pueden
persistir caché entre ejecuciones (volúmenes Docker) y se autentican de
forma no interactiva y de larga duración (GitHub App + tokens de vida
corta pedidos en cada arranque, no un PAT que caduque).

El propio repo se autogestiona con uno de esos runners: ver
["Pipeline de issues dirigida por labels"](#pipeline-de-issues-dirigida-por-labels)
más abajo.

## Estructura

```
docker-compose.yml     # un servicio por runner, cada uno con su `profiles: [...]`
.env / .env.example    # config de todo el proyecto
<runner>/               # una carpeta por runner, con su propio Dockerfile + entrypoint.sh
spec/                   # un fichero runner-<nombre>.md por runner, con el detalle de cada uno
.github/
  workflows/            # workflows de este propio repo
  actions/              # composite actions reutilizadas por esos workflows
```

Un único `docker-compose.yml` en la raíz define todos los servicios
(runners). Cada subcarpeta es un runner independiente, con su propio
`Dockerfile` y `entrypoint.sh`, usado como build context por el servicio
correspondiente:

- [`claude/`](claude/) — runner para el workflow
  [`.github/workflows/issue-pipeline.yml`](.github/workflows/issue-pipeline.yml)
  (label `ionosL1`). Incluye `git`, `gh` y la CLI de `claude`.
  Detalle completo en [`spec/runner-claude.md`](spec/runner-claude.md).
- [`deploy-docker/`](deploy-docker/) — runner genérico de despliegue
  (label `deployDocker`), consumido por los pipelines de otras apps de
  la organización, no por ningún workflow de este repo. Incluye el
  cliente `docker` (con acceso al `dockerd` del host vía socket
  montado, Docker-outside-of-Docker) pero no decide qué se despliega.
  Detalle completo en
  [`spec/runner-deploy-docker.md`](spec/runner-deploy-docker.md).

Al añadir un runner nuevo se crean tres cosas a la vez: la carpeta con su
`Dockerfile`/`entrypoint.sh` (minimal para lo que ese workflow concreto
necesita — no se comparte una imagen "todo incluido" entre runners), su
servicio en `docker-compose.yml`, y su fichero `spec/runner-<nombre>.md`.
Las convenciones completas para esto viven en [`CLAUDE.md`](CLAUDE.md).

## Arranque rápido

```bash
cp .env.example .env
# editar .env: GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, COMPOSE_PROFILES...
# crear $SECRETS_DIR y colocar ahí los secretos de cada runner (ver más abajo)
docker compose up -d
```

## Configuración y arranque

La configuración de todo el proyecto vive en un único `.env` en la raíz
(copiar desde `.env.example`). Incluye, por cada servicio, sus variables
propias (por ejemplo `GITHUB_ORG`, `RUNNER_NAME`... para `claude-runner`).

Qué servicios arrancan se controla con `COMPOSE_PROFILES` en ese `.env`:
cada servicio de `docker-compose.yml` está etiquetado con un `profiles:
[...]`, y basta con incluir o quitar ese nombre de la lista para
activarlo o dejarlo parado, sin tocar el propio `docker-compose.yml`.

```
docker compose up -d
```

levanta únicamente los servicios cuyo profile esté en `COMPOSE_PROFILES`.

## Registro contra la organización

Los runners se autentican como una GitHub App (no con un token de
registro estático, que caduca en ~1h) y usan la API de GitHub para:

1. Generar un JWT firmado con la clave privada de la App.
2. Cambiarlo por un installation access token.
3. Pedir con ese token un registration token de la organización.
4. Registrar el runner (`config.sh`) con ese token y arrancarlo (`run.sh`).

Al parar el contenedor (`SIGTERM`/`SIGINT`) se desregistra automáticamente
para no dejar runners "offline" colgados en la organización.

Variables de entorno requeridas por runner:

- `GITHUB_ORG`
- `GITHUB_APP_ID`
- `GITHUB_APP_INSTALLATION_ID`
- `GITHUB_APP_PRIVATE_KEY_PATH` (ruta a la `.pem`, montada como volumen)
- `RUNNER_NAME` / `RUNNER_LABELS` (opcionales)

## Estado y secretos

Nada sensible se hornea en la imagen. Se monta como volumen en tiempo de
ejecución:

- La clave privada de la GitHub App (`.pem`).

`claude` no requiere ningún estado persistente en este runner: se
autentica con `CLAUDE_CODE_OAUTH_TOKEN` (token de larga duración
generado con `claude setup-token`), guardado como secreto de
organización en GitHub y pasado como variable de entorno a nivel de
workflow (no de este repo) en cada ejecución -- no hace falta login
interactivo ni volumen para `~/.claude`. Tampoco necesita ninguna clave
SSH: las etapas `preparation`/`implementation` de la pipeline de issues
hacen `git push` por HTTPS con el `GITHUB_TOKEN` efímero del propio job
(`permissions: contents: write`, scopeado a esas dos etapas), no con una
deploy key estática (ver "Pipeline de issues dirigida por labels" más
abajo y [`spec/runner-claude.md`](spec/runner-claude.md)).

Los certificados y claves privadas de todos los runners viven fuera del
repo, en una ruta del sistema: `SECRETS_DIR` (configurable en `.env`,
por defecto `/etc/github-selfhosted-runners/secrets`). Todos los runners
de este repo se registran con la misma GitHub App (una única instalación
a nivel de organización), así que comparten el mismo
`github-app-private-key.pem` -- no hace falta un fichero por runner.
Antes de levantar `claude-runner` hay que crear esa ruta en la máquina
host y colocar ahí sus ficheros:

```
sudo mkdir -p /etc/github-selfhosted-runners/secrets
sudo cp github-app-private-key.pem /etc/github-selfhosted-runners/secrets/
# El contenedor corre como `runner` (uid:gid 1001:1001, fijado en
# claude/Dockerfile), no como root -- este fichero debe ser suyo, no de
# root, o el runner no podrá leerlo pese al `:ro` del mount.
sudo chown 1001:1001 /etc/github-selfhosted-runners/secrets/github-app-private-key.pem
sudo chmod 700 /etc/github-selfhosted-runners/secrets
sudo chmod 600 /etc/github-selfhosted-runners/secrets/github-app-private-key.pem
```

`docker-compose.yml` monta ese fichero desde `$SECRETS_DIR/`
dentro del contenedor; no forma parte del repo ni del `.env`.

Ningún runner de este repo monta ya ninguna clave SSH: `claude-runner`
pushea con el `GITHUB_TOKEN` efímero del job (ver arriba) y
`deploy-docker-runner` obtiene, bajo demanda, un installation access
token de esta misma GitHub App para clonar por HTTPS otros repos
privados de la organización durante el deploy (ver
[`spec/runner-deploy-docker.md`](spec/runner-deploy-docker.md), sección
"Registro y baja").

`deploy-docker-runner` añade estado propio, fuera del patrón anterior de
"solo secretos de solo lectura": monta `/var/run/docker.sock` del host
(`:rw`, Docker-outside-of-Docker) y hace bind mount 1:1 de `DEPLOY_DIR`
(variable de `.env`, ruta del host fuera del repo). Es una decisión de
diseño consciente, documentada en detalle en
[`spec/runner-deploy-docker.md`](spec/runner-deploy-docker.md).

`DEPLOY_DIR/<proyecto>` debe pertenecer a uid:gid `1001:1001` (el mismo
usuario `runner`) antes de que un workflow consumidor haga
`git pull`/`git clone` ahí -- igual que `github-app-private-key.pem`
más arriba. Si `deploy-docker-runner` crea ese subdirectorio por
primera vez (el primer `git clone` de un workflow consumidor), ya queda
con el propietario correcto y no hace falta ninguna acción manual. El
problema solo aparece si `DEPLOY_DIR/<proyecto>` ya existía de antes con
otro propietario (root, otro usuario, un checkout manual previo) -- en
ese caso, aplicar `sudo chown -R 1001:1001 DEPLOY_DIR/<proyecto>` antes
de que el pipeline consumidor use el runner (ver
[`spec/runner-deploy-docker.md`](spec/runner-deploy-docker.md)).

## Pipeline de issues dirigida por labels

Este repo se gestiona a sí mismo con una pipeline de issues por labels
(`.github/workflows/issue-pipeline.yml`), que corre sobre el propio
runner `claude` definido aquí: el repo se apoya en la infraestructura
que él mismo define, no en runners alojados por GitHub.

Cada etapa se dispara al añadir un label a un issue (o al comentar en un
issue que ya lo tiene, para responder preguntas aclaratorias sin quitar
y volver a poner el label):

| Label            | Qué hace                                                                                     |
| ---------------- | --------------------------------------------------------------------------------------------- |
| `documentation`  | Analiza el issue y propone (solo comenta, no escribe) un plan de cambios en `spec/`.           |
| `preparation`    | Crea/reutiliza la rama `issue-<n>` y aplica en ella los cambios de `spec/` acordados.           |
| `implementation` | Sobre esa misma rama, implementa el cambio real de código.                                     |
| `merge`          | Abre un Pull Request desde `issue-<n>` contra la rama por defecto.                              |

Cada etapa comprueba primero que quien disparó el evento tiene permiso
`write`/`admin` sobre el repo, y arranca revisando `CLAUDE.md` y `spec/`
como fuente de verdad de las convenciones del proyecto. Detalle completo
de esta pipeline y de las convenciones de runners en [`CLAUDE.md`](CLAUDE.md).

## Documentación

- [`CLAUDE.md`](CLAUDE.md) — convenciones del proyecto: estructura,
  cómo añadir/modificar runners, y cómo funciona la pipeline de issues.
- [`spec/`](spec/) — un fichero `runner-<nombre>.md` por runner, con el
  detalle específico de cada uno (imagen, autenticación, secretos,
  variables de entorno).

## TODO

- Automatizar el despliegue de los contenedores en la VM (docker compose
  o similar).
- Añadir el resto de runners a medida que se necesiten nuevos workflows.
