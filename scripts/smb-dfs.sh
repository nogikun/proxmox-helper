#!/usr/bin/env bash
set -Eeuo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
Usage:
  smb-dfs.sh gateway --ctid ID [--root-share containers] [--root-path /srv/dfs/containers] [--user dfsuser]
  smb-dfs.sh add --gateway ID --ctid ID --ip IPv4 --name NAME --share files --path /srv/files [--root-share containers] [--user dfsuser]
USAGE
}
need_value() {
  (($# >= 2)) || die "missing value for $1"
  [[ -n $2 ]] || die "missing value for $1"
}

MODE=
if (($#)); then MODE=$1; shift; fi
[[ -n $MODE ]] || { usage; exit 2; }
GATEWAY_CTID=
TARGET_CTID=
TARGET_IP=
LINK_NAME=
SHARE_NAME=files
SHARE_PATH=
ROOT_SHARE=containers
ROOT_PATH=/srv/dfs/containers
SMB_USER=dfsuser

while (($#)); do
  option=$1; shift
  case "$option" in
    --gateway) need_value "$option" "$@"; GATEWAY_CTID=$1; shift ;;
    --ctid) need_value "$option" "$@"; TARGET_CTID=$1; shift ;;
    --ip) need_value "$option" "$@"; TARGET_IP=$1; shift ;;
    --name) need_value "$option" "$@"; LINK_NAME=$1; shift ;;
    --share) need_value "$option" "$@"; SHARE_NAME=$1; shift ;;
    --path) need_value "$option" "$@"; SHARE_PATH=$1; shift ;;
    --root-share) need_value "$option" "$@"; ROOT_SHARE=$1; shift ;;
    --root-path) need_value "$option" "$@"; ROOT_PATH=$1; shift ;;
    --user) need_value "$option" "$@"; SMB_USER=$1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $option" ;;
  esac
done

