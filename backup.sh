#!/bin/zsh

source .env

# # Enable these two lines if you are using the storage account network rules.
# # This will allow access to the storage account from everywhere.
# az storage account update --default-action Allow --name $TODO_YOUR_STORAGE_ACCOUNT_NAME
# sleep 60

# Get the current active revision
rev=$(az containerapp revision list -n $TODO_CONTAINER_APP_NAME -g $TODO_RESOURCE_GROUP_NAME --query "[0].name" --output tsv)

echo "Deactivate the current revision: $rev"
az containerapp revision deactivate -n $TODO_CONTAINER_APP_NAME -g $TODO_RESOURCE_GROUP_NAME --revision $rev

echo "Download the files from the storage account file share"
az storage file download-batch --account-key $TODO_YOUR_ACCOUNT_KEY --account-name $TODO_YOUR_STORAGE_ACCOUNT_NAME --destination ./vaultwarden --no-progress --source vaultwarden

echo "Reactivate the revision"
az containerapp revision activate -n $TODO_CONTAINER_APP_NAME -g $TODO_RESOURCE_GROUP_NAME --revision $rev

# # If you are using the storage account network rules, disable access from everywhere again.
az storage account update --default-action Deny --name $TODO_YOUR_STORAGE_ACCOUNT_NAME