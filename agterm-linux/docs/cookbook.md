# Cookbook on Linux

The shared [cookbook](../../cookbook/) ships with the upstream recipes.
Use Ctrl for the platform command modifier and install scripts under your Linux home directory.
Paths such as `/Users/you/bin` in upstream examples become `/home/you/bin`.
Install Python 3, bash, and jq where a recipe requires them.
The named-companion and end-of-task-offer recipes use the same control protocol on Linux.

## Container overlays

The [container-overlays recipe](../../cookbook/container-overlays/) supports terminal programs,
HTML files, and URL pages through a host receiver.
On native Linux Docker, a bridge container's `host.docker.internal` does not reach a receiver bound
to the host's loopback address.
For a local development container, keep the receiver on `127.0.0.1` and use host networking:

```sh
docker run -d --name dev --hostname dev --network host \
  -v "$HOME/agterm-bridge":/agterm-bridge \
  -e AGT_OVL_HOST=127.0.0.1 -e AGT_OVL_EXPOSE= \
  -e AGTERM_SESSION_ID -e AGTERM_WINDOW_ID -e AGTERM_WORKSPACE_ID \
  -e AGTERM_PANE -e AGTERM_PANE_ID YOUR_IMAGE sleep infinity
```

Host networking also makes the container's development server reachable on host loopback,
so this form omits `-p` and disables the recipe's port-publishing helper.
The receiver can control the terminal as your account; keep its loopback binding and stop it when finished.

The receiver's default command template names `/usr/local/bin/docker`.
If `command -v docker` returns `/usr/bin/docker`, start the receiver with this template:

```sh
uv run agtermctl-receiver.py --exec-template \
  '/usr/bin/docker exec -it -e TERM=xterm-ghostty -e COLORTERM=truecolor {ENVFLAGS} {CONTAINER} sh -c "$(printf %s {B64} | base64 -d)"'
```

Follow the recipe's remaining wrapper, bind-map, staging, and terminfo setup.
Its overlay wrapper targets the HTML/URL/program flags available in v0.39.0;
open image and Markdown pages with the host's `agtermctl` directly.
