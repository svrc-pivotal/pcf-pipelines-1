#!/usr/bin/env bash
#
# Create storage containers and buckets in Azure

function check_env_vars() {

  # Make sure that the environment variables for talking to Azure
  # are present.
  if [ ! -f ./env.sh ]; then
     echo "Missing environtment configuration."
     echo "Please load ./env.sh with Azure creds to continue."
     exit 255
  fi
}

function check_rc() {

  # Check the return code of previous command.
  local RC=$1
  if [ $RC != 0 ]; then
    echo "Failed"
    exit 1
  else
    echo "Ok"
  fi
  echo "" 2>&1
}


function check_for_deps() {

  # Make sure jq is installed for parsing json
  echo -n "Checking for deployment dependencies: "
  for util in jq azure; do
     $util --help > /dev/null 2>&1
    if [ $? != 0 ]; then
      echo "Please install $util."
      exit 255
    fi
  done
  echo "Ok"
}

function run_cmd() {

  local cmd=$*
  echo "runcmd:  $*" 2>&1
  # This will provide the return code to the caller
  eval $cmd 2>&1
}

function login_to_azure() {

  local APP_ID=$1
  local APP_PASS=$2
  local TENANT_ID=$3
  local SUBSCRIPTION_ID=$4

  # Get the command line logged in using env.sh creds.
  # using telemetry here ensures that data collection is not enabled
  azure telemetry -d > /dev/null 2>&1
  if [ $? != 0 ]; then
    echo
    echo "Please insall the Azure CLI."
    exit 255
  fi

  echo "Configuring the Azure CLI"
  echo -n " - Setting Azure cli to config mode (arm): "
  run_cmd "azure config mode arm"
  check_rc $?

  echo -n " - Logging to Azure cli ($APP_ID): "
  run_cmd "azure login --username $APP_ID --password $APP_PASS \
    --service-principal --tenant $TENANT_ID --environment AzureCloud"
  check_rc $?

  echo -n " - Setting subscription ($SUBSCRIPTION_ID): "
  run_cmd "azure account set $SUBSCRIPTION_ID"
  check_rc $?
  echo
}

function logout_of_azure() {

  # log out of azure
  local APP_ID=$1

  echo -n " - Logging out of Azure cli ($APP_ID): "
  run_cmd "azure logout --username $APP_ID"
  check_rc $?
}

function create_resource_group() {

  # Create a resource group.
  local RG=$1
  local LOCATION=$2
  echo -n "Creating resource group ($RG): "
  run_cmd "azure group create $RG $LOCATION"
  check_rc $?
}

function rand_string() {

  # Generate a random string.
  local COUNT=$1
  RAND=$(openssl rand -base64 32 | tr -dc a-z-0-9 | head -c $COUNT)
  echo $RAND
}

function create_ad_app() {

  # Create an instance of Active Directory.
  local SP=$1
  local APP_PASS=$2
  local URI=$3

  echo -n "Creating AD Instance ($SP): "
  run_cmd 'azure ad app create --name' "$SP" \
    '--password' "$APP_PASS" '--home-page http://BOSHAzureCPI' \
    '--identifier-uris' "$URI"
  check_rc $?
}

function get_ad_app_id() {

  # Return the Active Directory application ID.
  local URI=$1
  APP_ID=$(azure ad app show --identifierUri $URI --json \
    | jq -r '.[] | .appId')
  echo $APP_ID
}

function create_ad_sp() {

  # Create a service principal in the AD app.
  local AD_APP_ID=$1
  echo -n "Creating Active Directory SP ($AD_APP_ID): "
  run_cmd "azure ad sp create -a $AD_APP_ID"
  check_rc $?
  sleep 5 # Check if needed?
}

function create_roll_asignment() {

  # Asign a roll in a resource group.
  local APP_ID=$1
  local ROLL=$2
  local RG=$3

  echo -n "Creating roll $ROLL in $RG: "
  run_cmd "azure role assignment create --spn $APP_ID \
    --roleName '${ROLL}' --resource-group $RG"
  check_rc $?
}

function create_vnet() {

  # Create a VNET.
  local RG=$1
  local VNET=$2
  local LOCATION=$3
  local CIDR=$4

  echo -n "Creating VNET ($VNET): "
  run_cmd "azure network vnet create $RG $VNET $LOCATION \
       --address-prefixes $CIDR"
  check_rc $?
}

function create_subnet() {

  # Create a subnet.
  local RG=$1
  local VNET=$2
  local SUBNET_NAME=$3
  local CIDR=$4

  echo -n "Creating subnet $SUBNET_NAME ($VNET): "
  run_cmd "azure network vnet subnet create $RG $VNET $SUBNET_NAME \
    --address-prefix $CIDR"
  check_rc $?
}

