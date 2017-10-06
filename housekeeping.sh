#!/bin/bash

#
# housecleaning script for prosody
#

# // TODO
# 1. delete Spectrum2 old users

###### CONFIGURATION ######
# configuration variables
tmp_directory=/tmp/prosody
logfile=/var/log/prosody/housekeeping.log
composition=$tmp_directory/composition.txt
unused_accounts=$tmp_directory/unused_accounts.txt
old_accounts=$tmp_directory/old_accounts.txt
junk_to_delete=$tmp_directory/junk_to_delete.txt
dbjunk_to_delete=$tmp_directory/dbjunk_to_delete.txt
prepared_list=$tmp_directory/prepared_list.txt

# external config file
configfile=$tmp_directory/.user.config
configfile_secured=$tmp_directory/tmp.config
backupconf=/var/backups/prosody_housekeeping.user.config

# external ignore file
ignored_accounts=$tmp_directory/ignored_accounts.txt

###### PRE RUN FUNCTION SECTION ######
prerun_check()
{
	# check if all commands needed to run are present in $PATH
	needed_commands="printf mkdir ls echo grep cat date prosodyctl"
	missing_counter=0
	for needed_command in $needed_commands; do
		if ! hash "$needed_command" >/dev/null 2>&1 ; then
			log_to_file "$(printf "Command not found in PATH: %s\\n" "$needed_command" >&2)"
			((missing_counter++))
		fi
	done

	if ((missing_counter > 0)); then
		log_to_file "$(printf "Minimum %d commands are missing in PATH, aborting\\n" "$missing_counter" >&2)"
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
			log_to_file "$(echo "no config inside $tmp_directory using $backupconf")"
			cp "$backupconf" "$configfile"
		else
			#config file is not present
			log_to_file "$(echo "no config file has been set. copy the sample config file to $configfile")"
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
	source  $configfile

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
		filter_expired_http_uploads
		filter_mam_messages --test

		# Only present files if they are present
		if [ -s $unused_accounts ]; then
			echo -e "Registration expired: \\n$(cat $unused_accounts)\\n"
		fi

		if [ -s $old_accounts ]; then
			echo -e "unused Accounts: \\n$(cat $old_accounts)\\n"
		fi

		if [ -s $junk_to_delete ]; then
			echo -e "expired HTTP_Upload Folders: \\n$(cat $junk_to_delete)\\n"
		fi

		if [ -s $dbjunk_to_delete ]; then
			echo -e "MAM Entries marked for deletion: \\n$(cat $dbjunk_to_delete)\\n"
		fi
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
	# clear composition
	rm -f $composition

	# only run this filter if its enabled
	if [ "$enable_unused" = "true" ]; then
		# filter all registered but not logged in accounts older then $unused_accounts_timeframe
		prosodyctl mod_list_inactive "$host" "$unused_accounts_timeframe" event | grep registered | sed 's/registered//g' >> "$composition"

		# filter out ignored accounts
		if [ -f "$ignored_accounts" ]; then
			# check if there is an ignore file if not skip
			filter_ignored_accounts "$composition" "$unused_accounts"
		fi
	fi
}

filter_old_accounts()
{
	# clear composition
	rm -f $composition

	if [ "$enable_old" = "true" ]; then
		# filter all inactive accounts older then $old_accounts_timeframe
		prosodyctl mod_list_inactive "$host" "$old_accounts_timeframe" >> "$composition"

		# filter out ignored accounts
		if [ -f "$ignored_accounts" ]; then
			# check if there is an ignore file if not skip
			filter_ignored_accounts "$composition" "$old_accounts"
		fi
	fi
}

filter_ignored_accounts()
{
	# compare $ignored_accounts to selected accounts only parsing those not ignored
	grep -v -F -x -f $ignored_accounts "$1" > "$2"
}

filter_expired_http_uploads()
{
	if [ "$enable_http_upload" = "true" ]; then
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
			echo "SELECT * FROM prosody.prosodyarchive WHERE \`when\` < UNIX_TIMESTAMP(DATE_SUB(curdate(),INTERVAL $mam_message_live)) and \`store\` != \"offline\";" | mysql -u "$prosody_db_user" -p"$prosody_db_password" &>> "$dbjunk_to_delete"
			return 1
		fi
		# this is currently a workaround caused by the extrem slowness of prosodys own clearing mechanism
		# delete all expired mod_mam messages from archive
		echo "DELETE FROM prosody.prosodyarchive WHERE \`when\` < UNIX_TIMESTAMP(DATE_SUB(curdate(),INTERVAL $mam_message_live)) and \`store\` != \"offline\";" | mysql -u "$prosody_db_user" -p"$prosody_db_password"
	fi
}

###### General Functions ######
clearcomp()
{
	if [ "$1" = "-removal" ]; then
		# run the created script to delete the selected accounts
		bash "$prepared_list"

		# removal of tmp files
		rm -f "$composition" "$unused_accounts" "$old_accounts" "$junk_to_delete" "$dbjunk_to_delete" "$prepared_list"

		# remove variables for privacy reasons	
		unset tmp_directory logfile composition unused_accounts old_accounts junk_to_delete dbjunk_to_delete prepared_list logging host enable_unused unused_accounts_timeframe enable_old
		unset old_accounts_timeframe enable_mam_clearing mam_message_live prosody_db_user prosody_db_password enable_http_upload http_upload_path http_upload_expire
		exit
	fi

	# removal of tmp files
	rm -f "$composition" "$unused_accounts" "$old_accounts" "$junk_to_delete" "$dbjunk_to_delete" "$prepared_list"
}


prepare_execution()
{
	if [ -s $unused_accounts ]; then
		# prepare selected user list to be removed
		sed -e 's/^/prosodyctl deluser /' "$unused_accounts" >> "$prepared_list"

		if [ "$logging" = "true" ]; then
			# read the files line by line and prepend and append some info
			while read -r line; do
				log_to_file "$(echo -e "$line" | sed -e 's/^/Registration expired: /')"
			done < "$unused_accounts"
		fi
	fi

	if [ -s $old_accounts ]; then
		# prepare selected user list to be removed
		sed -e 's/^/prosodyctl deluser /'  "$old_accounts" >> "$prepared_list"

		if [ "$logging" = "true" ]; then
			# read the files line by line and prepend and append some info
			while read -r line; do
				log_to_file "$(echo -e "$line" | sed -e 's/^/Account expired: /')"
			done < "$old_accounts"
		fi
	fi

	if [ -s $junk_to_delete ]; then
		# prepare folder list to be removed
		sed -e 's/^/rm -rf /' "$junk_to_delete" >> "$prepared_list"

		if [ "$logging" = "true" ]; then
			# read the files line by line and prepend and append some info
			while read -r line; do
				log_to_file "$(echo -e "$line" | sed -e 's/^/Folder: "/' | sed 's/$/" has been marked for removal./')"
			done < "$old_accounts"
		fi
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

# filter expired http_upload folders
filter_expired_http_uploads

# epired mod_mam filter
filter_mam_messages

# prepare the userlist for removal
prepare_execution

# final step cleanup
clearcomp -removal
