ARG RCLONE_VER="latest"
FROM rclone/rclone:$RCLONE_VER

LABEL maintainer="Gerardo Junior <me@gerardo-junior.com>"
LABEL url="https://github.com/gerardo-junior/nuxtjs-docker.git"

RUN apk update && \
    apk add python3 py3-requests

COPY ./tools /tools
# RUN pip install -r /tools/requirements.txt

VOLUME ["/config"]
WORKDIR /config
RUN chgrp -R 0 /config && \
    chmod -R g+rwX /config && \
    chown -R rclone:0 /config && \
    chmod +x /tools/entrypoint.sh
ENTRYPOINT ["/tools/entrypoint.sh"]
USER rclone