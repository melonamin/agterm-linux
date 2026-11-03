#!/bin/sh
# Paints the body produced by agtermCore.HudLayout inside a passive overlay terminal.
set -uf

unset LC_ALL
LC_CTYPE=C.UTF-8
export LC_CTYPE

file=${AGTERM_HUD_FILE:-}
[ -n "$file" ] || exit 0

esc=$(printf '\033')
csi="$esc["
down="${csi}E"

cleanup() {
    trap - EXIT INT TERM HUP
    printf '%s?25h%s0m' "$csi" "$csi"
}
trap 'cleanup; exit 0' INT TERM HUP
trap cleanup EXIT
trap 'painted=' WINCH
printf '%s?25l' "$csi"

frame=0
painted=''
while [ -f "$file" ]; do
    cols=40
    rows=5
    spinner=0
    interval=0.5
    owner=''
    glyph=''
    fg=''
    block=''
    sep=''
    attr=''
    count=0
    first=1
    header=1
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$header" = 1 ]; then
            header=0
            set -- $line
            case ${1:-} in ''|*[!0-9]*) ;; *) cols=$1 ;; esac
            case ${2:-} in ''|*[!0-9]*) ;; *) rows=$2 ;; esac
            case ${3:-} in 1) spinner=1 ;; esac
            case ${4:-} in ''|0|*[!0-9]*) ;; *) owner=$4 ;; esac
            case ${5:-} in ''|*[!0-9.]*) ;; *) interval=$5 ;; esac
            case ${6:-} in ''|-|*[!0-9";"]*) ;; *) fg="${csi}${6}m" ;; esac
            if [ "$spinner" = 1 ] && [ $# -gt 6 ]; then
                shift 6
                eval "glyph=\${$(( frame % $# + 1 ))}"
            else
                spinner=0
            fi
            continue
        fi
        count=$(( count + 1 ))
        block="$block$sep"
        sep="$down"
        if [ -z "$line" ]; then
            attr="${csi}2m"
            continue
        fi
        pre=''
        if [ "$spinner" = 1 ] && [ "$first" = 1 ]; then pre="$glyph "; fi
        first=0
        left=$(( (cols - ${#line} - ${#pre}) / 2 ))
        if [ "$left" -gt 0 ]; then block="$block${csi}${left}C"; fi
        block="$block$attr$pre$line"
    done 2>/dev/null < "$file"

    frame=$(( frame + 1 ))
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then exit 0; fi

    top=$(( (rows - count) / 2 ))
    pad=''
    while [ "$top" -gt 0 ]; do
        pad="$pad$down"
        top=$(( top - 1 ))
    done

    out="${csi}0m${csi}H${csi}J$fg$pad$block${csi}0m"
    if [ "$out" != "$painted" ]; then
        printf '%s' "$out"
        painted=$out
    fi
    sleep "$interval"
done
