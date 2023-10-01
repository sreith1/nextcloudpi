#!/bin/bash
# Nextcloud backups
#
# Copyleft 2023 by Tobias Knöppler
# GPL licensed (see end of file) * Use at your own risk!
#

tmpl_destination() {
  find_app_param kopia DESTINATION
}

tmpl_repository_type() {
  [[ "$DESTINATION" =~ .*'@'.*':'.* ]] && echo "sftp" || echo "filesystem"
}

tmpl_repository_password() {
  find_app_param kopia REPOSITORY_PASSWORD
}

install() {
  wget https://raw.githubusercontent.com/nachoparker/btrfs-snp/master/btrfs-snp -O /usr/local/bin/btrfs-snp
  chmod +x /usr/local/bin/btrfs-snp
}

configure() {

  set -e

  mkdir -p /usr/local/etc/kopia
  mkdir -p /var/log/kopia
  hostname="$(ncc config:system:get overwrite.cli.url)"

  docker_args=()
  kopia_args=()
  if [[ "$DESTINATION" =~ .*'@'.*':'.* ]]
  then
    repo_type="sftp"
    sftp_user="${DESTINATION%@*}"
    sftp_host="${DESTINATION#*@}"
    sftp_host="${sftp_host%:*}"
    repo_path="${DESTINATION#*:}"
    ssh -o "BatchMode=yes" "${sftp_user}@${sftp_host}" || { echo "SSH non-interactive not properly configured"; return 1; }
    kopia_args=(--host "${sftp_host}" --user "${sftp_user}" --path "${repo_path}")
  else
    repo_type="filesystem"
    repo_path="${DESTINATION}"
    docker_args=(-v "${repo_path}:/repository")
    kopia_args=(--path "/repository")
  fi

  export KOPIA_PASSWORD="${REPOSITORY_PASSWORD}"

  echo "Attempting to connect to existing repository first..."
  docker run --rm --pull always \
    -v /usr/local/etc/kopia:/app/config \
    -v /var/log/kopia:/app/logs \
    -e KOPIA_PASSWORD \
    "${docker_args[@]}" \
    kopia/kopia:latest repository connect "${repo_type}" \
      "${kopia_args[@]}" \
      --override-username ncp \
      --override-hostname "$hostname" || {
    echo "Creating new repository..."
    docker run --rm \
      -v /usr/local/etc/kopia:/app/config \
      -v /var/log/kopia:/app/logs \
      -e KOPIA_PASSWORD \
      "${docker_args[@]}" \
      kopia/kopia:latest repository create "${repo_type}" \
        "${kopia_args[@]}" \
        --override-username ncp \
        --override-hostname "$hostname"
  }

  echo "Configuring backup policy..."
  docker run --rm \
    -v /usr/local/etc/kopia:/app/config \
    -v /var/log/kopia:/app/logs \
    -v "${DESTINATION}:/repository" \
    -e KOPIA_PASSWORD \
    kopia/kopia:latest policy set --global \
      --keep-annual 2 --keep-monthly 12 --keep-weekly 4 --keep-daily 7 --keep-hourly 24 \
      --add-ignore '/ncdata/.opcache' \
      --add-ignore '/ncdata/nextcloud.log' \
      --add-ignore '/ncdata/ncp-update-backups' \
      --add-ignore '/ncdata/appdata_*/preview/*' \
      --add-ignore '/ncdata/*/cache' \
      --add-ignore '/ncdata/*/uploads' \
      --add-ignore '/ncdata/.data_*'

  cat > /etc/cron.hourly/ncp-kopia <<EOF
#!/bin/bash
/usr/local/bin/kopia-bkp.sh "${REPOSITORY_PASSWORD}"
EOF
  echo "Repository initialized successfully"

}
