# Runner: claude-test

Carpeta: `claude-test/`. Servicios en `docker-compose.yml`:
`claude-test-runner` (imagen `gallegovela-github-selfhosted-runners/claude-test-runner:latest`,
contenedor `gh-runner-claude-test`) y su contenedor auxiliar
`claude-test-dind` (imagen `docker:<versión>-dind`, contenedor
`gh-runner-claude-test-dind`). Los dos con el profile `claude-test`.

## Propósito

Atiende las etapas de una pipeline de issues que, además de ejecutar la
CLI de `claude`, necesitan **construir y probar la rama en contenedores**.
Se registra contra la organización con el label `ionos-l1-test`.

Primer consumidor: `generic-data-collector`, cuyas etapas `develop`,
`testPR` y `module-test` (`issue-pipeline.yml`) levantan con
`docker compose` la rama completa (la app, PostgreSQL, MinIO y Mailpit)
más un contenedor de pruebas, y ejecutan dentro lint, tests unitarios,
build y Playwright. Las demás etapas, que no necesitan Docker, siguen en
`claude-runner`.

## Imagen (`claude-test/Dockerfile`)

Igual que `claude/Dockerfile` (ver `spec/runner-claude.md`), más:

- `docker-ce-cli`, `docker-buildx-plugin` y `docker-compose-plugin`,
  desde el repositorio APT oficial de Docker (el mismo que usa
  `deploy-docker/`). El plugin de Compose tiene que ser 2.24.4 o
  posterior, porque los entornos de prueba de los consumidores usan
  `ports: !reset []`.
- **Sin `dockerd` y sin el socket del host**: el cliente habla con el
  contenedor `claude-test-dind` por TCP (`DOCKER_HOST`).
- Mismo usuario `runner` 1001:1001. No necesita el grupo `docker`,
  porque no hay socket.

También lleva Node, la CLI `codex` y el plugin de Codex, igual que
`claude/Dockerfile` (ver "Codex" en `spec/runner-claude.md`). Los
workflows siguen instalando su versión de Node con `actions/setup-node`,
que queda primero en el `PATH`.

## Registro y baja (`claude-test/entrypoint.sh`)

Copia de `claude/entrypoint.sh` (una carpeta por runner, sin compartir
scripts), con `ionos-l1-test` como label por defecto. Mismo flujo GitHub
App → installation token → registration token, misma baja best-effort al
parar y mismo `stop_grace_period: 30s`.

## Docker-in-Docker (`claude-test-dind`)

- `docker:<versión>-dind` con `privileged: true` (dockerd no arranca sin
  él). La versión mayor se fija con `CLAUDE_TEST_DIND_VERSION`.
- `DOCKER_TLS_CERTDIR=""`: escucha en `tcp://0.0.0.0:2375` **sin TLS ni
  autenticación**. Por eso los dos servicios comparten una red propia,
  `claude-test`, a la que no se conecta ningún otro servicio, y el
  puerto no se publica en el host.
- `/var/lib/docker` en el volumen `claude-test-dind-data`: las capas de
  imagen y la caché de build sobreviven entre ejecuciones y recreaciones
  del contenedor.
- `--mtu` (`CLAUDE_TEST_DIND_MTU`, 1500 por defecto): si en la VM la red
  tiene una MTU menor, las descargas dentro de los contenedores de
  prueba pueden quedarse colgadas; en ese caso, bajarla (por ejemplo a
  1400).

El runner pasa su entorno a cada job, así que cualquier `docker` o
`docker compose` de un workflow usa este daemon sin configuración
adicional en el workflow.

## Decisión de diseño: DinD y no el socket del host

Al contrario que `deploy-docker` (ver `spec/runner-deploy-docker.md`),
este runner **no** monta `/var/run/docker.sock`:

- Lo que se levanta aquí es efímero (un entorno de pruebas por rama, que
  el workflow borra al terminar): no tiene que sobrevivir al runner, que
  era el motivo de usar el Docker del host en `deploy-docker`.
