#!/bin/bash
# make a paper backup of borg repository URL, passphrase and SSH key (if it's remote repo)
# as defined in Vorta (https://github.com/borgbase/vorta), then print it on a sheet of paper
# and store in a secure place
#
# script assumes:
#   - all your Borg repositories are defined in Vorta
#   - passphrases are included in system keychain 
#   - repokey encryption (and you either don't see a need for a backup or have a separate backup of it - see man borg-key-export)
#   - your passphrase only contains ASCII characters
#   - SSH key is used for authentication and is not protected by passphrase
#   - remote repositories have borg installed
#
# requirements:
#   - qrencode
#   - secret-tool
#   - enscript
#   - gv (ps viewer)
#   - connected and configured printer
# 
tempdir=$(mktemp -d)
cd "${tempdir}"

function get_ssh_key {
  local url=$1
  echo "Determining the correct SSH key.." >&2
  for identity in ~/.ssh/*
  do
    file "${identity}" | grep -q 'private key' || continue
    echo "Testing ${identity}.." >&2
    SSH_AUTH_SOCK= ssh -o PreferredAuthentications=publickey \
                       -o PasswordAuthentication=no \
                       -i "${identity}" \
                       "${url}" borg -V >/dev/null 2>&1
    if [ $? -eq 0 ]
    then
      # first match is a good match
      cat "${identity}"
      return 0
    fi
  done
  echo "SSH key could not be determined, quitting" >&2
  return 1
}

function get_passphrase {
  local url=$1
  local passphrase=$(secret-tool lookup repo_url "${url}")
  if [ -z "${passphrase}" ]
  then
    echo "Passphrase not stored in password manager, quitting" >&2
    return 1
  else
    echo "${passphrase}"
    return 0
  fi
}

vorta_db=~/.local/share/Vorta/settings.db

if [ ! -f "${vorta_db}" ]
then
  echo "Vorta configuration not found"
  exit 1
fi

which secret-tool >/dev/null 2>/dev/null
if [ $? -ne 0 ]
then
  echo "secret-tool missing. Please install libsecret"
  exit 1
fi

which enscript >/dev/null 2>/dev/null
if [ $? -ne 0 ]
then
  echo "Please install enscript"
  exit 1
fi

which qrencode >/dev/null 2>/dev/null
if [ $? -ne 0 ]
then
  echo "Please install qrencode"
  exit 1
fi

output=$(
sqlite3 -separator ' '  "${vorta_db}"  'select name, url from repomodel join backupprofilemodel on repomodel.id == backupprofilemodel.id' | \
  while read -r profile_name repo_url
do
  # is this a local or remote repository?
  is_local=$(echo "${repo_url}" | grep -c "^/")
  if [ "${is_local}" -eq 0 ]
  then
    repo_type="Remote"
    # retrieve SSH key
    ssh_key=$(get_ssh_key "${repo_url%%:*}")
    [ -z "${ssh_key}" ] && exit 1
    eps_sshkey=$(mktemp -p $tempdir --suffix=.eps)
    echo "${ssh_key}" | qrencode -t EPS -o "${eps_sshkey}"
  else
    repo_type="Local"
  fi
  
  # retrieve passphrase
  passphrase=$(get_passphrase "${repo_url}") 
  [ -z "${passphrase}" ] && exit 1

  eps_passphrase=$(mktemp -p $tempdir --suffix=.eps)
  echo "${passphrase}" | qrencode -t EPS -o "${eps_passphrase}"

  echo -en "Profile: ${profile_name}\n${repo_type} repo: ${repo_url}"

  if [ "${is_local}" -eq 1 ]
  then
    echo -e " ($(df "${repo_url}" | tail -1 | awk '{print $1}'))\nPassphrase: ${passphrase}\nNULLBYTEepsf[h3c]{$eps_passphrase}"
  else
    echo -e "\n${ssh_key}\nPassphrase: ${passphrase}"
    echo -e "NULLBYTEepsf[h6cny]{$eps_sshkey}NULLBYTEepsf[h6c]{$eps_passphrase}"
  fi
  echo "=========================="
done)

exit_code=$?
if [ "${exit_code}" -ne 0 ]
then
  exit "${exit_code}"
fi

txt_output=$(mktemp -p $tempdir --suffix=.txt)
ps_output=$(mktemp -p $tempdir --suffix=.ps)

echo "${output}" | sed 's/NULLBYTE/\x00/g' > "${txt_output}"
enscript -b "borg backup/recover info for host: $(hostname), generated: $(date '+%x %X')" -e -p "${ps_output}" -f Courier10 "${txt_output}"
echo "${txt_output}"
echo "${ps_output}"
/usr/bin/gv "${ps_output}"
# cleanup everything
rm -r "${tempdir}"
