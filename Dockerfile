ARG RCLONE_VER="latest"
FROM rclone/rclone:$RCLONE_VER

LABEL maintainer="Gerardo Junior <me@gerardo-junior.com>"
LABEL url="https://github.com/gerardo-junior/rclone-docker.git"

# # Atualizar pacotes e instalar dependências necessárias
# RUN apk update && \
#     apk add --no-cache curl jq

# # Copiar os scripts para o contêiner
COPY ./tools /tools

# Configurar permissões
# VOLUME ["/config"]
# WORKDIR /config
# RUN chgrp -R 0 /config && \
#     chmod -R g+rwX /config && \
#     chown -R rclone:0 /config && \
#     chmod +x /tools/entrypoint.sh

# Definir o ponto de entrada
ENTRYPOINT ["/tools/entrypoint.sh"]
# USER rclone