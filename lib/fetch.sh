#!/usr/bin/env bash
# LibreOuya downloads: manifest entries (pinned hashes, local mirror first),
# F-Droid index lookups (hash from the signed repo index), and unpinned
# downloads that show their hash and ask before use.

LO_FDROID_SDK=16

# ---- manifest ---------------------------------------------------------------

# manifest_get <id> sets M_FILE M_SIZE M_SHA256 M_MD5 M_SHA1 M_SOURCES M_NOTE.
# Empty fields are written as "-" in manifest.tsv, because tab is IFS
# whitespace and bash would otherwise merge empty columns.
manifest_get() {
	local id f size sha md5 sha1 src note found=0
	while IFS=$'\t' read -r id f size sha md5 sha1 src note; do
		[ "$id" = "$1" ] || continue
		found=1
		break
	done <"$LO_ROOT/manifest.tsv"
	[ "$found" = 1 ] || die "no manifest entry '$1'"
	M_FILE=$f
	M_SIZE=${size#-}
	M_SHA256=${sha#-}
	M_MD5=${md5#-}
	M_SHA1=${sha1#-}
	M_SOURCES=$src
	M_NOTE=${note#-}
}

# verify_file <path> : 0 = every pinned value matched, 1 = mismatch,
# 2 = nothing pinned to check against.
verify_file() {
	local f=$1 pinned=0 v
	[ -f "$f" ] || return 1
	if [ -n "$M_SIZE" ]; then
		pinned=1
		v=$(size_of "$f")
		[ "$v" = "$M_SIZE" ] || { warn "size $v, expected $M_SIZE"; return 1; }
	fi
	if [ -n "$M_SHA256" ]; then
		pinned=1
		v=$(sha256_of "$f")
		[ "$v" = "$M_SHA256" ] || { warn "sha256 $v, expected $M_SHA256"; return 1; }
	fi
	if [ -n "$M_MD5" ]; then
		pinned=1
		v=$(md5_of "$f")
		[ "$v" = "$M_MD5" ] || { warn "md5 $v, expected $M_MD5"; return 1; }
	fi
	if [ -n "$M_SHA1" ]; then
		pinned=1
		v=$(sha1_of "$f")
		[ "$v" = "$M_SHA1" ] || { warn "sha1 $v, expected $M_SHA1"; return 1; }
	fi
	[ "$pinned" = 1 ] || return 2
	return 0
}

curl_get() {
	# curl_get <url> <dest>. Resumes partial downloads.
	act curl -fL --retry 3 --connect-timeout 20 -C - -o "$2" -- "$1"
}

# fetch_entry <id> : sets LO_FETCHED to a verified local file.
fetch_entry() {
	local id=$1 src dest part rc
	manifest_get "$id"
	dest=$LO_CACHE/files/$M_FILE
	mkdir -p -- "$LO_CACHE/files"
	for src in $M_SOURCES; do
		case $src in
		mirror:*)
			local p=$LO_ROOT/${src#mirror:}
			[ -f "$p" ] || continue
			if verify_file "$p"; then
				ok "Using bundled copy $p (verified)"
				LO_FETCHED=$p
				return 0
			fi
			warn "bundled copy $p failed verification, trying downloads"
			;;
		*)
			if [ -f "$dest" ] && verify_file "$dest" >/dev/null 2>&1; then
				ok "Using cached $dest (verified)"
				LO_FETCHED=$dest
				return 0
			fi
			say "Need $M_FILE${M_SIZE:+ ($M_SIZE bytes)}: $M_NOTE"
			ask "Download it from $src?" || continue
			part=$dest.part
			if ! curl_get "$src" "$part"; then
				warn "download from $src failed"
				continue
			fi
			[ "$LO_DRY" = 1 ] && { LO_FETCHED=$dest; return 0; }
			rc=0
			verify_file "$part" || rc=$?
			if [ "$rc" = 0 ]; then
				mv -- "$part" "$dest"
				ok "Downloaded and verified $M_FILE"
				LO_FETCHED=$dest
				return 0
			fi
			if [ "$rc" = 2 ]; then
				say "Nothing is pinned for $M_FILE. sha256: $(sha256_of "$part")"
				if ask "Use it anyway?"; then
					mv -- "$part" "$dest"
					LO_FETCHED=$dest
					return 0
				fi
			fi
			rm -f -- "$part"
			warn "$src gave a file that does not match the manifest, discarded"
			;;
		esac
	done
	err "could not get a verified copy of $id"
	return 1
}

# fetch_url <url> <filename> <sha256 or -> : generic verified download.
# With "-" the hash is shown and the user decides.
fetch_url() {
	local url=$1 name=$2 want=$3 dest part have
	dest=$LO_CACHE/files/$name
	part=$dest.part
	mkdir -p -- "$LO_CACHE/files"
	if [ "$want" != - ] && [ -f "$dest" ] && [ "$(sha256_of "$dest")" = "$want" ]; then
		ok "Using cached $name (verified)"
		LO_FETCHED=$dest
		return 0
	fi
	curl_get "$url" "$part" || { err "download failed: $url"; return 1; }
	[ "$LO_DRY" = 1 ] && { LO_FETCHED=$dest; return 0; }
	have=$(sha256_of "$part")
	if [ "$want" = - ]; then
		say "No published hash for $name. sha256: $have"
		ask "Use it?" || { rm -f -- "$part"; return 1; }
	elif [ "$have" != "$want" ]; then
		rm -f -- "$part"
		err "$name sha256 $have, expected $want. Discarded."
		return 1
	fi
	mv -- "$part" "$dest"
	ok "Downloaded $name"
	LO_FETCHED=$dest
}

# ---- F-Droid ----------------------------------------------------------------
# The F-Droid index lists every APK with its minSdk, ABIs and sha256. Picking
# from it means no pinned versions to bump, and the hash still comes from the
# repo rather than from a guess.

fdroid_index() {
	# fdroid_index <repo|archive> : sets LO_FD_INDEX
	local which=$1 url f
	url=https://f-droid.org/$which/index-v2.json
	f=$LO_CACHE/fdroid/$which-index-v2.json
	mkdir -p -- "$LO_CACHE/fdroid"
	if [ -s "$f" ] && ! older_than_days "$f" 7; then
		LO_FD_INDEX=$f
		return 0
	fi
	say "Need F-Droid's $which index (tens of MB, cached for 7 days)."
	ask "Download $url?" || return 1
	act curl -fL --retry 3 --connect-timeout 20 -o "$f.part" -- "$url" || {
		rm -f -- "$f.part"
		return 1
	}
	[ "$LO_DRY" = 1 ] && return 1
	jq -e '.packages' "$f.part" >/dev/null 2>&1 || {
		rm -f -- "$f.part"
		err "$url is not an index-v2 file"
		return 1
	}
	mv -- "$f.part" "$f"
	LO_FD_INDEX=$f
}

# Newest version of a package that runs on API 16 with 32-bit ARM or no
# native code. Prints: name<TAB>sha256<TAB>size<TAB>versionName
fdroid_pick() {
	jq -r --arg p "$1" --argjson sdk "$LO_FDROID_SDK" '
	  (.packages[$p].versions // {}) | [ .[]
	    | select(((.manifest.usesSdk.minSdkVersion // 1) | tonumber) <= $sdk)
	    | select((.manifest.nativecode // []) as $n
	        | ($n | length) == 0 or ($n | any(. == "armeabi-v7a" or . == "armeabi")))
	  ] | sort_by(.manifest.versionCode) | last // empty
	  | [.file.name, .file.sha256, (.file.size | tostring), .manifest.versionName] | @tsv
	' "$2"
}

# fdroid_get <package> : sets LO_FETCHED and FD_VERSION.
fdroid_get() {
	local pkg=$1 which line name sha size ver
	need_cmds jq
	for which in repo archive; do
		fdroid_index "$which" || continue
		line=$(fdroid_pick "$pkg" "$LO_FD_INDEX")
		[ -n "$line" ] || { say "  $pkg: nothing for Android 4.1 in F-Droid $which"; continue; }
		IFS=$'\t' read -r name sha size ver <<<"$line"
		name=${name#/}
		say "  $pkg $ver ($size bytes) from F-Droid $which"
		ask "Download and verify it?" || return 1
		fetch_url "https://f-droid.org/$which/$name" "$name" "$sha" || return 1
		FD_VERSION=$ver
		return 0
	done
	return 1
}

# ---- platform-tools ---------------------------------------------------------

get_platform_tools() {
	local os zip
	need_cmds curl unzip
	case $(uname -s) in
	Linux) os=linux ;;
	Darwin) os=darwin ;;
	MINGW* | MSYS* | CYGWIN*) os=windows ;;
	*) die "no platform-tools build for $(uname -s)" ;;
	esac
	zip=$LO_CACHE/platform-tools-latest-$os.zip
	say "Google's platform-tools (adb + fastboot) for $os, unpacked to $LO_CACHE/platform-tools"
	ask "Download https://dl.google.com/android/repository/platform-tools-latest-$os.zip?" || return 1
	act curl -fL --retry 3 -o "$zip" -- "https://dl.google.com/android/repository/platform-tools-latest-$os.zip" || return 1
	act unzip -o -q "$zip" -d "$LO_CACHE" || return 1
	# Some unzip builds drop the exec bit.
	act chmod +x -- "$LO_CACHE/platform-tools/adb" "$LO_CACHE/platform-tools/fastboot" 2>/dev/null || true
	ok "platform-tools ready. They are used when no adb is on PATH."
}