[[ $MODE == gateway || $MODE == add ]] || { usage; die "mode must be gateway or add"; }
[[ $EUID -eq 0 ]] || die "run as root on a Proxmox VE node"
command -v pct >/dev/null || die "pct was not found; run on a Proxmox VE node"
[[ $ROOT_SHARE =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "invalid DFS root share name"
[[ $SMB_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "use a lowercase Unix username such as dfsuser"

valid_ctid() { [[ $1 =~ ^[0-9]{1,9}$ ]] && (( 10#$1 >= 100 )); }
check_running() {
  valid_ctid "$1" || die "invalid CTID: $1"
  status=$(pct status "$1" 2>/dev/null) || die "cannot read CTID $1"
  [[ $status == *"status: running"* ]] || die "CTID $1 must be running"
}
valid_path() {
  [[ $1 == /* && $1 != *$'\n'* && $1 != *$'\r'* && $1 != *'\'* && $1 != *'%'* ]] || return 1
  case "/$1/" in */../*) return 1 ;; esac
}

if [[ $MODE == gateway ]]; then
  [[ -n $TARGET_CTID ]] || die "--ctid is required"
  valid_path "$ROOT_PATH" || die "invalid DFS root path"
  check_running "$TARGET_CTID"
else
  [[ -n $GATEWAY_CTID && -n $TARGET_CTID && -n $TARGET_IP && -n $LINK_NAME && -n $SHARE_PATH ]] ||
    { usage; die "add requires --gateway, --ctid, --ip, --name, and --path"; }
  [[ $GATEWAY_CTID != "$TARGET_CTID" ]] || die "gateway and target CTIDs must differ"
  [[ $LINK_NAME =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "DFS link name must be lowercase letters, digits, underscore, or hyphen"
  [[ $SHARE_NAME =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "invalid SMB share name"
  valid_path "$SHARE_PATH" || die "share path must be absolute and must not contain newline, backslash, percent, or '..' components"
  [[ $TARGET_IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "invalid IPv4 address"
  IFS=. read -r a b c d <<< "$TARGET_IP"
  for octet in "$a" "$b" "$c" "$d"; do (( 10#$octet <= 255 )) || die "invalid IPv4 address"; done
  check_running "$GATEWAY_CTID"
  check_running "$TARGET_CTID"
  [[ $TARGET_IP != 127.* ]] || die "target IP must be reachable from clients"
  pct exec "$TARGET_CTID" -- ip -4 -o addr show scope global | grep -Fq "inet $TARGET_IP/" ||
    die "target LXC does not currently have $TARGET_IP; use a static address or DHCP reservation"
fi

WORK_DIR=$(mktemp -d)
PASSWORD_FILE=$WORK_DIR/password
CONF_FILE=$WORK_DIR/share.conf
REMOTE_SECRET=/run/pve-smb-dfs-$$.secret
REMOTE_CONF=/run/pve-smb-dfs-$$.conf
REMOTE_CTID=
cleanup() {
  result=$?
  if [[ -n $REMOTE_CTID ]]; then
    pct exec "$REMOTE_CTID" -- rm -f "$REMOTE_SECRET" "$REMOTE_CONF" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
  exit "$result"
}
trap cleanup EXIT

read -r -s -p "SMB password for $SMB_USER: " first; printf '\n'
read -r -s -p "Repeat password: " second; printf '\n'
[[ -n $first && $first == "$second" ]] || die "password is empty or entries do not match"
printf '%s\n%s\n' "$first" "$first" > "$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"
unset first second

install_samba() {
  pct exec "$1" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y samba'
}
ensure_smb_user() {
  local id=$1
  pct exec "$id" -- getent passwd "$SMB_USER" >/dev/null 2>&1 ||
    pct exec "$id" -- useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SMB_USER"
  REMOTE_CTID=$id
  pct push "$id" "$PASSWORD_FILE" "$REMOTE_SECRET" --perms 0600
  pct exec "$id" -- bash -c 'if pdbedit -L -u "$1" >/dev/null 2>&1; then smbpasswd -s "$1" < "$2"; else smbpasswd -s -a "$1" < "$2"; fi' _ "$SMB_USER" "$REMOTE_SECRET"
}
append_config() {
  local id=$1
  pct exec "$id" -- cp -a /etc/samba/smb.conf /etc/samba/smb.conf.before-pve-smb-dfs
  pct push "$id" "$CONF_FILE" "$REMOTE_CONF" --perms 0600
  pct exec "$id" -- bash -c 'cat "$1" >> /etc/samba/smb.conf' _ "$REMOTE_CONF"
  if ! pct exec "$id" -- testparm -s >/dev/null; then
    pct exec "$id" -- cp -a /etc/samba/smb.conf.before-pve-smb-dfs /etc/samba/smb.conf
    die "Samba config invalid; original smb.conf restored in CTID $id"
  fi
}
section_exists() { pct exec "$1" -- grep -Fiqx "[$2]" /etc/samba/smb.conf; }
parameter() {
  pct exec "$1" -- testparm -s --section-name "$2" --parameter-name "$3" 2>/dev/null |
    tail -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

if [[ $MODE == gateway ]]; then
  install_samba "$TARGET_CTID"
  pct exec "$TARGET_CTID" -- mkdir -p "$ROOT_PATH"
  pct exec "$TARGET_CTID" -- chmod 755 "$ROOT_PATH"
  pct exec "$TARGET_CTID" -- chown root:root "$ROOT_PATH"
  ensure_smb_user "$TARGET_CTID"
  if section_exists "$TARGET_CTID" "$ROOT_SHARE"; then
    [[ $(parameter "$TARGET_CTID" "$ROOT_SHARE" path) == "$ROOT_PATH" ]] || die "DFS share already exists with another path"
    [[ $(parameter "$TARGET_CTID" "$ROOT_SHARE" 'msdfs root') == yes ]] || die "existing share is not an MSDFS root"
    [[ $(parameter "$TARGET_CTID" "$ROOT_SHARE" 'valid users') == "$SMB_USER" ]] || die "existing share has different valid users"
  else
    if pct exec "$TARGET_CTID" -- grep -Eiq '^[[:space:]]*host msdfs[[:space:]]*=[[:space:]]*no([[:space:]]|$)' /etc/samba/smb.conf; then
      die "smb.conf explicitly disables host msdfs"
    fi
    if ! pct exec "$TARGET_CTID" -- grep -Eiq '^[[:space:]]*host msdfs[[:space:]]*=[[:space:]]*yes([[:space:]]|$)' /etc/samba/smb.conf; then
      pct exec "$TARGET_CTID" -- sed -i '/^[[:space:]]*\[global\][[:space:]]*$/a\   host msdfs = yes' /etc/samba/smb.conf
    fi
    printf '\n[%s]\n   path = %s\n   browseable = yes\n   read only = yes\n   msdfs root = yes\n   valid users = %s\n' "$ROOT_SHARE" "$ROOT_PATH" "$SMB_USER" > "$CONF_FILE"
    append_config "$TARGET_CTID"
  fi
  pct exec "$TARGET_CTID" -- testparm -s >/dev/null || die "Samba config is invalid"
  pct exec "$TARGET_CTID" -- systemctl enable --now smbd
  pct exec "$TARGET_CTID" -- systemctl reload smbd
  printf 'DFS gateway ready: share [%s]\n' "$ROOT_SHARE"
  exit 0
fi

pct exec "$GATEWAY_CTID" -- pdbedit -L -u "$SMB_USER" >/dev/null 2>&1 ||
  die "SMB user $SMB_USER is missing on gateway; run gateway setup first"
gateway_root=$(parameter "$GATEWAY_CTID" "$ROOT_SHARE" path)
[[ -n $gateway_root ]] || die "DFS root share [$ROOT_SHARE] was not found"
[[ $(parameter "$GATEWAY_CTID" "$ROOT_SHARE" 'msdfs root') == yes ]] || die "share [$ROOT_SHARE] is not an MSDFS root"

install_samba "$TARGET_CTID"
pct exec "$TARGET_CTID" -- getent passwd "$SMB_USER" >/dev/null 2>&1 ||
  pct exec "$TARGET_CTID" -- useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SMB_USER"
if pct exec "$TARGET_CTID" -- test -d "$SHARE_PATH"; then
  pct exec "$TARGET_CTID" -- runuser -u "$SMB_USER" -- test -rwx "$SHARE_PATH" ||
    die "$SMB_USER cannot read, write, and enter existing path; adjust permissions manually"
else
  pct exec "$TARGET_CTID" -- install -d -m 0775 -o "$SMB_USER" -g "$SMB_USER" "$SHARE_PATH"
fi
REMOTE_CTID=$TARGET_CTID
pct push "$TARGET_CTID" "$PASSWORD_FILE" "$REMOTE_SECRET" --perms 0600
pct exec "$TARGET_CTID" -- bash -c 'if pdbedit -L -u "$1" >/dev/null 2>&1; then smbpasswd -s "$1" < "$2"; else smbpasswd -s -a "$1" < "$2"; fi' _ "$SMB_USER" "$REMOTE_SECRET"

if section_exists "$TARGET_CTID" "$SHARE_NAME"; then
  [[ $(parameter "$TARGET_CTID" "$SHARE_NAME" path) == "$SHARE_PATH" ]] || die "share [$SHARE_NAME] exists with another path"
  [[ $(parameter "$TARGET_CTID" "$SHARE_NAME" 'valid users') == "$SMB_USER" ]] || die "share [$SHARE_NAME] has different valid users"
  [[ $(parameter "$TARGET_CTID" "$SHARE_NAME" 'force user') == "$SMB_USER" ]] || die "share [$SHARE_NAME] has a different force user"
  [[ $(parameter "$TARGET_CTID" "$SHARE_NAME" 'read only') == no ]] || die "share [$SHARE_NAME] is read-only"
else
  printf '\n[%s]\n   path = %s\n   browseable = yes\n   read only = no\n   valid users = %s\n   force user = %s\n   create mask = 0664\n   directory mask = 0775\n' \
    "$SHARE_NAME" "$SHARE_PATH" "$SMB_USER" "$SMB_USER" > "$CONF_FILE"
  append_config "$TARGET_CTID"
fi
pct exec "$TARGET_CTID" -- testparm -s >/dev/null || die "Samba config is invalid"
pct exec "$TARGET_CTID" -- systemctl enable --now smbd
pct exec "$TARGET_CTID" -- systemctl reload smbd

link_path=$gateway_root/$LINK_NAME
link_target="msdfs:$TARGET_IP\\$SHARE_NAME"
if pct exec "$GATEWAY_CTID" -- test -L "$link_path"; then
  existing=$(pct exec "$GATEWAY_CTID" -- readlink "$link_path")
  [[ $existing == "$link_target" ]] || die "DFS link $LINK_NAME already points elsewhere: $existing"
elif pct exec "$GATEWAY_CTID" -- test -e "$link_path"; then
  die "gateway path $link_path exists and is not a symlink"
else
  pct exec "$GATEWAY_CTID" -- ln -s "$link_target" "$link_path"
fi
pct exec "$GATEWAY_CTID" -- systemctl reload smbd
printf 'DFS link ready: %s -> %s\n' "$LINK_NAME" "$link_target"