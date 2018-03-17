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
prepared_accounts=$tmp_directory/prepared_accounts.txt

# external config file
script_version="1.0.1"
configfile=$tmp_directory/.user.config
configfile_secured=$tmp_directory/tmp.config
backupconf=/var/backups/prosody_housekeeping.user.config

# external ignore file
ignored_accounts=$tmp_directory/ignored_accounts.txt
ignore_backup=/var/backups/prosody_housekeeping.ignored_accounts.backup

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

		# exit code for missing commands in PATH
		exit 11
	fi

	# check if everything is present if not create it
	if [ ! -d "$tmp_directory" ]; then
		mkdir -p "$tmp_directory"
	fi

	if [ ! -f "$ignored_accounts" ]; then
		touch $ignored_accounts
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

			# exit code for missing config file
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
	# shellcheck source=$tmp_directory/.user.config
	# shellcheck disable=SC1091
	source  $configfile

	# check if the latest config version is used to prevent bad stuff from happening
	if [ ! "$script_version" == "$conf_version" ]; then
		# throw error on outdated config file
		log_to_file "Error: Your config file is outdated. Please update your config file to proceed."

		# exit code for outdated config file
		exit 2
	fi

	# checking if ignore file is present
	if [ ! -f "$ignored_accounts" ]; then
		if [ -f "ignore_backup" ]; then
			log_to_file "ignore file missing, using backup $ignore_backup"
			cp "$ignore_backup" "ignored_accounts"
		else
			log_to_file "no ignore file present,creating one ..."
			touch "$ignored_accounts"
		fi
	else
		# copy ignore file to /var/backups
		cp "$ignored_accounts" "$ignore_backup"
	fi

	# clear env
	clearcomp
}

catch_help()
{
	# catch  -h / --help
	if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
		display_help

		# gracefull exit
		exit 0
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
			printf "Registration expired:\\n%s\\n" "$(<$unused_accounts)"
		fi

		if [ -s $old_accounts ]; then
			printf "unused Accounts:\\n%s\\n" "$(<$old_accounts)"
		fi

		if [ -s $junk_to_delete ]; then
			printf "expired HTTP_Upload Folders:\\n%s\\n" "$(<$junk_to_delete)"
		fi

		if [ -s $dbjunk_to_delete ]; then
			printf "MAM Entries marked for deletion:\\n%i\\n" "$(< $dbjunk_to_delete wc -l)"
		fi

		# gracefully exit the config test
		exit 0
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
	for tld in "${host[@]}"; do
		# only run this filter if its enabled
		if [ "$enable_unused" = "true" ]; then
			# filter all registered but not logged in accounts older then $unused_accounts_timeframe
			prosodyctl mod_list_inactive "$tld" "$unused_accounts_timeframe" event | grep registered | sed 's/registered//g' > "$composition"

			# if there are any accounts selected
			if [ -s "$composition" ]; then
				# filter out ignored accounts
				filter_ignored_accounts > "$unused_accounts"
			fi
		fi
	done
}

filter_old_accounts()
{
	for tld in "${host[@]}"; do
		# only run this filter if its enabled
		if [ "$enable_old" = "true" ]; then
			# filter all accounts logged out $old_accounts_timeframe in the past
			prosodyctl mod_list_inactive "$host" "$old_accounts_timeframe" event | grep logout | sed 's/logout//g' | sed 's/ //g' > "$composition"

			# if there are any accounts selected
			if [ -s "$composition" ]; then
				# filter out ignored accounts
				filter_ignored_accounts > "$old_accounts"
			fi
		fi
	done
}

