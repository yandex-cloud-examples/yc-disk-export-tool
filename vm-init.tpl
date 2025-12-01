#cloud-config

datasource:
  Ec2:
    strict_id: false
ssh_pwauth: no
#users:
#- name: "${USER_NAME}"
#  sudo: ALL=(ALL) NOPASSWD:ALL
#  shell: /bin/bash
#  ssh-authorized-keys:
#  - "${USER_SSH_KEY}"
write_files:
- path: /root/.aws/config
  content: |
    [default]
    region = ru-central1
    endpoint_url = https://storage.yandexcloud.net
- path: /root/tools.sh
  content: |
    #!/bin/bash

    echo "Install bc"
    apt install -y bc

    echo "Install YC CLI"
    YC_VER=$(curl -sfL https://storage.yandexcloud.net/yandexcloud-yc/release/stable)
    curl -sfL "https://storage.yandexcloud.net/yandexcloud-yc/release/$$YC_VER/linux/amd64/yc" -o /usr/local/bin/yc
    chmod +x /usr/local/bin/yc

    echo "Install AWS CLI v2"
    curl -sfL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-2.22.35.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    cd aws
    ./install

    # Waiting when qemu-img will be ready
    while ! qemu-img --version 2>/dev/null; do sleep 5; done
  permissions: '0740'
- path: /root/export.sh
  content: |
    #!/bin/bash

    # Get S3 credentials from Lockbox
    export YC_TOKEN=$(curl -sf -H Metadata-Flavor:Google http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token | jq -r .access_token)
    
    RES_LIST=($(curl -sf -H "Authorization: Bearer $$YC_TOKEN" https://payload.lockbox.api.cloud.yandex.net/lockbox/v1/secrets/${SECRET_ID}/payload | jq -r '.entries[0] | .key, .textValue'))
    export AWS_ACCESS_KEY_ID=$${RES_LIST[0]}
    export AWS_SECRET_ACCESS_KEY=$${RES_LIST[1]}

    # Create qcow2 image from raw disk
    echo "[disk-export-tool] Start image build."
    qemu-img convert -p -c -o compression_type=zlib -f raw -O qcow2 /dev/vdb ${SRC_NAME}.qcow2
    MSG="[disk-export-tool] Build qcow2 image for $SRC_TYPE $SRC_NAME was completed."
    echo $$MSG
    yc logging write --level=INFO --message="$$MSG" --folder-id=${WFOLDER}

    # Copy qcow2 file to the Object Storage
    echo "[disk-export-tool] Start transfer image to S3 Object Storage"
    aws s3 cp ${SRC_NAME}.qcow2 s3://${BUCKET}/${SRC_NAME}.qcow2
    MSG="[disk-export-tool] Export of ${SRC_TYPE} ${SRC_NAME} to s3://$BUCKET/$SRC_NAME.qcow2 successfully completed."
    echo "$$MSG"
    yc logging write --level=INFO --message="$$MSG" --folder-id=${WFOLDER}

    # VM Self destroy
    export VM_ID=$(curl -sf -H Metadata-Flavor:Google http://169.254.169.254/computeMetadata/v1/instance/id)
    curl -sf -X DELETE -H "Authorization: Bearer $$YC_TOKEN" https://compute.api.cloud.yandex.net/compute/v1/instances/$$VM_ID
  permissions: '0740'
packages:
  - jq
  - qemu-utils
  - unzip
package_update: true
runcmd:
  - /root/tools.sh
  - /root/export.sh
