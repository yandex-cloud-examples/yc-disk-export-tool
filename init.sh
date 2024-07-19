#!/bin/bash

# ===================================
# Init s3 Bucket for disk export tool
# ===================================

check_input_params () {

  FOLDER_ID=$1
  BUCKET=$2
  SA_NAME=$3
  SUBNET=$4

  printf "\n== Check input parameters ==\n"
  echo "Check that folder-id is exists ..."
  if ! yc resource-manager folder get $FOLDER_ID > /dev/null ; then
    exit
  else
    cloud_id=$(yc resource-manager folder get --id=$FOLDER_ID --format=json | jq -r .cloud_id)
  fi

  echo "Check that Subnet is exists ..."
  if ! yc vpc subnet get --name=$SUBNET --folder-id=$FOLDER_ID > /dev/null ; then
    exit
  fi
  
  echo "Check that S3 bucket at the folder is exists ..."
  if yc storage bucket get $BUCKET --folder-id=$FOLDER_ID 1>/dev/null 2>/dev/null ; then
    folder_id=$(yc storage bucket get --name=$BUCKET --format=json | jq -r .folder_id)
    if [[ "$folder_id" == "$FOLDER_ID" ]] ; then
      echo "ERROR: S3 bucket \"$BUCKET\" already exists at the specified folder"
      exit
    else
      echo "ERROR: S3 Bucket \"$BUCKET\" already exists at the folder $folder_id"
      exit
    fi
  fi

  echo "Check that Lockbox Secret at the folder is exists ..."
  if yc lockbox secret get --name=$SA_NAME --folder-id=$FOLDER_ID 1>/dev/null 2>/dev/null ; then
    exit
  fi

  printf "\nCheck that SA is exists across the cloud ...\n"
  folder_list=$(yc resource-manager folder list --cloud-id=$cloud_id --format=json | jq -r '.[] .id' | tr "\n" " ")
  for folder in $folder_list ; do
    echo "Check folder $folder for SA"
    if yc iam service-account get --name=$SA_NAME --folder-id=$folder 1>/dev/null 2>/dev/null ; then
      echo "ERROR: SA \"$SA_NAME\" already exists at the folder $folder"
      exit
    fi
  done

  return 0
}


# ========
# Main ()
# ========
if [ "$#" != "5" ]; then
  printf "Disk Export tool Init.\n" 
  printf "$0 <folder-id> <bucket-name> <sa-name> <subnet-name> <config-file>\n"
  printf "For example:\n$0 b1g22jx2133dpa3yvxc3 my-s3-bucket disk-export-sa subnet-a ./disk-export.cfg\n"
  exit

else
  FOLDER_ID=$1
  BUCKET=$2
  SA_NAME=$3
  SUBNET=$4
  CFG_NAME=$5

  SA_DESCR="SA for disk export operations"

  check_input_params $FOLDER_ID $BUCKET $SA_NAME $ZONE $SUBNET
  echo "Validations has been completed!"

  printf "\n== Create Service Account (SA) ==\n"
  SA_ID=$(yc iam service-account create --name="$SA_NAME" --folder-id=$FOLDER_ID --description="SA for disk export operations" --format=json | jq -r .id)

  echo "== Grant roles to the SA =="
  yc resource-manager folder add-access-binding --id=$FOLDER_ID --role="compute.editor" --subject="serviceAccount:$SA_ID" 1>/dev/null 2>/dev/null
  yc resource-manager folder add-access-binding --id=$FOLDER_ID --role="storage.uploader" --subject="serviceAccount:$SA_ID" 1>/dev/null 2>/dev/null
  yc resource-manager folder add-access-binding --id=$FOLDER_ID --role="lockbox.payloadViewer" --subject="serviceAccount:$SA_ID" 1>/dev/null 2>/dev/null
  yc resource-manager folder add-access-binding --id=$FOLDER_ID --role="logging.writer" --subject="serviceAccount:$SA_ID" 1>/dev/null 2>/dev/null

  printf "\n== Create Static key for the SA =="
  PARAMS=($(yc iam access-key create --service-account-id=$SA_ID --description="Static key for S3 access" --format=json | jq -r '.access_key.key_id, .secret'))
  S3_KEY=${PARAMS[0]}
  S3_SECRET=${PARAMS[1]}

  printf "\n== Create Lockbox secret with S3 static key =="
  yc lockbox secret create --name=$SA_NAME --folder-id=$FOLDER_ID --payload="[{'key': '$S3_KEY', 'text_value': '$S3_SECRET'}]" > /dev/null

  printf "\n== Create S3 bucket for exported images ==\n"
  yc storage bucket create --name=$BUCKET --folder-id=$FOLDER_ID > /dev/null

  # Save Worker parameters to configuration file
  printf "{\n  \"folder_id\": \"$FOLDER_ID\",\n  \"bucket\": \"$BUCKET\",\n  \"sa\": \"$SA_NAME\",\n  \"subnet\": \"$SUBNET\"\n}\n" | tee $CFG_NAME
  echo "== Configuration saved to $CFG_NAME =="
fi
  exit
