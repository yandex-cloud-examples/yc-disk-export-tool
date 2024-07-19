#!/bin/bash

# ======================================
# Yandex Cloud VM disk/image Export tool
# ======================================

check_input_params () {
  SRC_TYPE=$1
  FOLDER_ID=$2
  SRC_NAME=$3
  CFG_NAME=$4

  printf "\n== Check Input parameters ==\n"

  echo "Check source-type ..."
  if [[ "$SRC_TYPE" != "disk" && "$SRC_TYPE" != "image" ]]; then
    echo "The source-type was wrong. Please specify: \"disk\" or \"image\""
    exit
  fi

  echo "Check that folder-id is exists ..."
  if ! yc resource-manager folder get --id=$FOLDER_ID > /dev/null ; then
    exit
  fi

  echo "Check source-name ..."
  if [[ "$SRC_TYPE" == "disk" ]]; then
    if ! yc compute instance get --folder-id=$FOLDER_ID --name=$SRC_NAME > /dev/null ; then
      exit
    fi
  else
    # src-type = image
    if ! yc compute image get --folder-id=$FOLDER_ID --name=$SRC_NAME > /dev/null ; then
      exit
    fi
  fi

  echo "Check that config file is exists ..."
  if [ ! -f $CFG_NAME ]; then
    echo "ERROR: config file \"$CFG_NAME\" not found"
    exit
  fi

  return 0
}

check_config_params () {

  WFOLDER=$1
  BUCKET=$2
  SA_NAME=$3
  WSUBNET=$4 

  printf "\n== Check Config file parameters ==\n"

  echo "Check that Folder is exists ..."
  if ! yc resource-manager folder get --id=$WFOLDER > /dev/null ; then
    exit
  fi

  echo "Check that S3 bucket at the folder is exists ..."
  if yc storage bucket get --name=$BUCKET --folder-id=$WOLDER > /dev/null ; then
    folder_id=$(yc storage bucket get $BUCKET --format=json | jq -r .folder_id)
    if [[ "$folder_id" != "$WFOLDER" ]] ; then
      echo "ERROR: S3 bucket \"$BUCKET\" already exists at another folder $folder_id"
      exit
    fi
  fi

  echo "Check that SA at the folder is exists ..."
  if ! yc iam service-account get --name=$SA_NAME --folder-id=$WFOLDER > /dev/null ; then
    exit
  fi

  echo "Check that Subnet is exists ..."
  if ! yc vpc subnet get --name=$WSUBNET --folder-id=$WFOLDER > /dev/null ; then
    exit
  fi

  echo "Check that Lockbox Secret with SA name is exists ..."
  if ! yc lockbox secret get --name=$SA_NAME --folder-id=$WFOLDER > /dev/null ; then
    exit
  fi  

  return 0
}

# ========
# Main ()
# ========
if [ "$#" != "4" ]; then
  printf "VM Disk Export tool\n" 
  printf "$0 <source-type> <folder-id> <source-name> <config-file>\n"
  printf "  <source-type>: disk | image\n"
  printf "  <source-name>: your-vm-name | your-image-name\n"
  printf "For example:\n  $0 disk b1g22jx2133dpa3yvxc3 mytest-vm ./disk-export.cfg\n"
  printf "  $0 image b1g22jx2133dpa3yvxc3 my-image ./disk-export.cfg\n"
  exit

