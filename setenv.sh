#!/bin/bash
# Run like this  .  ./setenv.sh to externalize the vars

export PATH=/home/alunde/start9-registry/dist:/home/alunde/.cabal/bin:/home/alunde/.ghcup/bin:/home/alunde/.cargo/bin:/home/alunde/.local/bin:$PATH
# export PATH=/home/alunde/.local/bin:/home/alunde/start9-registry/dist:/home/alunde/.cabal/bin:/home/alunde/.ghcup/bin:/home/alunde/.cargo/bin:$PATH
export RESOURCES_PATH=/home/alunde/start9-registry/repository
export SSL_PATH=/home/alunde/start9-registry/ssl
export SSL_AUTO=false
export REGISTRY_HOSTNAME=start9registry.isviable.com
export YESOD_PORT=8443
#export YESOD_PORT=443
export TOR_PORT=447
export STATIC_BIN=/home/alunde/.cargo/bin/
export ERROR_LOG_ROOT=/home/alunde/start9-registry/logs
export MARKETPLACE_NAME="Is Viable"
export PG_DATABASE=s9reg
export PG_USER=s9usr
export PG_PASSWORD=S9R3gistr3y
export PG_HOST=localhost
export PG_PORT=5432


