# The bench tailnet's second node: a peer the OS/7 machine must be able to reach,
# so "Running" is checked against a packet and not only against a word. Tailscale
# from the vendor's tarball at the version the role's fixtures were recorded with.
#
# NO CERTIFICATE IS BAKED IN. run-tailscale.py makes a new lab CA on every run and
# mounts it at /usr/local/share/ca-certificates/os7-tslab.crt; the command below
# trusts whatever is mounted there before tailscaled starts. The same image also
# makes that CA (openssl is a dependency of ca-certificates), so the lab needs no
# openssl on the host.
FROM ubuntu:26.04
ARG TS_VERSION=1.104.5
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      ca-certificates curl iproute2 iptables iputils-ping >/dev/null \
 && curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_amd64.tgz" | tar xz -C /tmp \
 && install -m 0755 /tmp/tailscale_${TS_VERSION}_amd64/tailscale /usr/bin/tailscale \
 && install -m 0755 /tmp/tailscale_${TS_VERSION}_amd64/tailscaled /usr/sbin/tailscaled \
 && rm -rf /tmp/tailscale_* /var/lib/apt/lists/*
CMD ["/bin/sh", "-c", "update-ca-certificates >/dev/null && exec /usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock"]
