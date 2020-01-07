#!/bin/bash

################################################################################################################################################################
#    import_blueprints.sh
#    Connect to a Nutanix Prism Central instance and import all Nutanix Calm blueprints from a specified directory (or current directory if unspecified).
#    You would need to *heavily* modify this script for use in a production environment so that it contains appropriate error-checking and exception handling.
#
#    Example command:
#    sh import_blueprints.sh -i 10.42.7.39 -u admin -p techX2019! -d /Users/sharon.santana/Desktop/saved_blueprints -o default -n primary -t examplecontainer -r 00059a26-7fd3-1063-0000-00000000760

#    author: 'Sharon Santana @ Nutanix'
#    version: '1.1'
#    email: 'sharon@nutanix.com'
#    status: 'Development/Demo'
###################################################################################################################################################################

# Default values for arguments
PC_IP=""
USERNAME=""
PASSWORD=''
DIRECTORY=""
CALM_PROJECT="none"
PE_IP="none"
CLSTR_NAME="none"
CTR_UUID="none"
CTR_NAME="none"
NETWORK_NAME="none"
VLAN_NAME="none"

# Loop through arguments and process them according to if the user entered them or not
PARAMS=""
while (("$#")); do
    case "$1" in
    -h | --help)
        echo "\n"
        echo "-i|--pc-ip: prism central ip"
        echo "-u|--username: prism username"
        echo "-p|--password: prism password"
        echo "-d|--directory: local directory path for blueprint file to be imported"
        echo "-o|--project: project name inside Calm"
        echo "-e|--pe-ip: PE ip"
        echo "-c|--cluster-name: cluster name of the cluster where Era VM will exist"
        echo "-t|--container-name: container name of the cluster where Era VM will exist"
        echo "-r|--container-uuid: uuid of the container where Era VM will exist"
        echo "-n|--network-name: network name of the cluster where Era VM will exist"
        echo "-v|--vlan-name: vlan name of the cluster where Era VM will exist"
        echo "\n"
        echo "Example command: import_blueprints.sh -c 10.10.10.10 -u admin -p secret -d /path/to/blueprint/file -j default"
        echo "\n"
        shift 1
        ;;
    -i | --cluster-ip)
        PC_IP=$2
        shift 2
        ;;
    -u | --username)
        USERNAME=$2
        shift 2
        ;;
    -p | --password)
        PASSWORD="$2"
        shift 2
        ;;
    -d | --directory)
        DIRECTORY=$2
        shift 2
        ;;
    -o | --project)
        CALM_PROJECT=$2
        shift 2
        ;;
    -e | --pe_ip)
        PE_IP=$2
        shift 2
        ;;
    -l | --clstr_name)
        CLSTR_NAME=$2
        shift 2
        ;;
    -r | --ctr_uuid)
        CTR_UUID=$2
        shift 2
        ;;
    -t | --ctr_name)
        CTR_NAME=$2
        shift 2
        ;;
    -n | --network_name)
        NETWORK_NAME=$2
        shift 2
        ;;
    -v | --network_vlan)
        VLAN_NAME=$2
        shift 2
        ;;
    --) # end argument parsing
        shift
        break
        ;;
    -* | --*=) # unsupported flags
        echo "Error: Unsupported flag $1" >&2
        exit 1
        ;;
    *) # preserve positional arguments
        PARAMS="$PARAMS $1"
        shift
        ;;
    esac
done

# set positional arguments in their proper place
eval set -- "$PARAMS"

# validate required parameters
if [ "$PC_IP" == "" ]; then
    echo "PC IP: $PC_IP is required."
    exit 0
fi

if [ "$USERNAME" == "" ]; then
    echo "USERNAME IP: $USERNAME is required."
    exit 0
fi

if [ "$PASSWORD" == "" ]; then
    echo "PASSWORD IP: $PASSWORD is required."
    exit 0
fi

if [ "$DIRECTORY" == "" ]; then
    echo "DIRECTORY path: $DIRECTORY is required."
    exit 0
fi

