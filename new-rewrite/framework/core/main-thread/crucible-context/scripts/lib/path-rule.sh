# The context's path rule, in one home: what a path in the context may be.
# Sourced, so it sets no shell option; its names start with pr_.
# shellcheck shell=sh

# Prints why absolute path $1 can't be in the context, or nothing. The checks
# use the text only, and match names in any letter case.
pr_problem() {
	case $1 in /*) ;; *) echo 'not absolute'; return 0 ;; esac
	case $1 in *\'* | *\"* | *'`'*) echo 'holds a quote'; return 0 ;; esac
	if printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'; then echo 'holds a control character'; return 0; fi
	case /$1/ in */../*) echo 'holds a .. segment'; return 0 ;; esac
	pr_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	case ${pr_lower}/ in */.git/* | */.ssh/*) echo 'is under .git or .ssh'; return 0 ;; esac
	case ${pr_lower} in */.docker/config.json) echo 'is a Docker credentials file'; return 0 ;; esac
	pr_base=${pr_lower##*/}
	# shellcheck disable=SC2254 # the patterns are meant to glob
	case ${pr_base} in
		.env* | *.pem | *.key | *.crt | *.cer | id_* | credentials* | *.p12 | *.pfx | *.jks | *.keystore | .netrc | .pgpass | .npmrc | .pypirc)
			echo 'names a key, credential or secrets file'; return 0 ;;
		claude.md | skill.md)
			echo 'is an instruction file, which an agent may follow as instructions'; return 0 ;;
		settings.local.json)
			echo 'is a personal settings file, private and may hold secrets'; return 0 ;;
	esac
	pr_config=$(printf '%s' "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}" | tr '[:upper:]' '[:lower:]')
	case ${pr_lower} in
		"${pr_config}"/skills | "${pr_config}"/skills/* | "${pr_config}"/agents | "${pr_config}"/agents/*)
			echo 'is a Claude skill or agent, which an agent may follow as instructions'; return 0 ;;
		"${pr_config}"/settings.json)
			echo 'is a personal settings file, private and may hold secrets'; return 0 ;;
	esac
	return 0
}
