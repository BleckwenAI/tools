#!/bin/bash
# A simple Linux CLI for Azure Blob Storage. Just requires curl
# Bleckwen 2021, version 1.0

CONFIG_FILE=$HOME/.azblob
STORAGE_VERSION=2020-06-12
Debug=0

function die {
  echo -e "\033[1;31m${1:-fail}\033[m"
  exit 1
}

function read_params {
  line=$1
  Account=$(sed -n "$line p" $CONFIG_FILE | awk '{print $1}')
  Container=$(sed -n "$line p" $CONFIG_FILE | awk '{print $2}')
  AccessKey=$(sed -n "$line p" $CONFIG_FILE | awk '{print $3}')
  [[ -n $AccessKey ]] || die "Wrong syntax in file $CONFIG_FILE line $line"
}

if [[ ! -f $CONFIG_FILE ]]; then
    echo "Configuration file $CONFIG_FILE is missing. Please create it using following syntax:

STORAGE_ACCOUNT DEFAULT_CONTAINER ACCESS_KEY
...
"
  exit 1
else
  read_params 1
fi


function help {
  echo "USAGE: $(basename $0) [OPTIONS] COMMAND [CONTAINER] [FILE]

CONTAINER is optional. When absent using the default one from Config file

Commands:
  ls          list container content
  put FILE    upload file
  get FILE    retrieve file
  help        display this

Options
  -a ACCOUNT  storage Account (by default the first line from Config file)
"
  exit
}


# https://docs.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key
function get_headers {
  method=$1
  resource=$2
  length=$3

  date_h="x-ms-date:$(TZ=GMT LC_ALL=en_US date '+%a, %d %h %Y %H:%M:%S %Z')"
  version_h="x-ms-version:${STORAGE_VERSION}"
  block_h="x-ms-blob-type:BlockBlob"
  content=""

  if [[ $method == GET ]]; then
    canonical_headers="${date_h}\n${version_h}"
  else
    canonical_headers="${block_h}\n${date_h}\n${version_h}"
    content=application/octet-stream
  fi
  canonical_resource="/${Account}/${resource}"
  # signature string https://docs.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key
  sign_str="${method}\n\n\n${length}\n\n${content}\n\n\n\n\n\n\n${canonical_headers}\n${canonical_resource}"

  # Decode the Base64 encoded access key, convert to Hex.
  decoded_key="$(echo -n $AccessKey | base64 -d -w0 | xxd -p -c256)"
  # Create the HMAC signature for the Authorization header
  sign=$(printf "$sign_str" | openssl dgst -sha256 -mac HMAC -macopt hexkey:$decoded_key  -binary | base64 -w0)

  auth_h="Authorization: SharedKey $Account:$sign"
}

function parse_xml {
  if [[ $Debug -eq 1 ]]; then
    while read -E; do echo "# $E"; done
  else
    local IFS=\>
    while read -d \< E C; do
     [[ $E == Message ]] && die "$C"
     [[ $E == Name ]] && echo $C
    done
  fi
}

# https://docs.microsoft.com/en-us/rest/api/storageservices/list-blobs
function list_blobs {
  [[ -n $1 ]] && Container=$1
  get_headers GET "$Container\ncomp:list\nrestype:container"
  url="https://${Account}.blob.core.windows.net/${Container}?restype=container&comp=list"
  curl -s -H "$date_h" -H $version_h -H "$auth_h"  $url | parse_xml
}

# https://docs.microsoft.com/en-us/rest/api/storageservices/put-blob
function put_blob {
  [[ $# -ne 0 ]] || help
  if [[ -f $2 ]]; then
    Container=$1
    file=$2
  else
    file=$1
    [[ -f $file ]] || die "File $file does not exist"
  fi
  filename=$(basename $file)
  filesize=$(stat --printf=%s $file)
  get_headers PUT "$Container/$filename" $filesize
  url="https://${Account}.blob.core.windows.net/${Container}/$filename"
  curl -X PUT -H $block_h -H "$date_h" -H $version_h -H "$auth_h" -H Content-Type:application/octet-stream --data-binary "@$file" $url  || die
  echo "File uploaded to $url"
}

# https://docs.microsoft.com/en-us/rest/api/storageservices/get-blob
function get_blob {
  [[ $# -ne 0 ]] || help
  if [[ -f $2 ]]; then
    Container=$1
    filename=$2
  else
    filename=$1
  fi
  [[ -f $filename ]] && die "File $filename already exists locally. Remove it first"
  get_headers GET "$Container/$filename"
  url="https://${Account}.blob.core.windows.net/${Container}/$filename"
  curl -s -H "$date_h" -H $version_h -H "$auth_h" -o $filename $url || die
  echo "File $filename downloaded from $url"
}


[[ $# -ne 0 ]] || help

if [[ $1 == -D ]]; then
  Debug=1; shift
fi

if [[ $1 == -a && $# -ge 3 ]]; then
  Account=$2
  shift; shift
  line=$(grep -n "^$Account" $CONFIG_FILE | head -1 | cut -d : -f)
  [[ -n $line ]] || die "STORAGE_ACCOUNT $Account not defined in $CONFIG_FILE"
  read_params $line
fi

cmd=$1
shift
case $cmd in
  help) help;;
  ls)  list_blobs $*;;
  get) get_blob $*;;
  put) put_blob $*;;
  *)   die "Unknown command $cmd"
esac

