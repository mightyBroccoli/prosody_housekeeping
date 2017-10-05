#!/bin/bash

#
# housecleaning script for prosody
#

# // TODO
# 1. delete Spectrum2 old users

###### CONFIGURATION ######
# configuration variables
tmp_directory=/tmp/prosody/
logfile=/var/log/prosody/housekeeping.log
unused_accounts=$tmp_directory/unused_accounts.txt
old_accounts=$tmp_directory/old_accounts.txt
junk_to_delete=$tmp_directory/junk_to_delete.txt
dbjunk_to_delete=tmp_directory/dbjunk_to_delete.txt
prepared_list=$tmp_directory/prepared_list.txt

# external config file
configfile=$tmp_directory/.user.config
configfile_secured=$tmp_directory/tmp.config
backupconf=/var/backups/prosody_housekeeping.user.config


###### PRE RUN FUNCTION SECTION ######
prerun_check()
{
	# check if all commands needed to run are present in $PATH
	needed_commands="printf mkdir ls echo grep cat date prosodyctl"
	missing_counter=0
	for needed_command in $needed_commands; do
		if ! hash "$needed_command" >/dev/null 2>&1 ; then
			log_to_file "Command not found in PATH: %s\\n" "$needed_command" >&2
			((missing_counter++))
		fi
	done

	if ((missing_counter > 0)); then
		log_to_file "Minimum %d commands are missing in PATH, aborting\\n" "$missing_counter" >&2
		exit 11
	fi

	#check if tmp directory is present if not create it
	if [ ! -d "$tmp_directory" ]; then
		mkdir -p "$tmp_directory"
	fi

	#first run check
	# check for presents of the configfile if not exit
	if [ ! -f "$configfile" ]; then
		if [ -f "$backupconf" ]; then
			log_to_file "no config inside $tmp_directory using $backupconf"
			cp "$backupconf" "$configfile"
		else
			#config file is not present
			log_to_file "no config file has been set. copy the sample config file to $configfile"
			exit 10
		fi
	else
		# copy config file to /var/backups
		cp "$configfile" "$backupconf"
	fi

	# check if config file contains something we don't want
	if	grep -E -q -v '^#|^[^ ]*=[^;]*' "$configfile"; then
		grep -E '^#|^[^ ]*=[^;&]*'  "$configfile" > "$configfile_secured"
		configfile="$configfile_secured"
	fi

	# source the config file
	source  "$configfile"

	# clear env
	clearcomp
}

catch_help()
{
	# catch  -h / --help
	if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
		display_help
		exit
	fi
}

catch_configtest()
{
	# test your configuration first to see what would have be deleted
	if [ "$1" == "-t" ] || [ "$1" == "--configtest" ]; then
		filter_unused_accounts
		filter_old_accounts
		filter_mam_messages --test

		echo -e "Registration expired: \\n$unused_accounts\\n"
		echo -e "Unused Accounts: \\n$old_accounts"
		echo -e "MAM Messages marked for deletion: \\n$junk_to_delete"
		exit
	fi
}

display_help()
{
	echo -e "Prosody housecleaning script"
	echo -e "Workflow"
	echo -e "1. Filter registered but unused accounts from Database \\n2. Filter Account that have been inactive for too long\\n3. Remove expired Messaged from Prosodys MAM from the Database\\n4. Remove the selected Accounts\\n"
	echo -e "There are some major variables needed to be set:"
	echo -e "1. maximum age of registered but unused accounts\\n2. maximum age of unused accounts\\n3. maximum age of mod_mam records\\n4. Prosodys Database login credentials"
}

###### FILTER SECTION ######
filter_unused_accounts()
{
	# only run this filter if its enabled
	if [ "$enable_unused" = "true" ]; then
		# filter all registered but not logged in accounts older then $unused_accounts_timeframe
		prosodyctl mod_list_inactive "$host" "$unused_accounts_timeframe" event | grep registered | sed 's/registered//g' >> "$unused_accounts"

		# // TODO
		# ignore specific users
		# also remove offline messages and stuff
	fi
}

filter_old_accounts()
{
	if [ "$enable_old" = "true" ]; then
		# filter all inactive accounts older then $old_accounts_timeframe
		prosodyctl mod_list_inactive "$host" "$old_accounts_timeframe" >> "$old_accounts"

		# // TODO
		# ignore specific users
		# also remove offline messages and stuff
	fi
}

filter_expired_http_uploads()
{
	if [ "$enable_mam_clearing" = "true" ]; then
		# currently a workaround as the mod_http_uploud is not removing the folder which holds the file
		find "$http_upload_path"/* -maxdepth 0 -type d -mtime +"$http_upload_expire" >> "$junk_to_delete"
	fi
}

filter_mam_messages()
{
	# only run this filter if $enable_mam_clearing is set to true
	if [ "$enable_mam_clearing" = "true" ]; then
		# catch config test
		if [ "$1" = "--test" ]; then
			# this is currently a workaround caused by the extrem slowness of prosodys own clearing mechanism
			# filter all expired mod_mam messages from archive
			echo "SELECT * FROM prosody.prosodyarchive WHERE \`when\` < UNIX_TIMESTAMP(DATE_SUB(curdate(),INTERVAL $mam_message_live));" | mysql -u "$prosody_db_user" -p"$prosody_db_password" &>> "$dbjunk_to_delete"
			return 1
		fi
		# this is currently a workaround caused by the extrem slowness of prosodys own clearing mechanism
		# delete all expired mod_mam messages from archive
		echo "DELETE FROM prosody.prosodyarchive WHERE \`when\` < UNIX_TIMESTAMP(DATE_SUB(curdate(),INTERVAL $mam_message_live));" | mysql -u "$prosody_db_user" -p"$prosody_db_password"
	fi
}

###### General Functions ######
clearcomp()
{
	if [ "$1" = "-removal" ]; then
		# run the created script to delete the selected accounts
		bash "$prepared_list"

		#remove all tmp files and variables for privacy reasons
		rm -f "$unused_accounts" "$old_accounts" "$prepared_list" "$junk_to_delete"
		unset unused_accounts_timeframe old_accounts_timeframe host mam_message_live enable_mam_clearing prosody_db_user prosody_db_password accounts_to_delete prepared_list
	fi

	# remove the temp files
	rm -f "$accounts_to_delete"
}

prepare_execution()
{
	# prepare selected user list to be removed
	sed -e 's/^/prosodyctl deluser /' "$unused_accounts $old_accounts" > "$prepared_list"

	# prepare folder list to be removed
	sed -e 's/^/rm -rf /' "$junk_to_delete" >> "$prepared_list"

	if [ "$logging" = "true" ]; then
		{	sed -e 's/^/Registration expired: /' "$unused_accounts"
			sed -e 's/^/Account expired: /' "$old_accounts"
			sed -e 's/^/Folder: ""/' "$junk_to_delete" | sed 's/$/" has been marked for removal./'
		} >> log_to_file
	fi
}

log_to_file()
{
	# ghetto logging
	echo "[$(date --rfc-3339=seconds)] - $*" >> "$logfile"
}

###### MAIN CODE SECTION ######
# catch user help input
catch_help "$@"
# check env and some tests
prerun_check
# catch user config test
catch_configtest "$@"

# unused accounts filter
filter_unused_accounts
# old accounts filter
filter_old_accounts
# epired mod_mam filter
filter_mam_messages

# prepare the userlist for removal
prepare_execution
# final step cleanup
clearcomp -removal
