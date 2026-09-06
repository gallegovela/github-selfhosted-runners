# Runner: deploy-docker

Carpeta: `deploy-docker/`. Servicio propuesto en `docker-compose.yml`:
`deploy-docker-runner` (profile `deploy-docker`, imagen
`gallegovela-github-selfhosted-runners/deploy-docker-runner:latest`,
contenedor `gh-runner-deploy-docker`).

## Propósito

Runner genérico de infraestructura: el paso final de los pipelines de
**varias aplicaciones distintas** de la organización (no solo de este
repo), que hace checkout del código de una app y la despliega
recompilando sus imágenes y reiniciando sus contenedores en la misma
máquina host donde vive el runner. Se registra contra la organización
con un label propio (p.ej. `deployDocker`), reclamado por los workflows
consumidores con `runs-on: deploy-docker`.

Es deliberadamente una **capacidad de infraestructura, no un flujo de
despliegue prescrito**: este runner provee acceso al Docker del host y a
la configuración persistente de cada proyecto, pero no decide qué
comandos se ejecutan (`docker compose build`, `up`, `down`, en qué
orden...) -- eso lo define el workflow de cada repo consumidor. Igual
que `claude` (ver `spec/runner-claude.md`), es minimal: solo lleva lo
que esta función necesita, no el toolchain propio de ninguna app
concreta.

## Imagen (`deploy-docker/Dockerfile`)

- Base: `ubuntu:24.04` (igual que `claude/`).
- Paquetes base: `ca-certificates`, `curl`, `git`, `openssl`.
- CLI `docker` + plugin `compose`, instalados desde el repositorio APT
  oficial de Docker. **Sin `dockerd` propio** -- ver "Docker-outside-of-
  Docker" más abajo. Sin `gh`, salvo que algún workflow consumidor lo
  necesite (no es una dependencia de este runner en sí).
- El binario del runner de GitHub Actions (`actions-runner`) se descarga
  fijado por versión y verificado por `sha256sum`, igual que en
  `claude/Dockerfile`.
- Usuario no root: se crea el usuario `runner`, con el mismo
  razonamiento que en `claude/Dockerfile` (el runner de Actions rechaza
  ejecutarse como root). Además de su uid/gid propios, este usuario debe
  pertenecer al **grupo `docker` del host** para poder usar el socket
  montado (ver más abajo) -- el gid de ese grupo varía entre hosts, así
  que se fija en build time vía `ARG`/variable de entorno
  (`DOCKER_GID` o similar), no hardcodeado.
- `actions-runner/_work` se pre-crea en la imagen, propiedad de
  `runner`, por el mismo motivo que en `claude/Dockerfile` (evitar que
  Docker lo cree como root al montarlo).
- `get-installation-token.sh` (ver "Registro y baja" más abajo) se copia
  a `/home/runner/bin` y se añade al `PATH` -- además de usarlo el
  propio `entrypoint.sh` para registrarse, queda disponible para que
  cualquier step de un workflow consumidor que corra en este runner lo
  invoque directamente.
- `installdependencies.sh` del runner de Actions corre como root
  (necesita `apt-get`); todo lo demás corre como `runner`.
