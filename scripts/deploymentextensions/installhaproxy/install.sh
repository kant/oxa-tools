#!/bin/bash
#
# Copyright (c) Microsoft Corporation. All Rights Reserved.
# Licensed under the MIT license. See LICENSE file on the project webpage for details.

#
# This script installs and configures HAProxy for Mysql Load Balancing and supporting seamless failover
#

ERROR_HAPROXY_INSTALLER_FAILED=10101

# Oxa Tools
# Settings for the OXA-Tools public repository 
oxa_tools_public_github_account="Microsoft"
oxa_tools_public_github_projectname="oxa-tools"
oxa_tools_public_github_projectbranch="oxa/master.fic"
oxa_tools_public_github_branchtag=""
oxa_tools_repository_path="/oxa/oxa-tools"

# Initialize required parameters

# this is the server that will run HA Proxy
target_server="10.0.0.16"   

# this is a space-separated list (originally base64-encoded) of mysql servers in the replicated topology. The master is listed first followed by 2 slaves
mysql_master_server_ip=""
mysql_slave1_server_ip=""
mysql_slave2_server_ip=""
mysql_server_list=""
mysql_server_port="3306"

mysql_admin_username=""
mysql_admin_password=""

# haproxy settings
haproxy_port="3308"
haproxy_username="haproxy_check"
haproxy_initscript="/etc/default/haproxy"
haproxy_configuration_file="/etc/haproxy/haproxy.cfg"
haproxy_configuration_template_file="${oxa_tools_repository_path}/scripts/deploymentextensions/installhaproxy/haproxy.template.cfg"

# operation mode: 0=local, 1=remote via ssh
remote_mode=0

# Email Notifications
notification_email_subject="Move Mysql Data Directory"
admin_email_address=""

#############################################################################
# parse the command line arguments

parse_args() 
{
    while [[ "$#" -gt 0 ]]
    do
        arg_value="${2}"
        shift_once=0

        if [[ "${arg_value}" =~ "--" ]]; 
        then
            arg_value=""
            shift_once=1
        fi

         # Log input parameters to facilitate troubleshooting
        echo "Option '${1}' set with value '"${arg_value}"'"

        case "$1" in
          --oxatools-public-github-accountname)
            oxa_tools_public_github_account="${arg_value}"
            ;;
          --oxatools-public-github-projectname)
            oxa_tools_public_github_projectname="${arg_value}"
            ;;
          --oxatools-public-github-projectbranch)
            oxa_tools_public_github_projectbranch="${arg_value}"
            ;;
          --oxatools-public-github-branchtag)
            oxa_tools_public_github_branchtag="${arg_value}"
            ;;
          --oxatools-repository-path)
            oxa_tools_repository_path="${arg_value}"
            ;;
          --admin-email-address)
            admin_email_address="${arg_value}"
            ;;
          --target-server)
            target_server="${arg_value}"
            ;;
          --mysql-server-port)
            mysql_server_port="${arg_value}"
            ;;
          --mysql-admin-username)
            mysql_admin_username="${arg_value}"
            ;;
          --mysql-admin-password)
            mysql_admin_password="${arg_value}"
            ;;
          --haproxy-server-port)
            haproxy_port="${arg_value}"
            ;;
          --mysql-server-list)
            mysql_server_list=(`echo ${arg_value} | base64 --decode`)
            ;;
          --remote)
            remote_mode=1
            ;;
        esac

        shift # past argument or value

        if [ $shift_once -eq 0 ]; 
        then
            shift # past argument or value
        fi

    done
}

###############################################
# START CORE EXECUTION
###############################################

# Source our utilities for logging and other base functions (we need this staged with the installer script)
# the file needs to be first downloaded from the public repository
current_path="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
utilities_path=$current_path/utilities.sh

# check if the utilities file exists. If not, bail out.
if [[ ! -e $utilities_path ]]; 
then  
    echo :"Utilities not present"
    exit 3
fi

# source the utilities now
source $utilities_path

# Script self-identification
print_script_header "HA Proxy Installer"

# pass existing command line arguments
parse_args $@

# sync the oxa-tools repository
repo_url=`get_github_url "$oxa_tools_public_github_account" "$oxa_tools_public_github_projectname"`
sync_repo $repo_url $oxa_tools_public_github_projectbranch $oxa_tools_repository_path $access_token $oxa_tools_public_github_branchtag

