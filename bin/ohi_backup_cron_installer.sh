#!/bin/bash

###
# Verify this is being run as root.
if [[ `whoami` != "root" ]]; then
	echo "ERROR: Script can only be run as root"
	exit 1
fi

###
# Get the script path
echo -n "Enter the full path to the ohi_backup.sh script (Default: /usr/local/bin/ohi_backup.sh): "
read ohi_backup 

if ! [[ -n $ohi_backup ]]; then
	ohi_backup="/usr/local/bin/ohi_backup.sh"
fi

# Verify the script is the FULL path
if [[ ${ohi_backup:0:1} != "/" ]]; then
        echo "ERROR: Must use the full path to the file."
        exit 1
fi

# Verify the script exists
if ! [[ -e $ohi_backup ]]; then
	echo "ERROR: [$ohi_backup] does not exist!"
	exit 1
fi

# Verify the script can only be run by root
perm_check=`find "$ohi_backup" -user root -perm 700 | wc -l`
if [[ $perm_check -ne 1 ]]; then
	echo
	echo "ERROR: The script [$ohi_backup] does not have the right permissions. Should be 700 (read/write/executable only by root)." 
	echo "This can be done by running "
	echo "# chmod 700 $ohi_backup"
	echo
	exit 1
fi

###
# Verify the config path
echo -n "Enter the full path to the ohi_backup.cfg config file (Default: /usr/local/etc/ohi_backup.cfg): "
read ohi_config 


if ! [[ -n $ohi_config ]]; then
	ohi_config="/usr/local/etc/ohi_backup.cfg"
fi

# Verify the config file is the full path
if [[ ${ohi_config:0:1} != "/" ]]; then
        echo "ERROR: Must use the full path to the file."
        exit 1
fi

# Verify the config file exists
if ! [[ -e $ohi_config ]]; then
	echo "ERROR: [$ohi_config] does not exist!"
	exit 1
fi

# Verify the config file can only be run by root
perm_check=`find "$ohi_config" -user root -perm 600 | wc -l`
if [[ $perm_check -ne 1 ]]; then
	echo
	echo "ERROR: The config file [$ohi_config] does not have the right permissions. Should be 600 (read/write only by root)." 
	echo "This can be done by running "
	echo "# chmod 600 $ohi_config"
	echo
	exit 1
fi

###
# Check to see if cron already has an entry for this script
cron_check=`crontab -u root -l | grep "$ohi_backup $ohi_config" | wc -l`

if [[ $cron_check -gt 0 ]]; then
	echo "Found an entry of the script in cron already, not adding a new one"
	crontab -u root -l | grep "$ohi_backup $ohi_config"
	exit
fi

###
# Generate two random numbers for use in crontab
minute=$RANDOM
let "minute %= 60"
hour=$RANDOM
let "hour %= 5"
day=$RANDOM
let "day %= 7"

if [[ ! $minute ]]; then
	echo "ERROR: Could not generate the minute variable"
	exit 1;
fi
if [[ ! $hour ]]; then
	echo "ERROR: Could not generate the hour variable"
	exit 1;
fi

echo "Adding entry [$minute $hour * * $day $ohi_backup $ohi_config > /dev/null] to cron"

# Add the new entry to cron
crontab -u root -l > /tmp/tmp.root.cron
echo "$minute $hour * * $day $ohi_backup $ohi_config > /dev/null" >> /tmp/tmp.root.cron
crontab -u root /tmp/tmp.root.cron
rm -f /tmp/tmp.root.cron
echo "Finished adding entry to cron. View cron list with:"
echo "# crontab -l"
echo

