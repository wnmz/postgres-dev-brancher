# Custom postgres:15 image that hosts a protected "root" database plus
# instant, diff-only btrfs-snapshot branches cloned from it. See
# entrypoint.sh and bin/ for the mechanism. Generic - no assumptions about
# schemas, roles, or how data gets into root.
FROM postgres:15

RUN apt-get update && apt-get install -y --no-install-recommends \
    btrfs-progs \
    util-linux \
    procps \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY bin/_common.sh /usr/local/lib/pgbranch/_common.sh
COPY bin/create bin/list bin/delete bin/lock bin/unlock /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/create /usr/local/bin/list /usr/local/bin/delete /usr/local/bin/lock /usr/local/bin/unlock

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["tail", "-f", "/dev/null"]