# execute the installer remote
if [[ $remote == 0 ]];
then
    # at this point, we are on the jumpbox attempting to execute the installer on the remote target 

    # copy the installer & the utilities files to the target server & ssh/execute the Operations
    scp ./install.sh "${target_server}":~/
    exit_on_error "Unable to copy installer script to '${target_server}' from '${HOSTNAME}' !" $ERROR_HAPROXY_INSTALLER_FAILED, $notification_email_subject $admin_email_address

    scp ./utilities.sh "${target_server}":~/
    exit_on_error "Unable to copy utilities to '${target_server}' from '${HOSTNAME}' !" $ERROR_HAPROXY_INSTALLER_FAILED, $notification_email_subject $admin_email_address

    # build the command for remote execution
    $encoded_server_list=`echo ${mysql_server_list} | base64`
    remote_command="sudo bash ~/install.sh --oxatools-public-github-accountname $oxa_tools_public_github_account --oxatools-public-github-projectname $oxa_tools_public_github_projectname --oxatools-public-github-projectbranch $oxa_tools_public_github_projectbranch --oxatools-public-github-branchtag $oxa_tools_public_github_branchtag --oxatools-repository-path $oxa_tools_repository_path --admin-email-address $admin_email_address --target-server $target_server --mysql-server-port $mysql_server_port --mysql-admin-username $mysql_admin_username --mysql-admin-password $mysql_admin_password --haproxy-server-port $haproxy_port --mysql-server-list $encoded_server_list --remote"

    # run the remote command
    ssh "${target_server}":~/ $remote_command
    exit_on_error "Could not execute the installer on the remote target: ${target_server} from '${HOSTNAME}' !" $ERROR_HAPROXY_INSTALLER_FAILED, $notification_email_subject $admin_email_address

    log "Completed Remote execution successfully"
    exit
fi

#############################################
# Main Operations
# this should run on the target server
#############################################

# setup the server references
mysql_master_server_ip=${mysql_server_list[0]}
mysql_slave1_server_ip=${mysql_server_list[1]}
mysql_slave2_server_ip=${mysql_server_list[2]}

# 1. Create the HA Proxy Mysql account on the master mysql server
mysql -u ${mysql_admin_username} -p${mysql_admin_password} -h ${mysql_master_server_ip} -e "INSERT INTO mysql.user (Host,User) values ('${target_server}','${haproxy_username}') ON DUPLICATE KEY UPDATE Host='${target_server}', User='${haproxy_username}'; FLUSH PRIVILEGES;"
exit_on_error "Unable to create HA Proxy Mysql account on '${HOSTNAME}' !" $ERROR_HAPROXY_INSTALLER_FAILED, $notification_email_subject $admin_email_address

# Validate user access
database_list=`mysql -u ${haproxy_username} -N -h ${mysql_master_server_ip} -e "SHOW DATABASES"`
exit_on_error "Unable to access the target server using ${haproxy_username}@${mysql_master_server_ip} without password from '${HOSTNAME}' !" $ERROR_HAPROXY_INSTALLER_FAILED, $notification_email_subject $admin_email_address

# 2. Install HA Proxy
stop_haproxy
install_haproxy

# 3. Configure HA Proxy

# 3.1 Enable HA Proxy to be initialized from startup script
enabled_regex="^ENABLED=.*"

if grep -Gxq $enabled_regex $haproxy_initscript;
then
    # Existing Alias: Override it
    sed -i "s/${enabled_regex}/ENABLED=1/I" $haproxy_initscript
else
    # Alias doesn't exist: Append It
    cat "ENABLED=1" >> $haproxy_initscript
fi

# 3.2 Update the HA Proxy configuration
if [ -f "${haproxy_configuration_file}" ];
then
    mv "${haproxy_configuration_file}"{,.bak}
    exit_on_error "Unable to backup the HA Proxy configuration file at ${haproxy_configuration_file} !" $ERROR_HAPROXY_INSTALLER_FAILED, $notification_email_subject $admin_email_address
fi

cp  "${haproxy_configuration_template_file}" "${haproxy_configuration_file}"
exit_on_error "Unable to copy the HA Proxy configuration template from  the target server using ${haproxy_username}@${mysql_master_server_ip} without password from '${HOSTNAME}' !" $ERROR_HAPROXY_INSTALLER_FAILED, $notification_email_subject $admin_email_address

set -x
log "Replacing template variables"
sed -i "s/{HAProxyPort}/${haproxy_port}/I" "${haproxy_configuration_file}"
sed -i "s/{MysqlServerPort}/${mysql_server_port}/I" "${haproxy_configuration_file}"
sed -i "s/{MysqlMasterServerIP}/${mysql_master_server_ip}/I" "${haproxy_configuration_file}"
sed -i "s/{MysqlSlave1ServerIP}/${mysql_slave1_server_ip}/I" "${haproxy_configuration_file}"
sed -i "s/{MysqlSlave2ServerIP}/${mysql_slave2_server_ip}/I" "${haproxy_configuration_file}"

# 3.3 Start HA Proxy
start_haproxy
exit_on_error "Unable to start HA Proxy on '${HOSTNAME}' !" $ERROR_HAPROXY_INSTALLER_FAILED, $notification_email_subject $admin_email_address

# 3.4 Final validation
database_list=`mysql -u ${mysql_admin_username} -p${mysql_admin_password} -h ${mysql_master_server_ip} -P ${haproxy_port} -e "SHOW DATABASES;"`
exit_on_error "Unable to access the target server using ${mysql_admin_username}@${mysql_master_server_ip} from '${HOSTNAME}' !" $ERROR_HAPROXY_INSTALLER_FAILED, $notification_email_subject $admin_email_address

if [[ -z "${database_list// }" ]];
then    
    log "The database list returned is empty: '${database_list}'"
    exit $ERROR_HAPROXY_INSTALLER_FAILED
fi

log "Completed HA Proxy installation ${target_user}"