- La imagen configura `git config --global --add safe.directory '*'`
  para el usuario `runner`, para que el `git clone`/`git pull` que hacen
  los workflows consumidores dentro de `DEPLOY_DIR/<proyecto>` no falle
  por "dubious ownership" cuando el propietario en el host de esa ruta no
  coincide con el uid de `runner` en el contenedor (ver "Decisión de
  diseño" más abajo).

## Registro y baja como runner de organización (`deploy-docker/entrypoint.sh`)

Mismo patrón que `claude/entrypoint.sh` (ver `spec/runner-claude.md`,
sección homónima), con su propio `entrypoint.sh` -- no se comparte
imagen ni script entre runners, según la convención de este repo:

1. JWT firmado en RS256 con la clave privada de la GitHub App
   (`GITHUB_APP_PRIVATE_KEY_PATH`).
2. Cambio del JWT por un installation access token.
3. Registration token de la organización con ese installation token.
4. `config.sh --url https://github.com/<org> --token <reg_token> --name
   <RUNNER_NAME> --labels <RUNNER_LABELS> --unattended --replace`,
   seguido de `run.sh`.

Al recibir `SIGTERM`/`SIGINT`, se desregistra (JWT -> installation token
-> remove-token -> `config.sh remove`), de forma best-effort, igual que
`claude`. `docker-compose.yml` debe darle el mismo `stop_grace_period:
30s` que a `claude-runner`, por el mismo motivo (la cadena de llamadas a
la API de GitHub necesita más tiempo que el grace period por defecto de
Compose).

No necesita ninguna clave SSH. El checkout de la app desplegada en sí lo
sigue haciendo el workflow consumidor con `actions/checkout` y su token
efímero estándar, pero el propio paso de deploy dentro de ese workflow
puede necesitar clonar otros repos privados de la organización
(submódulos, dependencias internas) que ese token efímero no cubre --
para eso, `get-installation-token.sh` (`/home/runner/bin`, en el `PATH`)
obtiene bajo demanda un installation access token de la misma GitHub App
compartida que ya usa para registrarse (`GITHUB_APP_ID` +
`GITHUB_APP_INSTALLATION_ID` + `GITHUB_APP_PRIVATE_KEY_PATH`, ya
montados; el mismo mecanismo JWT -> installation token de los pasos 1-2
de más arriba, extraído a un script propio en vez de duplicado inline,
sin ningún secreto nuevo). Un step de un workflow consumidor lo invoca
directamente para clonar por HTTPS
(`git clone https://x-access-token:$(get-installation-token.sh)@github.com/...`).
Precondición operativa: si la instalación de la GitHub App está limitada a
"selected repositories", hay que añadir a esa lista los repos
adicionales que el deploy necesite clonar; si está instalada a nivel de
organización completa, no hace falta nada.

## Variables de entorno

Requeridas (sin default, `docker-compose.yml` falla si faltan):

- `GITHUB_ORG`
- `GITHUB_APP_ID`
- `GITHUB_APP_INSTALLATION_ID`

Con default en `docker-compose.yml`:

- `RUNNER_NAME` (propio de este runner, p.ej. `deploy-docker-runner-1`)
- `RUNNER_LABELS` (propio, p.ej. `deployDocker`)

Nueva, sin default, configurada en `.env` (mismo patrón que
`SECRETS_DIR`):

- `DEPLOY_DIR`: ruta del host, fuera del repo, con un subdirectorio por
  proyecto desplegado (`DEPLOY_DIR/<proyecto>`), montada como bind mount
  1:1 dentro del contenedor (ver "Secretos y volúmenes").

Fijada por el propio `docker-compose.yml` (no configurable por `.env`):

- `GITHUB_APP_PRIVATE_KEY_PATH=/home/runner/secrets/github-app-private-key.pem`

## Secretos y volúmenes

- `github-app-private-key.pem`, montado desde `$SECRETS_DIR` igual que
  en `claude-runner` (`:ro`), propiedad del uid:gid del usuario `runner`
  de este runner en el host.
- **`/var/run/docker.sock` del host, montado `:rw`.** Esta es una
  **decisión de diseño consciente**, no un volumen más: un socket Docker
  da control root-equivalente sobre el host (cualquier proceso que pueda
  hablar con él puede montar cualquier ruta del host, ejecutar contenedores
  privilegiados, etc.). Es una desviación explícita de la filosofía de
  secretos de este proyecto ("nada sensible se monta salvo secretos de
  solo lectura" -- ver `CLAUDE.md`), asumida porque es el único mecanismo
  para que este runner, corriendo él mismo en un contenedor, deje
  contenedores desplegados corriendo en el host una vez termina su
  propia ejecución (patrón **Docker-outside-of-Docker**, no
  Docker-in-Docker: no lleva `dockerd` propio, habla directamente con el
  daemon del host a través del socket).
- **Bind mount de `DEPLOY_DIR`, 1:1 (misma ruta dentro y fuera del
  contenedor)**, tomada directamente del valor de `DEPLOY_DIR` en
  `.env` -- no se mapea a un alias interno fijo (p.ej. `/var/www`). El
  motivo: el `docker compose` que corre dentro de este contenedor habla
  con el *dockerd del host* a través del socket, así que cualquier bind
  mount relativo que declare el `docker-compose.yml` de una app
  desplegada lo resuelve el dockerd usando la ruta que ve el proceso que
  invocó `compose` -- si esa ruta no coincide dentro y fuera del
  contenedor del runner, esos bind mounts de la app resolverían mal en
  el host.

  Dentro de `DEPLOY_DIR` cada proyecto tiene su propio subdirectorio
  (`DEPLOY_DIR/<proyecto>`), con los ficheros de configuración/datos
  persistentes de esa app, conocido por convención de nombre por su
  propio pipeline consumidor.

  `DEPLOY_DIR/<proyecto>` debe pertenecer a uid:gid `1001:1001` (el
  mismo usuario `runner`) antes de que un workflow consumidor haga
  `git pull`/`git clone` ahí -- ver las instrucciones operativas en
  `README.md`, sección "Estado y secretos".

## Decisión de diseño: Docker-outside-of-Docker y flujo de despliegue

- **DooD, no DinD**: se eligió montar el socket del host en vez de correr
  un `dockerd` propio dentro del contenedor del runner porque el
  objetivo es que los contenedores desplegados sobrevivan a la propia
  ejecución del runner (y a su recreación) -- con DinD quedarían
  anidados dentro de un daemon efímero, no en el host real.

- **Dirección del copiado: checkout -> `DEPLOY_DIR/<proyecto>`, no al
  revés.** El workflow consumidor debe copiar el código recién
  descargado hacia `DEPLOY_DIR/<proyecto>` y compilar/desplegar desde
  ahí, no copiar la configuración de `DEPLOY_DIR` hacia el workspace
  efímero del checkout. Motivos:
  - **Persistencia**: si el `docker-compose.yml` de la app tiene sus
    propios bind mounts (datos de base de datos, uploads, logs), esas
    rutas solo sobreviven entre despliegues si el propio
    `docker-compose.yml` vive en una ruta estable del host
    (`DEPLOY_DIR/<proyecto>`) y no en el workspace efímero de
    `actions-runner/_work` (volumen nombrado, no bind mount 1:1, y que
    desaparece en cada recreación del contenedor del runner).
  - **Menor exposición de secretos**: la configuración de cada proyecto
    en `DEPLOY_DIR` suele incluir secretos/config de producción. Mover
    código (público, sin secretos) hacia `DEPLOY_DIR` expone menos que
    mover esa configuración hacia el workspace efímero del checkout.
  - **Consistencia operativa**: un operador que entra al host siempre
    encuentra el estado desplegado de cada proyecto en la misma ruta.

  Al copiar, el workflow consumidor no debe pisar ficheros que solo
  existen en `DEPLOY_DIR` (datos persistentes, `.env` de producción no
  versionado) -- típicamente con `rsync --exclude` o una convención
  documentada de qué vive en git y qué es local-only. Esto es
  responsabilidad de cada pipeline consumidor, no de este runner, pero
  explica por qué `DEPLOY_DIR` es una ruta estable por proyecto y no un
  directorio recreado en cada despliegue.

- **Riesgo de auto-recreación**: si el `docker compose up` de una app
  desplegada recreara por error un contenedor o red que coincide en
  nombre con los del propio runner, el runner podría auto-desregistrarse
  a media ejecución. No es un riesgo del día a día dado que cada app
  vive en su propio subdirectorio de `DEPLOY_DIR` con su propio
  `docker-compose.yml`, pero cada pipeline consumidor debe nombrar sus
  servicios/redes evitando colisión con los del runner.

- **Propiedad real de `DEPLOY_DIR/<proyecto>`, distinta del problema de
  `safe.directory`**: el `Permission denied` real al escribir dentro de
  `.git/` (issue #5) no es el mismo fallo que el "dubious ownership" del
  issue #3 -- `safe.directory` silencia una comprobación de seguridad de
  git sobre el propietario del directorio, pero no concede permisos de
  escritura reales a nivel de filesystem. Se ha optado por documentar la
  propiedad esperada (`1001:1001`) como responsabilidad operativa (ver
  "Secretos y volúmenes" y `README.md`) en vez de añadir una
  comprobación/healthcheck automática al arranque del contenedor,
  coherente con la misma decisión ya tomada para `safe.directory` más
  abajo (documentar en vez de automatizar). Si en el futuro se quiere
  una comprobación activa, que sea un issue aparte.

- **Installation token de la GitHub App en vez de una deploy key SSH
  estática** para clonar repos privados adicionales durante el deploy
  (ver "Registro y baja"): un token de vida corta (~1h) pedido bajo
  demanda reutiliza infraestructura ya existente en este runner (el
  mismo mecanismo JWT -> installation token del registro) sin añadir
  ningún secreto nuevo, frente a una clave SSH estática compartida entre
  runners. Al dejar de necesitarse SSH en ningún runner de este repo,
  también permitió retirar `openssh-client` y la pre-creación de
  `~/.ssh`/`ssh-keyscan` de ambas imágenes, y el volumen `id_ed25519` de
  `docker-compose.yml`.

- **`safe.directory` con comodín (`'*'`), no rutas concretas**:
  `DEPLOY_DIR/<proyecto>` es dinámico (un subdirectorio por app
  desplegada, con nombre decidido por cada pipeline consumidor), así que
  no hay una lista fija de rutas que registrar una a una en
  `safe.directory` -- de ahí el comodín en vez de una entrada por
  proyecto. Es una ampliación de superficie menor comparada con el
  riesgo ya asumido y documentado del socket Docker montado `:rw`
  (acceso root-equivalente al host): confiar en cualquier directorio para
  operaciones `git` es un riesgo bajo en comparación. Esta configuración
  es solo para el usuario `runner` de *este* contenedor, no afecta a
  `claude-runner` ni a ningún otro runner.

## Referencia cruzada

- Origen: issue #1 ("Nuevo runner para despliegue"), hilo completo de
  decisiones de diseño (DooD, `DEPLOY_DIR` 1:1, dirección del copiado).
  Issue #3 ("Error en action que usa el runner deploy-docker"): fallo
  "dubious ownership" de git en `DEPLOY_DIR/<proyecto>` por desajuste de
  propietario entre el host y el uid de `runner`, resuelto con
  `safe.directory '*'`. Issue #5 ("Problema con runner deploy-docker"):
  `Permission denied` real al escribir `.git/FETCH_HEAD` en
  `DEPLOY_DIR/<proyecto>` -- propiedad real de filesystem, no
  "dubious ownership" -- y sustitución de la deploy key SSH por un
  installation token de la GitHub App para clonar repos privados
  adicionales durante el deploy.
- Convenciones generales de runners: `CLAUDE.md`.
- Runner de referencia para estructura de imagen/registro:
  `spec/runner-claude.md`.
- Workflow(s) que consumen este runner: ninguno en este repo -- cada
  repo de aplicación define su propio pipeline con
  `runs-on: deploy-docker`.
