#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
preview_if_requested install-binaries "$@"
require_root
detect_os
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
install -d -m 0755 /usr/local/bin /var/lib/vps-setup/binaries
for requested in "$@"; do
  found=no
  while IFS=$'\t' read -r tool arch url checksum member; do
    [[ $tool == "$requested" && ($arch == "$ARCH" || $arch == all) ]] || continue
    found=yes
    marker="/var/lib/vps-setup/binaries/$tool"
    if [[ -f $marker && $(cat "$marker") == "$checksum" ]]; then
      if [[ $tool == jetbrains-mono && -d /usr/local/share/fonts/jetbrains-mono ]] ||
        [[ $tool == superfile && -x /usr/local/bin/spf ]] ||
        [[ -x /usr/local/bin/$tool ]]; then continue; fi
    fi
    step "Install $tool"
    progress "Download $tool" curl --fail --silent --show-error --location --retry 3 "$url" -o "$temporary/archive"
    printf '%s  %s\n' "$checksum" "$temporary/archive" | sha256sum --check --status
    case "$tool" in
      superfile)
        tar -xOf "$temporary/archive" "$member" >"$temporary/binary"
        install -m 0755 "$temporary/binary" /usr/local/bin/spf
        ;;
      jetbrains-mono)
        install -d -m 0755 /usr/local/share/fonts/jetbrains-mono
        unzip -jo "$temporary/archive" 'JetBrainsMonoNerdFontMono-*.ttf' 'OFL.txt' -d /usr/local/share/fonts/jetbrains-mono
        chmod 0644 /usr/local/share/fonts/jetbrains-mono/*
        fc-cache -f
        ;;
      nvim)
        version=${url%/*}
        version=${version##*/}
        destination="/opt/neovim/$version"
        install -d -m 0755 "$destination"
        tar -xzf "$temporary/archive" -C "$destination" --strip-components=1 "$member"
        ln -sfn "$destination/bin/nvim" /usr/local/bin/nvim
        ;;
      lua-language-server)
        version=${url##*/lua-language-server-}
        version=${version%%-linux-*}
        destination="/opt/lua-language-server/$version"
        install -d -m 0755 "$destination"
        tar -xzf "$temporary/archive" -C "$destination"
        cat >"$temporary/lua-language-server" <<EOF
#!/usr/bin/env bash
exec "$destination/bin/lua-language-server" "\$@"
EOF
        install -m 0755 "$temporary/lua-language-server" /usr/local/bin/lua-language-server
        ;;
      *)
        if [[ $member == - ]]; then
          install -m 0755 "$temporary/archive" "/usr/local/bin/$tool"
        else
          tar -xOf "$temporary/archive" "$member" >"$temporary/binary"
          install -m 0755 "$temporary/binary" "/usr/local/bin/$tool"
        fi
        ;;
    esac
    printf '%s\n' "$checksum" >"$marker"
  done <"$ROOT/config/apt/binaries.tsv"
  [[ $found == yes ]] || die "No pinned binary for $requested on $ARCH"
done