filter_ignored_accounts()
{
	# prepare the ignore list
	# remove spaces and empty lines
	# sort and remove duplicates
	sed 's/ //g' $ignored_accounts | sed '/^$/d' | sort | uniq > $tmp_directory/ignored_accounts_prepared.txt

	# copy newly edited ignore list
	mv $tmp_directory/ignored_accounts_prepared.txt $ignored_accounts

	# compare $ignored_accounts to selected accounts only parsing those not ignored
	grep -Fvf $ignored_accounts $composition
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
		# this is currently a workaround caused by the extrem slowness of prosodys own clearing mechanism
		# filter all expired mod_mam messages from archive
		echo "SELECT * FROM prosody.prosodyarchive WHERE \`when\` < UNIX_TIMESTAMP(DATE_SUB(curdate(),INTERVAL $mam_message_live)) and \`store\` LIKE \"archive%\";" | mysql -u "$prosody_db_user" -p"$prosody_db_password" &>> "$dbjunk_to_delete"

		# catch config test
		if [ "$1" = "--test" ]; then
			return 0
		fi

		# this is currently a workaround caused by the extrem slowness of prosodys own clearing mechanism
		# delete all expired mod_mam messages from archive
		echo "DELETE FROM prosody.prosodyarchive WHERE \`when\` < UNIX_TIMESTAMP(DATE_SUB(curdate(),INTERVAL $mam_message_live)) and \`store\` LIKE \"archive%\";" | mysql -u "$prosody_db_user" -p"$prosody_db_password"

		# only log this if garbage collection actually deleted stuff
		if [ -s $dbjunk_to_delete ]; then
			log_to_file "MAM garbage collection removed $(wc -l < $dbjunk_to_delete) lines from the database."
		fi
	fi
}

###### General Functions ######
log_to_file()
{
	# ghetto logging
	echo "[$(date --rfc-3339=seconds)] - $*" >> "$logfile"
}

prepare_execution()
{
	if [ -s "$unused_accounts" ]; then
		rm -f "$composition"
		# prepare selected user list to be removed
		while read -r line; do
			if [ "$logging" = "true" ]; then
				# read the files line by line and prepend and append some info
				log_to_file "$(echo -e "$line" | sed -e 's/^/Registration expired: /')"
			fi
				echo "user:delete([[$line]])" >> "$composition"
		done < "$unused_accounts"

		# concatenate all accounts together for removal
		cat "$composition" >> "$prepared_accounts"
	fi

	if [ -s "$old_accounts" ]; then
		rm -f "$composition"
		# prepare selected user list to be removed
		while read -r line; do
			if [ "$logging" = "true" ]; then
				# read the files line by line and prepend and append some info
				log_to_file "$(echo -e "$line" | sed -e 's/^/Account expired: /')"
			fi
				echo "user:delete([[$line]])" >> "$composition"
		done < "$old_accounts"

		# concatenate all accounts together for removal
		cat "$composition" >> "$prepared_accounts"
	fi
}

clearcomp()
{
	if [ "$1" = "-removal" ]; then
		# hand the deletion to the prosody telnet interface
		if [ -s $prepared_accounts ]; then
			(
			while read -r line; do
				echo "$line"
			done < "$prepared_accounts"
			echo quit
			) | nc localhost 5582 &>/dev/null
		fi

		# run the created script to delete the selected accounts
		if [ -s $junk_to_delete ]; then
			while read -r line; do
				if [ "$logging" = "true" ]; then
					log_to_file "$(echo -e "$line" | sed -e 's/^/Folder: "/' | sed 's/$/" has been marked for removal./')"
				fi
				rm -rf "$line"
			done < "$junk_to_delete"
		fi

		# ISSUE #5
		# workaround to list out all users deleted by this to later be removed from spectrum2 db
		if [ -s $old_accounts ]; then
			cat "$old_accounts" >> /var/backups/prosody_housekeeping_spectrum2_accounts.txt
		fi

		# removal of tmp files
		rm -f "$composition" "$unused_accounts" "$old_accounts" "$junk_to_delete" "$dbjunk_to_delete" "$prepared_accounts"

		# remove variables for privacy reasons
		unset tmp_directory logfile composition unused_accounts old_accounts junk_to_delete dbjunk_to_delete prepared_accounts logging host enable_unused unused_accounts_timeframe enable_old
		unset old_accounts_timeframe enable_mam_clearing mam_message_live prosody_db_user prosody_db_password enable_http_upload http_upload_path http_upload_expire
		exit 0
	fi

	# removal of tmp files
	rm -f "$composition" "$unused_accounts" "$old_accounts" "$junk_to_delete" "$dbjunk_to_delete" "$prepared_accounts"
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
