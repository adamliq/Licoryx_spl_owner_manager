#!/usr/bin/env bash
# Seed a Splunk docker container with users and lookups for testing.
# Usage: tests/docker/setup_data.sh [container] [admin_password]
set -euo pipefail
C=${1:-splunk}
PW=${2:-'Chang3d!Passw0rd'}
API=https://localhost:8089
UPW='Us3rPassw0rd!'
adm() { curl -sk -u "admin:$PW" "$@"; }
as() { local u=$1; shift; curl -sk -u "$u:$UPW" "$@"; }

echo "== users"
# leaver: will be deleted to orphan their lookups
for spec in alice:user bob:power carol:user leaver:power; do
  u=${spec%%:*}; r=${spec##*:}
  adm -o /dev/null -w "$u %{http_code}\n" $API/services/authentication/users \
    -d name=$u -d password="$UPW" -d roles=$r -d force-change-pass=0
done

mklookup() { # owner app name sharing
  local owner=$1 app=$2 name=$3 sharing=$4
  printf 'host,owner_team\nweb01,%s\ndb01,%s\n' "$owner" "$owner" | docker exec -i -u splunk "$C" \
    bash -c 'mkdir -p /opt/splunk/var/run/splunk/lookup_tmp && cat > "/opt/splunk/var/run/splunk/lookup_tmp/$1"' _ "$name"
  as "$owner" -o /dev/null -w "create $app/$name as $owner: %{http_code}\n" \
    "$API/servicesNS/$owner/$app/data/lookup-table-files" \
    -d name="$name" -d eai:data="/opt/splunk/var/run/splunk/lookup_tmp/$name"
  if [ "$sharing" != user ]; then
    adm -o /dev/null -w "share $name $sharing: %{http_code}\n" \
      "$API/servicesNS/$owner/$app/data/lookup-table-files/$name/acl" \
      -d owner="$owner" -d sharing="$sharing" -d perms.read='*' -d perms.write='admin,power'
  fi
}

echo "== lookups"
for i in 1 2 3 4 5; do mklookup leaver search leaver_assets_$i.csv app; done
mklookup leaver search leaver_global.csv global
mklookup leaver search leaver_private.csv user
mklookup bob search bob_app.csv app
mklookup bob search bob_private.csv user
mklookup alice search alice_private.csv user
mklookup alice search 'xss<img src=x onerror=alert(1)>.csv' app || true

echo "== delete leaver (orphans their lookups)"
adm -o /dev/null -w "delete leaver: %{http_code}\n" -X DELETE $API/services/authentication/users/leaver
