#!/bin/bash

debug=0
datestr=`date +%Y%m%d%H`
rundate=`date`
nextrundate=`date --date="tomorrow"`

#########################################################################
# logwrite function
#------------------------------------------------------------------------
# Writes to syslog messages passed in
#########################################################################
logwrite() {
	
	if [[ $2 == "DEBUG" ]]; then
		if [[ $debug -ne 1 ]]; then
			return
		fi
	fi

	# set log level variable
	if [[ ! -n $2 ]]; then
		logger -s -t ohi_backup "[UNKNOWN] - $1"
		return
	fi
	logger -s -t ohi_backup "[$2] - $1"
}

#########################################################################
# master_check function	
#------------------------------------------------------------------------
# The master check function will retrieve the information from the API of
# the current machine, such as the attached drive and name. It will also 
# verify that there is only one server running with the current IP address.
#########################################################################
master_check() {
	
	# get the ip address of the current machine
	ip_addr=`/sbin/ifconfig eth0 | grep "inet addr" | sed 's/^.*inet addr:\([0-9]\{1,3\}\(\.[0-9]\{1,3\}\)\{3\}\).*$/\1/'`
	logwrite "Current ip address is [$ip_addr]" "INFO"
	
	# if the ip address was not found, exit
	if [[ ! -n $ip_addr ]]; then
		logwrite "Could not find ip address of current server! Exiting!" "ERROR"
		exit 1;
	fi
	
	# get a list of servers for the user from the api
	server_list=`curl -K <(echo "user = "${api_user}:${api_secret}"") -f -s -H "Content-Type: header" -H 'Expect:' "${api_address}servers/list" -k`
	
	# check each of the servers for the ip address
	for server in `echo $server_list`; do
		values=`curl -K <(echo "user = "${api_user}:${api_secret}"") -f -s -H "Content-Type: header" -H 'Expect:' "${api_address}servers/${server}/info" -k`
		
		oldIFS=$IFS
		IFS=$'\n'
		for key in $values; do
			IFS=" "
			set - $key
			#echo "key [$1] value [$2]"
			[[ "$1" == "nic:0:dhcp:ip" ]] && this_ip=$2
			[[ "$1" == "name" ]] && shift && this_name=$@
			[[ "$1" == "ide:0:0" ]] && this_drive=$2
			
		done

		# extracted this_ip and this_name from the list, compare the ip to our current ip
		if [[ "$ip_addr" == "$this_ip" ]]; then
			if [[ -n $server_name ]]; then
				logwrite "There are two servers sharing the same IP, can't determine which server I am. Exiting" "ERROR"
				return 1
			fi
			server_name=$this_name
			server_drive=$this_drive
			server_pw=`</dev/urandom tr -dc A-Za-z0-9 | head -c8`
		fi
		IFS=$oldIFS
		unset this_ip
		unset this_name
		unset this_drive

	done

	if [[ -n $server_name ]]; then
		logwrite "Current servername is [$server_name]" "INFO"
	else
		logwrite "Servername could not be found! Exiting!" "ERROR"
		exit 1;
	fi

	return 0

}

#########################################################################
# exec_local_pre_backup function
#------------------------------------------------------------------------
# This function will take the string local_pre_script provided in the
# config file and execute it. It will look for 
#########################################################################
exec_local_pre_backup() {
	
	# verify the script exists
	if [[ ! -n $local_pre_script ]]; then
		logwrite "local_pre_script is not set, no preliminary script specified, skipping." "INFO"
		return 0
	fi

	# Verify the script has root-only permissions
	perm_check=`find "$local_pre_script" -user root -perm 700 | wc -l`
	if [[ $perm_check -ne 1 ]]; then
		logwrite "The script [$local_pre_script] does not have the right permissions. Should be 700 (read/write/executable only by root)" "ERROR"
		return 1
	fi
	unset perm_check
	
	# Execute the script
	logwrite "Executing [$local_pre_script]" "INFO"
	"$local_pre_script"
	pre_script_result=$?
	if [[ $pre_script_result -ne 0 ]] || [[ ! -n $pre_script_result ]]; then
		logwrite "The local_pre_script [$local_pre_script] failed, returning a status of [$pre_script_result]. Exiting!" "ERROR"
		return 1
	else
		logwrite "The local_pre_script [$local_pre_script] returned with a status of [$pre_script_result]. Continuing." "INFO"
		return 0
	fi
	 
	return 1
}

