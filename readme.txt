Open Hosting API Backup (OAB)  

A few things to consider:

1. OAB is made available with no warranty.
2. OAB is free to use and free to modify.
3. OAB has been tested on OHI’s pre-installed CentOS 5.6.  And, while we expect it to work with any of our pre-installed images, the configurations will vary slightly.  


Below are two sets of instructions: the first guides you through the installation and configuration of the backup process itself, while the second explains how to schedule the automated execution of the process with Cron.

Installation and configuration of OAB:

1. 	OAB requires a few programs:

  	cron & vixie-cron, which are used to automate the execution of the script
	curl – used to connect to the api
	rsync – used to copy the data to the target machine (required on the target machine also)
	expect – used to execute the rsync without user input
	
	All of these programs are already present on our pre-installed CentOS 5.6 image.

2. 	Copy the code over to your server:

	# scp ohi_backup.tar.gz toor@<IP address>:.


3. 	Login to your server and unpack the file:  

	# tar -xzvf ohi_backup.tar.gz


4.	Make the script executable: 

	# chmod +x ohi_backup/bin/ohi_backup.sh


5. 	Copy the code and config to the /usr/local/ directory tree.

	# cp ohi_backup/bin/ohi_backup.sh /usr/local/bin/.
	# cp ohi_backup/etc/ohi_backup.* /usr/local/etc/.


6. 	Edit the config to the correct parameters.

	# vi /usr/local/etc/ohi_backup.cfg

	These lines most be edited before your first use:

	api_user
	api_secret

	And this line must be edited if you're not not using CentOS 5.6:

	pre_install_uuid
           

7. 	And, test OAB by executing it manually:

       # /usr/local/bin/ohi_backup.sh /usr/local/etc/ohi_backup.cfg


We've also included a script to install a job that will run OAB every 24 hours. 
How to schedule the automated execution of the process with Cron:

1. 	Set the backup scripts permissions:

	# chmod 700 /usr/local/bin/ohi_backup.sh
	# chmod 600 /usr/local/etc/ohi_backup.cfg
	

2. 	Make the installer script executable:

	# chmod +x ohi_backup/bin/ohi_backup_cron_installer.sh


3. 	When executing the installer script, it will ask for the full paths to ohi_backup.sh and ohi_backup.cfg. If these are left blank, it uses default values of "/usr/local/bin/ohi_backup.sh" and "/usr/local/etc/ohi_backup.cfg". The installer will then check to ensure that these two input strings don't already have an entry into cron. It also does some initial checks ensure that it's only run as root, and both the ohi_backup.cfg file and the ohi_backup.sh file are only read/write/executable via root.
	
	Run the installer script: 

	#./ohi_backup/bin/ohi_backup_cron_installer.sh


4. Confirm successful entry by viewing cron list with:

	# crontab -l


5.  Finally, ensure cron is running:

	# service crond start




