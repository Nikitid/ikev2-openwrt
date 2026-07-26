#!/bin/sh

# charon reports why a handshake failed to syslog, not through VICI, so the
# operator used to get "the CHILD_SA failed; see logread" and a dead end. The
# fixtures below are real charon output shapes.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

# Run the classifier on its own, against a stubbed logread.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/logread" <<'EOF'
#!/bin/sh
cat "$LOGREAD_FIXTURE"
EOF
chmod +x "$tmp/bin/logread"

sed -n '/^classify_initiate_failure() {/,/^}/p' \
	"$root/luci-ikev2-manager/ikev2-manager.sh" >"$tmp/classify.sh"
[ -s "$tmp/classify.sh" ] || {
	printf 'classify_initiate_failure is missing\n' >&2
	exit 1
}
printf '\nclassify_initiate_failure\n' >>"$tmp/classify.sh"
sh -n "$tmp/classify.sh"

classify() {
	printf '%s\n' "$1" >"$tmp/fixture"
	PATH="$tmp/bin:$PATH" LOGREAD_FIXTURE="$tmp/fixture" sh "$tmp/classify.sh"
}

# The failure actually observed on a router: the gateway renewed to a
# certificate from an intermediate CA and sent only the leaf.
observed='daemon.info ipsec: 16[IKE] received end entity cert "CN=gateway.example"
daemon.info ipsec: 16[CFG] no issuer certificate found for "CN=gateway.example"
daemon.info ipsec: 16[CFG]   issuer is "C=US, O=Let'"'"'s Encrypt, CN=R13"
daemon.info ipsec: 16[IKE] no trusted RSA public key found for '"'"'gateway.example'"'"'
daemon.info ipsec: 16[ENC] generating INFORMATIONAL request 2 [ N(AUTH_FAILED) ]'
result="$(classify "$observed")"
case "$result" in
	*'certificate could not be validated'*'did not send'*) ;;
	*)
		printf 'an incomplete gateway chain was not identified: %s\n' "$result" >&2
		exit 1
		;;
esac

result="$(classify 'daemon.info ipsec: 09[IKE] no proposal chosen')"
case "$result" in
	*'no shared encryption proposal'*) ;;
	*) printf 'a proposal mismatch was not identified: %s\n' "$result" >&2; exit 1 ;;
esac

result="$(classify 'daemon.info ipsec: 11[IKE] giving up after 5 retransmits')"
case "$result" in
	*'did not answer'*) ;;
	*) printf 'an unreachable gateway was not identified: %s\n' "$result" >&2; exit 1 ;;
esac

result="$(classify 'daemon.info ipsec: 07[IKE] EAP-Identity authentication failed')"
case "$result" in
	*'rejected the credentials'*) ;;
	*) printf 'a credential failure was not identified: %s\n' "$result" >&2; exit 1 ;;
esac

# An unfamiliar failure must stay silent rather than guess, so the generic
# message and the raw VICI reason still reach the operator.
result="$(classify 'daemon.info ipsec: 03[IKE] something entirely new happened')"
[ -z "$result" ] || {
	printf 'an unrecognised failure was misclassified as: %s\n' "$result" >&2
	exit 1
}

# An empty log must not fail the classifier.
result="$(classify '')"
[ -z "$result" ] || {
	printf 'an empty log produced a classification: %s\n' "$result" >&2
	exit 1
}

# The reason has to reach the LuCI status message, not only the log file: the
# whole point is that "see logread" is not a diagnosis.
grep -Fq 'action_status "$id" error "Tunnel did not come up: $connect_reason"' \
	"$root/luci-ikev2-manager/ikev2-manager.sh" || {
	printf 'the connect action does not report the reason in its status\n' >&2
	exit 1
}
grep -Fq 'Settings were saved, but the tunnel did not come up: $connect_reason' \
	"$root/luci-ikev2-manager/ikev2-manager.sh" || {
	printf 'the client-connect action does not report the reason in its status\n' >&2
	exit 1
}

printf 'connect diagnosis tests OK\n'