#########################################################################
# gen_slave_image function
#------------------------------------------------------------------------
# This function will generate a new slave image to perform the backup to. 
# First it will create a drive with the same size as the masters drive. 
# Next it will copy the previous backup drive to the newly created drive, 
# if there is no previous backup drive, or the previous backup drive is not
# accessable, it will then copy from the pre-installed drive specified in 
# the config file.
#########################################################################
gen_slave_image () {

	######
	## create and truncate the new server name if needed
	new_name="${server_name}${backup_tag}${datestr}"
	if [[ ${#new_name} -gt 80 ]]; then
		logwrite "server name [${new_name}] is [${#new_name}] characters long, truncated to 80 characters, [${new_name:(-80)}]"
		new_name=${new_name:(-80)}
	fi


	######
	## get the UUID of the previous drive backup if using 
	if [[ $incremental_backup = "true" ]]; then
		previous_drive=`tail -1 $backup_inventory_location`
		set - $previous_drive
		prev_drive_uuid=$1
		if [[ -n $prev_drive_uuid ]]; then
			logwrite "Previous drive UUID = [$prev_drive_uuid]" "INFO"
		else
			unset prev_drive_uuid
		fi
	fi

	######
	## get the size of the master drive 
	drive_size=`curl -K <(echo "user = "${api_user}:${api_secret}"") -f -s -H "Content-Type: header" -H 'Expect:' "${api_address}drives/$server_drive/info" -k | grep size | sed 's/^.* //'`
	logwrite "drive size is [$drive_size]" "INFO"

	# if the drive size is empty or undefined, exit
	if [[ ! -n $drive_size ]]; then
		logwrite "Unable to find the size of drive $server_drive" "ERROR"
		return 1
	fi

	######
	## Create the new drive
	new_drive=`echo -e "name ${new_name}\nsize ${drive_size}" | curl --data-binary @- -K <(echo "user = "${api_user}:${api_secret}"") -s  -H "Content-Type: application/octet-stream"  -H 'Expect:' "${api_address}drives/create" -k | grep "drive " | sed 's/^.* //'`
	if [[ $? -ne 0 ]]; then
		logwrite "Create drive command failed!" "ERROR"
		return 1
	fi
	if [[ ! -n $new_drive ]]; then
		logwrite "Couldn't find the name of the new drive!" "ERROR"
		return 1
	fi

	logwrite "Created a new drive [$new_drive]" "INFO"

	
	######
	## If prev_drive_uuid is set, verify we can copy from it, and then copy from it, if not, copy from the pre-installed drive

	sleep 5 # sleep to let the new drive become accessable for copy

	if [[ -n $prev_drive_uuid ]]; then
		# prev_drive_uuid is set, attempt to copy from it
		echo "Copying from last backup [$prev_drive_uuid]"
		
		######
		## Copy from the previous backup drive to the new drive
		logwrite "Copy from the previous backup drive [${prev_drive_uuid}] to the new drive [${new_drive}]" "INFO"
 
		copy_drive_status=`echo -e "/drives/${new_drive}/image/${prev_drive_uuid}" | curl --data-ascii @- -K <(echo "user = "${api_user}:${api_secret}"") -s -H "Content-Type: header" "${api_address}drives/${new_drive}/image/${prev_drive_uuid}" -H 'Expect:' -k`
	
		if [[ $? -ne 0 ]]; then
			logwrite "Create drive command failed, copying from pre-installed UUID" "ERROR"
			unset prev_drive_uuid
		fi
		if [[ $copy_drive_status =~ "failed" ]]; then
			logwrite "Create drive command failed, [$copy_drive_status], copying from pre-installed UUID" "ERROR"
			unset prev_drive_uuid
		fi
		if [[ $copy_drive_status =~ "Internal API error" ]]; then
			logwrite "Create drive command failed, [$copy_drive_status], copying from pre-installed UUID" "ERROR"
			unset prev_drive_uuid
		fi


	fi

	if [[ ! -n $prev_drive_uuid ]]; then
		# prev_drive_uuid is NOT set, copy from pre-built image
		echo "Copying from pre installed image [$pre_install_uuid]"
	
		######
		## Copy from the pre-installed drive to the new drive
		logwrite "Copy from the pre-installed drive [${pre_install_uuid}] to the new drive [${new_drive}]" "INFO"
		copy_drive_status=`echo -e "/drives/${new_drive}/image/${pre_install_uuid}/gunzip" | curl --data-ascii @- -K <(echo "user = "${api_user}:${api_secret}"") -s -H "Content-Type: header" "${api_address}drives/${new_drive}/image/${pre_install_uuid}/gunzip" -H 'Expect:' -k`
	
		if [[ $? -ne 0 ]]; then
			logwrite "Create drive command failed!" "ERROR"
			return 1
		fi
		if [[ $copy_drive_status =~ "failed" ]]; then
			logwrite "Create drive command failed, [$copy_drive_status]" "ERROR"
			return 1
		fi

		echo "Result of copying drive is [$copy_drive_status]"
	fi


	######
	## Wait until the drive is done imaging

	sleep 5 # sleep to verify the imaging started before checking for it

	counter=0
	max=720
	success_counter=0  ## success_counter implemented to catch false positives with the imagine. There are some cases where checking for the imaging status returned null (aka finished) when it really wasn't. Only with several null returns after eachother will flag it as truly finished.
	success_max=5
	while [[ 1 -eq 1 ]]; do
		counter=$(($counter+1))
		imaging_check=`curl -K <(echo "user = "${api_user}:${api_secret}"") -s -H "Content-Type: header" "${api_address}drives/${new_drive}/info" -H 'Expect:' -k | grep "imaging "`
		
		if [[ -n $imaging_check ]]; then

			# reset the success_counter, as it definatly isn't done.
			success_counter=0
		else
			success_counter=$(($success_counter + 1))
		fi
		
		if [[ $success_counter -ge $success_max ]]; then
			logwrite "success_counter [$success_counter] is greater than or equal to succes_max [$success_max], breaking" "DEBUG"
			break
		fi
		if [[ $counter -ge $max ]]; then
			logwrite "Reached the max number of tries [$max] and the drive is still not imaged, exiting!" "ERROR"
			return 1
		fi
		
		# not done imaging, sleep and try again
		sleep 5
		
	done

	######
	## Create the new server using this drive
	slave_info=`echo -e "name ${new_name}\ncpu ${clone_server_mhz}\nmem ${clone_server_mem}\nide:0:0 ${new_drive}\nboot ide:0:0\npersistent true\nvnc auto\npassword ${server_pw}\nnic:0:dhcp auto\nnic:0:model e1000\nsmp auto" | curl --data-binary @- -K <(echo "user = "${api_user}:${api_secret}"") -s  -H "Content-Type: application/octet-stream"  -H 'Expect:' "${api_address}servers/create" -k`

	oldIFS=$IFS
	IFS=$'\n'
	for row in $slave_info; do
	        if [[ $row =~ "nic:0:dhcp:ip" ]]; then
	                slave_ip=`echo $row | grep "nic:0:dhcp:ip" | sed 's/^.* //'`
	        elif [[ $row =~ "server " ]]; then
	                slave_server=`echo $row | grep "server " | sed 's/^.* //'`
	        fi
	done
	IFS=$oldIFS

	if [[ ! -n $slave_ip ]]; then
		logwrite "slave ip is empty, [$slave_ip], exiting!" "ERROR"
		return 1
	fi

	logwrite "Slave IP is [$slave_ip], slave server is [$slave_server]" "INFO"

	return 0	

}


#########################################################################
# rsync_to_slave function
#------------------------------------------------------------------------
# This function will perform the rsync to the new machine. First itt will
# build a list of locations to exclude from the config file. Next it will
# determine what rsync method to use: Rsync with password or Rsync with
# keys.
# If the drive is a copy of a pre-installed image, rsync to user toor 
# with password will be used, using the password randomly generated 
# earlier. Once this machine is brought down, the password will never be 
# used again.
# If the drive is a copy of a previous backup, rsync via keys will be 
# used with user root.
#########################################################################
rsync_to_slave () {
	logwrite "sleeping for 70 seconds" "INFO"
	sleep 70

	# Build the exclude file list from the config file
	oldIFS=$IFS
	IFS='|'
	exclude_str=""
	for i in ${backup_exclude_list}; do
	        exclude_str="$exclude_str --exclude=$i"
	done
	IFS=$oldIFS

	if [[ ! -n $max_rsync_tries ]]; then
		max_rsync_tries=10
	fi
	rsync_counter=0

	# Loop and attempt the rsync until it's successful, or max tries has been reached
	while [[ $rsync_counter -le $max_rsync_tries ]]; do
		rsync_counter=$(($rsync_counter + 1))
		logwrite "Executing rsync, attempt [$rsync_counter]" "INFO"

		# Remove the slave IP entry from known_hosts, if it exists
		grep -v "${slave_ip}" ~/.ssh/known_hosts > ~/.ssh/known_hosts_new;
		mv -f ~/.ssh/known_hosts_new ~/.ssh/known_hosts

		if [[ ! -n $prev_drive_uuid ]]; then

# execute the rsync, assuming the keys do not exist
output=`/usr/bin/expect <<EOF
set timeout -1
spawn rsync --delete -av --numeric-ids -H --one-file-system --delete-after --exclude=/sys/ --exclude=/proc/ --exclude=${config_file} ${exclude_str} / toor@${slave_ip}:/
expect {

default {exit 1}


-re "Are you sure" {
        send "yes\r"
        exp_continue}

-re "password"  {
        send "${server_pw}\r"
        exp_continue}

-re ".*total size.*" {exit 0}

}
EOF`
			result=$?

		else 
			# execute the rsync, assuming the keys exist
			output=`rsync --delete -av --numeric-ids -H --one-file-system --delete-after --exclude=/sys/ --exclude=/proc/ --exclude=${config_file} ${exclude_str} --rsh='ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PasswordAuthentication=no -i /root/.ssh/ohi_backup.pem' / root@${slave_ip}:/ 2>&1`
			result=$?
		fi
		logwrite "result of rsync is [$result] and output is [$output]" "DEBUG"
		
		# Remove the slave IP entry from known_hosts
		grep -v "${slave_ip}" ~/.ssh/known_hosts > ~/.ssh/known_hosts_new;
		mv -f ~/.ssh/known_hosts_new ~/.ssh/known_hosts
	
		if [[ $result -ne 0 ]]; then
			logwrite "Rsync to slave failed, output [$output]" "ERROR"
			sleep 5
			continue
		fi
	
		logwrite "Finished rsync to [${slave_ip}]" "INFO"
		sleep 10

		# add the drive to the list of backups
		echo "${new_drive} ${datestr}" >> $backup_inventory_location
	
		return 0

	done

# if reached here, rsync never executed successfully. Shutdown, and remove the slave and slave drive

shutdown_slave

if [[ $? -ne 0 ]]; then
	logwrite "Could not shutdown the slave machine! Exiting!" "ERROR"
	exit 1
fi

remove_backup_server

if [[ $? -ne 0 ]]; then
	logwrite "Could not remove the backup server! Exiting!" "ERROR"
	exit 1
fi

destroy_drive "${new_drive}"

if [[ $? -ne 0 ]]; then
	logwrite "Could not remove the backup server! Exiting!" "ERROR"
	exit 1
fi

return 1

}


#########################################################################
# exec_local_post_backup function
#------------------------------------------------------------------------
# This function will take the string local_post_script provided in the
# config file and execute it. It will look for 
#########################################################################
exec_local_post_backup () {
	
	# verify the script exists
	if [[ ! -n $local_post_script ]]; then
		logwrite "local_post_script is not set, no post script specified, skipping." "INFO"
		return 0
	fi

	# Verify the script has root-only permissions
	perm_check=`find "$local_post_script" -user root -perm 700 | wc -l`
	if [[ $perm_check -ne 1 ]]; then
		logwrite "The script [$local_post_script] does not have the right permissions. Should be 700 (read/write/executable only by root)" "ERROR"
		return 1
	fi
	unset perm_check
	
	# Execute the script
	logwrite "Executing [$local_post_script]" "INFO"
	"$local_post_script"
	post_script_result=$?
	if [[ $post_script_result -ne 0 ]] || [[ ! -n $post_script_result ]]; then
		logwrite "The local_post_script [$local_post_script] failed, returning a status of [$post_script_result]!" "ERROR"
		return 1
	else
		logwrite "The local_post_script [$local_post_script] returned with a status of [$post_script_result]. Continuing." "INFO"
		return 0
	fi
	 
	return 1
}


#########################################################################
# exec_remote_post_backup function
#------------------------------------------------------------------------
# This function will take the string remote_post_script provided in the
# config file and execute it. It will look for 
#########################################################################
exec_remote_post_backup () {
	
	# verify the script exists
	if [[ ! -n $remote_post_script ]]; then
		logwrite "remote_post_script is not set, no post script specified, skipping." "INFO"
		return 0
	fi

	# Verify the script has root-only permissions
	perm_check=`find "$remote_post_script" -user root -perm 700 | wc -l`
	if [[ $perm_check -ne 1 ]]; then
		logwrite "The script [$remote_post_script] does not have the right permissions. Should be 700 (read/write/executable only by root)" "ERROR"
		return 1
	fi
	unset perm_check
	
	# Execute the script
	logwrite "Executing [$remote_post_script] on remote machine" "INFO"
	ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PasswordAuthentication=no -i /root/.ssh/ohi_backup.pem root@${slave_ip} "$remote_post_script"
	post_script_result=$?
	if [[ $post_script_result -ne 0 ]] || [[ ! -n $post_script_result ]]; then
		logwrite "The remote_post_script [$remote_post_script] failed, returning a status of [$post_script_result]!" "ERROR"
		return 1
	else
		logwrite "The remote_post_script [$remote_post_script] returned with a status of [$post_script_result]. Continuing." "INFO"
		return 0
	fi
	 
	return 1
}


#########################################################################
# shutdown_slave function
#------------------------------------------------------------------------
# This function will simply bring the slave server that was used for the
# rsync offline.
#########################################################################
shutdown_slave () {

	#logwrite "Sleeping 5 seconds" "INFO"
	#sleep 5
	logwrite "Shutting down the slave server [${slave_ip}] - [${slave_server}]" "INFO"
	# Shutdown the slave server
	shutdown_status=`echo -e "servers/${slave_server}/shutdown" | curl --data-ascii @- -K <(echo "user = "${api_user}:${api_secret}"") -f -s -H "Content-Type: header" -H 'Expect:' "${api_address}servers/${slave_server}/shutdown" -H 'Expect:' -k`
	shutdown_result=$?

	logwrite "shutdown status = [$shutdown_status]" "INFO"
	if [[ $shutdown_result -ne 0 ]]; then
		logwrite "Could not shut down the slave server [$slave_server]" "ERROR"
		return 1
	fi
	return 0
}


#########################################################################
# remove_backup_server function	
#------------------------------------------------------------------------
# This function will destroy the server after it's brought down. This
# will only remove the server, not the drive attatched to it.
#########################################################################
remove_backup_server () {

	# server was just shutdown, sleep for ten seconds to allow it to finish if it's still shutting down.
	sleep 60 
	logwrite "Removing the slave server [${slave_ip}] - [${slave_server}]" "INFO"
	# Remove the slave server
	destroy_slave_output=`echo -e "servers/${slave_server}/destroy" | curl --data-ascii @- -K <(echo "user = "${api_user}:${api_secret}"") -f -s -H "Content-Type: header" -H 'Expect:' "${api_address}servers/${slave_server}/destroy" -H 'Expect:' -k`
	destroy_slave_status=$?

	logwrite "destroy status = [$destroy_slave_status]" "INFO"
	if [[ $shutdown_result -ne 0 ]]; then
		logwrite "Could not remove the slave server [$slave_server]" "ERROR"
		return 1
	fi
	return 0
}


#########################################################################
# get_drive_list function
#------------------------------------------------------------------------
# This functino will retrieve a list of the backup drives from the 
# backup drive list file. It will assume that these drives are listed 
# in order from oldest to newest. The list of drives will be in the 
# string $drive_list
#########################################################################
get_drive_list () {

	# get a list of backup drives from newest to oldest

	drive_list=""
	while read line
	do
		set - $line
		backup_uuid=$1
		drive_list="${backup_uuid} ${drive_list}"
	done < ${backup_inventory_location}

	logwrite "result of reading file is [$?] with list as [${drive_list}]" "DEBUG"
	return 0
}


#########################################################################
# prune_backups function
#------------------------------------------------------------------------
# This function will use the maximum number of drives to keep variable
# from the config file and walk through all the backup drives found 
# in the get_drive_list function. Once it determines there is a drive to 
# destroy, it sends its UUID to the destroy_drive function.
#########################################################################
prune_backups () {

	if [[ $max_backups -le 0 ]]; then
		logwrite "max_backups is set to [$max_backups], not pruning anything." "INFO"
		return 0
	fi

	# using the drive_list, we'll walk through it and remove any drives that are past the max backups to keep
	counter=0
	for line in ${drive_list}; do
		counter=$(($counter+1))
		logwrite "backup drive [$line] is number [$counter] max to keep is [$max_backups]" "DEBUG"
		if [[ $counter -gt $max_backups ]]; then

			# destro drive
			destroy_drive "$line"
			destroy_result=$?

			if [[ $destroy_result -eq 0 ]]; then
				logwrite "Destroy drive complete" "INFO"
			elif [[ $destroy_result -eq 2 ]]; then
				logwrite "Could not destroy drive, it's in use" "WARNING"
			else 
				logwrite "Could not destroy drive!" "ERROR"
				return 1
			fi
		fi
	done
}

#########################################################################
# destroy_drive function
#------------------------------------------------------------------------
# This function recieves the UUID of a drive to destroy. First it will 
# check to make sure the drive is not in use. If it is, it returns with 
# a value of 2.
# Next it will execute the destroy drive api call, which will completely
# remove the drive.
# Lastly, it will remove the drive from the backup list file. 
#########################################################################
destroy_drive () {
	
	destroy_drive=$1
	logwrite "Destroying [${destroy_drive}]" "INFO"

	# see if drive is claimed at all
	destroy_drive_output=`curl -K <(echo "user = "${api_user}:${api_secret}"") -f -s -H "Content-Type: header" -H 'Expect:' "${api_address}drives/${destroy_drive}/info" -H 'Expect:' -k | grep "claimed "`

	if [[ -n $destroy_drive_output ]]; then
		logwrite "Drive is currently in use, NOT removing it." "WARNING"
		return 2
	fi

	# destroy the drive
	destroy_drive_output=`echo -e "drives/${destroy_drive}/destroy" | curl --data-ascii @- -K <(echo "user = "${api_user}:${api_secret}"") -f -s -H "Content-Type: header" -H 'Expect:' "${api_address}drives/${destroy_drive}/destroy" -H 'Expect:' -k`

	destroy_result=$?

	logwrite "Destroy output $destroy_output" "INFO"
	if [[ $destroy_result -ne 0 ]]; then
		logwrite "Could not destroy [$destroy_drive] [$destroy_result]! Exiting!" "ERROR"
		return 1
	fi

	cat ${backup_inventory_location} | grep -v "${destroy_drive}" > ${backup_inventory_location}.new
	mv -f ${backup_inventory_location}.new ${backup_inventory_location}

	return 0	

}


#########################################################################
# main process	
#------------------------------------------------------------------------
# All functions have now been defined, step through and execute them
# in order.
#########################################################################

# Exit if the script is already running
check_name=`basename $0`
check_running=`ps -ef | grep "$check_name" | grep "/bin/bash" | grep -v grep | grep -v $$ | wc -l`
if [[ $check_running -ge 1 ]]; then
	exit
fi


logwrite "Starting [`basename $0`]" "INFO"

#############
# verify that the requird programs are installed
#############
if ! type -t curl >/dev/null; then
	logwrite "This tool requires curl" "ERROR"
	bin_check=1
fi
if ! type -t expect >/dev/null; then
	logwrite "This tool requires expect" "ERROR"
	bin_check=1
fi
if ! type -t rsync >/dev/null; then
	logwrite "This tool requires rsync" "ERROR"
	bin_check=1
fi
if [[ $bin_check -eq 1 ]]; then
	exit 1
fi
#############

#############
# process the config file
#############
# Get location of config file
if [[ -n $1 ]]; then
	config_file=$1
else
	config_file="/usr/local/etc/ohi_backup.cfg"
fi

# verify config_file is the full path. This is required in order to exclude it in the rsync.
if [[ ${config_file:0:1} != "/" ]]; then
	logwrite "Config file [$config_file] must be the full path to the file" "ERROR"
	exit 1
fi

# verify the config_file exists
if [[ ! -f $config_file ]]; then
	logwrite "Config file [$config_file] does not exist! Exiting!" "ERROR"
	exit 1
fi

# load the config file
logwrite "Loading the config file [$config_file]" "INFO"
. $config_file
if [[ $? -ne 0 ]]; then
	logwrite "Could not load the config file [$config_file]" "ERROR"
	exit 1
else
	logwrite "Loaded the config file [$config_file]" "INFO"
fi
#############


#############
# Set defaults, and verify all config values are present
#############
if [[ ! -n $api_address ]]; then
	logwrite "api_address not specified in the config file" "ERROR"
	exit 1
fi

if [[ ! -n $api_user ]]; then
	logwrite "api_user not specified in the config file" "ERROR"
	exit 1
fi

if [[ ! -n $api_secret ]]; then
	logwrite "api_secret not specified in the config file" "ERROR"
	exit 1
fi

if [[ ! -n $clone_server_mhz ]]; then
	logwrite "clone_server_mhz not specified in the config file, setting it to default 500" "WARNING"
	clone_server_mhz=500
fi

if [[ $clone_server_mhz -lt 500 ]]; then
	logwrite "clone_server_mhz minimum is 500, value specified is [$clone_server_mhz], setting it to default 500" "WARNING"
	clone_server_mhz=500
fi

if [[ ! -n $clone_server_mem ]]; then
	logwrite "clone_server_mem not specified in the config file, setting it to default 256" "WARNING"
	clone_server_mem=256
fi

if [[ $clone_server_mem -lt 256 ]]; then
	logwrite "clone_server_mem minimum is 256, value specified is [$clone_server_mem], setting it to default 256" "WARNING"
	clone_server_mem=256
fi

if [[ ! -n $backup_tag ]]; then
	logwrite "backup_tag not specified in the config file, setting it to default [_ohibackup_]" "WARNING"
	backup_tag="_ohibackup_"
fi

if [[ ! -n $max_backups ]]; then
	logwrite "max_backups not specified in the config file, setting it to default [5]" "WARNING"
	max_backups=5
fi

if [[ ! -n $pre_install_uuid ]]; then
	logwrite "pre_install_uuid not specified in the config file" "ERROR"
	exit 1
fi

if [[ ! -n $backup_inventory_location ]]; then
	logwrite "backup_inventory_location not specified in the config file, setting it to default [/usr/local/etc/backup_drives.lst]" "WARNING"
	backup_inventory_location="/usr/local/etc/backup_drives.lst"
fi

if [[ ! -n $incremental_backup ]]; then
	logwrite "incremental_backup not specified in the config file, setting to default [true]" "WARNING"
	incremental_backup="true"
fi

if [[ $incremental_backup != "true" ]] && [[ $incremental_backup != "false" ]]; then
	logwrite "incremental_backup set to [$incremental_backup], should be either [true] or [false]. Exiting" "ERROR"
	exit 1
fi

dir_check=$(dirname $backup_inventory_location)
if [[ ! -e $backup_inventory_location ]]; then
	logwrite "File [$backup_inventory_location] does not exist, creating it" "INFO"
	touch $backup_inventory_location
	if [[ $? -ne 0 ]]; then
	
		if [[ ! -d $dir_check ]]; then
			logwrite "Could not create [$backup_inventory_location], directory does not exist" "ERROR"
			exit 1
		fi
	fi
fi
		
#############

#############
# Verify that the ssh keys are set up
#############
priv_key_file="/root/.ssh/ohi_backup.pem"
pub_key_file="/root/.ssh/ohi_backup.pem.pub"
if [[ ! -e $priv_key_file ]] || [[ ! -e $pub_key_file ]]; then
	rm -f $priv_key_file
	rm -f $pub_key_file
	logwrite "key file doesn't exist, generating it" "INFO"
	rm -f $pub_key_file
	ssh-keygen -t rsa -f /root/.ssh/ohi_backup.pem -N ''
	touch ~/.ssh/known_hosts
	cat /root/.ssh/ohi_backup.pem.pub >> ~/.ssh/authorized_keys
	chmod 600 ~/.ssh/authorized_keys
	chmod 700 ~/.ssh
fi

# Verify the authorized_keys file has the public key i it
pub_contents=`cat /root/.ssh/ohi_backup.pem.pub`
auth_keys=`cat /root/.ssh/authorized_keys`
if [[ $? -ne 0 ]]; then
	logwrite "The authorized_keys file could not be read, exiting!" "ERROR"
	exit 1
fi
pub_check=`echo $auth_keys | grep "$pub_contents" | wc -l`

if [[ $pub_check -eq 0 ]]; then
	logwrite "The authorized_keys file does not have the public key in it, adding it." "WARNING"
	cat /root/.ssh/ohi_backup.pem.pub >> ~/.ssh/authorized_keys
fi
#############


#########################################################################
# execute the master check
#########################################################################

master_check

if [[ $? -ne 0 ]]; then
	logwrite "Could not determine if I am the master! Exiting!" "ERROR"
	exit 1
fi

#########################################################################
# execute the local pre-backup script
#########################################################################

exec_local_pre_backup

if [[ $? -ne 0 ]]; then
	logwrite "Executing [$local_pre_script] failed! Aborting backup process!" "ERROR"
	exit 1
fi

#########################################################################
# generate slave image	
#########################################################################

gen_slave_image

if [[ $? -ne 0 ]]; then
	logwrite "Could not create the slave image! Exiting!" "ERROR"
	exit 1
fi

#########################################################################
# rsync to slave
#########################################################################

rsync_to_slave

if [[ $? -ne 0 ]]; then
	logwrite "Could not rsync to the slave machine! Exiting!" "ERROR"
	exit 1
fi


#########################################################################
# execute the local post-backup script
#########################################################################

exec_local_post_backup

if [[ $? -ne 0 ]]; then
	logwrite "Executing [$local_post_script] failed!" "ERROR"
fi


#########################################################################
# execute the local post-backup script
#########################################################################

exec_remote_post_backup

if [[ $? -ne 0 ]]; then
	logwrite "Executing [$remote_post_script] failed!" "ERROR"
fi


#########################################################################
# shutdown slave
#########################################################################

shutdown_slave

if [[ $? -ne 0 ]]; then
	logwrite "Could not shutdown the slave machine! Exiting!" "ERROR"
	exit 1
fi


#########################################################################
# destroy server
#########################################################################

remove_backup_server

if [[ $? -ne 0 ]]; then
	logwrite "Could not remove the backup server! Exiting!" "ERROR"
	exit 1
fi

#########################################################################
# get drive list
#########################################################################

get_drive_list

if [[ $? -ne 0 ]]; then
	logwrite "Could not get the server list! Exiting!" "ERROR"
	exit 1
fi

#########################################################################
# prune backups
#########################################################################

prune_backups

if [[ $? -ne 0 ]]; then
	logwrite "Could not prune the backup servers! Exiting!" "ERROR"
	exit 1
fi

logwrite "Finished [`basename $0`]" "INFO"
