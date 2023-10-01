#!/usr/bin/env bash

set -e

create_data_snapshot() {
  save_maintenance_mode

  local MOUNTPOINT
  MOUNTPOINT="$1"

  btrfs-snp "${MOUNTPOINT}" manual 1 0 ../ncp-snapshots

  restore_maintenance_mode
}

export KOPIA_PASSWORD="${1?Missing parameter: repository password}"

source /usr/local/etc/library.sh

repo_type="$(source "${BINDIR}/BACKUPS/kopia.sh"; tmpl_repository_type)"
repo_path="$(source "${BINDIR}/BACKUPS/kopia.sh"; tmpl_destination)"
docker_args=()
[[ "$repo_type" == "filesystem" ]] && docker_args=(-v "${repo_path}:/repository")
data_dir="$(source "${BINDIR}/CONFIG/nc-datadir.sh"; tmpl_data_dir)"
cache_dir="${data_dir}/.kopia"
is_nc_encrypt_active="$(source "${BINDIR}/SECURITY/nc-encrypt.sh"; is_active && echo 'true' || echo 'false')"
mkdir -p "${cache_dir}"

data_subvol="$data_dir"
[[ "$is_nc_encrypt_active" == "true" ]] && data_subvol="$(dirname "$data_dir")"

db_backup_dir="$(dirname "${data_dir}")"
db_backup_file="ncp-db-$( date -Iseconds -u )-bkp.sql"
db_backup_file="${db_backup_file/+00:00/}"
db_backup_file="${db_backup_file//:/-}"
mysqldump -u root --single-transaction nextcloud > "${db_backup_dir}/${db_backup_file}"

cleanup(){
  local ret=$?
  rm -f "${db_backup_dir}/${db_backup_file}"
  restore_maintenance_mode
  exit $ret
}
trap cleanup EXIT

docker run --rm --pull always \
  -v /usr/local/etc/kopia:/app/config \
  -v "${cache_dir}:/app/cache" \
  -v "${db_backup_dir?}/${db_backup_file?}:/db/${db_backup_file}" \
  -e KOPIA_PASSWORD \
  "${docker_args[@]}" \
  kopia/kopia:latest snapshot create "/db"

if [[ "$( stat -fc%T "$data_subvol" )" == "btrfs" ]] && btrfs subvolume show "$data_subvol" 2>/dev/null
then
  create_data_snapshot "${mountpoint}"
  data_dir="$(dirname "${mountpoint}")/ncp-snapshots"
else
  save_maintenance_mode
fi

docker run --rm \
  -v /usr/local/etc/kopia:/app/config \
  -v "${cache_dir}:/app/cache" \
  -v "${data_dir?}:/ncdata" \
  -e KOPIA_PASSWORD \
  "${docker_args[@]}" \
  kopia/kopia:latest snapshot create /ncdata