else
  export SRC_TYPE=$1
  FOLDER_ID=$2
  export SRC_NAME=$3
  CFG_NAME=$4
  check_input_params $SRC_TYPE $FOLDER_ID $SRC_NAME $CFG_NAME
  printf "== Validation of input parameters has been completed ==\n"
  
  PARAMS=($(jq -r '.folder_id, .bucket, .sa, .subnet' $CFG_NAME))
  export WFOLDER=${PARAMS[0]}
  export BUCKET=${PARAMS[1]}
  SA_NAME=${PARAMS[2]}
  WSUBNET=${PARAMS[3]}
  check_config_params $WFOLDER $BUCKET $SA_NAME $WSUBNET
  printf "== Validation of config file parameters has been completed ==\n"

  # =========================
  # Prepare source for Export
  # =========================
  zone_id=$(yc vpc subnet get --name=$WSUBNET --folder-id=$WFOLDER --format=json | jq -r .zone_id) > /dev/null
  export SECRET_ID=$(yc lockbox secret get --name=$SA_NAME --folder-id=$WFOLDER --format=json | jq -r .id)
  
  # If src = VM boot disk
  if [[ "$SRC_TYPE" == "disk" ]]; then
    BOOT_DISK_ID=$(yc compute instance get $SRC_NAME --folder-id=$FOLDER_ID --format=json | jq -r .boot_disk.disk_id)
    printf "\n== Create Snapshot from VM boot disk ==\n"
    SRC_ID=$(yc compute snapshot create --disk-id=$BOOT_DISK_ID --description="Snapshot of boot disk VM $SRC_NAME" --folder-id=$FOLDER_ID --format=json | jq -r .id)
    PARAMS=($(yc compute snapshot get $SRC_ID --folder-id=$FOLDER_ID --format=json | jq -r '.id, .disk_size'))
    CHUNKS=$(bc <<< "scale=0; ${PARAMS[1]}/99857989632 + 1")
    TSIZE=$(bc <<< "$CHUNKS * 93")
    printf "\n== Create Secondary disk from Snapshot for Export Helper VM ==\n"
    DISK_ID=$(yc compute disk create --zone=$zone_id --description="Disk from VM $SRC_NAME" --folder-id=$WFOLDER --source-snapshot-id=${PARAMS[0]} --type=network-ssd-nonreplicated --size=$TSIZE --format=json | jq -r .id)
    printf "\n== Delete disk Snapshot ==\n"
    yc compute snapshot delete $SRC_ID   
  fi

  # If src = disk image
  if [[ "$SRC_TYPE" == "image" ]]; then
    ISIZE="$(yc compute image get $SRC_NAME --folder-id=$FOLDER_ID --format=json | jq -r .min_disk_size)"
    CHUNKS=$(bc <<< "scale=0; $ISIZE/99857989632 + 1")
    TSIZE=$(bc <<< "$CHUNKS * 93")
    printf "\n== Create secondary disk from Image for Export Helper VM ==\n"
    DISK_ID=$(yc compute disk create --zone=$zone_id --description="Disk from image $SRC_NAME" --folder-id=$WFOLDER --source-image-name=$SRC_NAME --type=network-ssd-nonreplicated --size=$TSIZE --format=json | jq -r .id)
  fi

  # =========================
  # Create Export Helper VM
  # =========================
  IMG_FAMILY=ubuntu-2204-lts
 
  printf "\n== Create Export Helper VM ==\n"
  yc compute instance create --folder-id=$WFOLDER --zone=$zone_id \
    --description="Export Helper VM for $SRC_TYPE $SRC_NAME" \
    --create-boot-disk image-folder-id=standard-images,image-family=$IMG_FAMILY,type=network-ssd-nonreplicated,size=$TSIZE \
    --attach-disk disk-id=$DISK_ID,auto-delete=true \
    --memory 16 --cores 4 --core-fraction 100 \
    --network-interface subnet-name=$WSUBNET,nat-ip-version=ipv4 \
    --service-account-name=$SA_NAME \
    --metadata-from-file user-data=vm-init.tpl

  yc logging write --level=INFO --folder-id=$WFOLDER \
    --message="[disk-export-tool] Export of $SRC_TYPE $SRC_NAME to s3://$BUCKET/$SRC_NAME.qcow2 was started."
  echo "See logs in Default group at https://console.yandex.cloud/folders/$WFOLDER/logging/groups"
fi
exit
