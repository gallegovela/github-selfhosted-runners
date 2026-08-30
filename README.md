# gallegovela-github-selfhosted-runners

Runners de GitHub Actions autoalojados (self-hosted) para la organización
`gallegovela`. Cada runner se ejecuta como contenedor Docker en una única
máquina virtual, y se registra contra la organización (no contra un repo
concreto) para poder atender workflows de cualquier repo que lo necesite.

## Estructura

Un único `docker-compose.yml` en la raíz define todos los servicios
(runners). Cada subcarpeta es un runner independiente, con su propio
`Dockerfile` y `entrypoint.sh`, usado como build context por el servicio
correspondiente:

- `claude/` — runner para el workflow `.github/workflows/issue-pipeline.yml`
  (label `ionosL1`). Incluye `git`, `gh`, `ssh` y la CLI de `claude`.

Al añadir un nuevo runner, se crea una carpeta nueva con su propio
`Dockerfile`/`entrypoint.sh`, minimal para lo que ese workflow concreto
necesita — no se comparte una imagen "todo incluido" entre runners — y se
añade su servicio a `docker-compose.yml`.

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
- La clave SSH privada que usan los workflows para hacer `git push`.
- La sesión/autenticación de `claude` (`~/.claude`,
  `~/.local/share/claude`), que se inicia una vez de forma interactiva
  tras levantar el contenedor (el login OAuth no se puede scriptar).

Los certificados y claves privadas de todos los runners viven fuera del
repo, en una ruta del sistema: `SECRETS_DIR` (configurable en `.env`,
por defecto `/etc/github-selfhosted-runners/secrets`), con un
subdirectorio por servicio. Antes de levantar `claude-runner` hay que
crear esa ruta en la máquina host y colocar ahí sus ficheros:

```
sudo mkdir -p /etc/github-selfhosted-runners/secrets/claude
sudo cp github-app-private-key.pem /etc/github-selfhosted-runners/secrets/claude/
sudo cp id_ed25519 /etc/github-selfhosted-runners/secrets/claude/
# El contenedor corre como `runner` (uid:gid 1001:1001, fijado en
# claude/Dockerfile), no como root -- estos ficheros deben ser suyos,
# no de root, o el runner no podrá leerlos pese al `:ro` del mount.
sudo chown -R 1001:1001 /etc/github-selfhosted-runners/secrets/claude
sudo chmod 700 /etc/github-selfhosted-runners/secrets /etc/github-selfhosted-runners/secrets/claude
sudo chmod 600 /etc/github-selfhosted-runners/secrets/claude/*
```

`docker-compose.yml` monta esos ficheros desde `$SECRETS_DIR/claude/`
dentro del contenedor; no forman parte del repo ni del `.env`.

`id_ed25519` debe ser una clave dedicada a este runner (deploy key),
no una clave personal ni la de `root` del host -- un símlink a
`/root/.ssh/id_ed25519`, por ejemplo, mezclaría la identidad del
runner con la del administrador de la máquina.

## TODO

- Automatizar el despliegue de los contenedores en la VM (docker compose
  o similar).
- Añadir el resto de runners a medida que se necesiten nuevos workflows.
