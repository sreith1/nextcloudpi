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
data_dir="$(source "${BINDIR}/CONFIG/nc-data_dir.sh"; tmpl_data_dir)"
cache_dir="${data_dir}/.kopia"
mkdir -p "${cache_dir}"

mountpoint="$( stat -c "%m" "$data_dir" )" || { echo "Error retrieving ncdata mountpoint"; return 1; }

db_backup_dir="$(dirname "${data_dir}")"
db_backup_file="ncp-db-$( date -Iseconds -u )-bkp.sql"
mysqldump -u root --single-transaction nextcloud > "${db_backup_dir}/${db_backup_file}"

cleanup(){
  local ret=$?
  rm -f "${db_backup_dir}/${db_backup_file}"
  restore_maintenance_mode
  exit $ret
}
trap cleanup EXIT

docker run --rm \
  -v /usr/local/etc/kopia:/app/config \
  -v "${cache_dir}:/app/cache" \
  -v "${db_backup_dir?}/${db_backup_file?}:/db/${db_backup_file}" \
  -e KOPIA_PASSWORD \
  "${docker_args[@]}" \
  kopia/kopia:latest snapshot create "/db/${db_backup_file}"

if [[ "$( stat -fc%T "$mountpoint" )" == "btrfs" ]]
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

