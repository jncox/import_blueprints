#!/usr/bin/env python3.6

"""

    import_blueprints.py

    Connect to a Nutanix Prism Central instance and import all Nutanix Calm blueprints from a specified directory (or current directory if unspecified).

    Useful as a final step after you've dumped your blueprints using save_blueprints.py e.g. if you're setting up a temporary or new Prism Central instance during testing.

    You would need to *heavily* modify this script for use in a production environment so that it contains appropriate error-checking and exception handling.

"""

__author__ = "Chris Rasmussen @ Nutanix"
__version__ = "1.1"
__maintainer__ = "Chris Rasmussen @ Nutanix"
__email__ = "crasmussen@nutanix.com"
__status__ = "Development/Demo"

# default modules
import sys
import json
import getpass
import argparse
from time import localtime, strftime, mktime
import urllib3
import glob

# custom modules
import apiclient

def set_options():
    # configure some global settings for use later
    global ENTITY_RESPONSE_LENGTH
    # set ENTITY_RESPONSE_LENGTH to the max number of entities to return
    # not used in this script but is used in other templates
    ENTITY_RESPONSE_LENGTH = 50

def get_options():
    # process the command-line parameters provided by the user
    global cluster_ip
    global username
    global password
    global directory
    global project
    global dict_variables
   
    # specify both the mandatory and optional command-line parameters
    parser = argparse.ArgumentParser(description='Import Calm blueprints from JSON files')
    parser.add_argument('pc_ip',help='Prism Central IP address')
    parser.add_argument('-u', '--username',help='Prism Central username')
    parser.add_argument('-p', '--password',help='Prism Central password')
    parser.add_argument('-d', '--directory',help='Blueprint directory')
    parser.add_argument('-o', '--project',help='Name of the project the blueprint belongs to')
    parser.add_argument('-i', '--pe_vip',help='PE_VIP of the cluster where the Era VM will live')
    parser.add_argument('-c', '--ctr_uuid',help='CTR_UUID of the cluster where the Era VM will live')
    parser.add_argument('-t', '--ctr_name',help='CTR_NAME of the cluster where the Era VM will live')
    parser.add_argument('-l', '--clstr_name',help='CLSTR_NAME of the cluster where the Era VM will live')
    parser.add_argument('-e', '--era_id',help='ERA_ID of the cluster where the Era VM will live')
    parser.add_argument('-n', '--network_name',help='NETWORK_NAME of the cluster where the Era VM will live')
    parser.add_argument('-v', '--network_vlan',help='NETWORK_VLAN of the cluster where the Era VM will live')
    args = parser.parse_args()

    # validate the arguments to make sure all required info has been supplied
    if args.username:
        username = args.username
    else:
        username = input('Please enter your Prism Central username: ')

    if args.password:
        password = args.password
    else:
        password = getpass.getpass()

    if args.directory:
        directory = args.directory
    else:
        directory = '.'

    if args.project:
        project = args.project
    else:
        project = 'none'
    
    dict_variables = {'pe_vip':'none', 'ctr_uuid':'none', 'clstr_name':'none', 'ctr_name':'none', 'era_id':'none', 'network_name':'none', 'network_vlan':'none'}

    if args.pe_vip:
        dict_variables['pe_vip'] = args.pe_vip

    if args.ctr_uuid:
        dict_variables['ctr_uuid'] = args.ctr_uuid

    if args.clstr_name:
        dict_variables['clstr_name'] = args.clstr_name

    if args.ctr_name:
        dict_variables['ctr_name'] = args.ctr_name

    if args.era_id:
        dict_variables['era_id'] = args.era_id

    if args.network_name:
        dict_variables['network_name'] =  args.network_name
   
    if args.network_vlan:
        dict_variables['network_vlan'] = args.network_vlan

    cluster_ip = args.pc_ip