- Los agentes de estas etapas ejecutan comandos con amplios permisos (el
  programador, sin restricciones de herramientas). Con el socket del
  host, un error o un `docker compose down -v` con el nombre de proyecto
  equivocado podría parar o borrar los contenedores desplegados en la
  misma VM. Con DinD solo ven su propio daemon.
- Sin bind mounts compartidos: los consumidores construyen sus imágenes
  enviando el contexto de build al daemon y no montan carpetas del
  workspace en los contenedores, así que no hace falta que las rutas
  coincidan dentro y fuera (el problema que `deploy-docker` resuelve con
  el montaje 1:1 de `DEPLOY_DIR`).

Límite de este aislamiento: un contenedor `privileged` no es una barrera
de seguridad frente a código malicioso (desde dentro de DinD se puede
llegar al host). Protege de errores, no de un atacante. Si hiciera falta
más, la opción es ejecutar `claude-test-dind` con el runtime Sysbox
(`runtime: sysbox-runc`, sin `privileged`), que hay que instalar antes en
la VM.

## Variables de entorno

Requeridas (las mismas que el resto de runners): `GITHUB_ORG`,
`GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`.

Con default en `docker-compose.yml`:

- `CLAUDE_TEST_RUNNER_NAME` (default `claude-test-runner-1`)
- `CLAUDE_TEST_RUNNER_LABELS` (default `ionos-l1-test`)
- `CLAUDE_TEST_DIND_VERSION` (default `28`)
- `CLAUDE_TEST_DIND_MTU` (default `1500`)

Fijadas por `docker-compose.yml`:

- `GITHUB_APP_PRIVATE_KEY_PATH=/home/runner/secrets/github-app-private-key.pem`
- `DOCKER_HOST=tcp://claude-test-dind:2375`

## Secretos y volúmenes

- `github-app-private-key.pem`, montado desde `$SECRETS_DIR` (`:ro`),
  igual que en `claude-runner`.
- `runner-work-claude-test` en `actions-runner/_work` (checkouts y caché
  de herramientas, incluido Node).
- `claude-test-dind-data` en `/var/lib/docker` del contenedor DinD.
- `codex-home-claude-test` en `~/.codex`: el login de Codex de este
  runner (`docker exec -it gh-runner-claude-test codex login --device-auth`,
  ver "Codex" en `spec/runner-claude.md`).

## Imágenes que no se pueden descargar

DinD descarga sus imágenes por su cuenta: no ve las que ya tiene el
Docker del host. Si un consumidor usa una imagen que ya no se publica
(caso de `minio/minio`, retirada de Docker Hub y quay.io), se copia desde
el Docker del host, una vez y cada vez que se borre
`claude-test-dind-data`:

```bash
docker save minio/minio:latest | docker exec -i gh-runner-claude-test-dind docker load
```

## Mantenimiento

La caché de build de DinD crece con cada rama probada (los consumidores
borran sus contenedores, volúmenes e imágenes al terminar, pero no la
caché). Para limpiarla de vez en cuando, desde el host:

```bash
docker exec gh-runner-claude-test-dind docker builder prune -af --filter until=168h
docker exec gh-runner-claude-test-dind docker image prune -af --filter until=168h
```

Borrar el volumen `claude-test-dind-data` también es seguro: solo se
pierde la caché (y las imágenes cargadas a mano, que hay que volver a
cargar). `image prune` tampoco debe borrar esas imágenes: usa el filtro
de fecha o vuelve a cargarlas después.

## Referencia cruzada

- Consumidor: `gallegovela/generic-data-collector`,
  `.github/workflows/issue-pipeline.yml` (`runs-on: ionos-l1-test`) y su
  `specs/platform/design.md`, sección "Pruebas en contenedores".
- Runner base del que parte: `spec/runner-claude.md`.
- El otro runner con Docker, y por qué allí sí se usa el socket del
  host: `spec/runner-deploy-docker.md`.
