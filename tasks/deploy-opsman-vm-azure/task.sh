#!/usr/bin/env bash
#
# Copy the Ops Man Blob, Provision Ops Man NIC and VM

source pcf-pipelines/tasks/deploy-opsman-vm-azure/azure-functions.sh

login_to_azure $SERVICE_PRINCIPAL_ID $SERVICE_PRINCIPAL_PASS $TENANT_ID $SUBSCRIPTION_ID

echo "$OPSMAN_PUBLIC_KEY" > ./opsman.pub

CONNECTION_STRING=$(get_storage_connection_string "$AZURE_STORAGE_ACCOUNT")

if [ $? != 0 ]; then
  OPS_MAN_IMAGE_URL=$(grep ${azure_opsman_image_region} pivnet-opsmgr/*Azure.yml | awk '{split($0, a); print a[2]}')
  OPS_MAN_VERSION=$(cat pivnet-opsmgr/metadata.json | jq '.Release.Version' | sed -e 's/^"//' -e 's/"$//')
  echo "deploying vm w/ disk-image: ${OPS_MAN_IMAGE_URL}"

  echo -n "OPSMAN Blob Copy Start: "
  run_cmd "azure storage blob copy start '$OPS_MAN_IMAGE_URL' opsmanager \
    --dest-connection-string '$CONNECTION_STRING' \
    --dest-container opsmanager \
    --dest-blob image-$OPS_MAN_VERSION.vhd"
  check_rc $?
  
  clear
  echo "Starting OPSMAN upload."
  
  while true; do
    JSON=$(get_opsman_blob_copy_status_json "$CONNECTION_STRING")
    STATS=$(get_blob_copy_status "$JSON")
    PROGRESS=$(get_blob_copy_progress "$JSON")
  
    if [ $STATS == 'success' ]; then
  	 echo "Finally! Blob status is complete."
  	 break
    else
  	 clear
  	 echo "Still waiting: $PROGRESS"
    fi
  
    sleep 10
  done
fi

echo -n "Creating OPSMAN NIC: "
run_cmd "azure network nic create --name ${opsman_vm_identifier}-nic \
  --location $azure_location \
  --resource-group $azure_resource_group \
  --private-ip-address $OPSMAN_IP \
  --network-security-group-name $OPSMAN_NSG_NAME \
  --subnet-id /subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$opsman_vnet_nsg_name/providers/Microsoft.Network/VirtualNetworks/$OPSMAN_VNET_NAME/subnets/$OPSMAN_SUBNET_NAME"
check_rc $?

echo -n "Starting OPSMAN VM: "
run_cmd "azure vm create $azure_resource_group $opsman_vm_identifier $AZURE_LOCATION \
  Linux --nic-name ${opsman_vm_identifier}-nic \
  --os-disk-vhd https://$STORAGE_ACCOUNT.blob.core.windows.net/opsmanager/os_disk.vhd \
  --image-urn https://$STORAGE_ACCOUNT.blob.core.windows.net/opsmanager/image-$OPS_MAN_VERSION.vhd \
  --admin-username ubuntu --storage-account-name $AZURE_STORAGE_ACCOUNT \
  --vm-size $azure_instance_type --ssh-publickey-file ./opsman.pub"
check_rc $?

echo -n "Shutting down and deallocating OPSMAN VM: "
run_cmd "azure vm stop $azure_resource_group $opsman_vm_identifier"
check_rc $?

run_cmd "azure vm deallocate $azure_resource_group $opsman_vm_identifier"
check_rc $?

echo -n "Resizing OPSMAN OS Disk: "
run_cmd "azure vm set --new-os-disk-size $opsman_disk_size $azure_resource_group $opsman_vm_identifier"
check_rc $?

echo -n "Starting OPSMAN VM: "
run_cmd "azure vm start $azure_resource_group $opsman_vm_identifier"
check_rc $?

echo -n "Waiting for OPSMAN to come up"
connect_return=0
retry_counter=0
until [ $retry_counter -ge 10 ]
do
  echo -n "."
  run_cmd "curl --fail -k -v --connect-timeout 10 https://$OPSMAN_FQDN/"
  connect_return=$?
  if [ $connect_return == 0 ]; then break; fi
  retry_counter=$[$retry_counter+1]
  sleep 30s
done
echo ""

if [ $connect_return == 0 ]; then
  echo -n "Triggering decrypt: "
  run_cmd "curl --fail -k -v --connect-timeout 10 -X PUT https://$OPS_MAN_DOMAIN_NAME/api/v0/unlock?passphrase=$OPS_MAN_UI_DECRYPT_PASSPHRASE"
  check_rc $?
fi

# Cleanup; this file was created at the beginning of this script
rm ./opsman.pub

