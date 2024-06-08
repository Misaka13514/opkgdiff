#!/bin/bash
#   opkgdiff : a simple opkg changed conffiles updater
#
#   Copyright (c) 2007 Aaron Griffin <aaronmgriffin@gmail.com>
#   Copyright (c) 2013-2016 Pacman Development Team <pacman-dev@archlinux.org>
#   Copyright (c) 2024 Misaka13514 <Misaka13514@gmail.com>
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see <https://www.gnu.org/licenses/>.
#

shopt -s extglob

declare -r myname='opkgdiff'
declare -r myver='1.0'

diffprog=${DIFFPROG:-'vim -d'}
diffsearchpath=${DIFFSEARCHPATH:-/etc}
mergeprog=${MERGEPROG:-'diff3 -m'}
cachedirs=()
USE_COLOR='y'
SUDO=''
declare -i USE_FIND=0 USE_LOCATE=0 USE_OPKGDB=0 OUTPUTONLY=0 BACKUP=0 THREE_WAY_DIFF=0

if ! type -t colorize &>/dev/null; then
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[0;33m'
	BLUE='\033[0;34m'
	BOLD='\033[1m'
	ALL_OFF='\033[0m'
fi

die() {
	error "$@"
	exit 1
}

if ! type -t msg &>/dev/null; then
	msg() {
		printf "${GREEN}${BOLD}==>${ALL_OFF} ${BOLD}$1${ALL_OFF}\n" "${@:2}"
	}
fi

if ! type -t msg2 &>/dev/null; then
	msg2() {
		printf "${BLUE}${BOLD}  ->${ALL_OFF} ${BOLD}$1${ALL_OFF}\n" "${@:2}"
	}
fi

if ! type -t ask &>/dev/null; then
	ask() {
		printf "${BLUE}${BOLD}::${ALL_OFF} ${BOLD}$1${ALL_OFF}" "${@:2}"
	}
fi

usage() {
	cat <<EOF
${myname} v${myver}

opkg changed conffiles maintenance utility.

Usage: $myname [options]

Search Options:   select one (default: --opkgdb)
  -f, --find      scan using find
  -l, --locate    scan using locate
  -p, --opkgdb    scan active config files from opkg database

General Options:
  -b, --backup          when overwriting, save old files with .bak
  -c, --cachedir <dir>  scan "dir" for 3-way merge base candidates
                        (default: read from @sysconfdir@/opkg.conf)
      --nocolor         do not colorize output
  -o, --output          print files instead of merging them
  -s, --sudo            use sudo and sudoedit to merge/remove files
  -3, --threeway        view diffs in 3-way fashion
  -h, --help            show this help message and exit
  -V, --version         display version information and exit

Environment Variables:
  DIFFPROG        override the merge program (default: 'vim -d')
  DIFFSEARCHPATH  override the search path (only when using find)
                  (default: /etc)
  MERGEPROG       override the 3-way merge program (default: 'diff3 -m')

Example: DIFFPROG=meld DIFFSEARCHPATH="/boot /etc /usr" MERGEPROG="git merge-file -p" $myname
Example: $myname --output --locate
EOF
}

version() {
	printf "%s %s\n" "$myname" "$myver"
	echo 'Copyright (C) 2007 Aaron Griffin <aaronmgriffin@gmail.com>'
	echo 'Copyright (C) 2013-2016 Pacman Development Team <pacman-dev@archlinux.org>'
	echo 'Copyright (C) 2024 Misaka13514 <Misaka13514@gmail.com>'
}

print_existing() {
	[[ -f "$1" ]] && printf '%s\0' "$1"
}

base_cache_tar() {
	# TODO
	package="$1"

	for cachedir in "${cachedirs[@]}"; do
		pushd "$cachedir" &>/dev/null || {
			error "failed to chdir to '%s', skipping" "$cachedir"
			continue
		}

		find "$PWD" -name "$package-[0-9]*.pkg.tar*" ! -name '*.sig' |
			# pacsort --files --reverse | sed -ne '2p'

		popd &>/dev/null || exit
	done
}

diffprog_fn() {
	if [[ -n "$SUDO" ]]; then
		SUDO_EDITOR="$diffprog" sudoedit "$@"
	else
		$diffprog "$@"
	fi
}

view_diff() {
	opkgfile="$1"
	file="$2"

	package="$(opkg search "$file" | cut -d' ' -f1)" || return 1
	# base_tar="$(base_cache_tar "$package")"

	two_way_diff() {
		diffprog_fn "$opkgfile" "$file"
	}

	three_way_diff() {
		diffprog_fn "$opkgfile" "$base" "$file"
	}

	unset tempdir

	if (( ! THREE_WAY_DIFF )); then
		two_way_diff
	elif [[ -z $base_tar ]]; then
		msg2 "Unable to find a base package. falling back to 2-way diff."
		two_way_diff
	else
		basename="$(basename "$file")"
		tempdir="$(mktemp -d --tmpdir "$myname-diff-$basename.XXX")"
		base="$(mktemp "$tempdir"/"$basename.base.XXX")"
		merged="$(mktemp "$tempdir"/"$basename.merged.XXX")"

		if ! bsdtar -xqOf "$base_tar" "${file#/}" >"$base"; then
			msg2 "Unable to extract the previous version of this file. falling back to 2-way diff."
			two_way_diff
		else
			three_way_diff
		fi
	fi

	ret=1

	if cmp -s "$opkgfile" "$file"; then
		msg2 "Files are identical, removing..."
		$SUDO rm -v "$opkgfile"
		ret=0
	fi

	$SUDO rm -rf "$tempdir"
	return $ret
}

merge_file() {
	opkgfile="$1"
	file="$2"

	package="$(opkg search "$file" | cut -d' ' -f1)" || return 1
	# base_tar="$(base_cache_tar "$package")"

	if [[ -z $base_tar ]]; then
		msg2 "Unable to find a base package."
		return 1
	fi

	basename="$(basename "$file")"
	tempdir="$(mktemp -d --tmpdir "$myname-merge-$basename.XXX")"
	base="$(mktemp "$tempdir"/"$basename.base.XXX")"
	merged="$(mktemp "$tempdir"/"$basename.merged.XXX")"

	if ! bsdtar -xqOf "$base_tar" "${file#/}" >"$base"; then
		msg2 "Unable to extract the previous version of this file."
		return 1
	fi

	if $mergeprog "$file" "$base" "$opkgfile" >"$merged"; then
		msg2 "Merged without conflicts."
	fi

	$diffprog "$file" "$merged"

	while :; do
		ask "Would you like to use the results of the merge? [y/n] "

		read -r c || return 1
		case $c in
			y|Y) break ;;
			n|N) return 1 ;;
			*) msg2 "Invalid answer." ;;
		esac
	done

	if ! $SUDO cp -v "$merged" "$file"; then
		warning "Unable to write merged file to %s. Merged file is preserved at %s" "$file" "$merged"
		return 1
	fi
	$SUDO rm -rv "$opkgfile" "$tempdir"
	return 0
}

