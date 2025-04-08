#!/bin/sh

# Variáveis padrão
RCLONE_PORT="${RCLONE_PORT:-5572}"
RCLONE_USERNAME="${RCLONE_USERNAME:-rclone}"
RCLONE_PASSWORD="${RCLONE_PASSWORD:-rclone}"
RCLONE_URL="http://127.0.0.1:${RCLONE_PORT}"
MOUNTS_FILE="${MOUNTS_FILE:-"/config/mounts.json"}"

api_url="$RCLONE_URL/mount/listmounts"
mounts_file="$MOUNTS_FILE"

# Verificar se o arquivo mounts.json existe
if [ ! -f "$mounts_file" ]; then
  echo "ERROR: $mounts_file not found."
  exit 1
fi

# Verificar se o arquivo mounts.json contém um array vazio
if jq -e '. | length == 0' "$mounts_file" >/dev/null 2>&1; then
  echo "NOTICE: $mounts_file is empty. No mounts to validate. Considering healthy."
  exit 0
fi

# Obter a lista de mounts ativos da API
active_mounts=$(curl -s -X POST -u "$RCLONE_USERNAME:$RCLONE_PASSWORD" "$api_url" | jq -c '.mountPoints[]' 2>/dev/null)
if [ -z "$active_mounts" ]; then
  echo "ERROR: Failed to fetch active mounts from Rclone API."
  exit 1
fi

# Validar cada ponto de montagem configurado no mounts.json
all_mounts_valid=0
while IFS= read -r configured_mount; do
  fs=$(echo "$configured_mount" | jq -r '.fs')
  mount_point=$(echo "$configured_mount" | jq -r '.mountPoint')

  # Verificar se o ponto de montagem está ativo
  if ! echo "$active_mounts" | jq -e --arg fs "$fs" --arg mount_point "$mount_point" \
    'select(.Fs == $fs and .MountPoint == $mount_point)' >/dev/null; then
    echo "ERROR: Mount $fs at $mount_point is not active."
    all_mounts_valid=1
  fi
done < <(jq -c '.[]' "$mounts_file")

# Retornar sucesso se todos os mounts estiverem ativos
if [ "$all_mounts_valid" -eq 0 ]; then
  echo "All mounts are active."
  exit 0
else
  exit 1
fi
