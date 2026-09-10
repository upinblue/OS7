#!/bin/sh
# OS/7 — provision a Samba AD domain controller, then run it in the foreground.
#
# Run time and not build time: see the header of Dockerfile.ad-dc. The short
# version is that `samba-tool domain provision` writes the DC's own A record out
# of the address the machine has while it runs, and a container does not have
# that address until it is started.
#
# THE READINESS MARKER IS THE LAST THING WRITTEN, and it is written only after
# the directory has answered a query. A harness that waits for a port would be
# waiting for the wrong thing: smbd binds 389 before the directory is loaded,
# and a client that connects in that window gets a refusal that looks like a
# credential problem. This is the same rule the rest of the repository follows —
# ask the thing itself, not a proxy for it.
set -eu

REALM="${OS7_AD_REALM:-OS7.TEST}"
DOMAIN="${OS7_AD_DOMAIN:-OS7}"
ADMINPASS="${OS7_AD_ADMINPASS:-Passw0rd-OS7-test}"
READY=/var/lib/samba/.os7-ready

log() { echo "os7-ad-dc: $*" >&2; }

if [ ! -f /var/lib/samba/private/sam.ldb ]; then
	log "provisioning realm=${REALM} domain=${DOMAIN}"

	# The packaged smb.conf is a member-server configuration and provision
	# refuses to overwrite it. Removing it is what the Samba documentation
	# tells an administrator to do; it is a file the package ships, not one
	# anybody has edited.
	rm -f /etc/samba/smb.conf

	# posix:eadb IS NOT A TUNING OPTION, IT IS WHY THIS PROVISIONS AT ALL.
	# Measured 2026-08-27: without it, provision runs for a minute, applies
	# 89 domain updates, and then dies in setsysvolacl with
	#
	#   set_nt_acl_conn: fset_nt_acl returned NT_STATUS_ACCESS_DENIED
	#
	# because writing SYSVOL's security.NTACL extended attribute needs
	# CAP_SYS_ADMIN, which Docker drops. This Samba no longer offers
	# `--use-xattrs=no` (it went with the NTVFS file server), so the remaining
	# unprivileged route is Samba's own xattr store: a tdb instead of the
	# filesystem. The alternative is --privileged, and a harness that needs a
	# privileged container is a harness people stop running.
	#
	# The same option has to reach the DAEMON, not just the provision — it is
	# written into smb.conf below — or smbd hits the identical wall when it
	# serves SYSVOL.
	samba-tool domain provision \
		--use-rfc2307 \
		--realm="${REALM}" \
		--domain="${DOMAIN}" \
		--server-role=dc \
		--dns-backend=SAMBA_INTERNAL \
		--adminpass="${ADMINPASS}" \
		--option="posix:eadb=/var/lib/samba/private/eadb.tdb" \
		>/dev/null

	if ! grep -q "posix:eadb" /etc/samba/smb.conf; then
		log "carrying posix:eadb into smb.conf for the daemon"
		sed -i '/^\[global\]/a\\tposix:eadb = /var/lib/samba/private/eadb.tdb' \
			/etc/samba/smb.conf
	fi
	grep -q "posix:eadb" /etc/samba/smb.conf || {
		log "FAILED: posix:eadb did not reach smb.conf"
		exit 1
	}

	# The Kerberos configuration provision generates names this realm and its
	# KDC. Putting it where the krb5 library looks means kinit inside this
	# container needs no arguments — which matters, because the checks use it
	# as an INDEPENDENT witness that a ticket the client obtained is real.
	cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf

	# TLS is on by default and the certificate is self-signed. The checks copy
	# this CA out and install it on the client, which is not a workaround: it
	# is exactly the step an administrator performs before LDAPS works, and
	# OS/7 has a cmdlet story for it. Named here so the file is easy to find.
	log "CA for LDAPS: /var/lib/samba/private/tls/ca.pem"
else
	log "already provisioned"
fi

log "starting samba"
samba --foreground --no-process-group &
SAMBA_PID=$!

# Wait for the DIRECTORY, not for the socket. Sixty seconds is generous: a
# provisioned DC answers in two or three on any machine that can run this at
# all. Failing loudly here is the point — a harness that proceeds against a DC
# which never came up reports a client defect that does not exist.
i=0
while [ "${i}" -lt 60 ]; do
	if ldbsearch -H /var/lib/samba/private/sam.ldb \
		-b "" -s base defaultNamingContext >/dev/null 2>&1 &&
		ldapsearch -x -H ldap://localhost -s base -b "" defaultNamingContext \
			>/dev/null 2>&1; then
		echo "${REALM}" >"${READY}"
		log "ready: the directory answered on ldap://localhost"
		break
	fi
	i=$((i + 1))
	sleep 1
done

if [ ! -f "${READY}" ]; then
	log "FAILED: samba did not answer LDAP within 60s"
	kill "${SAMBA_PID}" 2>/dev/null || true
	exit 1
fi

wait "${SAMBA_PID}"