cmd() {
	if (( USE_LOCATE )); then
		# plocate searches for files that match all patterns whereas mlocate searches for files that match one or more patterns
		if type -p plocate >/dev/null; then
			for p in \*-opkg; do
				locate -0 -e -b "$p"
			done
		else
			locate -0 -e -b \*-opkg
		fi
	elif (( USE_FIND )); then
		find "$diffsearchpath" -name \*-opkg -print0
	elif (( USE_OPKGDB )); then
		opkg list-changed-conffiles | while read -r bkup; do
			print_existing "$bkup-opkg"
		done
	fi
}

while [[ -n "$1" ]]; do
	case "$1" in
		-f|--find)
			USE_FIND=1;;
		-l|--locate)
			USE_LOCATE=1;;
		-p|--opkgdb)
			USE_OPKGDB=1;;
		-b|--backup)
			BACKUP=1;;
		-c|--cachedir)
			cachedirs+=("$2"); shift;;
		--nocolor)
			USE_COLOR='n';;
		-o|--output)
			OUTPUTONLY=1;;
		-s|--sudo)
			SUDO=sudo;;
		-3|--threeway)
			THREE_WAY_DIFF=1 ;;
		-V|--version)
			version; exit 0;;
		-h|--help)
			usage; exit 0;;
		*)
			usage; exit 1;;
	esac
	shift
done

# check if messages are to be printed using color
if [[ -t 2 && $USE_COLOR != "n" ]]; then
	if type -t colorize &>/dev/null; then
		colorize
	fi
else
	unset ALL_OFF BOLD BLUE GREEN RED YELLOW
fi

if ! type -p "${diffprog%% *}" >/dev/null && (( ! OUTPUTONLY )); then
	die "Cannot find the $diffprog binary required for viewing differences."
fi

if ! type -p "${mergeprog%% *}" >/dev/null && (( ! OUTPUTONLY )); then
	die "Cannot find the $mergeprog binary required for merging differences."
fi

case $(( USE_FIND + USE_LOCATE + USE_OPKGDB )) in
	0) USE_OPKGDB=1;; # set the default search option
	[^1]) error "Only one search option may be used at a time"
	 	usage; exit 1;;
esac

# if [[ -z ${cachedirs[*]} ]]; then
# 	# TODO
# 	readarray -t cachedirs < <(pacman-conf CacheDir)
# fi

# see https://mywiki.wooledge.org/BashFAQ/020
while IFS= read -u 3 -r -d '' opkgfile; do
	file="${opkgfile%-opkg}"
	file_type="opkg"

	if (( OUTPUTONLY )); then
		echo "$opkgfile"
		continue
	fi

	msg "%s file found for %s" "$file_type" "$file"
	if [ ! -f "$file" ]; then
		warning "$file does not exist"
		$SUDO rm -iv "$opkgfile"
		continue
	fi

	if cmp -s "$opkgfile" "$file"; then
		msg2 "Files are identical, removing..."
		$SUDO rm -v "$opkgfile"
	else
		while :; do
			ask "(V)iew, (M)erge, (S)kip, (R)emove %s, (O)verwrite with %s, (Q)uit: [v/m/s/r/o/q] " "$file_type" "$file_type"
			read -r c || break
			case $c in
				q|Q) exit 0;;
				r|R) $SUDO rm -v "$opkgfile"; break ;;
				o|O)
					if (( BACKUP )); then
						$SUDO cp -v "$file" "$file.bak"
					fi
					$SUDO mv -v "$opkgfile" "$file"
					break ;;
				v|V)
					if view_diff "$opkgfile" "$file"; then
						break
					fi ;;
				m|M)
					if merge_file "$opkgfile" "$file"; then
						break
					fi ;;
				s|S) break ;;
				*) msg2 "Invalid answer." ;;
			esac
		done
	fi
done 3< <(cmd)

exit 0