# ensure the directory that contains the blueprints to be imported is not empty
if [[ $(ls -l "$DIRECTORY"/*.json) == *"No such file or directory"* ]]; then
    echo "There are no .json files found in the directory provided."
    exit 0
fi

# define the name of the bp that we want to change the variables
# not all bps being imported will have variables added to it. in this case only if the name is "EraServerDeployment.json"
NAME="EraServerDeployment.json"
project_uuid=''

# create a list to store all bluprints found in the directory provided by user
declare -a LIST_OF_BLUEPRINTS=()

# circle thru all of the files in the provided directory and add file names to a list of blueprints array
# IMPORTANT NOTE: THE FILES NAMES FOR THE JSON FILES BEING IMPORTED CAN'T HAVE ANY SPACES (IN THIS SCRIPT)
for FILE in "$DIRECTORY"/*.json; do
    BASENAM="$(basename ${FILE})"
    FILENAME="${BASENAM%.*}"
    LIST_OF_BLUEPRINTS+=("$BASENAM")
done

# echo $LIST_OF_BLUEPRINTS
# if the list of blueprints is not empty then:
if ((${#LIST_OF_BLUEPRINTS[@]})); then
    #   first check if the user has specified a project for the imported blueprints
    #   if they did, we need to make sure the project exists before assigning it to the BPs

    if [ $CALM_PROJECT != 'none' ]; then

        # curl command needed:
        # curl -s -k -X POST https://10.42.7.39:9440/api/nutanix/v3/projects/list -H 'Content-Type: application/json' --user admin:techX2019! -d '{"kind": "project", "filter": "name==default"}' | jq -r '.entities[].metadata.uuid'

        # formulate the curl to check for project
        _url_pc="https://${PC_IP}:9440/api/nutanix/v3/projects/list"

        # make API call and store project_uuid
        project_uuid=$(curl -s -k -X POST $_url_pc -H 'Content-Type: application/json' --user ${USERNAME}:${PASSWORD} -d "{\"kind\": \"project\", \"filter\": \"name==$CALM_PROJECT\"}" | jq -r '.entities[].metadata.uuid')

        if [ -z "$project_uuid" ]; then
            # project wasn't found
            # exit at this point as we don't want to assume all blueprints should then hit the 'default' project
            echo "\nProject $CALM_PROJECT was not found. Please check the name and retry."
            exit 0
        else
            echo "\nProject $CALM_PROJECT exists..."
        fi
    fi
else
    echo '\nNo JSON files found in' + $DIRECTORY +' ... nothing to import!'
fi

# update the user with script progress...
_num_of_files=${#LIST_OF_BLUEPRINTS[@]}
echo "\nNumber of .json files found: ${_num_of_files}"
echo "\nStarting blueprint updates and then exporting to Calm one file at a time...\n\n"

# go through the blueprint JSON files list found in the specified directory
for elem in "${LIST_OF_BLUEPRINTS[@]}"; do
    # read the entire JSON file from the directory
    JSONFile=${DIRECTORY}/"$elem"

    echo "\nCurrently updating blueprint $JSONFile..."

    # NOTE: bash doesn't do in place editing so we need to use a temp file and overwrite the old file with new changes for every blueprint
    tmp=$(mktemp)

    # ADD PROJECT (affects all BPs being imported) if no project was specified on the command line, we've already pre-set the project variable to 'none' if a project was specified, we need to add it into the JSON data
    if [ $CALM_PROJECT != 'none' ]; then
        # add the new atributes to the JSON and overwrite the old JSON file with the new one
        $(jq --arg proj $CALM_PROJECT --arg proj_uuid $project_uuid '.metadata+={"project_reference":{"kind":$proj,"uuid":$proj_uuid}}' $JSONFile >"$tmp" && mv "$tmp" $JSONFile)
    fi

    # ADD VARIABLES (affects ONLY if the current blueprint being imported MATCHES the name specified earlier "EraServerDeployment.json")
    if [ "$elem" == "${NAME}" ]; then
        if [ "$PE_IP" != "none" ]; then
            tmp_PE_IP=$(mktemp)
            # add the new variable to the json file and save it
            $(jq --arg var_name $PE_IP '(.spec.resources.service_definition_list[0].variable_list[] | select (.name=="PE_VIP")).value=$var_name' $JSONFile >"$tmp_PE_IP" && mv "$tmp_PE_IP" $JSONFile)
            # result="$(jq --arg newOBJ "${obj_with_replaced_variable}" '.spec.resources.service_definition_list[0].variable_list[] | select (.name=="PE_VIP") | .+=$newOBJ' $JSONFile )"
        fi
        if [ "$CLSTR_NAME" != "none" ]; then
            tmp_CLSTR_NAME=$(mktemp)
            $(jq --arg var_name $CLSTR_NAME '(.spec.resources.service_definition_list[0].variable_list[] | select (.name=="CLSTR_NAME")).value=$var_name' $JSONFile >"$tmp_CLSTR_NAME" && mv "$tmp_CLSTR_NAME" $JSONFile)
        fi
        if [ "$CTR_UUID" != "none" ]; then
            tmp_CTR_UUID=$(mktemp)
            $(jq --arg var_name $CTR_UUID '(.spec.resources.service_definition_list[0].variable_list[] | select (.name=="CTR_UUID")).value=$var_name' $JSONFile >"$tmp_CTR_UUID" && mv "$tmp_CTR_UUID" $JSONFile)
        fi
        if [ "$CTR_NAME" != "none" ]; then
            tmp_CTR_NAME=$(mktemp)
            $(jq --arg var_name $CTR_NAME '(.spec.resources.service_definition_list[0].variable_list[] | select (.name=="CTR_NAME")).value=$var_name' $JSONFile >"$tmp_CTR_NAME" && mv "$tmp_CTR_NAME" $JSONFile)
        fi
        if [ "$NETWORK_NAME" != "none" ]; then
            tmp_NETWORK_NAME=$(mktemp)
            $(jq --arg var_name $NETWORK_NAME '(.spec.resources.service_definition_list[0].variable_list[] | select (.name=="NETWORK_NAME")).value=$var_name' $JSONFile >"$tmp_NETWORK_NAME" && mv "$tmp_NETWORK_NAME" $JSONFile)
        fi
        if [ "$VLAN_NAME" != "none" ]; then
            tmp_VLAN_NAME=$(mktemp)
            $(jq --arg var_name $VLAN_NAME '(.spec.resources.service_definition_list[0].variable_list[] | select (.name=="VLAN_NAME")).value=$var_name' $JSONFile >"$tmp_VLAN_NAME" && mv "$tmp_VLAN_NAME" $JSONFile)
        fi
    fi

    # REMOVE the "status" and "product_version" keys (if they exist) from the JSON data this is included on export but is invalid on import. (affects all BPs being imported)
    tmp_removal=$(mktemp)
    $(jq 'del(.status) | del(.product_version)' $JSONFile >"$tmp_removal" && mv "$tmp_removal" $JSONFile)

    # GET BP NAME (affects all BPs being imported)
    # if this fails, it's either a corrupt/damaged/edited blueprint JSON file or not a blueprint file at all
    blueprint_name_quotes=$(jq '(.spec.name)' $JSONFile)
    blueprint_name="${blueprint_name_quotes%\"}" # remove the suffix " 
    blueprint_name="${blueprint_name#\"}" # will remove the prefix " 

    if [ blueprint_name == 'null' ]; then
        echo "\nUnprocessable JSON file found. Is this definitely a Nutanix Calm blueprint file?\n"
        exit 0
    else
        # got the blueprint name means it is probably a valid blueprint file, we can now continue the upload
        echo "\nUploading the updated blueprint: $blueprint_name...\n"

        # Example curl call from the console:
        # url="https://10.42.7.39:9440/api/nutanix/v3/blueprints/import_file"
        # path_to_file="/Users/sharon.santana/Desktop/saved_blueprints/EraServerDeployment.json"
        # bp_name="EraServerDeployment"
        # project_uuid="a944258a-fd8a-4d02-8646-72c311e03747"
        # password='techX2019!'
        # curl -s -k -X POST $url -F file=@$path_to_file -F name=$bp_name -F project_uuid=$project_uuid --user admin:"$password"

        url="https://${PC_IP}:9440/api/nutanix/v3/blueprints/import_file"
        path_to_file=$JSONFile
        bp_name=$blueprint_name
        project_uuid=$project_uuid
        password=$PASSWORD
        upload_result=$(curl -s -k -X POST $url -F file=@$path_to_file -F name=$bp_name -F project_uuid=$project_uuid --user admin:"$password")

        #if the upload_result var is not empty then let's say it was succcessful
        if [ -z "$upload_result" ]; then
            echo "\nUpload for $bp_name did not finish."
        else 
            echo "\nUpload for $bp_name finished."
            echo "-----------------------------------------"
            # echo "Result: $upload_result"
        fi
    fi
done

echo "\nFinished with all files!\n"