def main():     
        # set the global options
        set_options()

        # get the cluster connection info
        get_options()

        # disable insecure connection warnings
        # please be advised and aware of the implications in a production environment!
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

        # make sure all required info has been provided
        if not cluster_ip:
            raise Exception("Cluster IP is required.")
        elif not username:
            raise Exception("Username is required.")
        elif not password:
            raise Exception("Password is required.")
        else:    
            # get a list of all blueprints in the specified directory
            dir_path = directory.rstrip("/")
            blueprint_list = glob.glob(dir_path +'/*.json')

            if(len(blueprint_list) > 0):

                # first check if the user has specified a project for the imported blueprints
                # if they did, we need to make sure the project exists
                if project != 'none':
                    project_found = False
                    client = apiclient.ApiClient('post', cluster_ip, "projects/list", '{ "kind": "project" }', username, password )
                    results = client.get_info()
                    for current_project in results["entities"]:
                        if current_project["status"]["name"] == project:
                            project_found = True
                            project_uuid = current_project["metadata"]["uuid"]

                # was the project found?
                if project_found:
                    print('\nProject'+ project+  ' exists.')
                else:
                    # project wasn't found
                    # exit at this point as we don't want to assume all blueprints should then hit the 'default' project
                    print('\nProject ' +project+ ' was not found.  Please check the name and retry.')
                    sys.exit()

                # make sure the user knows what's happening ... ;-)
                print(len(blueprint_list) + ' JSON files found. Starting import ...\n')

                # go through the blueprint JSON files found in the specified directory
                for blueprint in blueprint_list:
                    start_time = localtime()
                    # open the JSON file from disk
                    with open(blueprint, "r") as f:
                        raw_json = f.read()

                        # if no project was specified on the commane line, we've already pre-set the project variable to 'none'
                        # if a project was specified, we need to add it into the JSON data
                        if project != 'none':
                            parsed = json.loads(raw_json)
                            parsed["metadata"]["project_reference"] = {}
                            parsed["metadata"]["project_reference"]["kind"] = "project"
                            parsed["metadata"]["project_reference"]["uuid"] = project_uuid

                            # ADD VARIABLES if the current blueprint being analized is the EraServerDeployment.json
                            if "EraServerDeployment" in parsed["metadata"]["name"]:
                                variable_list_of_dictionaries = parsed["spec"]["resources"]["service_definition_list"][0]["variable_list"]  
                                for var_dict in variable_list_of_dictionaries:
                                    variable_name = (var_dict["name"].lower())
                                    # if the variable was defined as and arg, add to the json file, skip otherwise
                                    if dict_variables[variable_name] != 'none':
                                        var_dict["value"] = dict_variables[variable_name]

                            # ensure the changes just made are saved into the json
                            raw_json = json.dumps(parsed)

                        # remove the "status" key from the JSON data this is included on export but is invalid on import
                        pre_process = json.loads(raw_json)
                        if "status" in pre_process:
                            pre_process.pop("status")
                        if "product_version" in pre_process:
                            pre_process.pop("product_version")

                        # after removing the non-required keys, make sure the data is back in the correct format
                        raw_json = json.dumps(pre_process)
                      
                        # try and get the blueprint name
                        # if this fails, it's either a corrupt/damaged/edited blueprint JSON file or not a blueprint file at all
                        try:
                            blueprint_name = json.loads(raw_json)['spec']['name']
                        except json.decoder.JSONDecodeError:
                            print(blueprint+' : Unprocessable JSON file found. Is this definitely a Nutanix Calm blueprint file?')
                            sys.exit()

                        # got the blueprint name - this is probably a valid blueprint file
                        # we can now continue and try the upload
                        client = apiclient.ApiClient(
                            'post',
                            cluster_ip,
                            "blueprints/import_json",
                            raw_json,
                            username,
                            password
                        )
                        try:
                            json_result = client.get_info()
                        except json.decoder.JSONDecodeError:
                            print(blueprint +': No processable JSON response available.')
                            sys.exit()
                        
                    # calculate how long the import took
                    end_time = localtime()
                    difference = mktime(end_time) - mktime(start_time)

                    try:
                        message = blueprint+' : ' + json_result['message_list'][0]['message']+'.'
                    except KeyError:
                        message = blueprint+' : Successfully imported in '+ difference+' seconds.'

                    # tell the user what happened, including any failures
                    print(message)

            else:
                print('\nNo JSON files found in' + directory +' ... nothing to import!')
                
            # w00t
            print("\nFinished!\n")

if __name__ == "__main__":
    main()