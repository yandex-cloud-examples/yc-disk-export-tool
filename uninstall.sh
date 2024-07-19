#!/bin/bash

set -e

if [ "$#" != "1" ]; then
  echo "Remove disk export tool resources" 
  echo "$0 <config-file>"
  echo "For example: $0 ./disk-export.cfg"
  exit
  # Check config file for exists
  if [ ! -f $1 ]; then
    echo "Config file \"$1\" not found!"
    exit
  fi

else

  PARAMS=($(jq -r '.folder_id, .sa_name, .secret, .bucket' $1))
  FOLDER_ID=${PARAMS[0]}
  SA_NAME=${PARAMS[1]}
  SECRET=${PARAMS[2]}
  BUCKET=${PARAMS[3]}

  echo -e "\n== Delete SA =="
  yc iam service-account delete --name="$SA_NAME" --folder-id=$FOLDER_ID
  echo -e "\n== Delete S3 Secrets in Lockbox =="
  yc lockbox secret delete --id="$SECRET" --folder-id=$FOLDER_ID
  echo -e "\n== Delete S3 Bucket. Can be failed if bucket is not empty! =="
  yc storage bucket delete --name=$BUCKET --folder-id=$FOLDER_ID
  echo -e "\n== Delete config file =="
  rm -f $1
fi
  exit
