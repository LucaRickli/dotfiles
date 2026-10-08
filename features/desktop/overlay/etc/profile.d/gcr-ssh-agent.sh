# shellcheck shell=sh
# SSH_AUTH_SOCK for every session: gcr's agent (gcr-ssh-agent.socket, which
# features/desktop's preset enables). The socket sets it only in systemd's
# user environment, which the compositors greetd starts do not inherit;
# greetd (source_profile) and xrdp's startwm.sh source /etc/profile. An agent
# that is already set (ssh -A, one of your own) stays.
if [ -z "${SSH_AUTH_SOCK:-}" ] && [ -S "${XDG_RUNTIME_DIR:-/nonexistent}/gcr/ssh" ]; then
    SSH_AUTH_SOCK=$XDG_RUNTIME_DIR/gcr/ssh
    export SSH_AUTH_SOCK
fi
