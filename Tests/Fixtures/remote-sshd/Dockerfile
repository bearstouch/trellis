# A disposable SSH host for scripts/test-remote-docker.sh (FR-RW02, FR-RW03): key-only login for `dev`, bash as the
# login shell, nothing of Trellis preinstalled.
FROM debian:stable-slim
RUN apt-get update -qq && apt-get install -y -qq openssh-server procps >/dev/null && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd && useradd -m -s /bin/bash dev && passwd -d dev >/dev/null \
 && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
ARG PUBLIC_KEY
RUN mkdir -p /home/dev/.ssh && echo "$PUBLIC_KEY" > /home/dev/.ssh/authorized_keys \
 && chown -R dev:dev /home/dev/.ssh && chmod 700 /home/dev/.ssh && chmod 600 /home/dev/.ssh/authorized_keys
CMD ["/usr/sbin/sshd", "-D", "-e"]
