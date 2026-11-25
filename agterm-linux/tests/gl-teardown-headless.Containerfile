# gl_teardown_headless.sh's image; its usage comment says how to build this and the image below.
FROM localhost/agterm-linux-ci:latest
RUN apt-get update && apt-get install -y --no-install-recommends sway fonts-dejavu-core procps \
    && rm -rf /var/lib/apt/lists/*