function nsg_create() {

  # Create a network security group.
  local RG=$1
  local NAME=$2
  local LOCATION=$3

  echo -n "Creating NSG ($OM_NSG_NAME): "
  run_cmd "azure network nsg create $RG $NAME $LOCATION"
  check_rc $?
}

function nsg_dest_rule_create() {

  # Add a destination rule to a network resource group.
  local RG=$1
  local NSG=$2
  local NAME=$3
  local PROTO=$4
  local DST_PORT=$5
  local PRI=$6

  echo -n "Creating NSG rule ($RG to $NAME): "
  run_cmd "azure network nsg rule create $RG $NSG $NAME \
    --protocol $PROTO --destination-port-range '$DST_PORT' --priority $PRI"
  check_rc $?
}

function create_lb() {

  # Create a load balancer.
  local RG=$1
  local NAME=$2
  local LOCATION=$3

  echo -n "Creating Load Balancer ($NAME): "
  run_cmd "azure network lb create $RG $NAME $LOCATION"
  check_rc $?
}

function create_lb_probe() {

  # Create a load balancer probe resource.
  local RG=$1
  local NAME=$2
  local PROBE=$3
  local PROTO=$4
  local PORT=$5

  echo -n "Creating LB Probe ($NAME): "
  run_cmd "azure network lb probe create $RG $NAME $PROBE \
    --protocol $PROTO --port $PORT"
  check_rc $?
}

function create_lb_addy_pool() {

  # Create a load balancer pool.
  local RG=$1
  local NAME=$2
  local POOL=$3

  echo -n "Creating LB POOL ($POOL): "
  run_cmd "azure network lb address-pool create $RG $NAME $POOL"
  check_rc $?
}

function create_lb_rule() {

  # Create a rule in a load balancer.
  local RG=$1
  local NAME=$2
  local SERVICE=$3
  local PROTO=$4
  local FE_PORT=$5
  local BE_PORT=$6

  echo -n "Adding LB Rule ($NAME): "
  run_cmd "azure network lb rule create $RG $NAME $SERVICE --protocol $PROTO
    --frontend-port $FE_PORT --backend-port $BE_PORT"
  check_rc $?
}

function create_availset() {

  # Create an availability set
  local RG=$1
  local NAME=$2
  local LOCATION=$3

  echo -n "Creating Availability Set ($NAME): "
  run_cmd "azure availset create $RG $NAME $LOCATION"
  check_rc $?
}

function create_public_ip() {

  # Create a public IP.
  local RG=$1
  local NAME=$2
  local LOCATION=$3

  echo -n "Creating public ip ($NAME): "
  run_cmd "azure network public-ip create $RG $NAME \
    $LOCATION --allocation-method Static"
  check_rc $?
}

function create_bucket() {

  # Given a bucket name and connection string, create a container.
  local BUCKET=$1
  local CONN=$2
  local PERMISSIONS=$3
  echo -n " - Creating $BUCKET storage container: "
  run_cmd "azure storage container create '$BUCKET' $PERMISSIONS --connection-string '$CONN'"
  check_rc $?
}

function create_table() {

  # Given a table name and connection string, create a table.
  local TABLE=$1
  local CONN=$2
  echo -n " - Creating $TABLE storage table: "
  run_cmd "azure storage table create '$TABLE' --connection-string '$CONN'"
  check_rc $?
}

function create_storage_account() {
  local ACCOUNT=$1
  local RESOURCE_GROUP=$2
  local ACCOUNT_TYPE=$3
  local LOCATION=$4
  echo -n "Creating Storage Account ($ACCOUNT): "
  run_cmd "azure storage account create $ACCOUNT \
    --resource-group $RESOURCE_GROUP --sku-name $ACCOUNT_TYPE --kind Storage \
    --location $LOCATION"
  check_rc $?
}

function create_pcf_storage_account() {

  # Given an account name, create a storage account.
  create_storage_account $1 $PCF_RG_NAME LRS $LOCATION
}

function get_storage_connection_string() {

  # Return a storage connection string, based on account name.
  local ACCOUNT=$1
  if [ -z ${2+x} ]; then local RG=$PCF_RG_NAME; else local RG=$2; fi
  CONN=$(azure storage account connectionstring show "$ACCOUNT" \
           --resource-group $RG --json | jq -r '.string')
  echo $CONN
}


function get_opsman_blob_copy_status_json(){
  local CONN=$1
  BLOB_COPY_SHOW=$(azure storage blob copy show opsmanager image.vhd \
    --connection-string $CONN --json)

  echo "$BLOB_COPY_SHOW"
}

function get_blob_copy_status() {
   local JSON=$1
   local STATUS=$(echo $JSON| jq -r '.copy.status')
   echo $STATUS
}

function get_blob_copy_progress() {
   local JSON=$1
   local PROGRESS=$(echo $JSON| jq -r '.copy.progress')
   echo $PROGRESS
}

